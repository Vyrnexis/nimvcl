## Host mode: embedding a control tree in a caller-owned SDL3 window/renderer.

import std/unittest
import sdl3 except Color, Cursor
import nimvcl

type
  Panel = ref object of Container
    clicks: int
    focusable: bool

method paint(p: Panel, c: Canvas) = c.fillRect(p.clientRect, rgb(255, 0, 0))
method doClick(p: Panel) = inc p.clicks
method canFocus(p: Panel): bool = p.focusable and p.isVisible and p.isEnabled

proc pixel(r: Renderer, x, y: int): (uint8, uint8, uint8) =
  let s = renderReadPixels(r, nil)
  var a: uint8
  discard readSurfacePixel(s, cint(x), cint(y), result[0], result[1], result[2], a)
  destroySurface s

suite "host mode":
  test "events, painting, close":
    check initSdl()
    let win = createWindow("host test", 300, 200, WINDOW_HIGH_PIXEL_DENSITY)
    check win != nil
    let ren = createRenderer(win, nil)
    check ren != nil
    let root = newContainer()
    let p = Panel(focusable: true)
    p.initContainer()
    p.setBounds(20, 20, 100, 60)
    p.tabStop = true
    root.insertControl(p)
    let host = newHost(win, ren, root)
    check root.width == 300 and root.height == 200
    check host.ctx.scale == 1

    var ev: Event
    proc motion(x, y: float32): Event =
      result.motion = MouseMotionEvent(`type`: EVENT_MOUSE_MOTION,
        windowID: getWindowID(win), x: x, y: y)
    proc button(down: bool, x, y: float32): Event =
      result.button = MouseButtonEvent(
        `type`: if down: EVENT_MOUSE_BUTTON_DOWN else: EVENT_MOUSE_BUTTON_UP,
        windowID: getWindowID(win), button: 1, down: down, clicks: 1, x: x, y: y)

    ev = motion(30, 30)
    check host.handleEvent(ev)                 # over the panel
    ev = motion(200, 150)
    check not host.handleEvent(ev)             # over nothing
    ev = button(true, 200, 150)
    check not host.handleEvent(ev)
    ev = button(false, 200, 150)
    check not host.handleEvent(ev)
    check p.clicks == 0
    ev = button(true, 30, 30)
    check host.handleEvent(ev)
    ev = button(false, 30, 30)
    check host.handleEvent(ev)
    check p.clicks == 1
    check host.focusedControl == p             # focused by the press

    # keyboard: consumed only while something is focused
    var k: Event
    k.key = KeyboardEvent(`type`: EVENT_KEY_DOWN, windowID: getWindowID(win),
                          key: uint32(ord('x')), down: true)
    check host.handleEvent(k)
    host.focusControl(nil)
    check not host.handleEvent(k)

    # events for another window are ignored
    ev = motion(30, 30)
    ev.motion.windowID = getWindowID(win) + 1000
    check not host.handleEvent(ev)

    # painting draws over what the app drew; no clear, no present
    discard setRenderDrawColor(ren, 0, 0, 255, 255)
    discard renderClear(ren)
    host.paint()
    check ren.pixel(40, 40) == (255'u8, 0'u8, 0'u8)
    check ren.pixel(250, 150) == (0'u8, 0'u8, 255'u8)
    check not host.needsPaint

    # resize through the event path
    discard setWindowSize(win, 400, 250)
    var rz: Event
    rz.window = WindowEvent(`type`: EVENT_WINDOW_RESIZED, windowID: getWindowID(win))
    check not host.handleEvent(rz)
    check root.width == 400 and root.height == 250

    host.close()
    check host.ctx == nil
    destroyRenderer ren
    destroyWindow win
    quitSdl()
