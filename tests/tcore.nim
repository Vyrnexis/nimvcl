## Regression tests for the code-review findings in core/, graphics/, platform/
## and the spinedit/scrollbar/splitter/trackbar/flowpanel controls. Headless.

import std/[unittest, strutils, importutils]
import sdl3 except Color, Cursor
import nimvcl
import nimvcl/core/popup
import nimvcl/platform/[dialogs, timers]
import nimvcl/controls/[spinedit, flowpanel]
privateAccess(SpinEdit)
privateAccess(ScrollBar)
privateAccess(GridPanel)
privateAccess(Timer)
privateAccess(SpinButtons)
import std/[tables, os]

type
  Probe = ref object of Container
    focusable: bool
    downs, captureLosts: int
    sawRepeat: seq[bool]
  Boom = ref object of Control          # paint raises
  Counted = object                      # counts live destructions
    live: bool
  LayoutBoom = ref object of Container
    fail: bool
  Relayouter = ref object of Container  # re-flags a sibling after its own layout
    other: Container
  CountLayout = ref object of Container
    passes: int

var destroyed: int

proc `=destroy`(c: Counted) =
  if c.live: inc destroyed
proc `=copy`(a: var Counted, b: Counted) {.error.}

method canFocus(p: Probe): bool = p.focusable and p.isVisible and p.isEnabled
method doMouseDown(p: Probe, b: MouseButton, s: ShiftState, x, y: float32) =
  inc p.downs
  procCall doMouseDown(Container(p), b, s, x, y)
method captureLost(p: Probe) =
  inc p.captureLosts
  procCall captureLost(Container(p))
method doKeyDown(p: Probe, key: var Key, s: ShiftState) =
  p.sawRepeat.add p.keyIsRepeat
  procCall doKeyDown(Container(p), key, s)
method paint(b: Boom, c: Canvas) = raise newException(ValueError, "paint boom")
method arrangeChildren(c: LayoutBoom, area: RectF): bool =
  if c.fail: raise newException(ValueError, "layout boom")
  false
method beforeLayout(c: CountLayout) = inc c.passes
method afterLayout(c: Relayouter) =
  if c.other != nil:
    let o = c.other
    c.other = nil
    o.relayout()                        # flags a sibling visited earlier

proc probe(parent: Container, x, y, w, h: float32, focusable = false): Probe =
  result = Probe(focusable: focusable)
  result.initContainer()
  result.setBounds(x, y, w, h)
  result.tabStop = focusable
  parent.insertControl(result)

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, shift: ShiftState = {},
          key = Key(0), repeat = false) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: mbLeft, clicks: 1, shift: shift,
                                     key: key, repeat: repeat))
proc settle(f: Form) =
  discard f.paintIfDirty()
  f.layoutIfNeeded()

template queued(body: untyped) =
  Application.queue(proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      body)

proc onUiString(s: string) = discard

suite "handlers that clear themselves (finding 1)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "onClick/onKeyDown/onMouseDown clearing themselves keep their captures alive":
    let c = newControl()
    var seen: seq[string]
    block:
      var big = "captured-" & $12345
      c.onClick = proc(sender: Control) =
        sender.onClick = nil
        var junk: seq[string]
        for i in 0 ..< 100: junk.add "overwrite" & $i
        seen.add big
      c.onKeyDown = proc(sender: Control, key: var Key, s: ShiftState) =
        sender.onKeyDown = proc(sender: Control, key: var Key, s: ShiftState) = discard
        var junk: seq[string]
        for i in 0 ..< 100: junk.add "overwrite" & $i
        seen.add big
    c.doClick()
    c.doClick()                          # the handler is gone now
    var k = key('a')
    c.doKeyDown(k, {})
    check seen == @["captured-12345", "captured-12345"]

  test "key chain handler that removes or replaces itself":
    let f = newForm(nil, 200, 100)
    f.show()
    var log: seq[string]
    f.addKeyHandler("a", proc(k: var Key, s: ShiftState) =
      f.addKeyHandler("a", proc(k: var Key, s: ShiftState) = log.add "a2")
      var junk: seq[string]
      for i in 0 ..< 100: junk.add "overwrite" & $i
      log.add "a1")
    f.feed(ekKeyDown, key = key('x'))
    f.feed(ekKeyDown, key = key('x'))
    check log == @["a1", "a2"]
    f.freeWindow()

  test "Timer handler that clears itself, Form handlers, popup onClosed":
    let t = newTimer(nil, 1000)
    var n = 0
    t.onTimer = proc(s: Timer) =
      s.onTimer = nil
      inc n
    t.enabled = true
    discard dispatchTimer(t.fId)
    discard dispatchTimer(t.fId)
    t.enabled = false
    check n == 1
    let f = newForm(nil, 200, 100)
    var shown = 0
    f.onShow = proc(s: Control) =
      f.onShow = nil
      inc shown
    f.show()
    check shown == 1
    let content = newContainer()
    content.setBounds(0, 0, 50, 30)
    let p = showPopup(f, content, rectF(10, 10, 40, 20))
    var closed = 0
    p.onClosed = proc(q: PopupWindow) =
      q.onClosed = nil
      inc closed
    closePopup(p)
    check closed == 1
    f.freeWindow()

