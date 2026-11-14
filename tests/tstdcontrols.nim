## Phase 5 standard controls (ProgressBar, TrackBar, SpinEdit, Splitter,
## StatusBar, ToolBar, PageControl/TabControl, FlowPanel, GridPanel).
## Headless (offscreen SDL): events go through Application.dispatch.

import std/[unittest, monotimes, times]
import nimvcl/core/[types, control, form, application, input, layout]
import nimvcl/platform/[events, window]
import nimvcl/controls/[common, button, edit, panel, progressbar, trackbar,
                        spinedit, splitter, statusbar, toolbar, pagecontrol,
                        flowpanel]

func `==`(a, b: RectF): bool =
  a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h

type
  Plain = ref object of Control
    ## Fixed-size control used as grid/flow content.

proc newPlain(parent: Container, w, h: float32): Plain =
  result = Plain()
  result.initControl()
  result.setBounds(0, 0, w, h)
  if parent != nil: parent.insertControl result

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, dy = 0'f32,
          shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     dy: dy, button: mbLeft, clicks: 1,
                                     shift: shift))
proc moveTo(f: Form, x, y: float32) = f.feed(ekMouseMove, x, y)
proc down(f: Form, x, y: float32) = f.feed(ekMouseDown, x, y)
proc up(f: Form, x, y: float32) = f.feed(ekMouseUp, x, y)
proc click(f: Form, x, y: float32) = f.down(x, y); f.up(x, y)
proc wheel(f: Form, x, y, dy: float32) = f.feed(ekMouseWheel, x, y, dy)
proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k,
                                     shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k,
                                     shift: shift))

proc newShown(w = 600'f32, h = 300'f32): Form =
  result = newForm(nil, w, h)
  result.show()

proc lay(f: Form) = layoutIfNeeded(f)

proc cx(c: Control): float32 = c.formOrigin.x + c.width / 2
proc cy(c: Control): float32 = c.formOrigin.y + c.height / 2
proc fx(c: Control, x: float32): float32 = c.formOrigin.x + x
proc fy(c: Control, y: float32): float32 = c.formOrigin.y + y

proc pump(ms: int) =
  ## Runs the event loop (timers!) for about `ms` milliseconds.
  let t0 = getMonoTime()
  while (getMonoTime() - t0).inMilliseconds < ms:
    Application.processMessages(10)

