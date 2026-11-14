## Cross-cutting phase 5 round 2: umbrella import, key-handler chain,
## layout-owner hook, visibility notification, mnemonics, modal ownership.
## Headless (offscreen SDL).

import std/[unittest]
import nimvcl                       # the umbrella must be enough

proc ev(f: Form, kind: EventKind, k = Key(0), shift: ShiftState = {}): PlatformEvent =
  PlatformEvent(kind: kind, windowId: f.win.id, key: k, shift: shift,
                button: mbLeft, clicks: 1)
proc down(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(f.ev(ekKeyDown, k, shift))
proc up(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(f.ev(ekKeyUp, k, shift))
proc tap(f: Form, k: Key, shift: ShiftState = {}) = f.down(k, shift); f.up(k, shift)
proc tap(f: Form, c: char, shift: ShiftState = {}) = f.tap(key(c), shift)

type
  Counter = ref object of Control
    n: int
    showing: seq[bool]

method visibilityChanged(c: Counter) =
  inc c.n
  c.showing.add c.isShowing

proc newCounter(parent: Container): Counter =
  result = Counter()
  result.initControl()
  if parent != nil: parent.insertControl result

proc newShown(w = 500'f32, h = 300'f32): Form =
  result = newForm(nil, w, h)
  result.show()

suite "phase 5 round 2":
  setup:
    Application.init()
  teardown:
    Application.shutdown()

  # ------------------------------------------------------------ key chain
  test "key chain: Ctrl+Tab works from inside a page, in any registration order":
    for menuFirst in [true, false]:
      let f = newShown()
      var mm: MainMenu
      if menuFirst: mm = newMainMenu(f)
      let pc = newPageControl(f, 10, 40, 400, 200)
      let s1 = newTabSheet(pc, "One")
      let s2 = newTabSheet(pc, "Two")
      let e1 = newEdit(s1, "", 10, 10, 100, 24)
      discard s2
      if not menuFirst:
        mm = newMainMenu(f)
        mm.addItem("&File").addItem("E&xit")
      else:
        mm.addItem("&File").addItem("E&xit")
      f.activeControl = e1
      check pc.tabIndex == 0
      f.tap(keyTab, {ssCtrl})
      check pc.tabIndex == 1
      f.tap(keyTab, {ssCtrl, ssShift})
      check pc.tabIndex == 0
      f.tap(keyPageDown, {ssCtrl})
      check pc.tabIndex == 1
      f.close()

  test "key chain: shared by Form and Host (UiRoot), user hook runs first":
    let f = newShown()
    var order: seq[string]
    f.ui.onUnhandledKey = proc(k: var Key, s: ShiftState) = order.add "user"
    f.addKeyHandler("a", proc(k: var Key, s: ShiftState) = order.add "a")
    f.ui.addKeyHandler("b", proc(k: var Key, s: ShiftState) =
      order.add "b"
      k = Key(0))
    f.ui.addKeyHandler("c", proc(k: var Key, s: ShiftState) = order.add "c")
    check f.ui.hasKeyHandler("a")
    f.tap(keyF5)
    check order == @["user", "a", "b"]
    f.removeKeyHandler("b")
    order.setLen 0
    f.tap(keyF5)
    check order == @["user", "a", "c"]
    f.close()

  # ------------------------------------------------------- layout owner
  test "arrangeChildren: flow/grid children keep their align":
    let f = newShown()
    let fp = newFlowPanel(f, 0, 0, 200, 100)
    let b1 = newButton(fp, "a", 0, 0, 80, 24)
    let b2 = newButton(fp, "b", 0, 0, 80, 24)
    let b3 = newButton(fp, "c", 0, 0, 80, 24)
    b3.align = alTop                     # ignored by the flow, but kept
    layoutIfNeeded(f)
    check b1.align == alNone and b2.align == alNone and b3.align == alTop
    check b1.left == 0 and b2.left == 80 and b3.top == 24   # wrapped to row 2
    let g = newGridPanel(f, 0, 120, 200, 100)
    g.columns = @[gsPercent(50), gsPercent(50)]
    let c1 = newButton(g, "a")
    check c1.align == alNone
    layoutIfNeeded(f)
    check c1.width == 100
    f.close()

  # -------------------------------------------------- visibility changes
  test "visibilityChanged: ancestor, tree edits, form show/hide":
    let f = newForm(nil, 300, 200)
    let p = newPanel(f, "", 0, 0, 100, 100)
    let c = newCounter(p)
    check c.n == 0 or c.n == 1           # inserted (form not shown yet)
    check not c.isShowing
    c.n = 0; c.showing.setLen 0
    f.show()
    check c.n == 1 and c.showing == @[true]
    p.visible = false
    check c.n == 2 and c.showing[^1] == false
    p.visible = true
    check c.n == 3 and c.showing[^1] == true
    c.visible = false
    check c.n == 4
    p.visible = false                    # c is hidden itself: no change for it
    p.visible = true
    check c.n == 4
    c.visible = true
    let n = c.n
    f.hide()
    check c.n == n + 1 and not c.isShowing
    f.show()
    check c.isShowing
    p.removeControl c
    check not c.isShowing
    f.close()

  test "progressbar marquee follows visibility without polling":
    let f = newShown()
    let p = newPanel(f, "", 0, 0, 200, 50)
    let pb = newProgressBar(p, 10, 10, 100, 18)
    pb.style = pbsMarquee
    check pb.runsMarquee                 # showing: started at once, no paint needed
    p.visible = false
    check not pb.runsMarquee             # stopped by the notification
    p.visible = true
    check pb.runsMarquee
    f.hide()
    check not pb.runsMarquee
    f.show()
    check pb.runsMarquee
    pb.style = pbsNormal
    check not pb.runsMarquee
    f.close()

  # ----------------------------------------------------------- mnemonics
  test "parseMnemonic and displayText":
    check parseMnemonic("&Open").text == "Open"
    check parseMnemonic("&Open").index == 0
    check parseMnemonic("&Open").ch == 'o'
    check parseMnemonic("Sa&ve && go").text == "Save & go"
    check parseMnemonic("Sa&ve && go").index == 2
    check parseMnemonic("A && B").index == -1
    check displayText("&&x") == "&x"
    check mnemonicOf("Fi&nd") == 'n'
    check mnemonicOf("none") == '\0'

  test "alt state is tracked and cleared on focus loss":
    let f = newShown()
    let b = newButton(f, "&Go", 10, 10, 80, 28)
    check not b.altHeld
    f.down(keyLAlt, {ssAlt})
    check b.altHeld
    f.up(keyLAlt)
    check not b.altHeld
    f.down(keyLAlt, {ssAlt})
    f.windowActivated(false)
    check not b.altHeld
    f.close()

  test "mnemonics: button, checkbox, radio, label, tab sheet":
    let f = newShown()
    var clicks = 0
    let b = newButton(f, "&Run", 10, 10, 80, 28)
    b.onClick = proc(s: Control) = inc clicks
    let cb = newCheckBox(f, "&Check", false, 10, 50, 100, 20)
    let r1 = newRadioButton(f, "R&adio one", true, 10, 80, 120, 20)
    let r2 = newRadioButton(f, "Ra&dio two", false, 10, 100, 120, 20)
    let ed = newEdit(f, "", 200, 10, 100, 24)
    let lbl = newLabel(f, "&Name", 140, 14)
    lbl.focusControl = ed
    let pc = newPageControl(f, 10, 140, 300, 120)
    let s1 = newTabSheet(pc, "&First")
    let s2 = newTabSheet(pc, "&Second")
    discard s1
    f.tap('r', {ssAlt})
    check clicks == 1
    f.tap('c', {ssAlt})
    check cb.checked and cb.focused
    f.tap('c', {ssAlt})
    check not cb.checked
    f.tap('d', {ssAlt})
    check r2.checked and not r1.checked and r2.focused
    f.tap('a', {ssAlt})
    check r1.checked
    f.tap('n', {ssAlt})
    check ed.focused
    f.tap('s', {ssAlt})
    check pc.activePage == s2
    f.tap('f', {ssAlt})
    check pc.tabIndex == 0
    # without Alt nothing happens
    f.tap('r')
    check clicks == 1
    # disabled / hidden controls are skipped
    b.enabled = false
    f.tap('r', {ssAlt})
    check clicks == 1
    b.enabled = true; b.visible = false
    f.tap('r', {ssAlt})
    check clicks == 1
    b.visible = true
    s2.enabled = false
    f.tap('s', {ssAlt})
    check pc.tabIndex == 0
    f.close()

  test "mnemonics: the menu bar has priority":
    let f = newShown()
    var clicks = 0
    let b = newButton(f, "&File", 10, 50, 80, 28)
    b.onClick = proc(s: Control) = inc clicks
    let mm = newMainMenu(f)
    mm.addItem("&File").addItem("E&xit")
    f.tap('f', {ssAlt})
    check clicks == 0
    check mm.openIndex == 0
    mm.closeMenus()
    f.close()

  test "mnemonic captions draw (underline while Alt is held)":
    let f = newShown()
    discard newButton(f, "&Run && go", 10, 10, 120, 28)
    discard newGroupBox(f, "&Group", 10, 50, 150, 80)
    check f.paintIfDirty()
    f.down(keyLAlt, {ssAlt})
    check f.ui.needsPaint
    check f.paintIfDirty()
    f.close()

  # --------------------------------------------------------------- modal
  test "showModal: owned by the active form; input of others is gated":
    let a = newShown()
    let other = newShown()
    other.windowActivated(true)
    check activeForm() == other
    let d = newForm(nil, 200, 100)
    var checked = false
    Application.queue(proc() =
      checked = true
      check d.modalOwner == other
      check not a.acceptsInput and not other.acceptsInput
      check d.acceptsInput
      d.modalResult = mrOk)
    check d.showModal() == mrOk
    check checked
    check a.acceptsInput and other.acceptsInput
    check d.modalOwner == nil
    # no active form: the main form owns it
    other.windowActivated(false)
    Application.mainForm = a
    let d2 = newForm(nil, 200, 100)
    Application.queue(proc() =
      check d2.modalOwner == a
      d2.modalResult = mrCancel)
    discard d2.showModal()
    a.close(); other.close()

  test "runModalLoop gates every form until the condition holds":
    let a = newShown()
    var done = false
    var gated = false
    Application.queue(proc() =
      gated = not a.acceptsInput
      done = true)
    runModalLoop(proc(): bool = done)
    check gated and done
    check a.acceptsInput
    a.close()
