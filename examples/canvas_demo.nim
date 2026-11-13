# Phase 1 demo: every Canvas primitive and text feature.
#
# Env:
#   NIMVCL_SCREENSHOT   render one frame to this BMP and exit
#   NIMVCL_SCALE        force the display scale (headless testing of 1.5x etc.)
#
# Build: nim c --outdir:build examples/canvas_demo.nim

import std/[os, strutils, math]
import sdl3 except Color
import nimvcl

const
  BaseW = 800
  BaseH = 640

let
  Bg = rgb(244, 244, 246)
  Ink = rgb(30, 30, 36)
  Muted = rgb(110, 110, 120)
  Accent = rgb(41, 115, 217)
  Red = rgb(217, 64, 56)
  Green = rgb(48, 160, 96)
  Amber = rgb(230, 170, 40)
  White = rgb(255, 255, 255)

const Lorem = "Wrapped paragraph: the quick brown fox jumps over the lazy dog. " &
  "Fractional scales such as 125% and 150% stay sharp because the font is " &
  "rasterised at size x scale, not stretched as a texture."

proc makeImage(): Image =
  ## 32x32 gradient with a transparent ring, generated from RGBA pixels.
  const n = 32
  var px = newSeq[uint8](n * n * 4)
  for y in 0 ..< n:
    for x in 0 ..< n:
      let o = (y * n + x) * 4
      let dx = x.float - 15.5
      let dy = y.float - 15.5
      let d = sqrt(dx * dx + dy * dy)
      px[o] = uint8(x * 255 div (n - 1))
      px[o + 1] = uint8(y * 255 div (n - 1))
      px[o + 2] = 160
      px[o + 3] = if d > 15.5: 0'u8 elif d > 12 and d < 14: 90'u8 else: 255'u8
  imageFromRgba(n, n, px)

proc label(c: Canvas, s: string, x, y: float32) =
  c.drawText(s, font(size = 11), x, y, Muted)

