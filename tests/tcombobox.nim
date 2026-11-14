## ComboBox tests, headless (offscreen SDL). Popups run on their top-level
## window fallback (see tpopup.nim); events are built by hand and fed through
## Application.dispatch.

import std/[unittest, strutils]
import nimvcl/core/[types, control, form, application, input, popup]
import nimvcl/platform/[events, window]
import nimvcl/graphics/[context, geometry]
import nimvcl/controls/[combobox, listbox, edit, label]

var
  changes = 0
  selects = 0
  drops = 0
  closes = 0

const Cities = ["Amsterdam", "Berlin", "Bern", "Cairo", "Dallas", "Dublin",
                "Edinburgh", "Florence", "Geneva", "Helsinki", "Istanbul"]

proc ev(win: PlatformWindow, kind: EventKind, x = 0'f32, y = 0'f32,
        k = Key(0), shift: ShiftState = {}): PlatformEvent =
  PlatformEvent(kind: kind, windowId: win.id, x: x, y: y, key: k, shift: shift,
                button: mbLeft, clicks: 1)

proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(ev(f.win, ekKeyDown, k = k, shift = shift))
  Application.dispatch(ev(f.win, ekKeyUp, k = k, shift = shift))
proc typeText(f: Form, s: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id, text: s))
proc click(win: PlatformWindow, x, y: float32) =
  Application.dispatch(ev(win, ekMouseDown, x, y))
  Application.dispatch(ev(win, ekMouseUp, x, y))
proc settle(f: Form) = discard f.paintIfDirty()

proc mk(f: Form, style: ComboStyle, y = 10'f32,
        items: openArray[string] = Cities): ComboBox =
  result = newComboBox(f, style, 10, y, 180)
  for s in items: result.add s
  result.onChange = proc(s: Control) = inc changes
  result.onSelect = proc(s: Control) = inc selects
  result.onDropDown = proc(s: Control) = inc drops
  result.onCloseUp = proc(s: Control) = inc closes

proc focus(c: ComboBox) =
  if c.style == csDropDown: c.edit.setFocus() else: c.setFocus()

