## Font descriptors and the font family registry. Pure Nim, no SDL.
##
## A `FontSpec` is a plain value (like VCL's TFont): it names a family, a
## logical size and a style. It holds no SDL handle; the `RenderContext`
## resolves it to a rasterised font at `size * scale` when text is drawn.

import std/[os, tables, sets, strutils, algorithm, streams]
from std/unicode import Rune, toUTF8
when not (defined(windows) or defined(macosx)): import std/osproc
import ./color

type
  FontStyle* = enum
    fsBold, fsItalic, fsUnderline, fsStrikeOut

  FontSpec* = object
    ## Font descriptor. `family` "" means the default family ("sans").
    family*: string
    size*: float32            ## logical pixels
    style*: set[FontStyle]
    color*: Color             ## text colour (VCL `Font.Color`); alpha 0 (the default) means the theme's text colour

  FontFiles = object
    regular, bold, italic, boldItalic: string

  SysVariant = object
    path: string              ## "" = the family is not installed
    bold, italic: bool        ## what the file really is (else the style is synthesised)

  ResolvedFont* = object
    ## Result of resolving a `FontSpec` against the registry.
    path*: string             ## TTF file to open
    ttfStyle*: uint32         ## SDL_ttf style flags (synthetic bold/italic only; underline and strike-out are drawn by the Canvas)
    isSystem*: bool           ## the file comes from the operating system's fonts (fontconfig)

const
  CjkCandidates = [
    # Noto Sans CJK: Arch (noto-fonts-cjk), Debian/Ubuntu, Fedora, openSUSE
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/OTF/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-DemiLight.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Medium.ttc",
    # Noto Serif CJK
    "/usr/share/fonts/noto-cjk/NotoSerifCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSerifCJK-Regular.ttc",
    # WenQuanYi
    "/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    "/usr/share/fonts/wqy-microhei/wqy-microhei.ttc",
    "/usr/share/fonts/wenquanyi/wqy-zenhei/wqy-zenhei.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc",
    # Droid Sans Fallback
    "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
    "/usr/share/fonts/droid/DroidSansFallbackFull.ttf",
    "/usr/share/fonts/TTF/DroidSansFallback.ttf",
    # macOS
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
    # Windows (the Fonts folder is looked up in `winFontsDir`)
    "msyh.ttc", "YuGothR.ttc", "malgun.ttf", "simsun.ttc"]
  DefaultFontSize* = 14'f32
  DefaultFamily* = "sans"
  MonoFamily* = "mono"
  # SDL_ttf TTF_STYLE_* values
  TtfBold = 0x01'u32
  TtfItalic = 0x02'u32
  # font.nim lives in src/nimvcl/graphics; the assets ship inside the package.
  CompiledAssetsDir = currentSourcePath().parentDir.parentDir / "assets"
  EmbeddedPrefix* = "embedded:"   ## `ResolvedFont.path` prefix of a font held in the binary

# The bundled fonts live in the binary (about 2.4 MB). Build with
# -d:nimvclNoEmbedFonts to skip that and load them from disk only.
when not defined(nimvclNoEmbedFonts):
  const
    EmbRegular = staticRead(CompiledAssetsDir / "fonts" / "NotoSans-Regular.ttf")
    EmbBold = staticRead(CompiledAssetsDir / "fonts" / "NotoSans-Bold.ttf")
    EmbItalic = staticRead(CompiledAssetsDir / "fonts" / "NotoSans-Italic.ttf")
    EmbMono = staticRead(CompiledAssetsDir / "fonts" / "NotoSansMono-Regular.ttf")
  let embeddedFonts = {
    "NotoSans-Regular.ttf": EmbRegular, "NotoSans-Bold.ttf": EmbBold,
    "NotoSans-Italic.ttf": EmbItalic, "NotoSansMono-Regular.ttf": EmbMono}.toTable
else:
  let embeddedFonts = initTable[string, string]()

var
  families: Table[string, FontFiles]
  memoryFonts: Table[string, ref string]   ## `embedded:` paths of registered font data
  retiredFonts: seq[ref string]            ## replaced data: still referenced by open fonts, never freed
  sysVariants: Table[string, SysVariant]   ## system lookups (also misses), see `systemVariant`
  sysFamilies: seq[string]
  sysFamiliesDone = false
  userFamilies: HashSet[string]
  fallbackFiles: seq[string]
  fallbackEpoch = 0
  initialized = false
  cjkFile = ""

func `==`*(a, b: FontSpec): bool =
  a.family == b.family and a.size == b.size and a.style == b.style and a.color == b.color

