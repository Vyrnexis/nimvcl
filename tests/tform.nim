## Form, input routing, Application and Timer tests. Headless (offscreen SDL):
## events are built by hand and fed through the same dispatch the loop uses.

import std/[unittest, strutils, sequtils, os, monotimes, times]
import sdl3 except Color, Cursor
import nimvcl

type
  Probe = ref object of Container
    ## Logs every event to the shared `trace` as "name.event".
    focusable, textInput, wheelHandled: bool
  Trace = seq[string]

var trace: Trace

proc mark(p: Control, what: string) = trace.add p.name & "." & what

method doMouseEnter(p: Probe) = p.mark "enter"; procCall doMouseEnter(Container(p))
method doMouseLeave(p: Probe) = p.mark "leave"; procCall doMouseLeave(Container(p))
method doMouseDown(p: Probe, b: MouseButton, s: ShiftState, x, y: float32) =
  p.mark "down"; procCall doMouseDown(Container(p), b, s, x, y)
method doMouseUp(p: Probe, b: MouseButton, s: ShiftState, x, y: float32) =
  p.mark "up"; procCall doMouseUp(Container(p), b, s, x, y)
method doMouseMove(p: Probe, s: ShiftState, x, y: float32) =
  p.mark "move:" & $int(x) & "," & $int(y)
  procCall doMouseMove(Container(p), s, x, y)
method doClick(p: Probe) = p.mark "click"; procCall doClick(Container(p))
method doDblClick(p: Probe) = p.mark "dbl"; procCall doDblClick(Container(p))
method doMouseWheel(p: Probe, s: ShiftState, dx, dy: float32, handled: var bool) =
  p.mark "wheel"
  if p.wheelHandled: handled = true
method doKeyDown(p: Probe, key: var Key, s: ShiftState) =
  p.mark "key:" & $key; procCall doKeyDown(Container(p), key, s)
method doKeyPress(p: Probe, text: var string) =
  p.mark "press:" & text
method doEnter(p: Probe) = p.mark "focus"; procCall doEnter(Container(p))
method doExit(p: Probe) = p.mark "blur"; procCall doExit(Container(p))
method canFocus(p: Probe): bool = p.focusable and p.isVisible and p.isEnabled
method wantsTextInput(p: Probe): bool = p.textInput

proc probe(parent: Container, name: string, x, y, w, h: float32,
           focusable = false): Probe =
  result = Probe(name: name, focusable: focusable)
  result.initContainer()
  result.setBounds(x, y, w, h)
  result.tabStop = focusable
  parent.insertControl(result)

proc mouse(f: Form, kind: EventKind, x, y: float32, button = mbLeft,
           clicks = 1, shift: ShiftState = {}): PlatformEvent =
  PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y, button: button,
                clicks: clicks, shift: shift)

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(mouse(f, kind, x, y, button, clicks, shift))
proc moveTo(f: Form, x, y: float32) = f.feed(ekMouseMove, x, y)
proc down(f: Form, x, y: float32, clicks = 1) = f.feed(ekMouseDown, x, y, clicks = clicks)
proc up(f: Form, x, y: float32) = f.feed(ekMouseUp, x, y)
proc click(f: Form, x, y: float32) = f.down(x, y); f.up(x, y)
proc key(f: Form, k: Key, shift: ShiftState = {}, kind = ekKeyDown) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, key: k,
                                     shift: shift))

proc has(t: Trace, s: string): bool = s in t
proc take(): Trace =
  result = trace
  trace = @[]

proc newShown(w = 400'f32, h = 300'f32): Form =
  result = newForm(nil, w, h)
  result.show()
  trace = @[]

proc destroy(f: Form) = f.freeWindow()

template queued(body: untyped) =
  ## Application.queue for test bodies (their locals are module globals).
  Application.queue(proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      body)

proc waitUntil(cond: proc(): bool, ms = 3000) =
  let t0 = getMonoTime()
  while not cond() and (getMonoTime() - t0).inMilliseconds < ms:
    Application.processMessages(20)

