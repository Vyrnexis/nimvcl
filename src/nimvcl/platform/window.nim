## `PlatformWindow`: an SDL window + renderer behind nimvcl-level procs.
## Core code (`Form`, `Host`) never calls SDL directly.
##
## "Points" are SDL window units. "Logical px" are nimvcl units: points divided
## by `forcedScale` when one is set (headless testing), else equal to points.
## The render scale (device px per logical px) is `scale`.

import std/strutils
import sdl3 except Color, Cursor
from sdl3_image import nil
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
    popup*: bool               ## created through `createPlatformPopup`
    popupFallback*: bool       ## a popup emulated with a borderless top-level window
    backbuf: Texture           ## persistent render target (partial repaints), device px
    bbW, bbH: cint             ## size the backbuffer was last (re)built for

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

proc dropBackbuffer*(w: PlatformWindow) =
  ## Frees the backbuffer texture (the next `ensureBackbuffer` rebuilds it).
  if w.backbuf != nil:
    destroyTexture(w.backbuf)
    w.backbuf = nil
  w.bbW = 0
  w.bbH = 0

proc destroy*(w: PlatformWindow) =
  ## Destroys the renderer, then the window (when owned). The RenderContext
  ## bound to the renderer must be closed BEFORE this.
  if w.window == nil: return
  w.dropBackbuffer()
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
  ## Device pixels per logical pixel: SDL's window pixel density (a float that
  ## does not wobble with the integer window size), else the pixel/point ratio.
  if w.forcedScale > 0: return w.forcedScale
  if w.window != nil:
    let d = getWindowPixelDensity(w.window)
    if d > 0: return float32(d)
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

# --------------------------------------------------------------- backbuffer

proc hasBackbuffer*(w: PlatformWindow): bool = w.backbuf != nil

proc ensureBackbuffer*(w: PlatformWindow): bool =
  ## Makes sure a render-target texture the size of the window's output exists.
  ## True when it was (re)created, i.e. its content is undefined and the caller
  ## must repaint everything. When the renderer cannot make target textures
  ## `hasBackbuffer` stays false and the caller paints straight to the window.
  ## The renderer's current target must be the window.
  var pw, ph: cint
  discard getCurrentRenderOutputSize(w.renderer, pw, ph)
  if pw <= 0 or ph <= 0: return false
  if pw == w.bbW and ph == w.bbH: return false
  w.dropBackbuffer()
  w.bbW = pw
  w.bbH = ph
  w.backbuf = createTexture(w.renderer, PIXELFORMAT_ARGB8888, TEXTUREACCESS_TARGET, pw, ph)
  if w.backbuf != nil:
    discard setTextureBlendMode(w.backbuf, BLENDMODE_NONE)
    discard setTextureScaleMode(w.backbuf, SCALEMODE_NEAREST)
  w.backbuf != nil

proc beginBackbuffer*(w: PlatformWindow) =
  ## Directs drawing into the backbuffer.
  discard setRenderTarget(w.renderer, w.backbuf)

proc endBackbuffer*(w: PlatformWindow) =
  ## Back to the window, then copies the whole backbuffer onto it (no
  ## blending). Does not present.
  discard setRenderTarget(w.renderer, nil)
  discard setRenderClipRect(w.renderer, nil)
  discard renderTexture(w.renderer, w.backbuf, nil, nil)

proc drawDebugRects*(w: PlatformWindow, rects: openArray[tuple[x, y, w, h: int]]) =
  ## Debug overlay on the window (not the backbuffer): a translucent red fill
  ## and an outline around each device-pixel rect. Gone with the next frame.
  discard setRenderDrawBlendMode(w.renderer, BLENDMODE_BLEND)
  for r in rects:
    var f = FRect(x: r.x.float32, y: r.y.float32, w: r.w.float32, h: r.h.float32)
    discard setRenderDrawColor(w.renderer, 255, 0, 0, 48)
    discard renderFillRect(w.renderer, f)
    discard setRenderDrawColor(w.renderer, 255, 0, 0, 255)
    discard renderRect(w.renderer, f)

