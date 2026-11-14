## Scrolling (phase 5): container scroll offset, ScrollBar, ScrollBox,
## wheel bubbling. Headless (offscreen SDL), events built by hand.

import std/unittest
import nimvcl
import nimvcl/controls/[scrollbar, scrolling, scrollbox, listbox]

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          clicks = 1, shift: ShiftState = {}, dx = 0'f32, dy = 0'f32) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift,
                                     dx: dx, dy: dy))
proc moveTo(f: Form, x, y: float32) = f.feed(ekMouseMove, x, y)
proc down(f: Form, x, y: float32) = f.feed(ekMouseDown, x, y)
proc up(f: Form, x, y: float32) = f.feed(ekMouseUp, x, y)
proc wheel(f: Form, x, y, dy: float32, dx = 0'f32, shift: ShiftState = {}) =
  f.moveTo(x, y)
  f.feed(ekMouseWheel, x, y, dx = dx, dy = dy, shift = shift)

proc newShown(w = 400'f32, h = 300'f32): Form =
  result = newForm(nil, w, h)
  result.show()

proc settle(f: Form) =
  ## Layout + one paint, like a frame.
  discard f.paintIfDirty()
  f.layoutIfNeeded()

suite "scroll offset in core":
  test "hit testing, coordinates and aligned children":
    let c = newContainer()
    c.setBounds(0, 0, 200, 200)
    let ch = newControl()
    ch.setBounds(100, 100, 50, 50)
    c.insertControl ch
    let bar = newControl()          # aligned: not scrolled
    bar.align = alTop
    bar.height = 20
    c.insertControl bar
    layout(c)
    check c.controlAtPoint(pointF(110, 110)) == ch
    c.setScrollOffset(60, 60)
    check c.scrollOffset == pointF(60, 60)
    check ch.visualRect == rectF(40, 40, 50, 50)
    check ch.boundsRect == rectF(100, 100, 50, 50)    # content coordinates
    check c.controlAtPoint(pointF(45, 45)) == ch
    check c.controlAtPoint(pointF(110, 110)) == nil
    check c.controlAtPoint(pointF(10, 10)) == Control(bar)
    check ch.clientToParent(pointF(0, 0)) == pointF(40, 40)
    check ch.parentToClient(pointF(45, 45)) == pointF(5, 5)
    check ch.clientToForm(pointF(0, 0)) == pointF(40, 40)
    check ch.formToClient(pointF(45, 50)) == pointF(5, 10)
    check bar.clientToParent(pointF(0, 0)) == pointF(0, 0)
    check c.rectInAncestor(ch) == rectF(40, 40, 50, 50)

  test "scrolled children are clipped to the viewport":
    let c = newContainer()
    c.setBounds(0, 0, 100, 100)
    let ch = newControl()
    ch.setBounds(50, 0, 100, 20)     # sticks out to the right
    c.insertControl ch
    check c.controlAtPoint(pointF(60, 10)) == ch
    check c.controlAtPoint(pointF(120, 10)) == nil

suite "ScrollBar":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "range, clamping and onChange":
    let b = newScrollBar(nil, sbVertical)
    var n = 0
    b.onChange = proc(s: Control) = inc n
    b.setRange(0, 1000, 100)
    check b.maxPosition == 900
    b.position = 5000
    check b.position == 900
    check n == 1
    b.position = -3
    check b.position == 0
    check n == 2
    b.position = 0
    check n == 2
    b.pageSize = 1000            # whole range visible: nothing to scroll
    check not b.canScroll
    b.position = 10
    check b.position == 0

  test "drag the thumb":
    let f = newShown()
    let b = newScrollBar(f, sbVertical, 10, 10, 12, 200)
    b.setRange(0, 1000, 100)
    let th = b.thumbRect
    check th.h == 24 and th.y == 0                # minimum thumb length
    f.moveTo(14, 10 + th.h / 2)
    f.down(14, 10 + th.h / 2)
    f.moveTo(14, 10 + th.h / 2 + 88)              # half of the free track (176)
    check abs(b.position - 450) < 1
    f.moveTo(14, 10 + 2000)                       # far beyond: clamped
    check b.position == 900
    f.up(14, 10 + 2000)
    f.moveTo(14, 15)                              # released: no more dragging
    check b.position == 900

  test "click the track pages, onScroll can adjust":
    let f = newShown()
    let b = newScrollBar(f, sbVertical, 10, 10, 12, 200)
    b.setRange(0, 1000, 100)
    f.down(14, 10 + 150); f.up(14, 10 + 150)
    check b.position == 100                       # one page (= pageSize)
    f.down(14, 10 + 150); f.up(14, 10 + 150)
    check b.position == 200
    b.largeChange = 50
    f.down(14, 10 + 190); f.up(14, 10 + 190)      # below the thumb
    check b.position == 250
    var codes: seq[ScrollCode]
    b.onScroll = proc(s: Control, code: ScrollCode, pos: var float32) =
      codes.add code
      pos = 400
    f.down(14, 10 + 195); f.up(14, 10 + 195)
    check b.position == 400
    check codes == @[scPageDown]

  test "wheel scrolls and only handles when it moved":
    let f = newShown()
    let p = newPanel(f)
    p.setBounds(0, 0, 300, 250)
    let b = newScrollBar(p, sbVertical, 10, 10, 12, 200)
    b.setRange(0, 1000, 100)
    b.smallChange = 10
    var outer = 0
    p.onMouseWheel = proc(s: Control, sh: ShiftState, dx, dy: float32,
                          handled: var bool) = inc outer
    f.wheel(14, 100, -1)                          # one notch down = 3 lines
    check b.position == 30
    check outer == 0                              # consumed
    f.wheel(14, 100, 1)
    check b.position == 0
    f.wheel(14, 100, 1)                           # at the top: bubbles on
    check outer == 1
    b.position = 900
    f.wheel(14, 100, -1)
    check outer == 2

  test "horizontal bar takes dx":
    let f = newShown()
    let b = newScrollBar(f, sbHorizontal, 10, 10, 200, 12)
    b.setRange(0, 1000, 100)
    b.smallChange = 10
    f.wheel(100, 14, 0, dx = -2)
    check b.position == 60

suite "ScrollBox":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "content size, auto scrollbars, viewport":
    let f = newShown()
    let sb = newScrollBox(f, 10, 10, 200, 100)
    settle f
    check sb.contentSize == sizeF(0, 0)
    check not sb.vScrollBar.visible and not sb.hScrollBar.visible
    let c1 = newControl(); c1.setBounds(10, 10, 300, 400)
    sb.insertControl c1
    settle f
    check sb.contentSize == sizeF(310, 410)
    check sb.vScrollBar.visible and sb.hScrollBar.visible
    check sb.viewport == rectF(0, 0, 188, 88)
    check sb.maxScroll == pointF(122, 322)
    # content smaller than the viewport: bars go away
    c1.setBounds(10, 10, 100, 50)
    settle f
    check not sb.vScrollBar.visible and not sb.hScrollBar.visible
    check sb.viewport == rectF(0, 0, 200, 100)
    # explicit content size
    sb.contentSize = sizeF(500, 50)
    settle f
    check sb.hScrollBar.visible and not sb.vScrollBar.visible
    check sb.viewport == rectF(0, 0, 200, 88)
    # one bar can make the other necessary
    sb.contentSize = sizeF(100, 95)
    settle f
    check sb.vScrollBar.visible == false
    sb.contentSize = sizeF(195, 105)
    settle f
    check sb.vScrollBar.visible and sb.hScrollBar.visible

  test "scrollbar modes":
    let f = newShown()
    let sb = newScrollBox(f, 0, 0, 200, 100)
    sb.vScrollMode = sbmAlways
    sb.hScrollMode = sbmNever
    sb.contentSize = sizeF(900, 50)
    settle f
    check sb.vScrollBar.visible and not sb.hScrollBar.visible
    check not sb.vScrollBar.canScroll

  test "wheel scrolls children; they move and hit-test shifted":
    let f = newShown()
    let sb = newScrollBox(f, 10, 10, 200, 100)
    let c1 = newButton(sb, "x", 10, 150, 80, 24)
    sb.contentSize = sizeF(100, 400)
    settle f
    check c1.formToClient(pointF(20, 170)) == pointF(0, 10)
    f.wheel(50, 50, -1)                           # 3 lines of 20 px
    check sb.scrollPos == pointF(0, 60)
    check sb.scrollOffset == pointF(0, 60)
    check c1.visualRect.y == 90
    f.wheel(50, 50, -10)
    check sb.scrollPos.y == sb.maxScroll.y        # clamped at the bottom
    check sb.maxScroll.y == 300
    f.wheel(50, 50, 20)
    check sb.scrollPos.y == 0
    f.wheel(50, 50, -1, shift = {ssShift})        # Shift+wheel: horizontal, no range
    check sb.scrollPos == pointF(0, 0)
    sb.contentSize = sizeF(500, 400)
    settle f
    f.wheel(50, 50, -1, shift = {ssShift})
    check sb.scrollPos.x == 60 and sb.scrollPos.y == 0

  test "bars scroll the content; position stays in sync":
    let f = newShown()
    let sb = newScrollBox(f, 0, 0, 200, 100)
    sb.contentSize = sizeF(100, 400)
    settle f
    sb.vScrollBar.position = 120
    check sb.scrollPos.y == 120
    check sb.scrollOffset.y == 120
    sb.scrollTo(0, 50)
    check sb.vScrollBar.position == 50
    # resizing re-clamps
    sb.scrollTo(0, 300)
    sb.setBounds(0, 0, 200, 300)
    settle f
    check sb.scrollPos.y == 100

  test "scrollIntoView and focus reveal":
    let f = newShown()
    let sb = newScrollBox(f, 10, 10, 200, 100)
    let b1 = newButton(sb, "one", 10, 10, 80, 24)
    let b2 = newButton(sb, "two", 10, 300, 80, 24)
    let b3 = newButton(sb, "three", 120, 50, 150, 24)   # partly right of the viewport
    settle f
    check sb.contentSize == sizeF(270, 324)
    b2.setFocus()
    check f.activeControl == Control(b2)
    # bottom edge of the button is at the bottom of the viewport
    check sb.scrollPos.y == 324 - sb.viewport.h
    check b2.visualRect.bottom == sb.viewport.h
    b1.setFocus()
    check sb.scrollPos.y == 10                   # top edge revealed
    b3.setFocus()
    check sb.scrollPos.x == 270 - sb.viewport.w
    # already visible: no movement
    let before = sb.scrollPos
    b3.setFocus()
    check sb.scrollPos == before
    # explicit API
    sb.scrollIntoView(rectF(0, 0, 10, 10))
    check sb.scrollPos == pointF(0, 0)

  test "mouse press does not scroll the clicked control":
    let f = newShown()
    let sb = newScrollBox(f, 10, 10, 200, 100)
    discard newButton(sb, "one", 10, 80, 80, 40)      # half visible
    settle f
    f.moveTo(40, 100)
    f.down(40, 100)
    check sb.scrollPos == pointF(0, 0)
    f.up(40, 100)

  test "aligned children fill the viewport and do not scroll":
    let f = newShown()
    let sb = newScrollBox(f, 0, 0, 200, 100)
    let top = newControl()
    top.align = alClient
    sb.insertControl top
    sb.contentSize = sizeF(100, 400)
    settle f
    check top.width == 188 and top.height == 100  # viewport, minus the bar
    sb.scrollTo(0, 100)
    check top.visualRect == rectF(0, 0, 188, 100)
    check sb.controlAtPoint(pointF(10, 10)) == Control(top)

  test "wheel bubbling: stops at a scroller, continues at its limits":
    let f = newShown(500, 400)
    let outer = newScrollBox(f, 0, 0, 300, 200)
    let inner = newScrollBox(outer, 10, 10, 200, 100)
    inner.contentSize = sizeF(100, 300)
    outer.contentSize = sizeF(250, 800)
    settle f
    f.wheel(50, 20, -1)                          # over the inner box
    check inner.scrollPos.y == 60
    check outer.scrollPos.y == 0                 # consumed by the inner one
    f.wheel(50, 20, -10)
    check inner.scrollPos.y == inner.maxScroll.y
    check outer.scrollPos.y == 0
    f.wheel(50, 20, -1)                          # inner at its limit: outer scrolls
    check outer.scrollPos.y == 60
    f.wheel(50, 20, 1)                           # up: the inner one can go up again
    check inner.scrollPos.y == inner.maxScroll.y - 60
    check outer.scrollPos.y == 60
    # a handler that sets handled stops the bubbling
    var seen = 0
    inner.onMouseWheel = proc(s: Control, sh: ShiftState, dx, dy: float32,
                              handled: var bool) =
      inc seen
      handled = true
    f.wheel(50, 20, -1)
    check seen == 1
    check outer.scrollPos.y == 60
