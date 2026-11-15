## `RenderContext`: everything that is bound to one renderer.
##
## Ownership rules (PLAN section 2.7):
##  * User-visible values (`FontSpec`, `Image`, `Color`) hold no renderer-bound
##    SDL handles.
##  * The context borrows the `Renderer` and owns the TTF text engine plus
##    caches of fonts, texts and textures. It is created and closed on the UI
##    thread, and `close` MUST run before the renderer is destroyed.
##  * `=destroy` frees nothing; in debug builds it asserts that `close` ran.
##
## Cache entries record the frame they were last used in; `endFrame` (through
## `sweep`) destroys the ones idle for more than `maxIdleFrames` frames.

import std/[tables, math, algorithm]
import sdl3, sdl3_ttf
import ./font, ./image, ./aa

const
  DefaultMaxIdleFrames* = 120     ## frames an unused cache entry survives
  DefaultTextCacheCap* = 2048     ## hard limit on cached text objects

type
  ## `align` is the wrap alignment: a property of the rasterised font handle
  ## in SDL_ttf (changing it relayouts every text using that font), so wrapped
  ## centred/right text gets its own handle.
  FontKey = tuple[path: string, px64: int32, style: uint32, align: uint8]
  TextKey = tuple[text: string, font: FontKey, wrapPx: int32]

  FontEntry = object
    font: Font
    fallbacks: seq[Font]
    textRefs: int
    lastUsed: int

  TextEntry = object
    text: ptr Text
    lastUsed: int

  TexEntry = object
    tex: Texture
    generation: uint32
    lastUsed: int

  RenderContextObj = object
    renderer: Renderer
    engine: TextEngine
    scale: float32
    frame: int
    closed: bool
    epoch: int                    # font registry epoch the caches were built for
    fonts: Table[FontKey, FontEntry]
    texts: Table[TextKey, TextEntry]
    textures: Table[uint64, TexEntry]
    maxIdleFrames*: int
    textCacheCap*: int
    geo*: GeoBuf                  # reusable vertex buffers for the Canvas

  RenderContext* = ref RenderContextObj

  FontMetrics* = object
    ## Logical pixels.
    ascent*, descent*, lineHeight*: float32

proc `=destroy`(c: RenderContextObj) =
  when not defined(release) and not defined(danger):
    doAssert c.closed or c.renderer == nil,
      "RenderContext was not closed before being freed: call close() on the UI thread"

proc `=copy`(a: var RenderContextObj, b: RenderContextObj) {.error.}