func font*(family = "", size = DefaultFontSize, style: set[FontStyle] = {}): FontSpec =
  ## Builds a `FontSpec`.
  FontSpec(family: family, size: size, style: style)

func withStyle*(f: FontSpec, style: set[FontStyle]): FontSpec =
  result = f
  result.style = style

func withSize*(f: FontSpec, size: float32): FontSpec =
  result = f
  result.size = size

func bold*(f: FontSpec): FontSpec =
  result = f
  result.style.incl fsBold

func italic*(f: FontSpec): FontSpec =
  result = f
  result.style.incl fsItalic

proc assetsDir*(): string =
  ## Directory holding the bundled assets: `NIMVCL_ASSETS` if set, otherwise
  ## the `assets` folder next to the sources (found at compile time).
  let e = getEnv("NIMVCL_ASSETS")
  if e.len > 0: e else: CompiledAssetsDir

proc fontsDir(): string = assetsDir() / "fonts"

proc registerFontFamily*(family, regular: string, bold = "", italic = "",
                         boldItalic = "") =
  ## Registers (or replaces) a family from TTF file paths. Missing variants
  ## fall back to `regular` plus a synthetic style. A registered family wins
  ## over the bundled one of the same name.
  userFamilies.incl family.toLowerAscii
  families[family.toLowerAscii] = FontFiles(regular: regular, bold: bold,
                                            italic: italic, boldItalic: boldItalic)
  inc fallbackEpoch   # contexts rebuild fonts

proc registerFontFamilyData*(family, regular: string, bold = "", italic = "",
                             boldItalic = "") =
  ## Like `registerFontFamily`, but from the bytes of TTF/OTF files (for
  ## example `staticRead("fonts/Foo.ttf")`), so the font travels inside the
  ## binary. The data is copied and kept for the life of the program. Missing
  ## variants fall back to `regular` plus a synthetic style.
  let key = family.toLowerAscii
  proc put(variant, data: string): string =
    if data.len == 0: return ""
    let name = "user/" & key & "/" & variant
    if name in memoryFonts: retiredFonts.add memoryFonts[name]
    var r = new string
    r[] = data
    memoryFonts[name] = r
    EmbeddedPrefix & name
  let ff = FontFiles(regular: put("regular", regular), bold: put("bold", bold),
                     italic: put("italic", italic),
                     boldItalic: put("bolditalic", boldItalic))
  userFamilies.incl key
  families[key] = ff
  inc fallbackEpoch

proc embeddedFontData*(path: string): tuple[data: pointer, len: int] =
  ## Bytes of a font held in the binary (`path` is `embedded:<file name>`),
  ## or (nil, 0). The memory is static: never free it.
  if path.startsWith(EmbeddedPrefix):
    let name = path[EmbeddedPrefix.len .. ^1]
    if name in memoryFonts:
      let s = memoryFonts[name]
      return (cast[pointer](cstring(s[])), s[].len)
    if name in embeddedFonts:
      let s = addr embeddedFonts[name]
      return (cast[pointer](cstring(s[])), s[].len)

proc bundledFont(file: string): string =
  ## Where a bundled font is loaded from: a copy under `NIMVCL_ASSETS` when
  ## that variable is set and the file exists there, else the embedded copy,
  ## else the assets folder on disk.
  let e = getEnv("NIMVCL_ASSETS")
  if e.len > 0 and fileExists(e / "fonts" / file): return e / "fonts" / file
  if file in embeddedFonts: return EmbeddedPrefix & file
  fontsDir() / file

proc addFallbackFontFile*(path: string) =
  ## Appends a global fallback font (symbols, CJK, emoji). Missing files are
  ## ignored. Contexts rebuild their font caches on the next use.
  if path.len > 0 and fileExists(path) and path notin fallbackFiles:
    fallbackFiles.add path
    inc fallbackEpoch

proc winFontsDir(): string =
  ## `%WINDIR%\\Fonts` ("" off Windows, so the candidates never match there).
  when defined(windows): getEnv("WINDIR", "C:\\Windows") / "Fonts"
  else: "/nonexistent-windows-fonts"

