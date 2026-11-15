## Partial repainting (dirty rectangles). Headless (offscreen SDL, software
## renderer): rect accumulation and merging, what a caret blink repaints, and
## pixel equality of the backbuffer after partial repaints with a fresh full
## repaint. Host mode keeps repainting fully.

import std/[unittest, os, importutils]
import sdl3 except Color, Cursor
import nimvcl
import nimvcl/controls/edit
privateAccess(Edit)

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: mbLeft, clicks: 1))
proc moveTo(f: Form, x, y: float32) = f.feed(ekMouseMove, x, y)

proc bytesOf(f: Form, full: bool): string =
  let path = getTempDir() / "nimvcl_repaint.bmp"
  doAssert f.screenshot(path, full)
  result = readFile(path)
  removeFile path

proc settle(f: Form) =
  ## Paints what is pending, like the application loop does.
  discard f.paintIfDirty()

proc checkSame(f: Form, what: string) =
  ## Partial repaints so far must equal a fresh full repaint. The first image is
  ## taken (partial) BEFORE the reference, which then discards the backbuffer.
  f.settle()
  let partial = bytesOf(f, full = false)
  let fresh = bytesOf(f, full = true)
  checkpoint what
  check partial.len == fresh.len
  check partial == fresh

type
  Tile = ref object of Control
    ## Translucent, anti-aliased rounded shape that paints over its parent.
    col: Color

method paint(t: Tile, c: Canvas) =
  c.fillRoundRect(t.clientRect, 12, t.col)

proc newTile(parent: Container, x, y, w, h: float32, col: Color): Tile =
  result = Tile(col: col)
  result.initControl()
  result.setBounds(x, y, w, h)
  parent.insertControl result

proc build(): tuple[f: Form, btn: Button, edit: Edit, sb: ScrollBox, a, b: Tile,
                    prog: ProgressBar, panel: Panel] =
  let f = newForm(nil, 420, 320)
  let panel = newPanel(f, "", 10, 10, 200, 140)
  let btn = newButton(panel, "Hover me", 20, 20, 100, 28)
  let a = newTile(panel, 60, 60, 90, 60, rgba(200, 60, 60, 200))
  let b = newTile(panel, 100, 80, 90, 50, rgba(60, 60, 200, 160))   # overlaps `a`
  let edit = newEdit(f, "hello", 230, 20, 160, 24)
  let sb = newScrollBox(f, 230, 60, 170, 120)
  for i in 0 ..< 8: newButton(sb, "item " & $i, 10, float32(10 + i * 40), 100, 28)
  let prog = newProgressBar(f, 10, 170, 200, 18)
  prog.max = 100
  newLabel(f, "A label", 230, 200)
  f.show()
  f.settle()
  (f, btn, edit, sb, a, b, prog, panel)

suite "dirty rects":
  test "overlapping and touching rects merge, disjoint ones stay apart":
    var l: seq[RectF]
    l.addDirtyRect(rectF(0, 0, 10, 10))
    l.addDirtyRect(rectF(20, 20, 10, 10))
    check l.len == 2
    l.addDirtyRect(rectF(5, 5, 10, 10))          # overlaps the first
    check l.len == 2
    check rectF(0, 0, 15, 15) in l
    l.addDirtyRect(rectF(15, 0, 5, 30))          # touches both: one rect left
    check l.len == 1
    check l[0] == rectF(0, 0, 30, 30)

  test "more than the limit collapse to the bounding box":
    var l: seq[RectF]
    for i in 0 ..< 7: l.addDirtyRect(rectF(float32(i * 20), float32(i * 20), 5, 5))
    check l.len == 1
    check l[0] == rectF(0, 0, 125, 125)