proc drawScene(c: Canvas, img: Image, lw, lh: float32, info: string) =
  let body = font()
  let small = font(size = 12)
  c.clear Bg
  c.drawText("nimvcl canvas demo", font(size = 20, style = {fsBold}), 16, 10, Ink)

  # ---- shapes ------------------------------------------------------------
  c.label "fillRect / frameRect", 16, 48
  c.fillRect(rectF(16, 66, 60, 40), Red)
  c.frameRect(rectF(86, 66, 60, 40), Ink)
  c.frameRect(rectF(156, 66, 60, 40), Accent, 3)
  c.fillRect(rectF(226, 66, 60, 40), Accent.withAlpha(90))   # alpha blend
  c.fillRect(rectF(246, 76, 60, 40), Amber.withAlpha(140))

  c.label "round rects / ellipses", 330, 48
  c.fillRoundRect(rectF(330, 66, 90, 40), 10, Accent)
  c.strokeRoundRect(rectF(430, 66, 90, 40), 10, Accent, 1)
  c.fillRoundRect(rectF(530, 66, 40, 40), 20, Green)               # circle
  c.strokeRoundRect(rectF(580, 66, 90, 40), 4, Muted, 2)
  c.fillEllipse(rectF(680, 66, 50, 40), Amber)
  c.strokeEllipse(rectF(736, 66, 48, 40), Red, 2)

  c.label "line / polygon", 16, 122
  for i in 0 .. 7:
    let a = i.float32 * PI.float32 / 8
    c.line(60, 196, 60 + 40 * cos(a), 196 - 40 * sin(a), Ink, 1)
  c.line(110, 140, 190, 200, Red, 3)
  c.line(110, 200, 190, 140, Accent, 1.5)
  c.line(196, 150.5, 276, 150.5, Ink, 1)
  c.line(196, 160, 276, 160, Ink, 0.5)
  c.fillPolygon([pointF(300, 200), pointF(340, 140), pointF(380, 200)], Green)
  var hex: seq[PointF]
  for i in 0 ..< 6:
    let a = i.float32 * PI.float32 / 3
    hex.add pointF(430 + 32 * cos(a), 170 + 32 * sin(a))
  c.fillPolygon(hex, Accent)

  # ---- clip / translate / image ------------------------------------------
  c.label "clip", 480, 124
  let clipBox = rectF(480, 142, 140, 56)
  c.fillRect(clipBox, White)
  c.pushClip(clipBox)
  c.fillRect(rectF(470, 180, 170, 12), Amber)
  c.fillEllipse(rectF(560, 130, 80, 80), Accent.withAlpha(180))
  c.drawText("Clipped text overflows the box", body, 486, 148, Ink)
  c.pushClip(rectF(500, 160, 50, 30))                    # nested: intersection
  c.fillRect(rectF(480, 150, 200, 60), Red.withAlpha(150))
  c.popClip()
  c.popClip()
  c.frameRect(clipBox, Ink)

  c.label "translate", 640, 124
  c.pushTranslate(640, 142)
  c.frameRect(rectF(0, 0, 144, 56), Muted)
  c.pushTranslate(8, 8)
  c.fillRect(rectF(0, 0, 40, 40), Accent)
  c.pushTranslate(24, 12)
  c.fillRect(rectF(0, 0, 40, 40), Green.withAlpha(200))
  c.popTranslate()
  c.popTranslate()
  c.drawText("(0,0)", small, 92, 20, Ink)
  c.popTranslate()

  c.label "image (RGBA)", 16, 218
  c.drawImage(img, rectF(16, 236, 64, 64))
  c.drawImage(img, rectF(90, 236, 32, 32))
  c.drawImage(img, rectF(130, 236, 64, 64), rectF(0, 0, 16, 16))   # sub-rect
  c.drawImage(img, rectF(204, 236, 64, 64), alpha = 110)
  c.frameRect(rectF(16, 236, 64, 64), Muted)

  # ---- alignment grid ------------------------------------------------------
  c.label "textRect hAlign x vAlign", 290, 218
  let hs = [taLeft, taCenter, taRight]
  let vs = [vaTop, vaCenter, vaBottom]
  let hn = ["L", "C", "R"]
  let vn = ["T", "M", "B"]
  for vi in 0 .. 2:
    for hi in 0 .. 2:
      let cell = rectF(290 + hi.float32 * 98, 236 + vi.float32 * 34, 92, 30)
      c.fillRect(cell, White)
      c.frameRect(cell, rgb(200, 200, 208))
      c.textRect(vn[vi] & hn[hi] & " Text", small, cell.inflate(-3), Ink,
                 hs[hi], vs[vi])

  # ---- ellipsis + wrap -----------------------------------------------------
  c.label "ellipsis", 16, 316
  var wx = 16'f32
  for w in [150'f32, 110, 70, 40]:
    let cell = rectF(wx, 334, w, 24)
    c.fillRect(cell, White)
    c.frameRect(cell, rgb(200, 200, 208))
    c.textRect("A long single line of text", body, cell.inflate(-3), Ink)
    wx += w + 10
  c.fillRect(rectF(16, 366, 150, 24), White)
  c.textRect("No ellipsis, just clipped", body, rectF(19, 366, 144, 24), Ink,
             ellipsis = false)
  c.frameRect(rectF(16, 366, 150, 24), rgb(200, 200, 208))

  c.label "wrapped paragraph (left / center / right)", 16, 402
  var px = 16'f32
  for (al, nm) in [(taLeft, "left"), (taCenter, "center"), (taRight, "right")]:
    let box = rectF(px, 420, 240, 96)
    c.fillRect(box, White)
    c.frameRect(box, rgb(200, 200, 208))
    c.textRect(Lorem, small, box.inflate(-4), Ink, al, vaTop, wrap = true)
    px += 250
  let m = c.measureText(Lorem, small, 232)
  c.label "measureText(wrap 232) = " & formatFloat(m.w, ffDecimal, 1) & " x " &
          formatFloat(m.h, ffDecimal, 1), 16, 520

  # ---- fonts ---------------------------------------------------------------
  c.label "fonts", 16, 544
  var fx = 16'f32
  proc sample(c: Canvas, s: string, f: FontSpec, fx: var float32, y: float32) =
    c.drawText(s, f, fx, y, Ink)
    fx += c.measureText(s, f).w + 14
  c.sample "Regular", font(), fx, 562
  c.sample "Bold", font(style = {fsBold}), fx, 562
  c.sample "Italic", font(style = {fsItalic}), fx, 562
  c.sample "Bold italic (synthetic)", font(style = {fsBold, fsItalic}), fx, 562
  c.sample "Underline", font(style = {fsUnderline}), fx, 562
  c.sample "Strike", font(style = {fsStrikeOut}), fx, 562
  c.drawText("mono: let x = 42  // 0O1l", font("mono", 14), 16, 586, Ink)
  c.drawText("Fallback: → ★ ✓ ♥ ⌘ ♫ ⚙ ✈ ☂  (colour emoji: see notes)",
             font(size = 16), 330, 584, Ink)
  let fm = c.fontMetrics(body)
  c.label "ascent " & formatFloat(fm.ascent, ffDecimal, 1) & "  descent " &
          formatFloat(fm.descent, ffDecimal, 1) & "  line " &
          formatFloat(fm.lineHeight, ffDecimal, 1) & "   |   " & info, 16, lh - 22

proc fatal(msg: string) =
  stderr.writeLine msg & ": " & sdlError()
  quit 1

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let forcedS = getEnv("NIMVCL_SCALE")
  let forced = if forcedS.len > 0: parseFloat(forcedS).float32 else: 0'f32

  if not initSdl(): fatal "SDL_Init"
  if not initTtf(): fatal "TTF_Init"
  let fs = if forced > 0: forced else: 1'f32
  let window = createWindow("nimvcl canvas demo", cint(BaseW.float32 * fs),
                            cint(BaseH.float32 * fs),
                            WINDOW_RESIZABLE or WINDOW_HIGH_PIXEL_DENSITY)
  if window == nil: fatal "createWindow"
  let renderer = createRenderer(window, nil)
  if renderer == nil: fatal "createRenderer"
  discard setRenderVSync(renderer, 1)

  proc currentScale(): float32 =
    if forced > 0: return forced
    var pw, ph, lw, lh: cint
    discard getWindowSizeInPixels(window, pw, ph)
    discard getWindowSize(window, lw, lh)
    if lw > 0: pw.float32 / lw.float32 else: 1'f32

  let ctx = newRenderContext(renderer, currentScale())
  let img = makeImage()
  echo "renderer: ", getRendererName(renderer), "  scale: ", ctx.scale

  proc paint(path: string) =
    ctx.setScale currentScale()
    let cv = beginFrame(ctx)
    var pw, ph: cint
    discard getCurrentRenderOutputSize(renderer, pw, ph)
    let lw = pw.float32 / ctx.scale
    let lh = ph.float32 / ctx.scale
    let info = "scale " & formatFloat(ctx.scale, ffDecimal, 2) & "  " &
               $int(lw) & "x" & $int(lh) & " logical  " &
               $getRendererName(renderer)
    cv.drawScene(img, lw, lh, info)
    cv.endFrame()
    if path.len > 0:
      let surf = renderReadPixels(renderer, nil)
      if surf == nil: fatal "renderReadPixels"
      if not saveBMP(surf, path.cstring): fatal "saveBMP"
      destroySurface surf
      echo "wrote ", path
    else:
      discard renderPresent(renderer)

  if shot.len > 0:
    paint shot
  else:
    var running = true
    var dirty = true
    var ev: Event
    while running:
      if dirty:
        paint ""
        dirty = false
      if not waitEvent(ev): fatal "waitEvent"
      while true:
        case ev.type
        of EVENT_QUIT, EVENT_WINDOW_CLOSE_REQUESTED: running = false
        of EVENT_KEY_DOWN:
          if ev.key.key == SDLK_ESCAPE: running = false
        of EVENT_WINDOW_EXPOSED, EVENT_WINDOW_RESIZED,
           EVENT_WINDOW_PIXEL_SIZE_CHANGED, EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
          dirty = true
        else: discard
        if not pollEvent(ev): break

  # renderer-bound resources first, then the renderer
  ctx.close()
  destroyRenderer renderer
  destroyWindow window
  quitTtf()
  quitSdl()

main()
