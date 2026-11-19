## Stock controls (phase 3). Headless (offscreen SDL): events are built by hand
## and fed through Application.dispatch, like tform.nim.

import std/unittest
import nimvcl

type
  Plain = ref object of Control
    ## Focusable control that uses no keys (like an Edit ignoring Enter/Esc).

method canFocus(p: Plain): bool = p.isVisible and p.isEnabled

proc newPlain(parent: Container, x, y, w, h: float32): Plain =
  result = Plain()
  result.initControl()
  result.setBounds(x, y, w, h)
  result.tabStop = true
  parent.insertControl result

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))
proc moveTo(f: Form, x, y: float32) = f.feed(ekMouseMove, x, y)
proc down(f: Form, x, y: float32) = f.feed(ekMouseDown, x, y)
proc up(f: Form, x, y: float32) = f.feed(ekMouseUp, x, y)
proc click(f: Form, x, y: float32) = f.down(x, y); f.up(x, y)
proc keyDown(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k,
                                     shift: shift))
proc keyUp(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k,
                                     shift: shift))
proc tap(f: Form, k: Key, shift: ShiftState = {}) = f.keyDown(k, shift); f.keyUp(k, shift)

proc newShown(w = 400'f32, h = 300'f32): Form =
  result = newForm(nil, w, h)
  result.show()

template queued(body: untyped) =
  Application.queue(proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      body)