suite "queue robustness (finding 2)":
  setup:
    Application.init()
  teardown:
    Application.onException = nil

  test "a raising job does not drop the rest (default: re-raise)":
    Application.onException = nil
    var ran: seq[int]
    queued: (ran.add 1; raise newException(ValueError, "boom"))
    queued: ran.add 2
    queued: ran.add 3
    expect ValueError: Application.processMessages()
    check ran == @[1]
    Application.processMessages()
    check ran == @[1, 2, 3]

  test "with onException every job runs in one pass":
    var errors = 0
    Application.onException = proc(e: ref Exception) = inc errors
    var ran: seq[int]
    queued: (ran.add 1; raise newException(ValueError, "boom"))
    queued: ran.add 2
    Application.processMessages()
    check ran == @[1, 2] and errors == 1

  test "boxed jobs left over at shutdown are freed":
    destroyed = 0
    Application.queue(Counted(live: true), proc(c: Counted) = discard)
    Application.shutdown()
    check destroyed == 1
    Application.init()
    Application.processMessages()        # nothing left to run
    check destroyed == 1

suite "modal state and loop guards (findings 3, 4)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    Application.onException = nil
    for f in openForms(): f.freeWindow()

  test "showModal restores the modal state when onShow raises":
    let o = newForm(nil, 100, 100)
    o.show()
    let m = newForm(nil, 100, 100)
    m.onShow = proc(s: Control) = raise newException(ValueError, "onShow boom")
    expect ValueError: discard m.showModal()
    check modalForm() == nil
    check not m.isModal
    check o.acceptsInput
    check not m.visible                  # hidden again

  test "showModal restores the state when the loop raises":
    let o = newForm(nil, 100, 100)
    o.show()
    let m = newForm(nil, 100, 100)
    Application.onException = nil
    queued: raise newException(ValueError, "in loop")
    expect ValueError: discard m.showModal()
    check modalForm() == nil and o.acceptsInput and not m.isModal

  test "paint and layout errors go to onException":
    var errors: seq[string]
    Application.onException = proc(e: ref Exception) = errors.add e.msg
    let f = newForm(nil, 200, 100)
    f.show()
    let b = Boom()
    b.initControl(f)
    f.insertControl b
    Application.processMessages()
    check "paint boom" in errors
    f.freeWindow()

  test "a layout that raises does not leave `layouting` stuck":
    let f = newForm(nil, 200, 100)
    let c = LayoutBoom(fail: true)
    c.initContainer()
    f.insertControl c
    expect ValueError: layout(c)
    check not c.layouting and c.needsLayout
    c.fail = false
    layout(c)
    check not c.needsLayout

  test "shutdown resets modal gates, run shuts down after an error":
    beginModalState()
    let f0 = newForm(nil, 100, 100)
    check not f0.acceptsInput
    Application.shutdown()
    Application.init()
    check f0.acceptsInput
    let f = newForm(nil, 100, 100)
    Application.onException = nil
    queued: raise newException(ValueError, "in run")
    expect ValueError: Application.run(f)
    check openForms().len == 0            # the finally ran `shutdown`
    check not f.hasWindow

  test "an idle hook raising on the first call goes to onException":
    var errors = 0
    Application.init()
    Application.onException = proc(e: ref Exception) = inc errors
    Application.addIdleHook("t", proc() = raise newException(ValueError, "idle"))
    let f = newForm(nil, 100, 100)
    queued: Application.terminate()
    Application.run(f)
    check errors >= 1
    Application.removeIdleHook("t")