proc ensureFontRegistry() =
  if initialized: return
  initialized = true
  if "sans" notin families:
    families["sans"] = FontFiles(regular: bundledFont("NotoSans-Regular.ttf"),
                                 bold: bundledFont("NotoSans-Bold.ttf"),
                                 italic: bundledFont("NotoSans-Italic.ttf"))
  if "mono" notin families:
    families["mono"] = FontFiles(regular: bundledFont("NotoSansMono-Regular.ttf"))
  const sys = "/usr/share/fonts/noto"
  # NotoColorEmoji.ttf is deliberately NOT probed: SDL_ttf 3.2 does not scale
  # CBDT bitmap strikes, so its glyphs render at a fixed 136x128 px. Opt in
  # with addFallbackFontFile once colour glyph scaling is solved.
  for f in ["NotoSansSymbols2-Regular.ttf", "NotoSansSymbols-Regular.ttf"]:
    addFallbackFontFile(sys / f)   # probes the path; no fontconfig yet
  when defined(windows):
    addFallbackFontFile(winFontsDir() / "seguisym.ttf")
  # One common CJK font (first found), as the LAST fallback: the bundled fonts
  # and the symbol fonts win for the glyphs they have.
  for c in CjkCandidates:
    # bare file names (the Windows entries) live in the Windows Fonts folder
    let f = if c.isAbsolute: c else: winFontsDir() / c
    if fileExists(f):
      cjkFile = f
      addFallbackFontFile(f)
      break

proc cjkFallbackFont*(): string =
  ## The system CJK font that was added to the fallback list ("" when none
  ## was found). The probe runs with the font registry, on first use.
  ensureFontRegistry()
  cjkFile

proc fallbackFontFiles*(): seq[string] =
  ## Current global fallback list (paths).
  ensureFontRegistry()
  fallbackFiles

proc fontRegistryEpoch*(): int =
  ## Bumped whenever families or fallbacks change.
  ensureFontRegistry()
  fallbackEpoch

# ------------------------------------------------------------ system fonts
# Linux/BSD: fontconfig through its command line tool `fc-list`, run once on
# first use (so there is no link-time dependency, and no process per family
# name); when it is missing every lookup simply finds nothing and the text
# uses the bundled "sans".
# Windows and macOS: the font folders are scanned once (first use) and the
# family and style are read from each file's `name` table (file name
# heuristics when that fails). TTC/OTC collections count with their first face
# only, because SDL_ttf opens face 0. No DirectWrite / CoreText is involved.

const
  # -d:nimvclFontScan forces the folder scan on Linux (for testing it there)
  HaveFontScan = defined(windows) or defined(macosx) or defined(nimvclFontScan)
  HaveFontconfig = (defined(linux) or defined(bsd)) and not HaveFontScan
  HaveFontList = HaveFontScan or HaveFontconfig   ## `scanned` is filled

type
  ScanEntry = object
    family: string
    plain: bool               ## the subfamily is a plain Regular/Bold/Italic/Bold Italic
    bold, italic: bool
    path: string

var
  scanned: seq[ScanEntry]
  scanDone = false

proc scanDirs(): seq[string] =
  when defined(windows):
    result.add winFontsDir()
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0: result.add local / "Microsoft" / "Windows" / "Fonts"
  elif defined(macosx):
    result = @["/System/Library/Fonts", "/Library/Fonts",
               getHomeDir() / "Library" / "Fonts"]
  else:
    result = @["/usr/share/fonts", getHomeDir() / ".local" / "share" / "fonts"]

proc u16(b: string, o: int): int =
  (ord(b[o]) shl 8) or ord(b[o + 1])

proc u32(b: string, o: int): int =
  (u16(b, o) shl 16) or u16(b, o + 2)

proc decodeName(b: string, platform: int): string =
  if platform == 3 or platform == 0:      # UTF-16BE (BMP only is enough here)
    var i = 0
    while i + 1 < b.len:
      result.add Rune(u16(b, i)).toUTF8
      i += 2
  else:
    result = b