suite "controls":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "button: mouse click":
    let f = newShown()
    let b = newButton(f, "Go", 10, 10, 100, 28)
    var n = 0
    b.onClick = proc(s: Control) = inc n
    f.click(50, 20)
    check n == 1
    f.click(200, 200)                 # outside
    check n == 1
    check b.focused

  test "button: pressed visual follows the pointer while held":
    let f = newShown()
    let b = newButton(f, "Go", 10, 10, 100, 28)
    var n = 0
    b.onClick = proc(s: Control) = inc n
    f.moveTo(50, 20)
    check b.isHot and not b.isPressed
    f.down(50, 20)
    check b.isPressed
    f.moveTo(250, 200)                # drag out: un-pressed, still captured
    check not b.isPressed
    f.moveTo(60, 20)                  # back in
    check b.isPressed
    f.moveTo(250, 200)
    f.up(250, 200)                    # released outside: no click
    check n == 0 and not b.isPressed
    f.click(50, 20)
    check n == 1

  test "button: Space clicks on key up, Enter on key down":
    let f = newShown()
    let b = newButton(f, "Go", 10, 10, 100, 28)
    var n = 0
    b.onClick = proc(s: Control) = inc n
    f.activeControl = b
    f.keyDown(keySpace)
    check b.isPressed and n == 0
    f.keyUp(keySpace)
    check n == 1 and not b.isPressed
    f.keyDown(keyEnter)
    check n == 2

  test "button: default and cancel via Enter / Esc":
    let f = newShown()
    let field = newPlain(f, 10, 100, 100, 24)
    let ok = newButton(f, "OK", 10, 10, 80, 28)
    let cancel = newButton(f, "Cancel", 100, 10, 80, 28)
    ok.isDefault = true
    cancel.isCancel = true
    var log: seq[string]
    ok.onClick = proc(s: Control) = log.add "ok"
    cancel.onClick = proc(s: Control) = log.add "cancel"
    f.activeControl = field
    f.tap(keyEnter)
    check log == @["ok"]
    f.tap(keyEscape)
    check log == @["ok", "cancel"]
    # a focused button takes Enter itself
    f.activeControl = cancel
    f.tap(keyEnter)
    check log == @["ok", "cancel", "cancel"]
    # disabled / hidden default buttons are skipped
    f.activeControl = field
    ok.enabled = false
    f.tap(keyEnter)
    check log.len == 3
    ok.enabled = true
    ok.visible = false
    f.tap(keyEnter)
    check log.len == 3
    ok.visible = true
    f.tap(keyEnter)
    check log.len == 4 and log[^1] == "ok"

  test "button: dialog keys are installed when the button gets into a form":
    let f = newShown()
    let ok = newButton(nil, "OK", 10, 10, 80, 28)
    ok.isDefault = true               # not in a form yet: no hook possible
    check not f.ui.hasKeyHandler("dialog")
    f.insertControl ok
    check f.paintIfDirty()
    check f.ui.hasKeyHandler("dialog")
    var n = 0
    ok.onClick = proc(s: Control) = inc n
    f.tap(keyEnter)                   # nothing focused: the form gets the key
    check n == 1

  test "button: modalResult is set on the form":
    let f = newShown()
    let b = newButton(f, "OK", 10, 10, 80, 28)
    b.modalResult = mrOk
    check f.modalResult == mrNone
    f.click(20, 20)
    check f.modalResult == mrOk

  test "button: onClick can veto the modalResult":
    let f = newShown()
    let b = newButton(f, "OK", 10, 10, 80, 28)
    b.modalResult = mrOk
    b.onClick = proc(s: Control) = f.modalResult = mrNone
    f.click(20, 20)
    check f.modalResult == mrNone

  test "button: modalResult closes a modal form":
    let m = newForm(nil, 300, 200)
    let b = newButton(m, "OK", 20, 20, 100, 28)
    b.modalResult = mrYes
    queued: m.click(30, 30)
    check m.showModal() == mrYes
    check not m.visible

  test "button: autoSize uses the text width":
    let f = newShown()
    let b = newButton(f, "OK", 10, 10)
    b.autoSize = true
    layoutIfNeeded(f)
    let w1 = b.width
    b.caption = "A rather long caption"
    layoutIfNeeded(f)
    check b.width > w1 and b.height >= f.theme.controlHeight

  test "checkbox: click and Space toggle, grayed cycle":
    let f = newShown()
    let c = newCheckBox(f, "Opt", false, 10, 10)
    var changes = 0
    var clicks = 0
    c.onChange = proc(s: Control) = inc changes
    c.onClick = proc(s: Control) = inc clicks
    f.click(14, 18)                   # on the box
    check c.checked and changes == 1 and clicks == 1
    f.click(c.width - 4, 18)          # on the caption side
    check c.state == cbUnchecked and changes == 2
    f.tap(keySpace)
    check c.checked
    f.tap(keySpace)
    check not c.checked
    c.allowGrayed = true
    f.click(14, 18); check c.state == cbChecked
    f.click(14, 18); check c.state == cbGrayed
    f.click(14, 18); check c.state == cbUnchecked
    c.state = cbGrayed
    c.allowGrayed = false             # grayed is not allowed any more
    check c.state == cbUnchecked

  test "radiobutton: group exclusivity":
    let f = newShown()
    let r1 = newRadioButton(f, "a", false, 10, 10)
    let r2 = newRadioButton(f, "b", false, 10, 40)
    let g = newPanel(f, "", 200, 10, 150, 100)
    let s1 = newRadioButton(g, "x", true, 10, 10)
    let s2 = newRadioButton(g, "y", false, 10, 40)
    f.click(14, 18)
    check r1.checked and not r2.checked
    f.click(14, 48)
    check r2.checked and not r1.checked
    check s1.checked and not s2.checked      # other group untouched
    s2.checked = true
    check s2.checked and not s1.checked and r2.checked

  test "radiobutton: arrows move and check, one tab stop per group":
    let f = newShown()
    let r1 = newRadioButton(f, "a", false, 10, 10)
    let r2 = newRadioButton(f, "b", false, 10, 40)
    let r3 = newRadioButton(f, "c", false, 10, 70)
    let after = newPlain(f, 10, 120, 80, 24)
    check tabStops(f) == @[Control(r1), after]       # none checked: the first
    r2.checked = true
    check tabStops(f) == @[Control(r2), after]
    f.activeControl = r2
    f.tap(keyDown)
    check r3.checked and f.activeControl == Control(r3)
    f.tap(keyRight)                                   # wraps to the first
    check r1.checked and f.activeControl == Control(r1)
    f.tap(keyUp)                                      # and back
    check r3.checked and f.activeControl == Control(r3)
    f.tap(keyLeft)
    check r2.checked
    r1.enabled = false
    f.tap(keyUp)                                      # skips the disabled one
    check r3.checked

  test "label: autoSize grows with the caption":
    let f = newShown()
    let l = newLabel(f, "Hi", 10, 10)
    layoutIfNeeded(f)
    let w1 = l.width
    check w1 > 0 and l.height > 0
    l.caption = "A much longer caption than before"
    layoutIfNeeded(f)
    check l.width > w1 + 40
    l.autoSize = false
    l.caption = "x"
    layoutIfNeeded(f)
    check l.width > w1 + 40                           # fixed now

  test "label: wordWrap keeps the width and grows in height":
    let f = newShown()
    let l = newLabel(f, "one two three four five six seven eight nine ten", 10, 10)
    l.wordWrap = true
    l.width = 80
    layoutIfNeeded(f)
    check l.width == 80
    check l.height > 2 * l.font.size

  test "label: without a window the size is kept":
    let l = newLabel(nil, "Hello", 0, 0)
    let s = l.preferredSize()
    check s.w == l.width and s.h == l.height

  test "label: clicking focuses focusControl":
    let f = newShown()
    let b = newButton(f, "B", 10, 100, 80, 28)
    let l = newLabel(f, "Name", 10, 10)
    l.focusControl = b
    check not l.canFocus
    layoutIfNeeded(f)
    f.click(12, 12)
    check f.activeControl == Control(b)

  test "disabled controls ignore input":
    let f = newShown()
    let b = newButton(f, "B", 10, 10, 80, 28)
    let c = newCheckBox(f, "C", false, 10, 50)
    let r = newRadioButton(f, "R", false, 10, 80)
    var n = 0
    b.onClick = proc(s: Control) = inc n
    b.enabled = false; c.enabled = false; r.enabled = false
    f.click(20, 20); f.click(14, 58); f.click(14, 88)
    check n == 0 and not c.checked and not r.checked
    check f.activeControl == nil
    b.enabled = true
    f.activeControl = b
    b.enabled = false                 # losing enabled drops focus
    check f.activeControl == nil
    b.click()
    check n == 0

  test "groupbox: client area is below the caption":
    let f = newShown()
    let g = newGroupBox(f, "Group", 10, 10, 200, 120)
    let inner = newPanel(g, "", 0, 0, 10, 10)
    inner.align = alClient
    layoutIfNeeded(f)
    check g.padding.top >= g.captionHeight
    check inner.top >= g.captionHeight
    check inner.left > 0 and inner.top == g.clientArea.y
    check inner.top + inner.height <= g.height - 1
    check g.clientArea.y >= g.captionHeight

  test "groupbox: padding is current right after caption/font changes":
    let f = newShown()
    let g = newGroupBox(f, "", 10, 10, 200, 120)
    let before = g.padding.top
    g.caption = "Now with a caption"
    check g.padding.top > before
    let p1 = g.padding.top
    g.font = font(size = 28)
    check g.padding.top > p1
    check g.padding.top >= g.captionHeight
    let inner = newPanel(g, "", 0, 0, 10, 10)
    inner.align = alClient
    layoutIfNeeded(f)
    check inner.top == g.clientArea.y
    g.caption = "x"
    g.font = font(size = 10)
    layoutIfNeeded(f)                 # relayout was requested by the setters
    check inner.top == g.clientArea.y

  test "panel: children inherit the panel fill, themes switch":
    let f = newShown()
    let p = newPanel(f, "", 10, 10, 200, 100)
    let g = newGroupBox(p, "g", 10, 10, 150, 60)
    let l = newLabel(g, "t", 5, 30)
    check p.color == f.theme.surface
    check l.color == f.theme.surface and g.color == f.theme.surface
    check f.color == f.theme.window
    f.theme = themeDark()
    check l.color == themeDark().surface
    p.color = rgb(1, 2, 3)
    check l.color == rgb(1, 2, 3)
    f.theme = nil

  test "radiobutton: tab stops need no paint (parent=, visibility)":
    let f = newShown()
    let a = newRadioButton(nil, "a")
    let b = newRadioButton(nil, "b")
    b.checked = true
    check tabStops(f).len == 0
    a.parent = f
    b.parent = f
    check tabStops(f) == @[Control(b)]
    b.visible = false
    check tabStops(f) == @[Control(a)]
    b.visible = true
    a.checked = true
    check tabStops(f) == @[Control(a)]
    a.enabled = false
    check tabStops(f) == @[Control(b)] or tabStops(f).len == 0

  test "paintbox: onPaint gets the canvas in client coordinates":
    let f = newShown()
    let pb = newPaintBox(f, 30, 40, 120, 60)
    var calls = 0
    var clip: RectF
    var who: Control
    pb.onPaint = proc(s: Control, c: Canvas) =
      inc calls
      who = s
      clip = c.currentClip
    check f.paintIfDirty()
    check calls == 1 and who == Control(pb)
    check clip.x == 0 and clip.y == 0 and clip.w == 120 and clip.h == 60

  test "every control paints in both themes":
    let f = newShown(500, 400)
    discard newLabel(f, "label", 10, 10)
    let b = newButton(f, "b", 10, 40, 80, 28); b.isDefault = true
    let fl = newButton(f, "flat", 100, 40, 80, 28)
    fl.flat = true
    discard newCheckBox(f, "c", true, 10, 80)
    discard newRadioButton(f, "r", true, 10, 110)
    let g = newGroupBox(f, "g", 150, 80, 200, 100)
    discard newPanel(g, "p", 10, 30, 100, 40)
    discard newBevel(f, bsFrame, 10, 150, 100, 20)
    discard newImageControl(f, newImage(8, 8, rgb(200, 0, 0)), 10, 200, 50, 50)
    f.activeControl = b
    for t in [themeLight(), themeDark()]:
      f.theme = t
      check f.paintIfDirty()

