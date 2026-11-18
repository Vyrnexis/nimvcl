## Font descriptors and the font family registry. Pure Nim, no SDL.
##
## A `FontSpec` is a plain value (like VCL's TFont): it names a family, a
## logical size and a style. It holds no SDL handle; the `RenderContext`
## resolves it to a rasterised font at `size * scale` when text is drawn.

import std/[os, osproc, tables, sets, strutils, algorithm, streams]
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
    "/usr/share/fonts/TTF/DroidSansFallback.ttf"]
  DefaultFontSize* = 14'f32
  DefaultFamily* = "sans"
  MonoFamily* = "mono"
  # SDL_ttf TTF_STYLE_* values
  TtfBold = 0x01'u32
  TtfItalic = 0x02'u32
  # font.nim lives in src/nimvcl/graphics; the assets are four levels up.
  CompiledAssetsDir = currentSourcePath().parentDir.parentDir.parentDir.parentDir / "assets"
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
  # One common CJK font (first found), as the LAST fallback: the bundled fonts
  # and the symbol fonts win for the glyphs they have.
  for f in CjkCandidates:
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
# Linux/BSD: fontconfig through its command line tools (`fc-match`, `fc-list`),
# so there is no link-time dependency; when they are missing every lookup
# simply finds nothing and the text uses the bundled "sans".
# TODO(windows, macos): enumerate and resolve through DirectWrite / CoreText.
# Until then `systemFontFamilies` is empty there and unknown families fall back
# to "sans".

const HaveFontconfig = defined(linux) or defined(bsd)

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

func fcEscape(s: string): string =
  ## Escapes the characters that are special in a fontconfig pattern.
  for c in s:
    if c in {'\\', '-', ':', ',', '='}: result.add '\\'
    result.add c

proc systemVariant(family: string, bold, italic: bool): SysVariant =
  ## The installed file that best matches `family` with the wanted style, or an
  ## empty path. fontconfig always answers (with a substitute when the family is
  ## missing): the answer only counts when it names the requested family.
  let key = family.toLowerAscii & (if bold: "|b" else: "|r") & (if italic: "i" else: "")
  if key in sysVariants: return sysVariants[key]
  when HaveFontconfig:
    var pat = fcEscape(family)
    if bold: pat.add ":weight=bold"
    else: pat.add ":weight=regular"
    pat.add (if italic: ":slant=italic" else: ":slant=roman")
    let o = runTool("fc-match", ["-f", "%{family}\t%{weight}\t%{slant}\t%{file}", pat])
    let parts = o.split('\t')
    if parts.len == 4 and parts[3].len > 0 and fileExists(parts[3]):
      var named = false
      for n in parts[0].split(','):
        if n.strip.cmpIgnoreCase(family.strip) == 0: named = true
      if named:
        let w = try: parseInt(parts[1].strip) except ValueError: 80
        let sl = try: parseInt(parts[2].strip) except ValueError: 0
        result = SysVariant(path: parts[3], bold: w >= 180, italic: sl > 0)
  sysVariants[key] = result

proc systemFontFamilies*(): seq[string] =
  ## Family names installed on the system, sorted and without duplicates
  ## (fontconfig's `fc-list`). Empty when the list cannot be read, on other
  ## platforms for now, or when `fc-list` is missing. The result is cached.
  if not sysFamiliesDone:
    sysFamiliesDone = true
    when HaveFontconfig:
      var seen = initHashSet[string]()
      for line in runTool("fc-list", [":", "family"]).splitLines:
        for n in line.split(','):
          let name = n.strip
          if name.len > 0 and not seen.containsOrIncl(name.toLowerAscii):
            sysFamilies.add name
      sysFamilies.sort(proc(a, b: string): int = cmpIgnoreCase(a, b))
  sysFamilies

proc refreshSystemFonts*() =
  ## Forgets the cached system lookups and family list (after installing fonts).
  sysVariants.clear()
  sysFamilies.setLen 0
  sysFamiliesDone = false
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