func quantiseScale(s: float32): float32 =
  ## Scales are kept in steps of 1/64 (the font cache key resolution), so tiny
  ## differences (from rounding window sizes) never flush the caches.
  max(round(s * 64) / 64, 1'f32 / 64)

proc newRenderContext*(renderer: Renderer, scale: float32 = 1): RenderContext =
  ## Creates a context for `renderer` (borrowed, not owned). Needs SDL_ttf
  ## initialised. Raises `IOError` if the text engine cannot be created.
  let eng = createRendererTextEngine(renderer)
  if eng == nil:
    raise newException(IOError, "createRendererTextEngine: " & $getError())
  RenderContext(renderer: renderer, engine: eng, scale: quantiseScale(scale),
                maxIdleFrames: DefaultMaxIdleFrames,
                textCacheCap: DefaultTextCacheCap, epoch: fontRegistryEpoch())

func renderer*(ctx: RenderContext): Renderer = ctx.renderer
func scale*(ctx: RenderContext): float32 = ctx.scale
func frameCount*(ctx: RenderContext): int = ctx.frame   # not `frame`: that is the frame macro
func isClosed*(ctx: RenderContext): bool = ctx.closed

func fontCount*(ctx: RenderContext): int = ctx.fonts.len
  ## Number of cached rasterised fonts (for tests and diagnostics).
func textCount*(ctx: RenderContext): int = ctx.texts.len
  ## Number of cached text objects.
func textureCount*(ctx: RenderContext): int = ctx.textures.len
  ## Number of cached textures.

proc destroyTexts(ctx: RenderContext) =
  for k, e in ctx.texts.pairs:
    if e.text != nil: destroyText(e.text)
  ctx.texts.clear()
  for _, e in ctx.fonts.mpairs: e.textRefs = 0

proc destroyFontEntry(e: FontEntry) =
  # closing the primary font detaches its fallbacks; they are closed after it
  if e.font != nil: closeFont(e.font)
  for f in e.fallbacks: closeFont(f)

proc destroyFonts(ctx: RenderContext) =
  for _, e in ctx.fonts.pairs: destroyFontEntry(e)
  ctx.fonts.clear()

proc destroyTextures(ctx: RenderContext) =
  for _, e in ctx.textures.pairs:
    if e.tex != nil: destroyTexture(e.tex)
  ctx.textures.clear()

proc flushFontCaches(ctx: RenderContext) =
  ctx.destroyTexts()      # texts first: they reference the fonts
  ctx.destroyFonts()

proc setScale*(ctx: RenderContext, s: float32) =
  ## Changes the display scale. Fonts are rasterised at `size * scale`, so on a
  ## change the font and text caches are destroyed (textures are kept). The
  ## scale is quantised to 1/64 before it is compared.
  let s = quantiseScale(s)
  if s != ctx.scale:
    ctx.scale = s
    ctx.flushFontCaches()

proc close*(ctx: RenderContext) =
  ## Destroys every cached SDL handle (texts, engine, fonts, textures) in that
  ## order. Idempotent. Must run on the UI thread before the renderer dies.
  if ctx.closed: return
  ctx.destroyTexts()
  if ctx.engine != nil:
    destroyRendererTextEngine(ctx.engine)
    ctx.engine = nil
  ctx.destroyFonts()
  ctx.destroyTextures()
  ctx.closed = true

proc destroy*(ctx: RenderContext) = ctx.close()

proc checkOpen(ctx: RenderContext) =
  doAssert not ctx.closed, "RenderContext used after close()"

proc beginFrameTick*(ctx: RenderContext) =
  ## Advances the frame counter (called by `beginFrame`). This is the only place
  ## where the caches are flushed after the font registry changed (families or
  ## fallbacks): never mid-frame, where text pointers are still in use.
  ctx.checkOpen()
  let e = fontRegistryEpoch()
  if e != ctx.epoch:
    ctx.epoch = e
    ctx.flushFontCaches()
  inc ctx.frame

# ------------------------------------------------------------------- fonts

proc fontKey(ctx: RenderContext, spec: FontSpec, align = 0'u8): FontKey =
  let r = resolveFont(spec)
  let size = if spec.size <= 0: DefaultFontSize else: spec.size
  (r.path, int32(round(size * ctx.scale * 64)), r.ttfStyle, align)

proc openEntry(key: FontKey): FontEntry =
  let px = key.px64.float32 / 64
  let f = openFont(key.path.cstring, px)
  if f == nil:
    raise newException(IOError, "openFont " & key.path & ": " & $getError())
  setFontHinting(f, hintingLight)
  setFontStyle(f, key.style)
  setFontWrapAlignment(f, HorizontalAlignment(key.align))
  result.font = f
  for p in fallbackFontFiles():
    let fb = openFont(p.cstring, px)
    if fb == nil: continue       # e.g. a bitmap font that cannot take this size
    setFontStyle(fb, key.style)
    if addFallbackFont(f, fb): result.fallbacks.add fb
    else: closeFont(fb)

proc fontFor(ctx: RenderContext, key: FontKey): Font =
  var e = ctx.fonts.getOrDefault(key)
  if e.font == nil:
    e = openEntry(key)
    ctx.fonts[key] = e
  ctx.fonts.withValue(key, v): v.lastUsed = ctx.frame
  e.font

proc fontMetrics*(ctx: RenderContext, spec: FontSpec): FontMetrics =
  ## Ascent, descent (positive) and line height in logical pixels.
  ctx.checkOpen()
  let f = ctx.fontFor(ctx.fontKey(spec))
  let s = ctx.scale
  FontMetrics(ascent: getFontAscent(f).float32 / s,
              descent: abs(getFontDescent(f).float32) / s,
              lineHeight: getFontHeight(f).float32 / s)

# ------------------------------------------------------------------- texts

proc getText*(ctx: RenderContext, str: string, spec: FontSpec, wrapPx = 0,
              align: HorizontalAlignment = horizontalAlignLeft): ptr Text =
  ## Cached shaped text for (string, font, wrap width in DEVICE px). `align`
  ## aligns the lines of a wrapped paragraph (ignored when `wrapPx` is 0). The
  ## pointer stays valid until the next `sweep`, `setScale` or `close`; do not
  ## keep it across frames.
  ctx.checkOpen()
  let al = if wrapPx > 0: uint8(ord(align)) else: 0'u8
  let fk = ctx.fontKey(spec, al)
  let key: TextKey = (str, fk, int32(max(wrapPx, 0)))
  let f = ctx.fontFor(fk)
  ctx.texts.withValue(key, e):
    e.lastUsed = ctx.frame
    return e.text
  let t = createText(ctx.engine, f, str.cstring, str.len.csize_t)
  if t == nil:
    raise newException(IOError, "createText: " & $getError())
  if wrapPx > 0: discard setTextWrapWidth(t, wrapPx.cint)
  ctx.texts[key] = TextEntry(text: t, lastUsed: ctx.frame)
  ctx.fonts.withValue(fk, v): inc v.textRefs
  t

proc measureDevice*(ctx: RenderContext, str: string, spec: FontSpec,
                    wrapPx = 0): tuple[w, h: float32] =
  ## Text size in device pixels (height of an empty string is one line).
  ctx.checkOpen()
  let fk = ctx.fontKey(spec)
  if str.len == 0:
    let f = ctx.fontFor(fk)
    return (0'f32, getFontHeight(f).float32)
  let t = ctx.getText(str, spec, wrapPx)
  var w, h: cint
  discard getTextSize(t, w, h)
  (w.float32, h.float32)

proc measureWidthDevice*(ctx: RenderContext, str: string, spec: FontSpec): float32 =
  ## Width of a single line of text in device pixels, without creating a
  ## cached text object. Use it for bulk measuring (e.g. sweeping every line
  ## of a big document); `measureDevice` is cheaper for text that is drawn.
  ctx.checkOpen()
  if str.len == 0: return 0
  let f = ctx.fontFor(ctx.fontKey(spec))
  var mw: cint
  var ml: csize_t
  if not measureString(f, str.cstring, str.len.csize_t, 0, mw, ml):
    return ctx.measureDevice(str, spec).w
  mw.float32

proc fitPrefix*(ctx: RenderContext, str: string, spec: FontSpec,
                maxPx: float32): int =
  ## Number of leading bytes of `str` that fit in `maxPx` device pixels.
  ctx.checkOpen()
  if maxPx < 1: return 0        # SDL_ttf treats a width of 0 as unlimited
  let f = ctx.fontFor(ctx.fontKey(spec))
  var mw: cint
  var ml: csize_t
  if not measureString(f, str.cstring, str.len.csize_t, cint(max(maxPx, 0)), mw, ml):
    return 0
  ml.int

# whole-cache sweeping helpers (the font a text uses is looked up by key)
proc sweep*(ctx: RenderContext) =
  ## Destroys cache entries unused for more than `maxIdleFrames` frames and
  ## trims the text cache to `textCacheCap`. Entries used this frame are kept.
  ctx.checkOpen()
  let limit = ctx.frame - ctx.maxIdleFrames
  # texts first (they reference fonts)
  var dead: seq[TextKey]
  for k, e in ctx.texts.pairs:
    if e.lastUsed < limit: dead.add k
  if ctx.texts.len - dead.len > ctx.textCacheCap:
    # over the cap: evict least recently used, never the current frame's
    var live: seq[(int, TextKey)]
    for k, e in ctx.texts.pairs:
      if e.lastUsed >= limit and e.lastUsed < ctx.frame: live.add (e.lastUsed, k)
    live.sort(proc (a, b: (int, TextKey)): int = cmp(a[0], b[0]))
    var excess = ctx.texts.len - dead.len - (ctx.textCacheCap * 3 div 4)
    for (_, k) in live:
      if excess <= 0: break
      dead.add k
      dec excess
  for k in dead:
    var e: TextEntry
    if ctx.texts.pop(k, e):
      destroyText(e.text)
      ctx.fonts.withValue(k.font, v): dec v.textRefs
  var deadFonts: seq[FontKey]
  for k, e in ctx.fonts.pairs:
    if e.lastUsed < limit and e.textRefs <= 0: deadFonts.add k
  for k in deadFonts:
    var e: FontEntry
    if ctx.fonts.pop(k, e): destroyFontEntry(e)
  var deadTex: seq[uint64]
  for k, e in ctx.textures.pairs:
    if e.lastUsed < limit: deadTex.add k
  for k in deadTex:
    var e: TexEntry
    if ctx.textures.pop(k, e): destroyTexture(e.tex)

# ---------------------------------------------------------------- textures

proc textureFor*(ctx: RenderContext, img: Image): Texture =
  ## Texture for `img`, created on first use and re-uploaded when the image's
  ## generation changed.
  ctx.checkOpen()
  var e = ctx.textures.getOrDefault(img.id)
  let surf = img.surface
  if e.tex == nil:
    let t = createTextureFromSurface(ctx.renderer, surf)
    if t == nil:
      raise newException(IOError, "createTextureFromSurface: " & $getError())
    discard setTextureScaleMode(t, SCALEMODE_LINEAR)
    e = TexEntry(tex: t, generation: img.generation)
  elif e.generation != img.generation:
    discard updateTexture(e.tex, nil, cast[ptr uint8](surf.pixels), surf.pitch)
    e.generation = img.generation
  e.lastUsed = ctx.frame
  ctx.textures[img.id] = e
  e.tex