suite "font, layout (findings 5, 10, 18)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "a font change re-measures auto-sized descendants":
    let f = newForm(nil, 400, 300)
    let p = newPanel(f, "", 0, 0, 300, 200)
    let l = newLabel(p, "Hello world", 5, 5)
    f.show()
    Application.processMessages()
    let w0 = l.width
    f.font = font("", 30)
    Application.processMessages()
    check l.width > w0

  test "a container flagged during the parent's pass is not lost":
    let f = newForm(nil, 300, 200)
    let b = CountLayout()
    b.initContainer()
    let a = Relayouter(other: b)
    a.initContainer()
    f.insertControl b                    # visited first
    f.insertControl a
    f.show()
    f.settle()
    check b.passes >= 2
    check not b.needsLayout and not f.childNeedsLayout

  test "FlowPanel children are auto-sized":
    let f = newForm(nil, 400, 240)
    f.show()
    let fp = newFlowPanel(f, 0, 0, 300, 100)
    let l = newLabel(fp, "A rather long label caption here")
    let ref1 = newLabel(f, "A rather long label caption here", 0, 150)
    f.settle()
    check l.autoSize
    check l.width == ref1.width and l.width > 75

  test "GridPanel auto-sizes children before arranging; dropped cells are forgotten":
    let f = newForm(nil, 400, 240)
    let g = newGridPanel(f, 0, 0, 300, 100)
    let l = newLabel(g, "x")
    g.setCell(l, 0, 0)
    check g.fCells.len == 1
    g.removeControl(l)
    check g.fCells.len == 0

suite "keys and focus (findings 6, 7, 9, 12)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "removeKeyHandler during the chain does not skip the next handler":
    let f = newForm(nil, 200, 100)
    f.show()
    var log: seq[string]
    f.addKeyHandler("a", proc(k: var Key, s: ShiftState) =
      log.add "a"; f.removeKeyHandler("a"))
    f.addKeyHandler("b", proc(k: var Key, s: ShiftState) = log.add "b")
    f.feed(ekKeyDown, key = key('x'))
    check log == @["a", "b"]
    f.feed(ekKeyDown, key = key('x'))
    check log == @["a", "b", "b"]

  test "a handler removed by an earlier one is not called":
    let f = newForm(nil, 200, 100)
    f.show()
    var log: seq[string]
    f.addKeyHandler("a", proc(k: var Key, s: ShiftState) =
      log.add "a"; f.removeKeyHandler("b"))
    f.addKeyHandler("b", proc(k: var Key, s: ShiftState) = log.add "b")
    f.addKeyHandler("c", proc(k: var Key, s: ShiftState) = log.add "c")
    f.feed(ekKeyDown, key = key('x'))
    check log == @["a", "c"]

  test "auto-repeat skips handlers registered with onRepeat = false and is visible to controls":
    let f = newForm(nil, 200, 100)
    f.show()
    var dialog = 0
    var other = 0
    proc countDialog(k: var Key, s: ShiftState) = inc dialog
    f.addKeyHandler("dialog", countDialog, onRepeat = false)
    f.addKeyHandler("other", proc(k: var Key, s: ShiftState) = inc other)
    f.feed(ekKeyDown, key = keyEnter)
    f.feed(ekKeyDown, key = keyEnter, repeat = true)
    check dialog == 1 and other == 2
    let p = f.probe(0, 0, 50, 50, focusable = true)
    p.setFocus()
    f.feed(ekKeyDown, key = key('a'))
    f.feed(ekKeyDown, key = key('a'), repeat = true)
    f.feed(ekKeyDown, key = key('a'))
    check p.sawRepeat == @[false, true, false]

  test "a press whose focus change hid the target is not delivered":
    let f = newForm(nil, 300, 200)
    f.show()
    let a = f.probe(0, 0, 100, 100, focusable = true)
    let b = f.probe(150, 0, 100, 100, focusable = true)
    a.setFocus()
    a.onExit = proc(s: Control) = b.visible = false
    f.settle()
    f.feed(ekMouseDown, 160, 10)
    check b.downs == 0
    check f.ui.captured == nil
    f.feed(ekMouseUp, 160, 10)

  test "Tab from a focused non-tab-stop continues from its place":
    let f = newForm(nil, 300, 200)
    f.show()
    let a = f.probe(0, 0, 50, 50, focusable = true)
    let b = f.probe(60, 0, 50, 50, focusable = true)
    let c = f.probe(120, 0, 50, 50, focusable = true)
    b.tabStop = false
    b.setFocus()
    check f.activeControl == Control(b)
    f.feed(ekKeyDown, key = keyTab)
    check f.activeControl == Control(c)
    b.setFocus()
    f.feed(ekKeyDown, key = keyTab, shift = {ssShift})
    check f.activeControl == Control(a)