suite "form basics":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "window is created lazily and freed in order":
    let f = newForm()
    check not f.hasWindow
    f.show()
    check f.hasWindow and f.visible
    check f.ctx != nil and not f.ctx.isClosed
    let c = f.ctx
    f.freeWindow()
    check not f.hasWindow and c.isClosed
    f.show()                       # can be shown again after being freed
    check f.hasWindow and not f.ctx.isClosed
    f.freeWindow()

  test "caption, size, paint":
    let f = newShown(320, 200)
    f.caption = "Hello"
    check f.width == 320 and f.height == 200
    check f.paintIfDirty()
    check not f.paintIfDirty()
    f.invalidate()
    check f.paintIfDirty()
    f.destroy()

  test "close: closeQuery veto, onClose action":
    let f = newShown()
    var asked = 0
    f.onCloseQuery = proc(s: Form, can: var bool) = inc asked; can = false
    f.close()
    check asked == 1 and f.visible
    f.onCloseQuery = nil
    f.onClose = proc(s: Form, a: var CloseAction) = a = caNone
    f.close()
    check f.visible
    f.onClose = nil
    f.close()
    check not f.visible and f.hasWindow          # caHide keeps the window
    f.show()
    f.onClose = proc(s: Form, a: var CloseAction) = a = caFree
    f.close()
    check not f.hasWindow

  test "window close event goes to Form.close":
    let f = newShown()
    var closed = false
    f.onClose = proc(s: Form, a: var CloseAction) = closed = true; a = caFree
    Application.dispatch(PlatformEvent(kind: ekWindowClose, windowId: f.win.id))
    check closed and not f.hasWindow

  test "real SDL events are translated":
    let f = newShown()
    let a = probe(f, "a", 10, 10, 100, 50)
    var ev: Event
    ev.motion = MouseMotionEvent(`type`: EVENT_MOUSE_MOTION, windowID: f.win.id,
                                 x: 20, y: 20)
    Application.dispatchEvent(ev)
    check take() == @["a.enter", "a.move:10,10"]
    ev.button = MouseButtonEvent(`type`: EVENT_MOUSE_BUTTON_DOWN,
      windowID: f.win.id, button: 1, down: true, clicks: 2, x: 20, y: 20)
    Application.dispatchEvent(ev)
    ev.button = MouseButtonEvent(`type`: EVENT_MOUSE_BUTTON_UP,
      windowID: f.win.id, button: 1, down: false, clicks: 2, x: 20, y: 20)
    Application.dispatchEvent(ev)
    check take() == @["a.down", "a.dbl", "a.up", "a.click"]
    ev.key = KeyboardEvent(`type`: EVENT_KEY_DOWN, windowID: f.win.id,
                           key: SDLK_TAB, down: true)
    Application.dispatchEvent(ev)       # no focusable controls: no crash
    f.destroy()