proc rendererName*(w: PlatformWindow): string = $getRendererName(w.renderer)

proc writeImage*(w: PlatformWindow, path: string): bool =
  ## Reads back the renderer's current frame (call after drawing, before
  ## present) and writes it to `path`: a PNG when the name ends in `.png`
  ## (case-insensitive), a BMP otherwise. Used for headless screenshots.
  let s = renderReadPixels(w.renderer, nil)
  if s == nil: return false
  result =
    if path.toLowerAscii.endsWith(".png"): sdl3_image.savePNG(s, path.cstring)
    else: saveBMP(s, path.cstring)
  destroySurface s

proc writeBmp*(w: PlatformWindow, path: string): bool =
  ## Same as `writeImage` (kept for compatibility; the format follows the
  ## file extension).
  w.writeImage(path)

# ------------------------------------------------------------------ popups

type PopupStyle* = enum psMenu, psTooltip

proc createPlatformPopup*(parent: PlatformWindow, offX, offY, logicalW, logicalH: float32,
                          style: PopupStyle, forcedScale: float32 = 0): PlatformWindow =
  ## Creates a hidden popup window (SDL_CreatePopupWindow: `xdg_popup` on
  ## Wayland, an override-redirect window on X11) at (`offX`, `offY`) logical px
  ## from the top-left of `parent`'s client area. When the video driver cannot
  ## make popups (for example `offscreen`) it falls back to a borderless,
  ## always-on-top, utility top-level window at the same place
  ## (`popupFallback` is set); tooltips are then also not focusable.
  let fs = if forcedScale > 0: forcedScale else: 1'f32
  let w = cint(max(logicalW * fs, 1))
  let h = cint(max(logicalH * fs, 1))
  let kind = if style == psMenu: WINDOW_POPUP_MENU else: WINDOW_TOOLTIP
  var win = createPopupWindow(parent.window, cint(offX * fs), cint(offY * fs), w, h,
                              kind or WINDOW_HIGH_PIXEL_DENSITY or WINDOW_HIDDEN)
  var fallback = false
  if win == nil:
    fallback = true
    var flags = WINDOW_HIGH_PIXEL_DENSITY or WINDOW_HIDDEN or WINDOW_BORDERLESS or
                WINDOW_ALWAYS_ON_TOP or WINDOW_UTILITY
    if style == psTooltip: flags = flags or WINDOW_NOT_FOCUSABLE
    win = createWindow("", w, h, flags)
    if win == nil: raise newException(IOError, "createPopup: " & sdlError())
    var px, py: cint
    discard getWindowPosition(parent.window, px, py)
    discard setWindowPosition(win, px + cint(offX * fs), py + cint(offY * fs))
  let r = createRenderer(win, nil)
  if r == nil:
    let e = sdlError()
    destroyWindow(win)
    raise newException(IOError, "createRenderer: " & e)
  discard setRenderVSync(r, 1)
  PlatformWindow(window: win, renderer: r, owned: true, forcedScale: forcedScale,
                 popup: true, popupFallback: fallback)

proc keyboardFocusId*(): uint32 =
  ## ID of the window with keyboard focus, 0 when none.
  let w = getKeyboardFocus()
  if w == nil: 0'u32 else: uint32(getWindowID(w))

proc isWaylandDriver*(): bool = $getCurrentVideoDriver() == "wayland"

proc displayUsableBounds*(w: PlatformWindow): tuple[ok: bool, x, y, w, h: float32] =
  ## Usable area of the display `w` is on, in global window points.
  var r: Rect
  if not getDisplayUsableBounds(getDisplayForWindow(w.window), r): return
  (true, float32(r.x), float32(r.y), float32(r.w), float32(r.h))