proc readNameTable(path: string): tuple[family, sub: string] =
  ## Family and subfamily from a TTF/OTF/TTC file's `name` table; ("", "") when
  ## it cannot be read. Typographic names (ids 16/17) win over ids 1/2.
  try:
    let f = newFileStream(path, fmRead)
    if f == nil: return
    defer: f.close()
    var head = f.readStr(12)
    if head.len < 12: return
    if head[0 ..< 4] == "ttcf":
      var more = f.readStr(4)           # offset of the first face
      if more.len < 4: return
      f.setPosition(u32(more, 0))
      head = f.readStr(12)
      if head.len < 12: return
    let numTables = u16(head, 4)
    let dir = f.readStr(numTables * 16)
    if dir.len < numTables * 16: return
    var nameOff, nameLen = -1
    for i in 0 ..< numTables:
      if dir[i * 16 ..< i * 16 + 4] == "name":
        nameOff = u32(dir, i * 16 + 8)
        nameLen = u32(dir, i * 16 + 12)
    if nameOff < 0 or nameLen < 6 or nameLen > 4_000_000: return
    f.setPosition(nameOff)
    let t = f.readStr(nameLen)
    if t.len < nameLen: return
    let count = u16(t, 2)
    let strOff = u16(t, 4)
    var best: array[4, (int, string)]   # ids 1, 2, 16, 17: (rank, text)
    for i in 0 ..< count:
      let r = 6 + i * 12
      if r + 12 > t.len: break
      let plat = u16(t, r)
      let lang = u16(t, r + 4)
      let id = u16(t, r + 6)
      let slot = case id
        of 1: 0
        of 2: 1
        of 16: 2
        of 17: 3
        else: -1
      if slot < 0: continue
      let len = u16(t, r + 8)
      let so = strOff + u16(t, r + 10)
      if so + len > t.len: continue
      # English Windows name beats other Windows names beats Mac names
      let rank = if plat == 3 and lang == 0x409: 3
                 elif plat == 3: 2
                 elif plat == 1 and lang == 0: 1
                 else: 0
      if rank > best[slot][0]:
        best[slot] = (rank, decodeName(t[so ..< so + len], plat))
    result.family = if best[2][1].len > 0: best[2][1] else: best[0][1]
    result.sub = if best[3][1].len > 0: best[3][1] else: best[1][1]
  except CatchableError:
    discard

proc guessFromFileName(path: string): tuple[family, sub: string] =
  ## Fallback when the name table is unreadable: "Arial Bold Italic.ttf" ->
  ## ("Arial", "Bold Italic"); "Foo-BoldItalic.otf" likewise.
  var stem = path.splitFile.name.replace('_', ' ').replace('-', ' ')
  var sub: seq[string]
  for w in ["BoldItalic", "BoldOblique", "Bold", "Italic", "Oblique", "Regular"]:
    if stem.endsWith(w) and stem.len > w.len:
      stem = stem[0 ..< stem.len - w.len]
      sub.insert(w, 0)
  var words = stem.strip.splitWhitespace
  while words.len > 1 and words[^1].toLowerAscii in ["bold", "italic", "oblique", "regular"]:
    sub.insert(words.pop, 0)
  result = (words.join(" "), sub.join(" "))

proc runTool(cmd: string, args: openArray[string]): string =
  ## Standard output of `cmd` ("" when it is missing or fails).
  when HaveFontconfig:
    try:
      let p = startProcess(cmd, args = args, options = {poUsePath})
      defer: p.close()
      result = p.outputStream.readAll()
      if p.waitForExit() != 0: result = ""
    except CatchableError:
      result = ""

proc scanFonts() =
  if scanDone: return
  scanDone = true
  when HaveFontconfig:
    # one line per face: family names (comma separated), style, weight, slant,
    # face index, file. SDL_ttf opens face 0 of a collection, so only that one counts.
    let o = runTool("fc-list", ["-f", "%{family}\t%{style}\t%{weight}\t%{slant}\t%{index}\t%{file}\n"])
    for line in o.splitLines:
      let parts = line.split('\t')
      if parts.len != 6 or parts[5].len == 0: continue
      if (try: parseInt(parts[4].strip) except ValueError: 0) != 0: continue
      let w = try: parseInt(parts[2].strip) except ValueError: 80
      let sl = try: parseInt(parts[3].strip) except ValueError: 0
      let sub = parts[1].split(',')[0].strip.toLowerAscii
      let plain = sub in ["", "regular", "book", "roman", "normal", "bold",
                          "italic", "bold italic", "oblique", "bold oblique"]
      for n in parts[0].split(','):
        let name = n.strip
        if name.len > 0:
          scanned.add ScanEntry(family: name, plain: plain, bold: w >= 180,
                                italic: sl > 0, path: parts[5])
  elif HaveFontScan:
    for d in scanDirs():
      try:
        if not dirExists(d): continue
        for path in walkDirRec(d):
          let ext = path.splitFile.ext.toLowerAscii
          if ext notin [".ttf", ".otf", ".ttc", ".otc"]: continue
          var (fam, sub) = readNameTable(path)
          if fam.len == 0: (fam, sub) = guessFromFileName(path)
          if fam.len == 0: continue
          let sl = sub.toLowerAscii
          let bold = "bold" in sl
          let italic = "italic" in sl or "oblique" in sl
          let plain = sl in ["", "regular", "book", "roman", "normal", "bold",
                             "italic", "bold italic", "oblique", "bold oblique"]
          scanned.add ScanEntry(family: fam, plain: plain, bold: bold,
                                italic: italic, path: path)
      except CatchableError:
        discard