suite "mouse routing":
  setup:
    Application.init()
  teardown:
    for f in openForms(): f.freeWindow()

  test "click needs down and up over the same control":
    let f = newShown()
    discard probe(f, "a", 10, 10, 100, 50)
    discard probe(f, "b", 150, 10, 100, 50)
    f.click(20, 20)
    check take() == @["a.enter", "a.down", "a.up", "a.click"]
    f.down(20, 20)
    f.up(160, 20)                       # released over b: capture keeps it on a
    let t = take()
    check "a.down" in t and "a.up" in t and "a.click" notin t
    check "b.down" notin t and "b.up" notin t
    f.up(300, 250)                      # stray up: nothing
    f.down(300, 250)
    f.up(20, 20)                        # pressed on the form, released on a
    check "a.click" notin take()
    f.destroy()

  test "release outside after drag does not click, inside does":
    let f = newShown()
    discard probe(f, "a", 10, 10, 100, 50)
    f.down(20, 20)
    f.moveTo(300, 200)
    f.up(300, 200)
    check "a.click" notin take()
    f.down(20, 20)
    f.moveTo(300, 200)
    f.moveTo(30, 30)
    f.up(30, 30)
    check "a.click" in take()
    f.destroy()

  test "capture keeps moves on the pressed control":
    let f = newShown()
    discard probe(f, "a", 10, 10, 100, 50)
    discard probe(f, "b", 150, 10, 100, 50)
    f.down(20, 20)
    trace = @[]
    f.moveTo(350, 250)                  # far outside a
    check take() == @["a.leave", "a.move:340,240"]
    f.moveTo(160, 20)                   # over b, but captured by a
    check take() == @["a.move:150,10"]
    f.moveTo(20, 20)
    check take() == @["a.enter", "a.move:10,10"]
    f.up(160, 20)
    let t = take()
    check t[0] == "a.up" and "b.enter" in t
    f.destroy()

  test "hover enter/leave sequence":
    let f = newShown()
    discard probe(f, "a", 10, 10, 100, 50)
    discard probe(f, "b", 150, 10, 100, 50)
    f.moveTo(20, 20)
    f.moveTo(30, 30)
    f.moveTo(160, 20)
    f.moveTo(160, 200)
    f.moveTo(20, 20)
    Application.dispatch(PlatformEvent(kind: ekWindowMouseLeave, windowId: f.win.id))
    var enters: Trace
    for s in take():
      if s.endsWith("enter") or s.endsWith("leave"): enters.add s
    check enters == @["a.enter", "a.leave", "b.enter", "b.leave", "a.enter", "a.leave"]
    check f.ui.hovered == nil
    f.destroy()

  test "disabled controls receive nothing":
    let f = newShown()
    let a = probe(f, "a", 10, 10, 100, 50, focusable = true)
    a.enabled = false
    f.moveTo(20, 20)
    f.click(20, 20)
    f.feed(ekMouseWheel, 20, 20)
    check take().len == 0
    check f.ui.focusedControl == nil
    f.destroy()

  test "a disabled control swallows the mouse: the parent gets nothing":
    let f = newShown()
    let outer = probe(f, "outer", 10, 10, 200, 100, focusable = true)
    let a = probe(outer, "a", 10, 10, 50, 30, focusable = true)
    a.enabled = false
    f.moveTo(25, 25)
    f.click(25, 25)
    f.feed(ekMouseWheel, 25, 25)
    check take().len == 0
    check f.ui.hovered == nil
    check f.ui.focusedControl == nil
    outer.enabled = false          # a disabled container blocks its children too
    a.enabled = true
    f.click(25, 25)
    check take().len == 0
    f.destroy()

  test "event observers can be removed, also while they run":
    let f = newShown()
    var first, second = 0
    var removeFirst: EventObserver
    let b = proc(f: Form, pe: PlatformEvent) = inc second
    removeFirst = proc(f: Form, pe: PlatformEvent) =
      inc first
      Application.removeEventObserver(removeFirst)
    Application.addEventObserver(removeFirst)
    Application.addEventObserver(b)
    f.moveTo(5, 5)
    f.moveTo(6, 6)
    check first == 1
    check second == 2                    # the next observer still ran each time
    Application.removeEventObserver(b)
    f.moveTo(7, 7)
    check second == 2
    f.destroy()

  test "double click":
    let f = newShown()
    discard probe(f, "a", 10, 10, 100, 50)
    f.down(20, 20, clicks = 2)
    check "a.dbl" in take()
    f.up(20, 20)
    f.destroy()

  test "wheel bubbles to parents until handled":
    let f = newShown()
    let p = probe(f, "p", 10, 10, 200, 200)
    discard probe(p, "i", 10, 10, 50, 50)
    f.feed(ekMouseWheel, 30, 30)
    check take().filterIt(it.endsWith("wheel")) == @["i.wheel", "p.wheel"]
    p.wheelHandled = true
    let q = probe(f, "q", 250, 10, 100, 100)
    f.feed(ekMouseWheel, 30, 30)
    check take().filterIt(it.endsWith("wheel")) == @["i.wheel", "p.wheel"]
    discard q
    f.destroy()

  test "controlLost clears hover, capture and focus":
    let f = newShown()
    let a = probe(f, "a", 10, 10, 100, 50, focusable = true)
    f.down(20, 20)
    check f.ui.captured == a and f.ui.hovered == a and f.activeControl == a
    a.visible = false
    check f.ui.captured == nil and f.ui.hovered == nil and f.activeControl == nil
    check "a.blur" in take()
    f.up(20, 20)                        # nothing left to receive it
    check take().len == 0
    a.visible = true
    f.click(20, 20)
    check f.activeControl == a
    f.removeControl(a)                  # removal clears focus too
    check f.activeControl == nil and f.ui.hovered == nil
    f.insertControl(a)
    f.click(20, 20)
    a.enabled = false
    check f.activeControl == nil
    f.destroy()

  test "cursor changes do not crash":
    let f = newShown()
    let a = probe(f, "a", 10, 10, 100, 50)
    a.cursor = crHand
    f.moveTo(20, 20)
    a.cursor = crIBeam
    f.moveTo(300, 250)
    f.destroy()