suite "partial repaint":
  setup:
    Application.init()
    Application.forceScale = 1
  teardown:
    Application.theme = themeLight()
    for f in openForms(): f.freeWindow()
    Application.forceScale = 0

  test "a small invalidate leaves a small region, clipped and snapped":
    let (f, btn, _, _, _, _, _, _) = build()
    check not f.ui.needsPaint
    btn.invalidate(rectF(2, 2, 10, 10))
    check f.ui.needsPaint and not f.ui.dirty
    check f.ui.dirtyRects.len == 1
    # button at (20, 20) in a panel at (10, 10): form coordinates
    check f.ui.dirtyRects[0].x >= 30 and f.ui.dirtyRects[0].w <= 12
    btn.invalidate(rectF(-50, -50, 5, 5))        # outside the control: nothing
    check f.ui.dirtyRects.len == 1
    f.settle()
    check not f.ui.lastPaintFull
    check f.ui.dirtyRects.len == 0

  test "invalidating the whole form is a full repaint":
    let (f, _, _, _, _, _, _, _) = build()
    f.invalidate()
    check f.ui.dirty
    f.settle()
    check f.ui.lastPaintFull

  test "invalidate is clipped to the scroll viewport":
    let (f, _, _, sb, _, _, _, _) = build()
    let c = sb[7]                                 # far below the viewport
    c.invalidate()
    check not f.ui.needsPaint

  test "caret blink repaints only the caret area":
    let (f, _, edit, _, _, _, _, _) = build()
    edit.setFocus()
    f.settle()
    check edit.focused and edit.blink != nil
    let full0 = gPaintedControls
    f.invalidate()
    f.settle()
    let fullCost = gPaintedControls - full0
    let on0 = edit.caretOn
    edit.blink.onTimer(edit.blink)               # one blink tick
    check edit.caretOn != on0
    check f.ui.dirtyRects.len == 1 and not f.ui.dirty
    let r = f.ui.dirtyRects[0]
    check r.w <= 4 and r.h <= edit.height
    let before = gPaintedControls
    f.settle()
    let cost = gPaintedControls - before
    check not f.ui.lastPaintFull
    check f.ui.lastPaintRects.len == 1
    check cost > 0 and cost < fullCost            # fewer controls than a full frame
    check cost <= 3                               # form, edit (and nothing else)
    checkSame(f, "after a caret blink")
    edit.blink.onTimer(edit.blink)
    checkSame(f, "after the second blink")

  test "hover over a rounded button":
    let (f, btn, _, _, _, _, _, _) = build()
    checkSame(f, "initial")
    f.moveTo(45, 45)                              # inside the button
    check f.ui.hovered == Control(btn)
    checkSame(f, "button hovered")
    f.moveTo(300, 300)
    checkSame(f, "button unhovered")

  test "translucent AA tiles over a panel, overlapping siblings":
    let (f, _, _, _, a, b, _, _) = build()
    a.col = rgba(20, 160, 40, 170)
    a.invalidate()
    checkSame(f, "lower tile changed (upper overlaps it)")
    b.col = rgba(240, 200, 0, 120)
    b.invalidate()
    checkSame(f, "upper tile changed")
    a.left = a.left + 7                           # moves: old and new area
    checkSame(f, "lower tile moved")
    b.visible = false
    checkSame(f, "upper tile hidden")
    b.visible = true
    checkSame(f, "upper tile shown")

  test "the comparison detects a missing invalidate":
    let (f, _, _, _, a, _, _, _) = build()
    a.col = rgba(0, 0, 0, 255)                    # no invalidate on purpose
    check bytesOf(f, full = false) != bytesOf(f, full = true)

  test "scrolled ScrollBox":
    let (f, _, _, sb, _, _, _, _) = build()
    sb.scrollOffset = pointF(0, 55)
    checkSame(f, "scrolled")
    sb[3].invalidate()
    checkSame(f, "child of a scrolled box")
    sb[3].caption = "changed"
    checkSame(f, "child caption in a scrolled box")
    sb.scrollOffset = pointF(0, 0)
    checkSame(f, "scrolled back")

  test "progress ticks and text changes":
    let (f, _, edit, _, _, _, prog, _) = build()
    for p in [10, 40, 75, 100]:
      prog.position = p
      checkSame(f, "progress " & $p)
    edit.text = "a longer text value"
    checkSame(f, "edit text")
    edit.setFocus()
    checkSame(f, "edit focus")

  test "theme switch repaints everything":
    let (f, _, _, _, _, _, _, _) = build()
    Application.theme = themeDark()
    check f.ui.dirty
    f.settle()
    check f.ui.lastPaintFull
    checkSame(f, "dark theme")
    Application.theme = themeLight()
    checkSame(f, "light theme")

  test "resize recreates the backbuffer":
    let (f, btn, _, _, _, _, _, _) = build()
    f.width = 500
    f.height = 360
    f.syncMetrics()
    f.settle()
    check f.ui.lastPaintFull
    btn.invalidate()
    checkSame(f, "after the resize")
    f.width = 380
    f.syncMetrics()
    checkSame(f, "after shrinking")

  test "scale change":
    let (f, btn, _, _, _, _, _, _) = build()
    Application.forceScale = 2
    f.settle()
    check f.ui.lastPaintFull
    btn.invalidate()
    checkSame(f, "at 2x")
    Application.forceScale = 1
    f.settle()
    checkSame(f, "back at 1x")

  test "a render targets reset forces a full repaint":
    let (f, btn, _, _, _, _, _, _) = build()
    Application.dispatch(PlatformEvent(kind: ekRenderReset))
    check f.ui.dirty
    f.settle()
    check f.ui.lastPaintFull
    btn.invalidate()
    checkSame(f, "after the reset")

  test "popup windows and the form screenshot with popups still work":
    let (f, _, _, _, _, _, _, _) = build()
    check f.screenshotWithPopups(getTempDir() / "nimvcl_repaint_p.bmp")
    removeFile getTempDir() / "nimvcl_repaint_p.bmp"

suite "host mode":
  test "a host repaints fully every time":
    check initSdl()
    let win = createWindow("repaint host", 200, 120, WINDOW_HIGH_PIXEL_DENSITY)
    let ren = createRenderer(win, nil)
    let root = newContainer()
    let p = newPanel(root, "", 10, 10, 50, 50)
    let host = newHost(win, ren, root)
    host.paint()
    check not host.useBackbuffer
    check not host.needsPaint
    p.invalidate(rectF(0, 0, 4, 4))
    check host.dirty                              # a host never keeps partial rects
    check host.dirtyRects.len == 0
    host.paint()
    check host.lastPaintFull
    host.close()
    destroyRenderer ren
    destroyWindow win
