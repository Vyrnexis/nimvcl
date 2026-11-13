## Headless tests: golden images (software renderer on a surface, scale 1 and 2)
## plus non-pixel tests of the stacks, caches and resource lifetime.
## Env NIMVCL_UPDATE_GOLDEN=1 rewrites the golden BMPs.

import std/[unittest, os, strutils]
import sdl3 except Color
import nimvcl

const
  GoldenDir = currentSourcePath().parentDir / "golden"
  ChannelTol = 24        # per-channel difference that still counts as equal
  MaxBadRatio = 0.004    # fraction of pixels allowed to exceed the tolerance
  SceneW = 220
  SceneH = 130

type Target = object
  surf: ptr Surface
  renderer: Renderer
  ctx: RenderContext

proc openTarget(w, h: int, scale: float32): Target =
  result.surf = createSurface(cint(float32(w) * scale), cint(float32(h) * scale),
                              PIXELFORMAT_RGBA32)
  doAssert result.surf != nil, sdlError()
  result.renderer = createSoftwareRenderer(result.surf)
  doAssert result.renderer != nil, sdlError()
  result.ctx = newRenderContext(result.renderer, scale)

proc closeTarget(t: var Target) =
  # renderer-bound resources first, then the renderer, then the surface
  t.ctx.close()
  destroyRenderer t.renderer
  destroySurface t.surf

template withTarget(name: untyped, w, h: int, scale: float32, body: untyped) =
  block:
    var name = openTarget(w, h, scale)
    try:
      body
    finally:
      closeTarget name

proc makeImage(): Image =
  var px = newSeq[uint8](8 * 8 * 4)
  for y in 0 ..< 8:
    for x in 0 ..< 8:
      let o = (y * 8 + x) * 4
      px[o] = uint8(x * 36)
      px[o + 1] = uint8(y * 36)
      px[o + 2] = 128
      px[o + 3] = 255
  imageFromRgba(8, 8, px)

proc drawScene(c: Canvas, img: Image) =
  let f = font(size = 12)
  c.clear rgb(240, 240, 244)
  c.fillRect(rectF(8, 8, 40, 24), rgb(220, 60, 50))
  c.frameRect(rectF(56, 8, 40, 24), rgb(20, 20, 30))
  c.frameRect(rectF(104, 8, 40, 24), rgb(40, 110, 220), 2)
  c.fillRoundRect(rectF(152, 8, 60, 24), 8, rgb(40, 110, 220))
  c.strokeRoundRect(rectF(8, 40, 60, 24), 8, rgb(40, 110, 220))
  c.fillEllipse(rectF(76, 40, 40, 24), rgb(230, 170, 40))
  c.strokeEllipse(rectF(124, 40, 40, 24), rgb(220, 60, 50), 2)
  c.line(172, 40, 212, 64, rgb(20, 20, 30), 1.5)
  c.fillPolygon([pointF(8, 108), pointF(28, 72), pointF(48, 108)], rgb(50, 160, 100))
  c.drawImage(img, rectF(56, 72, 32, 32))
  c.drawImage(img, rectF(92, 72, 32, 32), alpha = 100)
  let box = rectF(130, 72, 80, 24)
  c.fillRect(box, rgb(255, 255, 255))
  c.pushClip(box)
  c.pushTranslate(130, 72)
  c.drawText("Clipped text overflows", f, 4, 4, rgb(20, 20, 30))
  c.popTranslate()
  c.popClip()
  c.frameRect(box, rgb(20, 20, 30))
  c.textRect("Ellipsis for a long line", f, rectF(130, 100, 80, 20), rgb(20, 20, 30))
  c.textRect("Mid", f, rectF(56, 108, 68, 18), rgb(20, 20, 30), taCenter, vaCenter)

proc renderScene(scale: float32): ptr Surface =
  ## Renders the fixed scene; the caller frees the returned RGBA32 surface.
  let img = makeImage()
  withTarget(t, SceneW, SceneH, scale):
    let c = beginFrame(t.ctx)
    c.drawScene(img)
    c.endFrame()
    let raw = renderReadPixels(t.renderer, nil)
    doAssert raw != nil, sdlError()
    result = convertSurface(raw, PIXELFORMAT_RGBA32)
    destroySurface raw
    doAssert result != nil