suite "keyboard and focus":
  setup:
    Application.init()
  teardown:
    for f in openForms(): f.freeWindow()

  test "mouse down focuses a focusable control":
    let f = newShown()
    let a = probe(f, "a", 10, 10, 100, 50, focusable = true)
    let b = probe(f, "b", 150, 10, 100, 50)
    f.click(20, 20)
    check f.activeControl == a and a.focused
    check take().filterIt(it.endsWith("focus")) == @["a.focus"]
    f.click(160, 20)                    # not focusable: focus stays
    check f.activeControl == a
    discard b
    f.activeControl = nil
    check take().filterIt(it.endsWith("blur")) == @["a.blur"]
    f.activeControl = b                 # refused: canFocus is false
    check f.activeControl == nil
    f.destroy()

  test "tab order: tabOrder, then index, nested containers, wrap":
    let f = newShown()
    let f1 = probe(f, "f1", 0, 0, 10, 10, true)
    f1.tabOrder = 2
    let f2 = probe(f, "f2", 20, 0, 10, 10, true)
    f2.tabOrder = 0
    let g = probe(f, "g", 40, 0, 100, 100)
    g.tabOrder = 1
    let g1 = probe(g, "g1", 0, 0, 10, 10, true)
    g1.tabOrder = 1
    let g2 = probe(g, "g2", 20, 0, 10, 10, true)
    g2.tabOrder = 0
    discard probe(f, "plain", 0, 20, 10, 10)             # not a stop
    let hidden = probe(f, "hidden", 0, 40, 10, 10, true)
    hidden.visible = false
    let dis = probe(f, "dis", 0, 60, 10, 10, true)
    dis.enabled = false
    check tabStops(f).mapIt(it.name) == @["f2", "g2", "g1", "f1"]
    var seen: seq[string]
    for i in 0 ..< 5:
      f.key(keyTab)
      seen.add f.activeControl.name
    check seen == @["f2", "g2", "g1", "f1", "f2"]
    f.key(keyTab, {ssShift})
    check f.activeControl == f1                          # backwards, wraps
    f.key(keyTab, {ssShift})
    check f.activeControl == g1
    f.destroy()

  test "keys go to the focused control; swallowed Tab does not navigate":
    let f = newShown()
    let a = probe(f, "a", 0, 0, 10, 10, true)
    discard probe(f, "b", 20, 0, 10, 10, true)
    f.activeControl = a
    trace = @[]
    a.onKeyDown = proc(c: Control, k: var Key, s: ShiftState) =
      if k == keyTab: k = Key(0)
    f.key(keyTab)
    check f.activeControl == a
    check "a.key:Tab" in take()
    f.key('x'.key)
    check take() == @["a.key:x"]
    f.destroy()

  test "keyPreview: form first, can swallow":
    let f = newShown()
    let a = probe(f, "a", 0, 0, 10, 10, true)
    f.activeControl = a
    f.name = "form"
    var seen: seq[string]
    f.onKeyDown = proc(c: Control, k: var Key, s: ShiftState) =
      seen.add "form:" & $k
      if k == 'q'.key: k = Key(0)
    trace = @[]
    f.key('x'.key)
    check seen.len == 0 and take() == @["a.key:x"]       # no preview
    f.keyPreview = true
    f.key('x'.key)
    check seen == @["form:x"] and take() == @["a.key:x"]
    f.key('q'.key)
    check seen == @["form:x", "form:q"] and take().len == 0
    f.activeControl = nil                               # no focus: form gets it once
    seen = @[]
    f.key('x'.key)
    check seen == @["form:x"]
    f.destroy()

  test "unhandled key hook":
    let f = newShown()
    var got: Key
    f.ui.onUnhandledKey = proc(k: var Key, s: ShiftState) = got = k
    f.key(keyEscape)
    check got == keyEscape
    f.destroy()

  test "text input reaches the focused control":
    let f = newShown()
    let a = probe(f, "a", 0, 0, 100, 20, true)
    a.textInput = true
    Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id,
                                       text: "hi"))
    check take().len == 0
    f.activeControl = a                  # starts SDL text input
    Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id,
                                       text: "hé"))
    check take().filterIt(it.contains("press")) == @["a.press:hé"]
    f.activeControl = nil                # stops it
    f.destroy()