suite "scale, context, canvas (findings 8, 11, 16)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "setScale quantises: tiny changes keep the caches, real ones flush":
    let f = newForm(nil, 200, 100)
    f.show()
    let ctx = f.ctx
    discard ctx.fontMetrics(font("", 14))
    check ctx.fontCount > 0
    let s0 = ctx.scale
    ctx.setScale(s0 + 0.002)
    check ctx.fontCount > 0 and ctx.scale == s0
    ctx.setScale(s0 * 1.5)
    check ctx.fontCount == 0

  test "window scale comes from the pixel density":
    let f = newForm(nil, 200, 100)
    f.show()
    check f.win.scale == getWindowPixelDensity(f.win.window)

  test "font registry changes flush the caches only at the frame start":
    let f = newForm(nil, 200, 100)
    f.show()
    let ctx = f.ctx
    let spec = font("", 14)
    let t1 = ctx.getText("hi", spec)
    check ctx.textCount == 1
    registerFontFamily("treview", assetsDir() / "fonts" / "NotoSans-Regular.ttf")
    let t2 = ctx.getText("hi", spec)     # mid-frame: same cached text, still valid
    check t1 == t2 and ctx.textCount == 1
    ctx.beginFrameTick()
    check ctx.textCount == 0 and ctx.fontCount == 0

  test "beginFrame/endFrame restore the renderer clip rect and blend mode":
    let f = newForm(nil, 200, 100)
    f.show()
    let r = f.win.renderer
    var rc = Rect(x: 3, y: 4, w: 50, h: 40)
    discard setRenderClipRect(r, addr rc)
    discard setRenderDrawBlendMode(r, BLENDMODE_NONE)
    let cv = beginFrame(f.ctx)
    cv.pushClip(rectF(0, 0, 10, 10))
    cv.endFrame()
    var back: Rect
    check renderClipEnabled(r)
    check getRenderClipRect(r, back)
    check back.x == 3 and back.y == 4 and back.w == 50 and back.h == 40
    var bm: BlendMode
    check getRenderDrawBlendMode(r, bm)
    check bm == BLENDMODE_NONE
    discard setRenderClipRect(r, nil)    # no clip before: none after
    let cv2 = beginFrame(f.ctx)
    cv2.endFrame()
    check not renderClipEnabled(r)

  test "forceScale re-syncs open windows and keeps their logical size":
    let f = newForm(nil, 200, 100)
    f.show()
    Application.forceScale = 2
    check f.ctx.scale == 2
    check f.win.pointSize == (400, 200)
    check f.width == 200 and f.height == 100
    Application.forceScale = 0
    check f.ctx.scale == f.win.scale