suite "image control":
  test "draw rect: natural, centered, stretched, proportional":
    # natural
    check imageDrawRect(100, 80, 40, 20, false, false, false) == rectF(0, 0, 40, 20)
    check imageDrawRect(100, 80, 40, 20, false, false, true) == rectF(30, 30, 40, 20)
    # stretch alone fills
    check imageDrawRect(100, 80, 40, 20, true, false, false) == rectF(0, 0, 100, 80)
    # proportional + stretch: fit, centred
    check imageDrawRect(100, 80, 40, 20, true, true, false) == rectF(0, 15, 100, 50)
    check imageDrawRect(100, 80, 20, 40, true, true, false) == rectF(30, 0, 40, 80)
    # proportional alone only shrinks
    check imageDrawRect(100, 80, 40, 20, false, true, false) == rectF(30, 30, 40, 20)
    check imageDrawRect(100, 40, 200, 80, false, true, false) == rectF(0, 0, 100, 40)
    check imageDrawRect(100, 80, 0, 0, true, true, true).isEmpty

  test "control: drawRect follows the properties":
    let i = newImageControl(nil, newImage(40, 20), 0, 0, 100, 80)
    check i.drawRect == rectF(0, 0, 40, 20)
    i.stretch = true
    check i.drawRect == rectF(0, 0, 100, 80)
    i.proportional = true
    check i.drawRect == rectF(0, 15, 100, 50)
    i.picture = nil
    check i.drawRect.isEmpty