suite "resize and scale":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    Application.forceScale = 0
    for f in openForms(): f.freeWindow()

  test "resize relayouts children":
    let f = newShown(400, 300)
    let c = probe(f, "c", 0, 0, 10, 10)
    c.align = alClient
    f.layoutIfNeeded()
    check c.width == 400 and c.height == 300
    var resized = 0
    f.onResize = proc(s: Control) = inc resized
    f.width = 500                        # program-driven: window follows
    Application.dispatch(PlatformEvent(kind: ekWindowResized, windowId: f.win.id))
    check f.width == 500 and resized >= 1
    check f.paintIfDirty()
    check c.width == 500 and c.height == 300
    f.destroy()

  test "scale change updates the render context":
    let f = newShown()
    check f.ctx.scale == 1
    Application.forceScale = 2
    Application.dispatch(PlatformEvent(kind: ekWindowScale, windowId: f.win.id))
    check f.ctx.scale == 2
    Application.forceScale = 1.5
    check f.ctx.scale == 1.5
    check f.paintIfDirty()
    f.destroy()

  test "theme switch invalidates forms":
    let f = newShown()
    discard f.paintIfDirty()
    check not f.ui.needsPaint
    Application.theme = themeDark()
    check f.ui.needsPaint
    Application.theme = themeLight()
    f.destroy()

suite "application":
  setup:
    Application.init()
  teardown:
    for f in openForms(): f.freeWindow()

  test "showModal returns the queued modalResult":
    let m = newShown()
    var inner: ModalResult
    queued: m.modalResult = mrYes
    m.hide()
    inner = m.showModal()
    check inner == mrYes
    check not m.visible and not m.isModal
    m.destroy()

  test "withModal / executeModalForm return the result and free the window":
    let a = newForm()
    queued: a.modalResult = mrOk
    check a.executeModalForm() == mrOk
    check not a.hasWindow
    var seen = mrNone
    let b = newForm()
    queued: b.modalResult = mrYes
    withModal(b):
      seen = dlgResult
      check b.hasWindow                 # still there while the body runs
    check seen == mrYes and not b.hasWindow
    # the window is freed when the body raises too
    let c = newForm()
    queued: c.modalResult = mrOk
    expect ValueError:
      withModal(c):
        raise newException(ValueError, "boom")
    check not c.hasWindow

  test "modal: other forms ignore input; closing gives mrCancel":
    let a = newShown()
    discard probe(a, "pa", 10, 10, 100, 50)
    let m = newForm()
    var leaked = true
    queued:
      a.feed(ekMouseDown, 20, 20)
      a.feed(ekMouseUp, 20, 20)
      leaked = "pa.down" in trace
      m.close()
    check m.showModal() == mrCancel
    check not leaked
    a.click(20, 20)                      # works again once the modal is gone
    check "pa.click" in take()
    a.destroy()

  test "modal closeQuery veto keeps the loop running":
    let m = newForm()
    var vetoes = 0
    m.onCloseQuery = proc(s: Form, can: var bool) =
      inc vetoes
      can = vetoes > 1
      if not can: queued: m.modalResult = mrOk     # try again
    queued: m.modalResult = mrOk
    check m.showModal() == mrOk
    check vetoes == 2

  test "queue from another thread runs on the UI thread":
    var ran = 0
    var ranOn = 0
    let mainId = getThreadId()
    var th: Thread[int]
    proc job(v: int): QueuedProc =
      result = proc() {.closure, gcsafe.} =
        {.cast(gcsafe).}:
          ranOn = getThreadId()
          ran += v + 1
    proc worker(n: int) {.thread.} =
      for i in 0 ..< n:
        {.cast(gcsafe).}:
          Application.queue(job(i))
    {.cast(gcsafe).}:
      createThread(th, worker, 5)
    waitUntil(proc(): bool = ran == 15)
    joinThread(th)
    check ran == 15 and ranOn == mainId

  test "Timer fires, stops when disabled":
    var ticks = 0
    let t = newTimer(nil, 15)
    t.onTimer = proc(s: Timer) = inc ticks
    check not t.enabled
    t.enabled = true
    waitUntil(proc(): bool = ticks >= 3)
    check ticks >= 3
    t.enabled = false
    Application.processMessages(0)       # drain stale ticks
    let n = ticks
    sleep 80
    Application.processMessages(0)
    check ticks == n
    t.interval = 10
    t.free()

  test "idle blocks: no events means the wait times out":
    # A stray event left by earlier tests (window expose, timer wake) ends a
    # wait early, which is correct; one quiet wait of the full length proves
    # the loop blocks.
    var waited = 0'i64
    for attempt in 0 ..< 5:
      for _ in 0 ..< 10: Application.processMessages(0)
      let t0 = getMonoTime()
      Application.processMessages(120)
      waited = (getMonoTime() - t0).inMilliseconds
      if waited >= 100: break
    check waited >= 100

  test "clipboard round trip":
    Application.clipboard = "nimvcl"
    check Application.clipboard == "nimvcl"