proc newShown(h = 400'f32): Form =
  result = newForm(nil, 400, h)
  result.show()
  result.syncMetrics()

proc clickCombo(f: Form, c: ComboBox, arrow = true) =
  f.win.click(if arrow: c.left + c.width - 10 else: c.left + 20, c.top + c.height / 2)

proc clickRow(c: ComboBox, i: int) =
  let p = c.popupWindow
  let r = c.dropList.itemRect(i)
  p.ui.win.click(r.x + r.w / 2, r.y + r.h / 2)

suite "combobox":
  setup:
    Application.init()
    Application.forceScale = 0
    popupFocusGrace = 0
    focusIdProc = proc(): uint32 = 0
    changes = 0; selects = 0; drops = 0; closes = 0
  teardown:
    closeAllPopups(nil)
    for f in openForms(): f.freeWindow()

  test "list style: click opens, sized to dropDownCount rows and the combo width":
    let f = newShown()
    let c = f.mk(csDropDownList)
    c.dropDownCount = 4
    f.settle()
    f.clickCombo(c, arrow = false)
    check c.droppedDown and drops == 1
    let p = c.popupWindow
    let ih = c.dropList.itemHeight
    check p.bounds.w == c.width and abs(p.bounds.h - (4 * ih + 2)) < 0.5
    check p.bounds.y == c.top + c.height and p.bounds.x == c.left
    check c.dropList.vScrollBar.visible
    # fewer items than rows: the list shrinks
    c.closeUp()
    check not c.droppedDown and closes == 1
    c.items = ["a", "b"]
    c.dropDown()
    check abs(c.popupWindow.bounds.h - (2 * ih + 2)) < 0.5
    c.closeUp()
    # dropDownWidth wins
    c.dropDownWidth = 260
    c.dropDown()
    check c.popupWindow.bounds.w == 260

  test "empty combo does not open":
    let f = newShown()
    let c = f.mk(csDropDownList, items = newSeq[string]())
    f.clickCombo(c)
    check not c.droppedDown and c.popupWindow == nil

  test "click on an item selects, closes, fires onChange then onSelect once":
    let f = newShown()
    let c = f.mk(csDropDownList)
    var order: seq[string]
    c.onChange = proc(s: Control) = order.add "change"
    c.onSelect = proc(s: Control) = order.add "select"
    f.clickCombo(c, arrow = false)
    c.clickRow(3)
    check not c.droppedDown and c.itemIndex == 3 and c.text == "Cairo"
    check order == @["change", "select"]
    # picking the already selected item: onSelect only
    f.clickCombo(c, arrow = false)
    c.clickRow(3)
    check order == @["change", "select", "select"]
    check closes == 2

  test "Esc and click outside close without change; the press is swallowed":
    let f = newShown()
    let c = f.mk(csDropDownList)
    let other = newEdit(f, "", 10, 100, 100)
    c.itemIndex = 1
    changes = 0
    f.clickCombo(c, arrow = false)
    f.tap(keyDown); f.tap(keyDown)
    check c.droppedDown and c.dropList.itemIndex == 3
    f.tap(keyEscape)
    check not c.droppedDown and c.itemIndex == 1 and c.text == "Berlin"
    check changes == 0 and selects == 0 and closes == 1
    f.clickCombo(c, arrow = false)
    f.tap(keyDown)
    f.win.click(other.left + 5, other.top + 5)      # outside the popup
    check not c.droppedDown and c.itemIndex == 1
    check f.activeControl != Control(other)         # swallowed: no focus change
    check changes == 0 and selects == 0

  test "Enter picks the highlight; Up/Down while open do not change the text":
    let f = newShown()
    let c = f.mk(csDropDownList)
    c.focus()
    f.tap(keyDown, {ssAlt})
    check c.droppedDown
    f.tap(keyDown); f.tap(keyDown)
    check c.text == "" and c.dropList.itemIndex == 1 and changes == 0
    f.tap(keyEnter)
    check not c.droppedDown and c.itemIndex == 1 and c.text == "Berlin"
    check changes == 1 and selects == 1
    c.dropDown()
    f.tap(keyEnd)
    f.tap(keyEnter)
    check c.itemIndex == 10
    c.dropDown()
    f.tap(keyEscape)
    check c.itemIndex == 10

  test "closed: Up/Down/Home/End select without a popup; Alt+Down and F4 open":
    let f = newShown()
    let c = f.mk(csDropDownList)
    c.focus()
    f.tap(keyDown)
    check c.itemIndex == 0 and not c.droppedDown and changes == 1 and selects == 1
    f.tap(keyDown); f.tap(keyDown)
    check c.itemIndex == 2 and changes == 3 and selects == 3
    f.tap(keyUp)
    check c.itemIndex == 1
    f.tap(keyEnd)
    check c.itemIndex == 10
    f.tap(keyDown)                                   # at the end: nothing
    check c.itemIndex == 10 and changes == 5
    f.tap(keyHome)
    check c.itemIndex == 0
    f.tap(keyF4)
    check c.droppedDown
    f.tap(keyF4)                                     # F4 again: picks and closes
    check not c.droppedDown
    f.tap(keyDown, {ssAlt})
    check c.droppedDown
    f.tap(keyEscape)
    check not c.droppedDown
    # code changes fire onChange but not onSelect
    let s0 = selects
    c.itemIndex = 4
    check c.text == "Dallas" and selects == s0
    c.itemIndex = -1
    check c.text == ""

  test "list style: type-ahead selects by prefix":
    let f = newShown()
    let c = f.mk(csDropDownList)
    c.focus()
    f.tap('d'.key)
    check c.text == "Dallas"
    f.tap('u'.key)
    check c.text == "Dublin"
    check selects == 2

  test "dropdown style: arrow toggles, the text area edits; Enter/Esc stay unused":
    let f = newShown()
    let c = f.mk(csDropDown)
    f.clickCombo(c, arrow = false)
    check not c.droppedDown and f.activeControl == Control(c.edit)
    f.clickCombo(c)
    check c.droppedDown
    f.clickCombo(c)                                  # swallowed press closes it
    check not c.droppedDown
    f.clickCombo(c)
    c.clickRow(2)
    check c.text == "Bern" and c.itemIndex == 2 and c.edit.selText == "Bern"
    check changes == 1 and selects == 1
    c.closeUp()
    # Enter and Esc are not consumed while closed
    var k = keyEnter
    c.edit.doKeyDown(k, {})
    check k == keyEnter
    k = keyEscape
    c.edit.doKeyDown(k, {})
    check k == keyEscape

  test "dropdown style: Up/Down select, typing edits, text matches items":
    let f = newShown()
    let c = f.mk(csDropDown)
    c.autoComplete = false
    c.focus()
    f.tap(keyDown)
    check c.text == "Amsterdam" and c.itemIndex == 0 and selects == 1 and changes == 1
    f.tap(keyDown)
    check c.text == "Berlin" and c.edit.selText == "Berlin"   # a pick selects all
    f.tap(keyEnd)
    f.typeText("x")
    check c.text == "Berlinx" and c.itemIndex == -1 and changes == 3 and selects == 2
    f.tap(keyBackspace)
    check c.text == "Berlin" and c.itemIndex == 1 and changes == 4
    c.text = "Cairo"
    check c.itemIndex == 3 and changes == 5
    c.text = "Mars"
    check c.itemIndex == -1 and c.text == "Mars"

  test "dropdown style: autocomplete completes, selects the rest, Backspace does not re-complete":
    let f = newShown()
    let c = f.mk(csDropDown)
    c.focus()
    f.typeText("be")
    check c.text == "Berlin" and c.edit.selText == "rlin" and c.edit.selStart == 2
    check changes == 1 and c.itemIndex == 1
    f.typeText("rn")                                 # continues typing over the selection
    check c.text == "Bern" and c.itemIndex == 2 and c.edit.selLength == 0
    f.tap(keyBackspace)
    check c.text == "Ber" and c.edit.selLength == 0 and c.itemIndex == -1
    f.tap(keyBackspace)
    check c.text == "Be"
    f.typeText("r")                                  # completes again
    check c.text == "Berlin"
    # no match: just the typed text
    c.text = ""
    f.typeText("zz")
    check c.text == "zz" and c.edit.selLength == 0
    # a complete match: nothing to complete
    c.text = ""
    f.typeText("Dallas")
    check c.text == "Dallas" and c.itemIndex == 4 and c.edit.selLength == 0

  test "sorted keeps items ordered":
    let f = newShown()
    let c = f.mk(csDropDownList, items = newSeq[string]())
    c.sorted = true
    for s in ["pear", "Apple", "fig", "banana"]: c.add s
    check @[c[0], c[1], c[2], c[3]] == @["Apple", "banana", "fig", "pear"]
    c.itemIndex = 1
    c.add "cherry"
    check c.text == "banana" and c.count == 5 and c.items.len == 5
    c.delete(0)
    check c.count == 4 and c[0] == "banana"
    c.clear()
    check c.count == 0

  test "popup flips above near the bottom of the display":
    let f = newShown(h = 760)
    let c = f.mk(csDropDownList, y = 700)
    c.dropDownCount = 6
    f.settle()
    c.dropDown()
    check c.droppedDown
    let p = c.popupWindow
    let anchor = c.clientToForm(c.clientRect)
    let below = placePopup(anchor, sizeF(p.bounds.w, p.bounds.h),
                           rectF(0, 0, 1024, 768), plBelow)
    check below.y == anchor.y - p.bounds.h or below.y == p.bounds.y
    check p.bounds.bottom <= 768 or p.bounds.y < anchor.y
    c.closeUp()
    # and stays below with room
    let c2 = f.mk(csDropDownList, y = 20)
    c2.dropDown()
    check c2.popupWindow.bounds.y == c2.top + c2.height

  test "wheel scrolls the open list; hover tracks the row; disabled does not open":
    let f = newShown()
    let c = f.mk(csDropDownList)
    c.dropDownCount = 4
    f.clickCombo(c, arrow = false)
    let p = c.popupWindow
    Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: p.ui.win.id,
                                       x: 40, y: 30, dy: -1))
    check c.dropList.scrollPos.y > 0
    p.ui.win.click(1, 1)                  # presses the first visible row's edge
    c.closeUp()
    c.enabled = false
    f.clickCombo(c, arrow = false)
    c.dropDown()
    check not c.droppedDown

  test "selected item is scrolled into view when opening":
    let f = newShown()
    let c = f.mk(csDropDownList)
    c.dropDownCount = 3
    c.itemIndex = 9
    c.dropDown()
    let r = c.dropList.itemRect(9)
    check r.y >= 0 and r.bottom <= c.popupWindow.bounds.h + 0.5
    c.closeUp()

  test "paints in all states":
    let f = newShown()
    let a = f.mk(csDropDownList)
    let b = f.mk(csDropDown, y = 60)
    a.itemIndex = 2
    b.text = "hello"
    b.enabled = false
    f.settle()
    b.enabled = true
    b.focus()
    f.settle()
    a.dropDown()
    f.settle()
    check f.screenshotWithPopups("build/tcombo_shot.bmp")

  test "focus requests reach the edit of a dropdown combo (label mnemonic, setFocus, activeControl)":
    let f = newShown()
    let c = f.mk(csDropDown)
    let l = newLabel(f, "&City", 10, 50)
    l.focusControl = c
    let d = f.mk(csDropDownList, y = 90)
    check not c.canFocus
    setFocus(c)
    check c.edit.focused and f.activeControl == Control(c.edit)
    f.activeControl = d
    check d.focused
    f.activeControl = c
    check c.edit.focused
    f.activeControl = nil
    f.tap(key('c'), {ssAlt})
    check c.edit.focused
    check Control(d).focusTarget == Control(d)       # list style takes the focus itself

  test "the drop-down list draws no focus ring of its own":
    let f = newShown()
    let c = f.mk(csDropDownList)
    check not c.dropList.showFocusRect
    check newListBox().showFocusRect                  # a stand-alone list keeps it

