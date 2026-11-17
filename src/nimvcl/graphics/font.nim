## Font descriptors and the font family registry. Pure Nim, no SDL.
##
## A `FontSpec` is a plain value (like VCL's TFont): it names a family, a
## logical size and a style. It holds no SDL handle; the `RenderContext`
## resolves it to a rasterised font at `size * scale` when text is drawn.

import std/[os, tables, sets, strutils]

type
  FontStyle* = enum
    fsBold, fsItalic, fsUnderline, fsStrikeOut

  FontSpec* = object
    ## Font descriptor. `family` "" means the default family ("sans").
    family*: string
    size*: float32            ## logical pixels
    style*: set[FontStyle]

  FontFiles = object
    regular, bold, italic, boldItalic: string

  ResolvedFont* = object
    ## Result of resolving a `FontSpec` against the registry.
    path*: string             ## TTF file to open
    ttfStyle*: uint32         ## SDL_ttf style flags (synthetic bold/italic only; underline and strike-out are drawn by the Canvas)

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

proc embeddedFontData*(path: string): tuple[data: pointer, len: int] =
  ## Bytes of a font held in the binary (`path` is `embedded:<file name>`),
  ## or (nil, 0). The memory is static: never free it.
  if path.startsWith(EmbeddedPrefix):
    let name = path[EmbeddedPrefix.len .. ^1]
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

proc resolveFont*(spec: FontSpec): ResolvedFont =
  ## Chooses a file for `spec`, synthesising bold/italic when the family has
  ## no such variant. Falls back to "sans" for unknown families.
  ensureFontRegistry()
  let fam = if spec.family.len == 0: DefaultFamily else: spec.family.toLowerAscii
  let ff = families.getOrDefault(fam, families[DefaultFamily])
  let wantB = fsBold in spec.style
  let wantI = fsItalic in spec.style
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
  ## Where the font for `spec` comes from: "embedded" (in the binary),
  ## "disk" (bundled file loaded from `NIMVCL_ASSETS` or the assets folder) or
  ## "registered" (a family set with `registerFontFamily`).
  let r = resolveFont(spec)
  let fam = if spec.family.len == 0: DefaultFamily else: spec.family.toLowerAscii
  if r.path.startsWith(EmbeddedPrefix): "embedded"
  elif fam in userFamilies and fam in families: "registered"
  else: "disk"
