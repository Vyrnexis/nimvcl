## `PlatformWindow`: an SDL window + renderer behind nimvcl-level procs.
## Core code (`Form`, `Host`) never calls SDL directly.
##
## "Points" are SDL window units. "Logical px" are nimvcl units: points divided
## by `forcedScale` when one is set (headless testing), else equal to points.
## The render scale (device px per logical px) is `scale`.

import sdl3 except Color, Cursor
import ../graphics/geometry
import ./sdlutil

export sdl3.Window, sdl3.Renderer

type
  PlatformWindow* = ref object
    window*: Window
    renderer*: Renderer
    owned*: bool               ## destroy window and renderer in `destroy`
    forcedScale*: float32      ## 0 = use the real pixel density
    textInputOn: bool

proc wrapWindow*(window: Window, renderer: Renderer): PlatformWindow =
  ## Wraps a window and renderer owned by the caller (host mode).
  PlatformWindow(window: window, renderer: renderer, owned: false)

proc createPlatformWindow*(title: string, logicalW, logicalH: float32,
                           resizable, borderless, stayOnTop: bool,
                           forcedScale: float32 = 0): PlatformWindow =
  ## Creates a hidden high-density window with a vsynced renderer.
  let fs = if forcedScale > 0: forcedScale else: 1'f32
  var flags = WINDOW_HIGH_PIXEL_DENSITY or WINDOW_HIDDEN
  if resizable: flags = flags or WINDOW_RESIZABLE
  if borderless: flags = flags or WINDOW_BORDERLESS
  if stayOnTop: flags = flags or WINDOW_ALWAYS_ON_TOP
  let w = createWindow(title.cstring, cint(max(logicalW * fs, 1)),
                       cint(max(logicalH * fs, 1)), flags)
  if w == nil: raise newException(IOError, "createWindow: " & sdlError())
  let r = createRenderer(w, nil)
  if r == nil:
    let e = sdlError()
    destroyWindow(w)
    raise newException(IOError, "createRenderer: " & e)
  discard setRenderVSync(r, 1)
  PlatformWindow(window: w, renderer: r, owned: true, forcedScale: forcedScale)

proc destroy*(w: PlatformWindow) =
  ## Destroys the renderer, then the window (when owned). The RenderContext
  ## bound to the renderer must be closed BEFORE this.
  if w.window == nil: return
  if w.owned:
    if w.renderer != nil: destroyRenderer(w.renderer)
    destroyWindow(w.window)
  w.renderer = nil
  w.window = nil

func id*(w: PlatformWindow): uint32 =
  if w.window == nil: 0'u32 else: uint32(getWindowID(w.window))

func coordScale(w: PlatformWindow): float32 =
  if w.forcedScale > 0: w.forcedScale else: 1'f32

func toLogical*(w: PlatformWindow, points: float32): float32 =
  points / w.coordScale

proc pointSize*(w: PlatformWindow): tuple[w, h: int] =
  var a, b: cint
  discard getWindowSize(w.window, a, b)
  (int(a), int(b))

proc pixelSize*(w: PlatformWindow): tuple[w, h: int] =
  var a, b: cint
  discard getWindowSizeInPixels(w.window, a, b)
  (int(a), int(b))

proc logicalSize*(w: PlatformWindow): SizeF =
  let (a, b) = w.pointSize
  sizeF(float32(a) / w.coordScale, float32(b) / w.coordScale)

proc scale*(w: PlatformWindow): float32 =
  ## Device pixels per logical pixel.
  if w.forcedScale > 0: return w.forcedScale
  let (pw, _) = w.pixelSize
  let (lw, _) = w.pointSize
  if lw > 0 and pw > 0: float32(pw) / float32(lw) else: 1'f32

proc setLogicalSize*(w: PlatformWindow, lw, lh: float32) =
  let s = w.coordScale
  discard setWindowSize(w.window, cint(max(lw * s, 1)), cint(max(lh * s, 1)))

proc setTitle*(w: PlatformWindow, title: string) =
  discard setWindowTitle(w.window, title.cstring)

proc show*(w: PlatformWindow) = discard showWindow(w.window)
proc hide*(w: PlatformWindow) = discard hideWindow(w.window)
proc raiseWindow*(w: PlatformWindow) = discard sdl3.raiseWindow(w.window)

proc setBordered*(w: PlatformWindow, v: bool) = discard setWindowBordered(w.window, v)
proc setResizable*(w: PlatformWindow, v: bool) = discard setWindowResizable(w.window, v)
proc setStayOnTop*(w: PlatformWindow, v: bool) = discard setWindowAlwaysOnTop(w.window, v)

proc setPosition*(w: PlatformWindow, x, y: int) =
  discard setWindowPosition(w.window, cint(x), cint(y))

proc position*(w: PlatformWindow): tuple[x, y: int] =
  var a, b: cint
  discard getWindowPosition(w.window, a, b)
  (int(a), int(b))

proc centerOnScreen*(w: PlatformWindow) =
  discard setWindowPosition(w.window, cint(WINDOWPOS_CENTERED),
                            cint(WINDOWPOS_CENTERED))

proc centerOn*(w, other: PlatformWindow) =
  ## Centers `w` over `other` (points).
  let (ox, oy) = other.position
  let (ow, oh) = other.pointSize
  let (sw, sh) = w.pointSize
  w.setPosition(ox + (ow - sw) div 2, oy + (oh - sh) div 2)

proc setModalFor*(w, parent: PlatformWindow) =
  ## Makes `w` a modal child of `parent` for the window manager (best effort;
  ## unsupported on some platforms and ignored there).
  discard setWindowParent(w.window, parent.window)
  discard setWindowModal(w.window, true)

proc clearModal*(w: PlatformWindow) =
  discard setWindowModal(w.window, false)
  discard setWindowParent(w.window, nil)

proc startTextInput*(w: PlatformWindow) =
  if not w.textInputOn:
    discard sdl3.startTextInput(w.window)
    w.textInputOn = true

proc stopTextInput*(w: PlatformWindow) =
  if w.textInputOn:
    discard sdl3.stopTextInput(w.window)
    w.textInputOn = false

proc setTextInputArea*(w: PlatformWindow, r: RectF) =
  ## IME candidate/composition area, in logical px of the window.
  let s = w.coordScale
  var rc = Rect(x: cint(r.x * s), y: cint(r.y * s), w: cint(r.w * s), h: cint(r.h * s))
  discard sdl3.setTextInputArea(w.window, addr rc, 0)

proc present*(w: PlatformWindow) = discard renderPresent(w.renderer)

proc rendererName*(w: PlatformWindow): string = $getRendererName(w.renderer)

proc writeBmp*(w: PlatformWindow, path: string): bool =
  ## Reads back the renderer's current frame (call after drawing, before
  ## present) and writes it as a BMP. Used for headless screenshots.
  let s = renderReadPixels(w.renderer, nil)
  if s == nil: return false
  result = saveBMP(s, path.cstring)
  destroySurface s