suite "standard controls":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  # ------------------------------------------------------------ ProgressBar
  test "progressbar: clamping, step, stepIt":
    let p = newProgressBar()
    p.min = 10
    p.max = 50
    check p.position == 10
    p.position = 100
    check p.position == 50
    p.position = -3
    check p.position == 10
    p.step = 15
    p.stepIt()
    check p.position == 25
    p.stepIt(); p.stepIt()
    check p.position == 50
    var n = 0
    p.onChange = proc(s: Control) = inc n
    p.position = 40
    p.position = 40
    check n == 1
    p.max = 30                       # position follows the range
    check p.position == 30
    check abs(p.fraction - 1.0) < 1e-6
    p.min = 0; p.max = 100; p.position = 25
    check abs(p.fraction - 0.25) < 1e-6

  test "progressbar: marquee runs only while visible":
    let f = newShown()
    let p = newProgressBar(f, 10, 10, 200, 18)
    p.style = pbsMarquee
    check p.runsMarquee                # started by visibilityChanged, no paint needed
    let ph = p.marqueePhase
    pump(150)
    check p.marqueePhase != ph
    p.visible = false
    check not p.runsMarquee            # stopped at once
    p.visible = true
    check p.runsMarquee
    p.style = pbsNormal
    check not p.runsMarquee

  # --------------------------------------------------------------- TrackBar
  test "trackbar: keys":
    let f = newShown()
    let t = newTrackBar(f, 10, 10, 200, 32)
    t.max = 20
    var n = 0
    t.onChange = proc(s: Control) = inc n
    f.click(t.cx, t.cy)                # focus (and a page click, ignore)
    t.position = 5
    n = 0
    f.tap(keyRight); check t.position == 6
    f.tap(keyLeft); f.tap(keyLeft); check t.position == 4
    f.tap(keyDown); check t.position == 5
    f.tap(keyUp); check t.position == 4
    f.tap(keyPageDown); check t.position == 6      # pageSize 2
    f.tap(keyPageUp); check t.position == 4
    t.lineSize = 3; t.pageSize = 7
    f.tap(keyRight); check t.position == 7
    f.tap(keyPageDown); check t.position == 14
    f.tap(keyEnd); check t.position == 20
    f.tap(keyRight); check t.position == 20        # clamped
    f.tap(keyHome); check t.position == 0
    check n > 0

  test "trackbar: thumb drag and page clicks":
    let f = newShown()
    let t = newTrackBar(f, 10, 10, 216, 32)        # travel = 200 px
    t.max = 10
    t.position = 0
    var th = t.thumbRect
    f.down(t.fx(th.x + 8), t.fy(th.y + 8))
    check t.isDragging
    f.moveTo(t.fx(8 + 100), t.fy(th.y + 8))
    check t.position == 5
    f.moveTo(t.fx(8 + 1000), t.fy(th.y + 8))       # beyond the end: clamped
    check t.position == 10
    f.moveTo(t.fx(-50), t.fy(th.y + 8))
    check t.position == 0
    f.up(t.fx(-50), t.fy(th.y + 8))
    check not t.isDragging
    # a click on the track pages towards the pointer
    t.position = 4
    th = t.thumbRect
    f.click(t.fx(th.right + 40), t.fy(th.y + 8))
    check t.position == 6
    th = t.thumbRect
    f.click(t.fx(th.x - 30), t.fy(th.y + 8))
    check t.position == 4
    check t.focused

  test "trackbar: vertical":
    let f = newShown()
    let t = newTrackBar(f, 10, 10, 32, 216)
    t.orientation = orVertical
    t.max = 10
    check t.height > t.width
    let th = t.thumbRect
    f.down(t.fx(th.x + 8), t.fy(th.y + 8))
    f.moveTo(t.fx(th.x + 8), t.fy(8 + 100))
    check t.position == 5
    f.up(0, 0)

  # --------------------------------------------------------------- SpinEdit
  test "spinedit: keys, clamp, wheel":
    let f = newShown()
    let s = newSpinEdit(f, 5, 10, 10, 100)
    s.maxValue = 8
    var n = 0
    s.onChange = proc(c: Control) = inc n
    lay f
    check s.edit.text == "5"
    s.edit.setFocus()
    f.tap(keyUp); check s.value == 6 and s.edit.text == "6"
    f.tap(keyUp); f.tap(keyUp); f.tap(keyUp)
    check s.value == 8                              # clamped
    f.tap(keyDown); check s.value == 7
    s.increment = 2
    f.tap(keyDown); check s.value == 5
    f.wheel(s.cx, s.cy, 1); check s.value == 7
    f.wheel(s.cx, s.cy, -2); check s.value == 3
    f.tap(keyPageUp); check s.value == 8
    check n > 0
    s.minValue = 2
    s.value = -50
    check s.value == 2

  test "spinedit: text commit, revert, negative numbers":
    let f = newShown()
    let s = newSpinEdit(f, 5, 10, 10, 100)
    let other = newButton(f, "x", 200, 10, 60)
    lay f
    s.edit.setFocus()
    s.edit.text = "abc"                             # invalid
    other.setFocus()
    check s.value == 5 and s.edit.text == "5"
    s.edit.setFocus()
    s.edit.text = "999"                             # out of range: clamped
    other.setFocus()
    check s.value == 100 and s.edit.text == "100"
    s.edit.setFocus()
    s.edit.text = "42"
    f.tap(keyEnter)
    check s.value == 42
    s.edit.text = ""
    other.setFocus()
    check s.edit.text == "42"
    # typing filters characters
    s.minValue = -10
    s.edit.setFocus()
    s.edit.clear()
    Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id,
                                       text: "-7x"))
    check s.edit.text == "-7"
    other.setFocus()
    check s.value == -7

  test "spinedit: buttons and auto-repeat":
    let f = newShown()
    let s = newSpinEdit(f, 0, 10, 10, 100)
    s.maxValue = 1000
    lay f
    let up = s.buttons
    let ux = up.fx(up.width / 2)
    f.down(ux, up.fy(4))
    check s.value == 1                              # immediate step
    check s.edit.focused
    s.repeatTick()                                  # what the timer calls
    check s.value == 2
    f.up(ux, up.fy(4))
    s.repeatTick()
    check s.value == 2                              # released: no more steps
    f.click(ux, up.fy(up.height - 4))               # lower half
    check s.value == 1
    # real timer: 400 ms delay, then 50 ms
    s.value = 0
    f.down(ux, up.fy(4))
    pump(250)
    check s.value == 1                              # still in the delay
    pump(650)
    let v = s.value
    check v >= 6
    f.up(ux, up.fy(4))
    pump(150)
    check s.value == v                              # stopped on release

  # --------------------------------------------------------------- Splitter
  proc splitForm(al: Align): (Form, Panel, Splitter, Panel) =
    let f = newShown(600, 400)
    let a = newPanel(f)
    let sp = newSplitter(f, al)
    let rest = newPanel(f)
    rest.align = alClient
    case al
    of alLeft, alRight:
      a.align = al; a.width = 150
      sp.width = 6
    else:
      a.align = al; a.height = 100
      sp.height = 6
    lay f
    (f, a, sp, rest)

  test "splitter: drag resizes the left neighbour":
    let (f, a, sp, rest) = splitForm(alLeft)
    check a.width == 150 and sp.left == 150 and rest.left == 156
    f.down(sp.cx, 100)
    f.moveTo(sp.cx + 100, 100)
    check a.width == 250
    lay f
    check sp.left == 250 and rest.left == 256 and rest.width == 344
    f.moveTo(250 + 3 - 40, 100)                     # relative to the moved splitter
    check a.width == 210
    f.moveTo(-100, 100)                             # minSize 30
    check a.width == 30
    f.moveTo(5000, 100)                             # leaves minSize for the client
    check a.width == 564.0
    f.up(0, 0)
    check not sp.isDragging
    f.moveTo(sp.cx - 50, 100)                       # no drag any more
    check a.width == 564.0

  test "splitter: constraints and minSize":
    let (f, a, sp, rest) = splitForm(alLeft)
    a.constraints = constraints(minWidth = 80, maxWidth = 300)
    sp.minSize = 50
    f.down(sp.cx, 100)
    f.moveTo(sp.cx + 400, 100)
    check a.width == 300                            # maxWidth
    f.moveTo(sp.cx - 400, 100)
    check a.width == 80                             # neighbour minWidth wins over minSize 50?
    f.up(0, 0)
    var moved = 0
    sp.onMoved = proc(s: Control) = inc moved
    sp.resizeTo(200)
    check a.width == 200 and moved == 1

  test "splitter: right, top and bottom alignment":
    block:
      let (f, a, sp, rest) = splitForm(alRight)
      check a.left == 450 and sp.left == 444
      f.down(sp.cx, 100)
      f.moveTo(sp.cx - 60, 100)                     # left = wider
      check a.width == 210
      f.up(0, 0)
    block:
      let (f, a, sp, rest) = splitForm(alTop)
      check sp.top == 100
      f.down(300, sp.cy)
      f.moveTo(300, sp.cy + 50)
      check a.height == 150
      f.up(0, 0)
    block:
      let (f, a, sp, rest) = splitForm(alBottom)
      check sp.top == 294.0
      f.down(300, sp.cy)
      f.moveTo(300, sp.cy - 40)
      check a.height == 140
      f.up(0, 0)

  test "splitter: neighbour is the previous same-align sibling":
    let f = newShown(600, 400)
    let p1 = newPanel(f)
    p1.align = alLeft; p1.width = 100
    let p2 = newPanel(f)
    p2.align = alLeft; p2.width = 120
    let sp = newSplitter(f)
    check sp.neighbour == Control(p2)
    p2.visible = false
    check sp.neighbour == Control(p1)

  # -------------------------------------------------------------- StatusBar
  test "statusbar: panel geometry":
    let f = newShown(400, 300)
    let sb = newStatusBar(f)
    check sb.align == alBottom
    lay f
    check sb.top + sb.height == 300 and sb.width == 400
    sb.addPanel("one", 100)
    sb.addPanel("two", 80, taCenter)
    let last = sb.addPanel("three", 5, taRight)
    check sb.panelRect(0) == rectF(0, 0, 100, sb.height)
    check sb.panelRect(1) == rectF(100, 0, 80, sb.height)
    check sb.panelRect(2) == rectF(180, 0, 220, sb.height)     # fills the rest
    sb.sizeGrip = true
    check sb.panelRect(2).w == 206.0
    last.text = "changed"
    check sb.panels[2].text == "changed"
    sb.simpleText = "hello"
    check sb.simplePanel and sb.simpleText == "hello"
    f.tap(keySpace)                                 # painting must not crash
    Application.processMessages()

  # ---------------------------------------------------------------- ToolBar
  test "toolbar: layout, push, check and group buttons":
    let f = newShown(500, 300)
    let tb = newToolBar(f)
    let b1 = newToolButton(tb, "New")
    let sep = newToolButton(tb, "", tbsSeparator)
    let c1 = newToolButton(tb, "Bold", tbsCheck)
    let g1 = newToolButton(tb, "Left", tbsCheck)
    let g2 = newToolButton(tb, "Right", tbsCheck)
    let dis = newToolButton(tb, "Off")
    dis.enabled = false
    g1.groupIndex = 1; g2.groupIndex = 1
    lay f
    check tb.align == alTop and tb.top == 0 and tb.width == 500
    check tb.height == f.theme.controlHeight + 6
    check b1.left < sep.left and sep.left < c1.left and c1.left < g1.left
    check sep.width == 8
    check b1.top == 3                                # centred with the padding
    var clicks = 0
    b1.onClick = proc(s: Control) = inc clicks
    f.click(b1.cx, b1.cy); f.click(b1.cx, b1.cy)
    check clicks == 2 and not b1.down                # push button never "down"
    f.click(c1.cx, c1.cy)
    check c1.down
    f.click(c1.cx, c1.cy)
    check not c1.down
    f.click(g1.cx, g1.cy)
    check g1.down and not g2.down
    f.click(g2.cx, g2.cy)
    check g2.down and not g1.down
    f.click(g2.cx, g2.cy)
    check g2.down                                    # a group needs one pressed
    g2.allowAllUp = true
    f.click(g2.cx, g2.cy)
    check not g2.down
    g1.down = true
    g2.down = true                                   # programmatic: group rule too
    check g2.down and not g1.down
    var dc = 0
    dis.onClick = proc(s: Control) = inc dc
    f.click(dis.cx, dis.cy)
    check dc == 0
    f.click(sep.cx, sep.cy)                          # separators do nothing
    check not sep.down

  # ------------------------------------------------------------ PageControl
  proc pages(f: Form): (PageControl, seq[TabSheet], seq[Edit]) =
    let pc = newPageControl(f)
    pc.align = alClient
    var shs: seq[TabSheet]
    var eds: seq[Edit]
    for i in 1 .. 3:
      let s = newTabSheet(pc, "Page " & $i)
      let e = newEdit(s, "e" & $i, 10, 10, 120)
      e.align = alNone
      shs.add s
      eds.add e
    lay f
    (pc, shs, eds)

  test "pagecontrol: only the active sheet is visible":
    let f = newShown()
    let (pc, shs, eds) = pages(f)
    check pc.tabCount == 3 and pc.activePageIndex == 0
    check pc.activePage == shs[0]
    check shs[0].visible and not shs[1].visible and not shs[2].visible
    check shs[0].top >= pc.stripHeight and shs[0].width == pc.width - 2
    pc.activePageIndex = 2
    check shs[2].visible and not shs[0].visible and pc.activePage == shs[2]
    lay f
    check shs[2].width == pc.width - 2
    var order: seq[Control]
    for s in tabStops(f): order.add s
    check eds[2] in order and eds[0] notin order and eds[1] notin order

  test "pagecontrol: click on tabs":
    let f = newShown()
    let (pc, shs, eds) = pages(f)
    var changes = 0
    pc.onChange = proc(s: Control) = inc changes
    let r1 = pc.tabRect(1)
    f.click(pc.fx(r1.x + r1.w / 2), pc.fy(r1.y + r1.h / 2))
    check pc.activePageIndex == 1 and changes == 1
    check pc.focused
    check pc.tabAt(r1.x + 2, r1.y + 2) == 1
    # clicking the active tab again changes nothing
    f.click(pc.fx(r1.x + 5), pc.fy(r1.y + 5))
    check changes == 1
    f.click(pc.fx(3000), pc.fy(8))                   # empty part of the strip
    check pc.activePageIndex == 1

  test "pagecontrol: keys on the strip, wrapping, veto":
    let f = newShown()
    let (pc, shs, eds) = pages(f)
    pc.setFocus()
    f.tap(keyRight); check pc.tabIndex == 1
    f.tap(keyRight); f.tap(keyRight); check pc.tabIndex == 2
    f.tap(keyLeft); check pc.tabIndex == 1
    f.tap(keyEnd); check pc.tabIndex == 2
    f.tap(keyHome); check pc.tabIndex == 0
    f.tap(keyTab, {ssCtrl}); check pc.tabIndex == 1
    f.tap(keyTab, {ssCtrl}); f.tap(keyTab, {ssCtrl}); check pc.tabIndex == 0   # wraps
    f.tap(keyTab, {ssCtrl, ssShift}); check pc.tabIndex == 2
    f.tap(keyPageUp, {ssCtrl}); check pc.tabIndex == 1
    f.tap(keyPageDown, {ssCtrl}); f.tap(keyPageDown, {ssCtrl}); check pc.tabIndex == 0
    var allow = false
    var asked = 0
    var changed = 0
    pc.onChanging = proc(s: Control, ok: var bool) =
      inc asked
      ok = allow
    pc.onChange = proc(s: Control) = inc changed
    f.tap(keyRight)
    check pc.tabIndex == 0 and asked == 1 and changed == 0
    check shs[0].visible and not shs[1].visible
    allow = true
    f.tap(keyRight)
    check pc.tabIndex == 1 and changed == 1 and shs[1].visible

  test "pagecontrol: Ctrl+Tab inside a page moves focus into the next page":
    let f = newShown()
    let (pc, shs, eds) = pages(f)
    Application.processMessages()                    # paint installs the key hook
    f.click(eds[0].cx, eds[0].cy)
    check eds[0].focused
    f.tap(keyTab, {ssCtrl})
    check pc.tabIndex == 1 and shs[1].visible and not shs[0].visible
    check eds[1].focused
    f.tap(keyPageUp, {ssCtrl})
    check pc.tabIndex == 0 and eds[0].focused
    # a page without focusable content: the strip takes the focus
    let empty = newTabSheet(pc, "Empty")
    lay f
    pc.activePageIndex = 0
    eds[0].setFocus()
    pc.activePageIndex = 3
    check pc.focused
    check empty.visible

  test "pagecontrol: tab scrolling when tabs overflow":
    let f = newShown(300, 200)
    let pc = newPageControl(f)
    pc.align = alClient
    for i in 1 .. 10: discard newTabSheet(pc, "Tab number " & $i)
    lay f
    check pc.overflowing
    check pc.firstVisibleTab == 0
    pc.activePageIndex = 9
    check pc.firstVisibleTab > 0                      # scrolled to show it
    check pc.tabRect(9).right <= pc.width
    let prev = pc.firstVisibleTab
    f.click(pc.fx(pc.width - 30), pc.fy(10))          # left arrow
    check pc.firstVisibleTab == prev - 1
    Application.processMessages()

  test "tabcontrol: tabs only":
    let f = newShown()
    let tc = newTabControl(f, @["One", "Two", "Three"], 10, 10, 300, 150)
    check tc.tabIndex == 0 and tc.tabCount == 3
    var n = 0
    tc.onChange = proc(s: Control) = inc n
    let r = tc.tabRect(2)
    f.click(tc.fx(r.x + 5), tc.fy(r.y + 5))
    check tc.tabIndex == 2 and n == 1
    f.tap(keyLeft); check tc.tabIndex == 1
    tc.addTab("Four")
    check tc.tabCount == 4
    tc.tabIndex = 3
    check tc.tabIndex == 3
    Application.processMessages()

  # -------------------------------------------------------------- FlowPanel
  test "flowpanel: wraps left to right":
    let f = newShown()
    let fp = newFlowPanel(f, 0, 0, 200, 200)
    var kids: seq[Plain]
    for i in 0 ..< 5: kids.add newPlain(fp, 80, 25)
    kids[2].height = 40
    lay f
    check kids[0].left == 0 and kids[0].top == 0
    check kids[1].left == 80 and kids[1].top == 0
    check kids[2].left == 0 and kids[2].top == 25      # wrapped
    check kids[3].left == 80 and kids[3].top == 25
    check kids[4].left == 0 and kids[4].top == 65.0  # row height = tallest
    fp.hGap = 10; fp.vGap = 5                          # 80+10+80 = 170 still fits
    lay f
    check kids[1].left == 90
    check kids[2].top == 30
    check kids[4].top == 75.0
    # margins and padding
    fp.hGap = 0; fp.vGap = 0
    fp.padding = spacing(10)
    kids[0].margins = spacing(5)
    lay f
    check kids[0].left == 15 and kids[0].top == 15
    check kids[1].left == 100.0                      # slot of child 0 is 90 wide
    # hidden children are skipped
    kids[1].visible = false
    lay f
    check kids[2].left == 100 and kids[2].top == 10

  test "flowpanel: top to bottom":
    let f = newShown()
    let fp = newFlowPanel(f, 0, 0, 300, 60)
    fp.flowStyle = fsTopBottomLeftRight
    var kids: seq[Plain]
    for i in 0 ..< 5: kids.add newPlain(fp, 70, 25)
    lay f
    check kids[0].left == 0 and kids[0].top == 0
    check kids[1].left == 0 and kids[1].top == 25
    check kids[2].left == 70 and kids[2].top == 0      # new column
    check kids[4].left == 140 and kids[4].top == 0

  test "flowpanel: positions every child itself, align is left untouched":
    let f = newShown()
    let fp = newFlowPanel(f, 0, 0, 200, 200)
    let header = newPlain(fp, 10, 30)
    header.align = alTop
    let a = newPlain(fp, 80, 25)
    lay f
    check header.align == alTop and a.align == alNone
    check header.top == 0 and header.left == 0 and header.width == 10
    check a.top == 0 and a.left == 10

  # -------------------------------------------------------------- GridPanel
  test "gridpanel: absolute and percent tracks, in-order placement":
    let f = newShown()
    let g = newGridPanel(f, 0, 0, 300, 100)
    g.columns = @[gsAbsolute(100), gsPercent(50), gsPercent(50)]
    g.rows = @[gsAbsolute(30), gsPercent(100)]
    var kids: seq[Plain]
    for i in 0 ..< 6: kids.add newPlain(g, 10, 10)
    lay f
    check g.cellRect(0, 0) == rectF(0, 0, 100, 30)
    check g.cellRect(1, 2) == rectF(200, 30, 100, 70)
    for i, k in kids:
      let r = g.cellRect(i div 3, i mod 3)
      check k.boundsRect == r
    check kids[4].left == 100 and kids[4].width == 100 and kids[4].top == 30
    g.padding = spacing(10)
    lay f
    check g.cellRect(0, 0) == rectF(10, 10, 100, 30)
    check kids[1].left == 110 and kids[1].width == 90     # (280 - 100) / 2

  test "gridpanel: auto tracks, spans, explicit cells, margins":
    let f = newShown()
    let g = newGridPanel(f, 0, 0, 300, 120)
    g.columns = @[gsAuto(), gsPercent(100)]
    g.rows = @[gsAuto(), gsPercent(50), gsPercent(50)]
    let a = newPlain(g, 70, 20)
    let b = newPlain(g, 10, 10)
    let c = newPlain(g, 10, 10)
    let d = newPlain(g, 10, 10)
    g.setCell(a, 0, 0)
    g.setCell(b, 0, 1)
    g.setCell(c, 1, 0, rowSpan = 2, colSpan = 2)
    # d takes the first free cell (row 1,0 and 1,1 and 2,x are taken): none left
    lay f
    check g.cellRect(0, 0).w == 70 and g.cellRect(0, 0).h == 20
    check a.boundsRect == rectF(0, 0, 70, 20)
    check b.boundsRect == rectF(70, 0, 230, 20)
    check c.boundsRect == rectF(0, 20, 300, 100)          # spans both columns, rows 1-2
    # margins reduce the child inside its cell and enlarge auto tracks
    a.margins = spacing(5)
    lay f
    check g.cellRect(0, 0).w == 80 and g.cellRect(0, 0).h == 30
    check a.boundsRect == rectF(5, 5, 70, 20)
    # a child that does not fit any cell is left alone
    check d.boundsRect.w == 10

  test "gridpanel: default is one cell per child row":
    let f = newShown()
    let g = newGridPanel(f, 0, 0, 200, 100)
    g.columns = @[gsPercent(50), gsPercent(50)]
    g.rows = @[gsPercent(50), gsPercent(50)]
    let k = newPlain(g, 5, 5)
    k.visible = false
    let a = newPlain(g, 5, 5)                             # first visible -> (0,0)
    lay f
    check a.boundsRect == rectF(0, 0, 100, 50)
    k.visible = true
    lay f
    check k.boundsRect == rectF(0, 0, 100, 50)
    check a.boundsRect == rectF(100, 0, 100, 50)