suite "capture lost (finding 17)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "base hook: focus loss, hiding and removal call captureLost; a release does not":
    let f = newForm(nil, 300, 200)
    f.show()
    let a = f.probe(0, 0, 100, 100)
    f.feed(ekMouseDown, 10, 10)
    f.feed(ekMouseUp, 10, 10)
    check a.captureLosts == 0
    f.feed(ekMouseDown, 10, 10)
    f.feed(ekWindowFocusLost)
    check a.captureLosts == 1
    f.feed(ekMouseUp, 10, 10)
    check a.captureLosts == 1
    f.feed(ekMouseDown, 10, 10)
    a.visible = false
    check a.captureLosts == 2
    a.visible = true
    f.feed(ekMouseDown, 10, 10)
    f.removeControl a
    check a.captureLosts == 3

  test "SpinEdit stops auto-repeat when the press ends without a release":
    let f = newForm(nil, 400, 240)
    f.show()
    let s = newSpinEdit(f, 5, 10, 10, 100)
    f.settle()
    let bp = s.buttons.clientToForm(pointF(5, 3))
    f.feed(ekMouseMove, bp.x, bp.y)
    f.feed(ekMouseDown, bp.x, bp.y)
    check s.repeat.enabled and s.repeatDir == 1
    f.feed(ekWindowFocusLost)
    check not s.repeat.enabled and s.repeatDir == 0
    check s.buttons.pressedDir == 0
    f.feed(ekMouseUp, 500, 500)
    check not s.repeat.enabled

  test "SpinEdit repeatTick stops when no button is held":
    let f = newForm(nil, 400, 240)
    f.show()
    let s = newSpinEdit(f, 5, 10, 10, 100)
    s.repeatDir = 1
    s.repeat.enabled = true
    s.repeatTick()
    check s.value == 5 and s.repeatDir == 0 and not s.repeat.enabled

  test "SpinEdit stops the repeat when the edit loses focus":
    let f = newForm(nil, 400, 240)
    f.show()
    let s = newSpinEdit(f, 5, 10, 10, 100)
    s.edit.setFocus()
    s.repeatDir = 1
    s.repeat.enabled = true
    f.activeControl = nil
    check s.repeatDir == 0 and not s.repeat.enabled

  test "ScrollBar and TrackBar drop their drag":
    let f = newForm(nil, 400, 240)
    f.show()
    let sb = newScrollBar(f, sbVertical, 300, 10, 12, 100)
    sb.setRange(0, 100, 20)
    let tb = newTrackBar(f, 10, 100, 150, 32)
    f.settle()
    f.feed(ekMouseDown, 306, 13)
    check sb.fDragging
    f.feed(ekWindowFocusLost)
    check not sb.fDragging
    f.feed(ekMouseUp, 306, 13)
    # the thumb of position 0 is centred at x = 8
    f.feed(ekMouseDown, 18, 100 + 13)
    check tb.isDragging
    f.feed(ekWindowFocusLost)
    check not tb.isDragging
    f.feed(ekMouseUp, 18, 113)

  test "ScrollBar wheel step honours wheelLines":
    let f = newForm(nil, 400, 240)
    f.show()
    let sb = newScrollBar(f, sbVertical, 300, 10, 12, 100)
    sb.setRange(0, 1000, 20)
    sb.smallChange = 10
    f.settle()
    check sb.wheelLines == 3
    var h = false
    sb.doMouseWheel({}, 0, -1, h)
    check sb.position == 30 and h
    sb.wheelLines = 5
    h = false
    sb.doMouseWheel({}, 0, -1, h)
    check sb.position == 80
    sb.wheelLines = 0                       # clamped to 1
    check sb.wheelLines == 1
    let sc = newScrollBox(f, 10, 10, 100, 100)
    sc.wheelLines = 7
    check sc.vScrollBar.wheelLines == 7 and sc.hScrollBar.wheelLines == 7

  test "Splitter drops its drag":
    let f = newForm(nil, 400, 240)
    f.show()
    let left = newPanel(f, "", 0, 0, 100, 50)
    left.align = alLeft
    let sp = newSplitter(f, alLeft)
    let rest = newPanel(f, "", 0, 0, 10, 10)
    rest.align = alClient
    f.settle()
    f.feed(ekMouseDown, sp.left + 3, 100)
    check sp.isDragging
    f.feed(ekWindowFocusLost)
    check not sp.isDragging
    f.feed(ekMouseUp, sp.left + 3, 100)

suite "misc (findings 13, 14, 15, 19, 20)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    startTimerImpl = startPlatformTimer
    for f in openForms(): f.freeWindow()

  test "a raising dialog callback does not escape":
    let done: FileDialogDone = proc(token: int, ok: bool, files: seq[string]) {.nimcall, gcsafe.} =
      raise newException(ValueError, "done boom")
    deliver(done, 1, true, @["a"])       # must not raise
    check true

  test "a popup whose first paint fails is unregistered and releases its content":
    let f = newForm(nil, 200, 100)
    f.show()
    let content = newContainer()
    content.setBounds(0, 0, 50, 30)
    let b = Boom()
    b.initControl(content)
    content.insertControl b
    expect ValueError: discard showPopup(f, content, rectF(10, 10, 40, 20))
    check openPopups().len == 0
    check content.host == nil

  test "paintPopups paints a copy and reports errors per popup":
    let f = newForm(nil, 200, 100)
    f.show()
    let c1 = newContainer()
    c1.setBounds(0, 0, 50, 30)
    let p1 = showPopup(f, c1, rectF(10, 10, 40, 20))
    c1.invalidate()
    var errors = 0
    paintPopups(proc(e: ref CatchableError) = inc errors)
    check errors == 0 and not p1.ui.needsPaint
    closeAllPopups(f)

  test "Timer.enabled stays false when the platform timer cannot start":
    startTimerImpl = proc(ms: uint32, tag: int): uint32 = 0
    let t = newTimer(nil, 100)
    expect IOError: t.enabled = true
    check not t.enabled
    startTimerImpl = startPlatformTimer
    t.enabled = true
    check t.enabled
    t.enabled = false

  test "TrackBar min=/max= re-clamp through position= (onChange fires)":
    let tb = newTrackBar()
    tb.max = 10
    tb.position = 8
    var changes = 0
    tb.onChange = proc(s: Control) = inc changes
    tb.max = 5
    check tb.position == 5 and changes == 1
    tb.min = 7                           # max follows
    check tb.position == 7 and tb.max == 7 and changes == 2

  test "Form behaves through a Control reference":
    let f = newForm(nil, 200, 100)
    let c: Control = f
    check not c.visible
    c.visible = true
    check f.visible and c.visible and f.hasWindow
    c.caption = "via control"
    check $getWindowTitle(f.win.window) == "via control"
    check f.caption == "via control"
    c.bringToFront()                     # raises the window, no crash
    c.visible = false
    check not f.visible and not c.visible

