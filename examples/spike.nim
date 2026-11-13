# Phase 0 spike (throwaway): proves the rendering approach for nimvcl.
#
#   - SDL3 window with HIGH_PIXEL_DENSITY, SDL_Renderer + vsync
#   - blocking waitEvent loop, redraw only on expose/resize/scale events
#   - logical coordinates; everything is multiplied by `scale` when drawn
#   - text via the SDL_ttf 3 renderer text engine, font rebuilt at pt * scale
#   - anti-aliased rounded rects through renderGeometry (1 device px alpha ramp)
#   - clip rect demo, headless screenshot mode
#
# Env:
#   NIMVCL_FONT                 path to a TTF (default Noto Sans)
#   NIMVCL_SPIKE_SCREENSHOT     render one frame to this BMP and exit
#   NIMVCL_SPIKE_SCALE          force a scale (headless testing of 1.5x etc.)
#
# Build: nim c --outdir:build examples/spike.nim

import std/[os, math, strutils]
import sdl3, sdl3_ttf

const
  DefaultFont = "/usr/share/fonts/noto/NotoSans-Regular.ttf"
  FontPt = 15.0'f32       # logical size; rasterised at FontPt * scale
  BaseW = 640             # initial window size, logical px
  BaseH = 470

type
  Rgba = tuple[r, g, b, a: float32]

  App = object
    window: Window
    renderer: Renderer
    engine: TextEngine
    font: Font
    fontPath: string
    scale: float32
    pixW, pixH: cint            # window size in device pixels
    texts: seq[ptr Text]        # rebuilt whenever the scale changes
    forcedScale: float32        # 0 = use the window's scale

proc fatal(msg: string) =
  stderr.writeLine msg & ": " & $getError()
  quit 1

func rgba(r, g, b: int, a = 255): Rgba =
  (r.float32 / 255, g.float32 / 255, b.float32 / 255, a.float32 / 255)

const
  Bg: Rgba = (0.94'f32, 0.94'f32, 0.95'f32, 1'f32)
  Accent: Rgba = (0.16'f32, 0.45'f32, 0.85'f32, 1'f32)
  Ink: Rgba = (0.12'f32, 0.12'f32, 0.14'f32, 1'f32)
  Red: Rgba = (0.85'f32, 0.25'f32, 0.22'f32, 1'f32)

# ---------------------------------------------------------------- geometry

type Geo = object
  verts: seq[Vertex]
  idx: seq[cint]

proc addVert(g: var Geo, x, y: float32, c: Rgba, alpha: float32): cint =
  result = g.verts.len.cint
  g.verts.add Vertex(position: FPoint(x: x, y: y),
                     color: FColor(r: c.r, g: c.g, b: c.b, a: c.a * alpha),
                     tex_coord: FPoint(x: 0, y: 0))

proc tri(g: var Geo, a, b, c: cint) =
  g.idx.add [a, b, c]

