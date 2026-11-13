## Font descriptors and the font family registry. Pure Nim, no SDL.
##
## A `FontSpec` is a plain value (like VCL's TFont): it names a family, a
## logical size and a style. It holds no SDL handle; the `RenderContext`
## resolves it to a rasterised font at `size * scale` when text is drawn.

import std/[os, tables, strutils]

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
  DefaultFontSize* = 14'f32
  DefaultFamily* = "sans"
  MonoFamily* = "mono"
  # SDL_ttf TTF_STYLE_* values
  TtfBold = 0x01'u32
  TtfItalic = 0x02'u32
  # font.nim lives in src/nimvcl/graphics; the assets are four levels up.
  # TODO: embed the bundled fonts with staticRead once the size trade-off is decided.
  CompiledAssetsDir = currentSourcePath().parentDir.parentDir.parentDir.parentDir / "assets"

var
  families: Table[string, FontFiles]
  fallbackFiles: seq[string]
  fallbackEpoch = 0
  initialized = false

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
  ## fall back to `regular` plus a synthetic style.
  families[family.toLowerAscii] = FontFiles(regular: regular, bold: bold,
                                            italic: italic, boldItalic: boldItalic)
  inc fallbackEpoch   # contexts rebuild fonts

proc addFallbackFontFile*(path: string) =
  ## Appends a global fallback font (symbols, CJK, emoji). Missing files are
  ## ignored. Contexts rebuild their font caches on the next use.
  if path.len > 0 and fileExists(path) and path notin fallbackFiles:
    fallbackFiles.add path
    inc fallbackEpoch

proc ensureFontRegistry() =
  if initialized: return
  initialized = true
  let d = fontsDir()
  if "sans" notin families:
    families["sans"] = FontFiles(regular: d / "NotoSans-Regular.ttf",
                                 bold: d / "NotoSans-Bold.ttf",
                                 italic: d / "NotoSans-Italic.ttf")
  if "mono" notin families:
    families["mono"] = FontFiles(regular: d / "NotoSansMono-Regular.ttf")
  const sys = "/usr/share/fonts/noto"
  # NotoColorEmoji.ttf is deliberately NOT probed: SDL_ttf 3.2 does not scale
  # CBDT bitmap strikes, so its glyphs render at a fixed 136x128 px. Opt in
  # with addFallbackFontFile once colour glyph scaling is solved.
  for f in ["NotoSansSymbols2-Regular.ttf", "NotoSansSymbols-Regular.ttf"]:
    addFallbackFontFile(sys / f)   # probes the path; no fontconfig yet

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