suite "fitPrefix (coordinator follow-up)":
  test "a width below one device pixel fits nothing":
    Application.init()
    let f = newForm(nil, 100, 50)
    f.show()
    check f.ctx.fitPrefix("hello", font("", 14), 0) == 0
    check f.ctx.fitPrefix("hello", font("", 14), 0.5) == 0
    check f.ctx.fitPrefix("hello", font("", 14), 1000) == 5
    f.freeWindow()

suite "interaction and lifetime fixes":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "a modal state cancels the press that opened it":
    let f = newForm(nil, 300, 200)
    f.show()
    let a = f.probe(0, 0, 100, 100, focusable = true)
    let b = f.probe(150, 0, 100, 100, focusable = true)
    f.feed(ekMouseDown, 10, 10)
    check f.ui.captured == a
    beginModalState()
    check f.ui.captured == nil
    endModalState()
    f.feed(ekMouseDown, 160, 10)       # goes to what is under the pointer
    check b.downs == 1 and a.downs == 1

  test "showModal cancels the capture of the form below":
    let f = newForm(nil, 300, 200)
    f.show()
    let a = f.probe(0, 0, 100, 100, focusable = true)
    f.feed(ekMouseDown, 10, 10)
    let d = newForm(nil, 100, 80)
    d.onShow = proc(s: Control) = d.modalResult = mrOk
    discard d.showModal()
    check f.ui.captured == nil
    d.freeWindow()

  test "no click for a control the mouse-up handler removed":
    let f = newForm(nil, 300, 200)
    f.show()
    let a = f.probe(0, 0, 100, 100)
    var clicks = 0
    a.onClick = proc(s: Control) = inc clicks
    a.onMouseUp = proc(s: Control, b: MouseButton, sh: ShiftState, x, y: float32) =
      s.parent = nil
    f.feed(ekMouseDown, 10, 10)
    f.feed(ekMouseUp, 10, 10)
    check clicks == 0

  test "freeing a control stops the timers it owns":
    let f = newForm(nil, 300, 200)
    let p = newPanel(f, "", 0, 0, 100, 100)
    startTimerImpl = proc(ms: uint32, tag: int): uint32 = 7
    defer: startTimerImpl = startPlatformTimer
    let t = newTimer(p, 10)
    t.enabled = true
    check t.enabled
    p.free()
    check not t.enabled
    check not dispatchTimer(1_000_000)

  test "a timer posts one event until it is handled":
    let id = 4242
    let h = startPlatformTimer(1, id)
    check h != 0
    sleep(60)
    var n = 0
    var pe: PlatformEvent
    while pollPlatformEvent(pe):
      if pe.kind == ekTimer and pe.timerId == id: inc n
    check n == 1                       # not one per millisecond
    ackPlatformTimer(h)
    sleep(30)
    n = 0
    while pollPlatformEvent(pe):
      if pe.kind == ekTimer and pe.timerId == id: inc n
    stopPlatformTimer(h)
    check n == 1
    while pollPlatformEvent(pe): discard

  test "many queued jobs wake the loop once":
    pushWake()
    pushWake()
    pushWake()
    var n = 0
    var pe: PlatformEvent
    while pollPlatformEvent(pe):
      if pe.kind == ekWake: inc n
    check n == 1