# Points of a rounded rect outline inset by `d` device px (negative = grow).
# Every ring built with the same `seg` has the same point count, so rings can be
# stitched index by index. Corner centres stay fixed while d < r; only the radius changes.
proc ringPoints(x, y, w, h, r: float32, seg: int, d: float32): seq[FPoint] =
  let rr = max(r - d, 0'f32)
  # corner centres: tl, tr, br, bl; start angles of each quarter (y down)
  # when the inset exceeds the radius the centre itself moves inwards
  let ci = max(r, d)
  let cx = [x + ci, x + w - ci, x + w - ci, x + ci]
  let cy = [y + ci, y + ci, y + h - ci, y + h - ci]
  let a0 = [PI, 1.5 * PI, 0.0, 0.5 * PI]
  for c in 0 .. 3:
    for s in 0 .. seg:
      let a = a0[c] + (PI / 2) * s.float / seg.float
      result.add FPoint(x: cx[c] + rr * cos(a).float32,
                        y: cy[c] + rr * sin(a).float32)

proc segments(r: float32): int =
  clamp(int(ceil(r / 2.0)) + 3, 4, 32)

# Filled AA rounded rect: centre fan + a 1 px feather ring (alpha 1 -> 0).
proc fillRoundRect(g: var Geo, x, y, w, h, r: float32, c: Rgba) =
  let r = min(r, min(w, h) / 2)
  let seg = segments(r)
  let inner = ringPoints(x, y, w, h, r, seg, 0.5)
  let outer = ringPoints(x, y, w, h, r, seg, -0.5)
  let ctr = g.addVert(x + w / 2, y + h / 2, c, 1)
  var ii, oi: seq[cint]
  for p in inner: ii.add g.addVert(p.x, p.y, c, 1)
  for p in outer: oi.add g.addVert(p.x, p.y, c, 0)
  let n = ii.len
  for i in 0 ..< n:
    let j = (i + 1) mod n
    g.tri ctr, ii[i], ii[j]
    g.tri ii[i], oi[i], ii[j]
    g.tri ii[j], oi[i], oi[j]

# Stroked AA rounded rect; the border lies inside the rect, `bw` device px wide.
proc strokeRoundRect(g: var Geo, x, y, w, h, r, bw: float32, c: Rgba) =
  let r = min(r, min(w, h) / 2)
  let seg = segments(r)
  # rings: outer feather, outer edge, inner edge, inner feather
  let ds = [-0.5'f32, 0.5, bw - 0.5, bw + 0.5]
  let al = [0'f32, 1, 1, 0]
  var rings: array[4, seq[cint]]
  for k in 0 .. 3:
    for p in ringPoints(x, y, w, h, r, seg, ds[k]):
      rings[k].add g.addVert(p.x, p.y, c, al[k])
  let n = rings[0].len
  for k in 0 .. 2:
    for i in 0 ..< n:
      let j = (i + 1) mod n
      g.tri rings[k][i], rings[k + 1][i], rings[k][j]
      g.tri rings[k][j], rings[k + 1][i], rings[k + 1][j]

proc flush(a: App, g: var Geo) =
  if g.idx.len > 0:
    if not renderGeometry(a.renderer, nil, g.verts, g.idx):
      fatal "renderGeometry"
  g.verts.setLen 0
  g.idx.setLen 0

# -------------------------------------------------------------------- text

proc destroyTexts(a: var App) =
  for t in a.texts: destroyText(t)
  a.texts.setLen 0

proc rebuildFont(a: var App) =
  ## Destroy everything that depends on the font and recreate it at pt * scale.
  destroyTexts a
  if a.font != nil: closeFont a.font
  a.font = openFont(a.fontPath.cstring, FontPt * a.scale)
  if a.font == nil: fatal "openFont " & a.fontPath
  setFontHinting(a.font, hintingLight)

proc newText(a: var App, s: string, c: Rgba): ptr Text =
  # length 0 = NUL terminated string
  result = createText(a.engine, a.font, s.cstring, 0)
  if result == nil: fatal "createText"
  discard setTextColorFloat(result, c.r, c.g, c.b, c.a)
  a.texts.add result

proc drawText(t: ptr Text, x, y: float32) =
  if not drawRendererText(t, x, y): fatal "drawRendererText"

# ------------------------------------------------------------------- scale

proc updateScale(a: var App): bool =
  ## Recompute pixel size and scale. Returns true if the scale changed.
  var pw, ph, lw, lh: cint
  discard getWindowSizeInPixels(a.window, pw, ph)
  discard getWindowSize(a.window, lw, lh)
  a.pixW = pw
  a.pixH = ph
  var s = if lw > 0: pw.float32 / lw.float32 else: 1'f32
  if a.forcedScale > 0: s = a.forcedScale
  result = abs(s - a.scale) > 0.001
  a.scale = s

# -------------------------------------------------------------------- draw

const Lorem = "Wrapped paragraph through setTextWrapWidth. The quick brown fox " &
  "jumps over the lazy dog. Fractional scales such as 125% and 150% must stay " &
  "sharp because the font is rasterised at pt x scale, not scaled up as a " &
  "texture. Ligatures, kerning and shaping come from HarfBuzz inside SDL_ttf."

proc draw(a: var App, screenshot: string) =
  let s = a.scale
  let lw = a.pixW.float32 / s     # logical size
  let lh = a.pixH.float32 / s

  # Texts are cached in `a.texts`; created on first frame after a font rebuild.
  if a.texts.len == 0:
    discard a.newText("nimvcl spike", Ink)                         # 0 heading
    discard a.newText("Filled", rgba(255, 255, 255))               # 1
    discard a.newText("Stroked 1px", Accent)                       # 2
    discard a.newText("fillRect", rgba(255, 255, 255))             # 3
    discard a.newText("Clipped text overflows the clip rectangle and gets cut off",
                      Ink)                                         # 4
    discard a.newText(Lorem, Ink)                                  # 5 paragraph
    discard a.newText(" ", Ink)                                    # 6 info line
  let info = "scale " & formatFloat(s, ffDecimal, 3) & "   window " &
             $int(lw) & "x" & $int(lh) & " logical, " & $a.pixW & "x" & $a.pixH & " px"
  discard setTextString(a.texts[6], info.cstring, 0)
  discard setTextWrapWidth(a.texts[5], cint((lw - 32) * s))

  discard setRenderDrawBlendMode(a.renderer, BLENDMODE_BLEND)
  discard setRenderDrawColorFloat(a.renderer, Bg.r, Bg.g, Bg.b, Bg.a)
  discard renderClear(a.renderer)

  var tw, th: cint
  template textAt(i: int, lx, ly: float32) =
    drawText(a.texts[i], lx * s, ly * s)
  template textCentered(i: int, rx, ry, rw, rh: float32) =
    discard getTextSize(a.texts[i], tw, th)
    drawText(a.texts[i], (rx + rw / 2) * s - tw.float32 / 2,
             (ry + rh / 2) * s - th.float32 / 2)

  textAt 0, 16, 12

  # rounded rects ---------------------------------------------------------
  var g: Geo
  g.fillRoundRect(16 * s, 50 * s, 190 * s, 80 * s, 12 * s, Accent)
  g.strokeRoundRect(222 * s, 50 * s, 190 * s, 80 * s, 12 * s, 1 * s, Accent)
  # small radius + 1px border over a fill, like a button
  g.fillRoundRect(428 * s, 50 * s, 190 * s, 80 * s, 4 * s, (1'f32, 1'f32, 1'f32, 1'f32))
  g.strokeRoundRect(428 * s, 50 * s, 190 * s, 80 * s, 4 * s, 1 * s,
                    (0.55'f32, 0.55'f32, 0.6'f32, 1'f32))
  a.flush g
  textCentered 1, 16, 50, 190, 80
  textCentered 2, 222, 50, 190, 80

  # plain fillRect (not anti-aliased, pixel snapped by the caller) -----------
  let fr = FRect(x: round(16 * s), y: round(150 * s),
                 w: round(110 * s), h: round(44 * s))
  discard setRenderDrawColorFloat(a.renderer, Red.r, Red.g, Red.b, Red.a)
  discard renderFillRect(a.renderer, fr)
  textCentered 3, 16, 150, 110, 44

  # clip rect demo ---------------------------------------------------------
  let cx = 142'f32
  let cy = 150'f32
  let cw = 190'f32
  let ch = 44'f32
  var clip = Rect(x: cint(cx * s), y: cint(cy * s), w: cint(cw * s), h: cint(ch * s))
  discard setRenderDrawColorFloat(a.renderer, 1, 1, 1, 1)
  discard renderFillRect(a.renderer, FRect(x: clip.x.float32, y: clip.y.float32,
                                           w: clip.w.float32, h: clip.h.float32))
  discard setRenderClipRect(a.renderer, addr clip)
  # a stripe that overshoots the clip box on every side
  discard setRenderDrawColorFloat(a.renderer, 0.9, 0.7, 0.2, 1)
  discard renderFillRect(a.renderer, FRect(x: (cx - 10) * s, y: (cy + 30) * s,
                                           w: (cw + 20) * s, h: 20 * s))
  drawText(a.texts[4], (cx + 6) * s, (cy + 6) * s)
  discard setRenderClipRect(a.renderer, nil)   # nil = disable clipping
  var g2: Geo
  g2.strokeRoundRect(clip.x.float32, clip.y.float32, clip.w.float32, clip.h.float32,
                     0, 1 * s, Ink)
  a.flush g2

  # wrapped paragraph ------------------------------------------------------
  textAt 5, 16, 214
  discard getTextSize(a.texts[5], tw, th)
  let paraBottom = 214 + th.float32 / s

  # info line at the bottom --------------------------------------------------
  textAt 6, 16, max(paraBottom + 16, lh - 30)

  if screenshot.len > 0:
    let surf = renderReadPixels(a.renderer, nil)
    if surf == nil: fatal "renderReadPixels"
    if not saveBMP(surf, screenshot.cstring): fatal "saveBMP"
    destroySurface surf
    echo "wrote ", screenshot
  else:
    discard renderPresent(a.renderer)

# -------------------------------------------------------------------- main

proc main() =
  var a: App
  a.fontPath = getEnv("NIMVCL_FONT", DefaultFont)
  let shot = getEnv("NIMVCL_SPIKE_SCREENSHOT")
  let forced = getEnv("NIMVCL_SPIKE_SCALE")
  if forced.len > 0: a.forcedScale = parseFloat(forced).float32

  if not sdl3.init(INIT_VIDEO): fatal "SDL_Init"
  if not sdl3_ttf.init(): fatal "TTF_Init"

  # When forcing a scale headlessly, make the window big enough in pixels.
  let fs = if a.forcedScale > 0: a.forcedScale else: 1'f32
  a.window = createWindow("nimvcl spike", cint(BaseW.float32 * fs), cint(BaseH.float32 * fs),
                          WINDOW_RESIZABLE or WINDOW_HIGH_PIXEL_DENSITY)
  if a.window == nil: fatal "createWindow"
  a.renderer = createRenderer(a.window, nil)
  if a.renderer == nil: fatal "createRenderer"
  if not setRenderVSync(a.renderer, 1):
    stderr.writeLine "note: vsync unavailable: " & $getError()
  a.engine = createRendererTextEngine(a.renderer)
  if a.engine == nil: fatal "createRendererTextEngine"

  discard updateScale(a)
  echo "renderer: ", getRendererName(a.renderer)
  echo "window pixel density: ", getWindowPixelDensity(a.window),
       "  display scale: ", getWindowDisplayScale(a.window),
       "  used scale: ", a.scale
  rebuildFont a

  if shot.len > 0:
    draw(a, shot)
  else:
    var dirty = true
    var running = true
    var ev: Event
    while running:
      if dirty:
        draw(a, "")
        dirty = false
      # Blocks here; ~0% CPU while idle. After the first event, drain the rest
      # of the queue so a burst of resize events costs one redraw.
      if not waitEvent(ev): fatal "waitEvent"
      while true:
        case ev.type
        of EVENT_QUIT, EVENT_WINDOW_CLOSE_REQUESTED:
          running = false
        of EVENT_KEY_DOWN:
          if ev.key.key == SDLK_ESCAPE: running = false
        of EVENT_WINDOW_EXPOSED, EVENT_WINDOW_RESIZED:
          dirty = true
        of EVENT_WINDOW_PIXEL_SIZE_CHANGED, EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
          if updateScale(a):
            echo "scale -> ", a.scale
            rebuildFont a
          dirty = true
        else: discard
        if not pollEvent(ev): break
      # pixel size may change without a dedicated event on some backends
      if dirty and updateScale(a): rebuildFont a

  # Order matters: texts and engine before the renderer, font after the texts.
  destroyTexts a
  destroyRendererTextEngine a.engine
  closeFont a.font
  destroyRenderer a.renderer
  destroyWindow a.window
  sdl3_ttf.quit()
  sdl3.quit()

main()