proc scanLookup(family: string, bold, italic: bool): SysVariant =
  ## Best file of an installed family: an exact style match with a plain
  ## subfamily name first, then the closest style (the caller synthesises the
  ## rest).
  var bestScore = -1
  for e in scanned:
    if e.family.cmpIgnoreCase(family.strip) != 0: continue
    var score = 0
    if e.bold == bold: score += 4
    if e.italic == italic: score += 4
    if e.plain: score += 2
    if score > bestScore:
      bestScore = score
      result = SysVariant(path: e.path, bold: e.bold, italic: e.italic)

proc systemVariant(family: string, bold, italic: bool): SysVariant =
  ## The installed file that best matches `family` with the wanted style, or an
  ## empty path. fontconfig always answers (with a substitute when the family is
  ## missing): the answer only counts when it names the requested family.
  let key = family.toLowerAscii & (if bold: "|b" else: "|r") & (if italic: "i" else: "")
  if key in sysVariants: return sysVariants[key]
  when HaveFontList:
    scanFonts()
    result = scanLookup(family, bold, italic)
  sysVariants[key] = result

proc systemFontFamilies*(): seq[string] =
  ## Family names installed on the system, sorted and without duplicates
  ## (fontconfig's `fc-list` on Linux/BSD, a scan of the font folders on Windows
  ## and macOS). Empty when the list cannot be read or `fc-list` is missing. The
  ## result is cached.
  if not sysFamiliesDone:
    sysFamiliesDone = true
    when HaveFontList:
      scanFonts()
      var seen = initHashSet[string]()
      for e in scanned:
        if not seen.containsOrIncl(e.family.toLowerAscii): sysFamilies.add e.family
      sysFamilies.sort(proc(a, b: string): int = cmpIgnoreCase(a, b))
  sysFamilies

proc refreshSystemFonts*() =
  ## Forgets the cached system lookups and family list (after installing fonts).
  sysVariants.clear()
  sysFamilies.setLen 0
  sysFamiliesDone = false
  scanned.setLen 0
  scanDone = false
  inc fallbackEpoch

proc registeredFontFamilies*(): seq[string] =
  ## Families added with `registerFontFamily` / `registerFontFamilyData`
  ## (lower case names), sorted.
  for f in userFamilies: result.add f
  result.sort()

proc resolveFont*(spec: FontSpec): ResolvedFont =
  ## Chooses a file for `spec`, synthesising bold/italic when the family has
  ## no such variant. Falls back to "sans" for unknown families.
  ensureFontRegistry()
  let fam = if spec.family.len == 0: DefaultFamily else: spec.family.toLowerAscii
  let wantB = fsBold in spec.style
  let wantI = fsItalic in spec.style
  if fam notin families:
    let v = systemVariant(spec.family, wantB, wantI)
    if v.path.len > 0:
      result.path = v.path
      result.isSystem = true
      if wantB and not v.bold: result.ttfStyle = result.ttfStyle or TtfBold
      if wantI and not v.italic: result.ttfStyle = result.ttfStyle or TtfItalic
      return
  let ff = families.getOrDefault(fam, families[DefaultFamily])
  var path = ff.regular
  var synthB = wantB
  var synthI = wantI
  if wantB and wantI and ff.boldItalic.len > 0:
    path = ff.boldItalic; synthB = false; synthI = false
  elif wantB and ff.bold.len > 0 and (not wantI or ff.italic.len == 0):
    path = ff.bold; synthB = false
  elif wantI and ff.italic.len > 0:
    path = ff.italic; synthI = false
  result.path = path
  if synthB: result.ttfStyle = result.ttfStyle or TtfBold
  if synthI: result.ttfStyle = result.ttfStyle or TtfItalic
  # Underline and strike-out are NOT passed to SDL_ttf: its renderer text engine
  # clips the underline and renders the strike as a light gap. The Canvas draws
  # both itself.

proc fontSource*(spec: FontSpec): string =
  ## Where the font for `spec` comes from: "system" (installed on this
  ## machine), "registered" (a family set with `registerFontFamily` or
  ## `registerFontFamilyData`), "embedded" (bundled, in the binary) or "disk"
  ## (bundled file loaded from `NIMVCL_ASSETS` or the assets folder).
  let r = resolveFont(spec)
  let fam = if spec.family.len == 0: DefaultFamily else: spec.family.toLowerAscii
  if r.isSystem: "system"
  elif fam in userFamilies and fam in families: "registered"
  elif r.path.startsWith(EmbeddedPrefix): "embedded"
  else: "disk"