suite "form icon and menu":
  Application.init()

  test "icon: kept, applied to the window when it exists and when it is created":
    let f = newForm(nil, 200, 100)
    check f.icon == nil
    let img = newImage(16, 16, rgb(200, 0, 0))
    f.icon = img                               # before the window exists
    check f.icon == img
    f.show()                                   # creates the window with the icon
    check f.hasWindow
    f.icon = newImage(32, 32, rgb(0, 0, 200))  # while shown
    check f.icon.width == 32
    f.icon = nil                               # clearing keeps the window alive
    check f.icon == nil and f.hasWindow
    f.freeWindow()

  test "menu: assigning a MainMenu makes it the form's bar; nil removes it":
    let f = newForm(nil, 300, 200)
    let mm = newMainMenu(nil)
    mm.addItem("File")
    check f.menu == nil
    f.menu = mm
    check f.menu == mm and mm.parent == Container(f) and mm.align == alTop
    let other = newMainMenu(nil)
    f.menu = other
    check f.menu == other and mm.parent == nil
    f.menu = nil
    check f.menu == nil

suite "window size limits":
  test "constraints reach the OS window when it exists and when it is created":
    var a, b: cint
    let f = newForm(nil, 300, 200)
    f.constraints = constraints(100, 80, 500, 400)   # no window yet
    f.show()
    discard getWindowMinimumSize(f.win.window, a, b)
    check (a, b) == (cint(100), cint(80))
    discard getWindowMaximumSize(f.win.window, a, b)
    check (a, b) == (cint(500), cint(400))
    f.constraints = constraints(150, 90)
    discard getWindowMinimumSize(f.win.window, a, b)
    check (a, b) == (cint(150), cint(90))
    discard getWindowMaximumSize(f.win.window, a, b)
    check (a, b) == (cint(0), cint(0))
    f.freeWindow()

suite "closing the main form":
  test "the other forms are closed first; a veto cancels, caFree fires onHide":
    let m = newForm(nil, 200, 150)
    let o = newForm(nil, 200, 150)
    var log: seq[string]
    m.onCloseQuery = proc(s: Form, c: var bool) = log.add "m.query"
    o.onCloseQuery = proc(s: Form, c: var bool) =
      log.add "o.query"; c = false
    o.onClose = proc(s: Form, a: var CloseAction) = log.add "o.close"; a = caFree
    o.onHide = proc(s: Control) = log.add "o.hide"
    m.show()
    o.show()
    m.close()
    check log == @["m.query", "o.query"]
    check m.visible and o.visible
    o.onCloseQuery = proc(s: Form, c: var bool) = log.add "o.query"
    log.setLen 0
    m.close()
    check log == @["m.query", "o.query", "o.close", "o.hide"]
    check not o.hasWindow and not m.visible

suite "shutdown order":
  test "modal forms first, then reverse registration order":
    let a = newForm(nil, 100, 80)
    let b = newForm(nil, 100, 80)
    let d = newForm(nil, 100, 80)
    a.show()
    b.show()
    var order: seq[Form]
    d.onShow = proc(s: Control) =
      order = shutdownOrder()
      d.modalResult = mrOk
    discard d.showModal()
    check order[0] == d
    check order.find(b) < order.find(a)
    check order.find(a) >= 0
    check order.len == openForms().len

suite "window state":
  test "requested before the window exists, kept across show and release":
    let f = newForm(nil, 200, 100)
    f.borderStyle = bsSizeable
    check f.windowState == wsNormal and not f.isMaximized
    f.maximize()
    check f.windowState == wsMaximized and f.isMaximized
    f.show()      # headless drivers cannot maximize: the request is remembered
    check f.isMaximized
    f.minimize()
    check f.isMinimized and not f.isMaximized
    f.windowState = wsNormal
    check f.windowState == wsNormal
    f.maximize()
    f.freeWindow()
    check f.isMaximized                # kept for the next window
    f.restore()
    check not f.isMaximized and not f.isMinimized
    f.show()
    check f.windowState == wsNormal
    f.freeWindow()

  test "PlatformWindow state queries on a normal window":
    let f = newForm(nil, 200, 100)
    f.show()
    check not f.win.isMaximized and not f.win.isMinimized
    f.freeWindow()