proc compareGolden(name: string, got: ptr Surface): tuple[bad: float, w, h: int] =
  let path = GoldenDir / name
  if getEnv("NIMVCL_UPDATE_GOLDEN") == "1":
    createDir GoldenDir
    doAssert saveBMP(got, path.cstring), sdlError()
    echo "updated golden ", path
    return (0.0, got.w.int, got.h.int)
  doAssert fileExists(path), "missing golden " & path & " (run with NIMVCL_UPDATE_GOLDEN=1)"
  let raw = loadBMP(path.cstring)
  doAssert raw != nil, sdlError()
  let exp = convertSurface(raw, PIXELFORMAT_RGBA32)
  destroySurface raw
  defer: destroySurface exp
  doAssert exp.w == got.w and exp.h == got.h,
    "golden size " & $exp.w & "x" & $exp.h & " != " & $got.w & "x" & $got.h
  var bad = 0
  for y in 0 ..< got.h.int:
    for x in 0 ..< got.w.int * 4:
      if abs(int(got.pixels[y * got.pitch + x]) - int(exp.pixels[y * exp.pitch + x])) > ChannelTol:
        inc bad
  (bad.float / (got.w.float * got.h.float * 4), got.w.int, got.h.int)

suite "canvas golden images":
  setup:
    doAssert initSdl(InitFlags(0)), sdlError()
    doAssert initTtf(), sdlError()
  teardown:
    quitTtf()
    quitSdl()

  for sc in [1.0'f32, 2.0'f32]:
    test "scene at scale " & $sc:
      let got = renderScene(sc)
      defer: destroySurface got
      let (bad, w, h) = compareGolden("scene_" & $sc & "x.bmp", got)
      check w == int(SceneW.float32 * sc)
      check h == int(SceneH.float32 * sc)
      check bad <= MaxBadRatio

  test "frameRect is crisp: 1 logical px is whole device px":
    for sc in [1.0'f32, 1.5'f32, 2.0'f32]:
      withTarget(t, 20, 20, sc):
        let c = beginFrame(t.ctx)
        c.clear rgb(255, 255, 255)
        c.frameRect(rectF(2, 2, 10, 10), rgb(0, 0, 0))
        c.endFrame()
        let raw = renderReadPixels(t.renderer, nil)
        let s = convertSurface(raw, PIXELFORMAT_RGBA32)
        destroySurface raw
        defer: destroySurface s
        # every pixel is pure black or pure white (no blending)
        for y in 0 ..< s.h.int:
          for x in 0 ..< s.w.int:
            let v = s.pixels[y * s.pitch + x * 4]
            check (v == 0 or v == 255)

suite "canvas state":
  setup:
    doAssert initSdl(InitFlags(0)), sdlError()
    doAssert initTtf(), sdlError()
  teardown:
    quitTtf()
    quitSdl()

  test "clip stack intersects in absolute coordinates":
    withTarget(t, 100, 100, 1.0):
      let c = beginFrame(t.ctx)
      check c.currentClip == rectF(0, 0, 100, 100)
      c.pushClip(rectF(10, 10, 50, 50))
      check c.currentClip == rectF(10, 10, 50, 50)
      c.pushTranslate(5, 5)
      # local (0,0,100,100) is absolute (5,5,100,100); intersect with (10,10,50,50)
      c.pushClip(rectF(0, 0, 100, 100))
      check c.clipDepth == 2
      check c.currentClip == rectF(5, 5, 50, 50)       # absolute (10..60) minus the offset
      check c.isClippedOut(rectF(60, 60, 10, 10))      # local 60 = absolute 65 > 60
      check not c.isClippedOut(rectF(40, 40, 10, 10))
      c.popClip()
      c.popTranslate()
      check c.currentClip == rectF(10, 10, 50, 50)
      c.pushClip(rectF(100, 100, 5, 5))                # disjoint -> empty
      check c.currentClip.isEmpty
      check c.isClippedOut(rectF(0, 0, 100, 100))
      c.popClip()
      c.popClip()
      check c.clipDepth == 0
      check c.currentClip == rectF(0, 0, 100, 100)
      c.endFrame()

  test "clip actually limits drawing":
    withTarget(t, 20, 20, 2.0):
      let c = beginFrame(t.ctx)
      c.clear rgb(255, 255, 255)
      c.pushClip(rectF(5, 5, 5, 5))
      c.fillRect(rectF(0, 0, 20, 20), rgb(255, 0, 0))
      c.popClip()
      c.endFrame()
      let raw = renderReadPixels(t.renderer, nil)
      let s = convertSurface(raw, PIXELFORMAT_RGBA32)
      destroySurface raw
      defer: destroySurface s
      template px(x, y: int): uint8 = s.pixels[y * s.pitch + x * 4 + 1]   # green
      check px(12, 12) == 0        # inside (10..20 device px)
      check px(9, 12) == 255       # just left of the clip
      check px(20, 12) == 255      # just right of it

  test "font resolution":
    check resolveFont(font()).path.endsWith("NotoSans-Regular.ttf")
    check resolveFont(font(style = {fsBold})).path.endsWith("NotoSans-Bold.ttf")
    check resolveFont(font(style = {fsBold})).ttfStyle == 0
    check resolveFont(font(style = {fsItalic})).path.endsWith("NotoSans-Italic.ttf")
    # no bold-italic file: a real file plus one synthetic bit
    let bi = resolveFont(font(style = {fsBold, fsItalic}))
    check bi.ttfStyle != 0
    # mono has only a regular file: bold is synthetic
    let mb = resolveFont(font("mono", style = {fsBold}))
    check mb.path.endsWith("NotoSansMono-Regular.ttf")
    check (mb.ttfStyle and 1'u32) != 0
    check resolveFont(font("no-such-family")).path.endsWith("NotoSans-Regular.ttf")

  test "underline and strike are drawn by the canvas in the text colour":
    for sc in [1.0'f32, 2.0'f32]:
      # dark pixels in rows y0..y1 of x < 40 logical, for each style
      proc darkRun(style: set[FontStyle], y0, y1: float32): int =
        withTarget(t, 120, 30, sc):
          let c = beginFrame(t.ctx)
          c.clear rgb(255, 255, 255)
          let f = font("sans", 14, style)
          c.drawText("Hello", f, 4, 4, clBlack)
          c.textRect("Wrapped words here", f, rectF(60, 0, 58, 30), clBlack,
                     wrap = true, vAlign = vaBottom)
          c.endFrame()
          let raw = renderReadPixels(t.renderer, nil)
          let s = convertSurface(raw, PIXELFORMAT_RGBA32)
          destroySurface raw
          for yy in int(y0 * sc) .. int(y1 * sc):
            for x in 0 ..< int(40 * sc):
              if s.pixels[yy * s.pitch + x * 4] < 100: inc result
          destroySurface s
      let asc = block:
        var a: float32
        withTarget(t, 10, 10, sc): a = beginFrame(t.ctx).fontMetrics(font("sans", 14)).ascent
        a
      let base = 4 + asc
      # underline: just below the baseline
      check darkRun({fsUnderline}, base + 0.5, base + 1.5) >
            darkRun({}, base + 0.5, base + 1.5) + int(20 * sc)
      # strike: a dark line through the x-height middle, wider than plain glyph strokes
      let mid = base - 0.3 * asc
      check darkRun({fsStrikeOut}, mid - 1, mid + 1) >
            darkRun({}, mid - 1, mid + 1) + int(8 * sc)
      # no light gap: at least one row near mid is dark across most of "Hello"
      var best = 0
      for k in 0 .. 3:
        best = max(best, darkRun({fsStrikeOut}, mid - 1.5 + k.float32 * 0.5,
                                 mid - 1.5 + k.float32 * 0.5))
      check best > int(28 * sc)

  test "text and font caches are reused":
    withTarget(t, 100, 40, 1.0):
      let c = beginFrame(t.ctx)
      c.drawText("hello", font(), 0, 0, clBlack)
      c.drawText("hello", font(), 0, 20, clBlack)
      check t.ctx.textCount == 1
      check t.ctx.fontCount == 1
      let m1 = c.measureText("hello", font())
      check m1.w > 10 and m1.h > 8
      check t.ctx.textCount == 1
      check c.measureText("", font()).h > 0
      let fm = c.fontMetrics(font())
      check fm.ascent > 0 and fm.descent > 0 and fm.lineHeight >= fm.ascent
      c.endFrame()

  test "measureText scales with the display scale (logical result)":
    var w1, w2: float32
    withTarget(t, 100, 40, 1.0):
      w1 = beginFrame(t.ctx).measureText("Hello world", font()).w
    withTarget(t, 100, 40, 2.0):
      w2 = beginFrame(t.ctx).measureText("Hello world", font()).w
    check abs(w1 - w2) < 1.5

  test "sweep destroys unused entries":
    withTarget(t, 100, 40, 1.0):
      t.ctx.maxIdleFrames = 3
      let img = makeImage()
      var c = beginFrame(t.ctx)
      c.drawText("keep", font(), 0, 0, clBlack)
      c.drawText("drop", font("mono"), 0, 10, clBlack)
      c.drawImage(img, rectF(0, 20, 8, 8))
      c.endFrame()
      check t.ctx.textCount == 2
      check t.ctx.fontCount == 2
      check t.ctx.textureCount == 1
      for i in 1 .. 6:                       # "keep" is used every frame, the rest idle
        c = beginFrame(t.ctx)
        c.drawText("keep", font(), 0, 0, clBlack)
        c.endFrame()
      check t.ctx.textCount == 1
      check t.ctx.fontCount == 1
      check t.ctx.textureCount == 0
      # a swept entry is simply recreated on demand
      c = beginFrame(t.ctx)
      c.drawImage(img, rectF(0, 20, 8, 8))
      c.drawText("drop", font("mono"), 0, 10, clBlack)
      c.endFrame()
      check t.ctx.textCount == 2
      check t.ctx.textureCount == 1

  test "text cache cap":
    withTarget(t, 100, 40, 1.0):
      t.ctx.textCacheCap = 8
      var c = beginFrame(t.ctx)
      for i in 0 ..< 20: c.drawText("item " & $i, font(), 0, 0, clBlack)
      c.endFrame()
      check t.ctx.textCount == 20             # all used this frame: kept
      c = beginFrame(t.ctx)
      c.endFrame()
      check t.ctx.textCount <= 8

  test "texture is re-uploaded when the image changes":
    withTarget(t, 20, 20, 1.0):
      let img = newImage(4, 4, rgb(255, 0, 0))
      for i in 0 ..< 2:
        let c = beginFrame(t.ctx)
        c.clear rgb(0, 0, 0)
        c.drawImage(img, rectF(0, 0, 4, 4))
        c.endFrame()
        let raw = renderReadPixels(t.renderer, nil)
        let s = convertSurface(raw, PIXELFORMAT_RGBA32)
        destroySurface raw
        let r = s.pixels[1 * s.pitch + 1 * 4]
        let g = s.pixels[1 * s.pitch + 1 * 4 + 1]
        destroySurface s
        if i == 0:
          check (r, g) == (255'u8, 0'u8)
          let gen = img.generation
          img.setPixel(1, 1, rgb(0, 255, 0))
          check img.generation != gen
        else:
          check (r, g) == (0'u8, 255'u8)
      check t.ctx.textureCount == 1

  test "setScale clears font and text caches, keeps textures":
    withTarget(t, 100, 40, 1.0):
      let img = makeImage()
      let c = beginFrame(t.ctx)
      c.drawText("hi", font(), 0, 0, clBlack)
      c.drawImage(img, rectF(0, 20, 8, 8))
      c.endFrame()
      check t.ctx.fontCount == 1 and t.ctx.textCount == 1 and t.ctx.textureCount == 1
      t.ctx.setScale 1.0                       # unchanged scale: nothing happens
      check t.ctx.fontCount == 1
      t.ctx.setScale 1.5
      check t.ctx.scale == 1.5
      check t.ctx.fontCount == 0
      check t.ctx.textCount == 0
      check t.ctx.textureCount == 1

  test "close frees everything and is idempotent":
    var t = openTarget(100, 40, 1.0)
    let img = makeImage()
    let c = beginFrame(t.ctx)
    c.drawText("bye", font(), 0, 0, clBlack)
    c.drawImage(img, rectF(0, 20, 8, 8))
    c.endFrame()
    check t.ctx.fontCount + t.ctx.textCount + t.ctx.textureCount == 3
    t.ctx.close()
    check t.ctx.isClosed
    check t.ctx.fontCount == 0 and t.ctx.textCount == 0 and t.ctx.textureCount == 0
    t.ctx.close()                              # second close is a no-op
    destroyRenderer t.renderer
    destroySurface t.surf

suite "images and platform helpers":
  setup:
    doAssert initSdl(InitFlags(0)), sdlError()
  teardown:
    quitSdl()

  test "image from RGBA pixels":
    let img = imageFromRgba(2, 1, [1'u8, 2, 3, 4, 5, 6, 7, 8])
    check img.width == 2 and img.height == 1
    check img.getPixel(0, 0) == rgba(1, 2, 3, 4)
    check img.getPixel(1, 0) == rgba(5, 6, 7, 8)
    check imageFromRgba(1, 1, [0'u8, 0, 0, 0]).id != img.id
    expect ImageError: discard imageFromRgba(4, 4, [0'u8])
    expect ImageError: discard loadImage("/no/such/file.png")

  test "user event type accessor":
    let base = registerEvents(2)
    check base != 0
    var ev: Event
    ev.user.`type` = base + 1
    check userEventType(ev) == base + 1
