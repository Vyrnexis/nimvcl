## ObjectInspector (controls/inspector). Headless (offscreen SDL), events built by hand.

import std/[unittest, strutils]
import nimvcl
import nimvcl/controls/inspector
from nimvcl/dsl/nfmsyntax import validNfmName

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))
proc click(f: Form, p: PointF, clicks = 1) =
  f.feed(ekMouseDown, p.x, p.y, clicks = clicks, shift = (if clicks > 1: {ssDouble} else: {}))
  f.feed(ekMouseUp, p.x, p.y)
proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k, shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k, shift: shift))
proc typeText(f: Form, s: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id, text: s))
proc settle(f: Form) =
  discard f.paintIfDirty()
  f.layoutIfNeeded()

type Rig = ref object
  f: Form
  ins: ObjectInspector
  changes: seq[string]

proc rig(): Rig =
  new result
  result.f = newForm(nil, 420, 640)
  result.f.show()
  result.ins = newObjectInspector(result.f, 10, 10, 340, 600)
  let r = result
  result.ins.onPropertyChanged = proc(s: Control, t: Obj, prop: string) =
    r.changes.add objectName(t) & "." & prop
  result.f.settle

proc valuePoint(r: Rig, name: string): PointF =
  r.ins.selectProp(name)                      # scrolls the row into view
  let i = r.ins.indexOfProp(name)
  doAssert i >= 0, "no row " & name
  let vr = r.ins.valueRect(i)
  r.ins.clientToForm(pointF(vr.x + 24, vr.y + vr.h / 2))

proc clickValue(r: Rig, name: string, clicks = 1) =
  r.f.click(r.valuePoint(name), clicks)

proc namePoint(r: Rig, name: string): PointF =
  let i = r.ins.indexOfProp(name)
  let nr = r.ins.nameRect(i)
  r.ins.clientToForm(pointF(nr.x + 60, nr.y + nr.h / 2))

proc mkButton(r: Rig, name = "okButton"): Button =
  result = newButton(r.f, "OK", 20, 400)
  result.name = name

suite "ObjectInspector":
  test "shows the properties of the selected object, grouped by category":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    check r.ins.rowCount > 20
    check r.ins.rowName(0) == "cat:Layout"
    check r.ins.indexOfProp("caption") > 0
    check r.ins.indexOfProp("onClick") < 0               # events live on their own tab
    check r.ins.valueTextOf("caption") == "OK"
    check r.ins.valueTextOf("align") == "alNone"
    check r.ins.valueTextOf("anchors") == "[akLeft, akTop]"
    check r.ins.valueTextOf("left") == "20"
    check r.ins.valueTextOf("name") == "okButton"
    r.ins.tab = itEvents
    check r.ins.indexOfProp("onClick") > 0
    check r.ins.indexOfProp("caption") < 0
    check r.ins.rowName(0) == "cat:Events"
    r.ins.tab = itProperties
    r.ins.inspect(newSeq[Obj]())
    check r.ins.rowCount == 0

  test "non-default values are bold":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    check r.ins.isBold("caption")
    check r.ins.isBold("left")
    check not r.ins.isBold("align")
    check not r.ins.isBold("visible")
    b.align = alTop
    check r.ins.isBold("align")

  test "grouping can be switched to a flat alphabetical list":
    let r = rig()
    r.ins.inspect(r.mkButton())
    r.ins.sortedFlat = true
    check r.ins.rowName(0) == "action"
    var prev = ""
    for i in 0 ..< r.ins.rowCount:
      let n = r.ins.rowName(i)
      check not n.startsWith("cat:")
      check n.toLowerAscii >= prev
      prev = n.toLowerAscii
    r.ins.sortedFlat = false
    check r.ins.rowName(0) == "cat:Layout"
    # a click on the toggle in the header
    let tg = r.ins.toggleRect
    r.f.click(r.ins.clientToForm(pointF(tg.x + 5, tg.y + 5)))
    check r.ins.sortedFlat

  test "categories collapse and expand":
    let r = rig()
    r.ins.inspect(r.mkButton())
    let n = r.ins.rowCount
    r.ins.setExpanded("cat:Layout", false)
    check r.ins.rowCount < n
    check r.ins.indexOfProp("align") < 0
    check not r.ins.isExpanded("cat:Layout")
    r.f.click(r.ins.clientToForm(pointF(40, r.ins.rowRect(0).y + 10)))   # the header row
    check r.ins.isExpanded("cat:Layout")
    check r.ins.rowCount == n

  test "tabs are switched by clicking them":
    let r = rig()
    r.ins.inspect(r.mkButton())
    let tr = r.ins.tabRect(itEvents)
    r.f.click(r.ins.clientToForm(pointF(tr.x + 10, tr.y + 10)))
    check r.ins.tab == itEvents
    let tp = r.ins.tabRect(itProperties)
    r.f.click(r.ins.clientToForm(pointF(tp.x + 10, tp.y + 10)))
    check r.ins.tab == itProperties

  test "edit a string: click, type, Enter":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.clickValue("caption")
    check r.ins.editing
    check r.ins.editText.visible
    check r.ins.editText.text == "OK"
    r.f.typeText("Hello")                    # the text was selected: it is replaced
    r.f.tap(keyEnter)
    check not r.ins.editing
    check b.caption == "Hello"
    check r.changes == @["okButton.caption"]
    check r.ins.valueTextOf("caption") == "Hello"

  test "Esc cancels an edit":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.clickValue("caption")
    r.f.typeText("zzz")
    r.f.tap(keyEscape)
    check not r.ins.editing
    check b.caption == "OK"
    check r.changes.len == 0

  test "edit a number; an invalid one is rejected":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.clickValue("tabOrder")
    r.f.typeText("abc")
    r.f.tap(keyEnter)
    check r.ins.editing                         # stays open
    check "not a whole number" in r.ins.lastError
    check b.tabOrder == 0
    check r.changes.len == 0
    r.f.tap(keyEscape)
    check not r.ins.editing
    b.tabOrder = 0
    r.clickValue("tabOrder")
    r.f.typeText("7")
    r.f.tap(keyEnter)
    check b.tabOrder == 7
    check r.ins.lastError == ""
    # floats
    r.clickValue("left")
    r.f.typeText("12.5")
    r.f.tap(keyEnter)
    check b.left == 12.5
    r.clickValue("top")
    r.f.typeText("1,5")
    r.f.tap(keyEnter)
    check "not a number" in r.ins.lastError
    check b.top == 400

  test "edit an enum through its drop-down":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.clickValue("align")
    check r.ins.editing
    check r.ins.editCombo.visible
    check r.ins.editCombo.droppedDown
    check r.ins.editCombo.items.len == 7
    r.f.tap(keyDown)                            # alNone -> alTop
    r.f.tap(keyDown)                            # -> alBottom
    r.f.tap(keyEnter)
    check not r.ins.editing
    check b.align == alBottom
    check r.changes == @["okButton.align"]

  test "edit a bool; double click cycles":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.ins.beginEdit("isDefault", openList = false)
    check r.ins.editing
    r.ins.editCombo.itemIndex = 1
    check r.ins.commitEdit()
    check b.isDefault
    r.ins.dispatchDouble(r.ins.indexOfProp("isDefault"))
    check not b.isDefault
    r.ins.dispatchDouble(r.ins.indexOfProp("modalResult"))
    check b.modalResult == mrOk

  test "set elements toggle with one click":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.ins.setExpanded("anchors", true)
    check r.ins.indexOfProp("anchors.akRight") > 0
    check r.ins.valueTextOf("anchors.akRight") == "false"
    r.clickValue("anchors.akRight")
    check b.anchors == {akLeft, akTop, akRight}
    check r.ins.valueTextOf("anchors.akRight") == "true"
    check r.changes == @["okButton.anchors.akRight"]
    r.clickValue("anchors.akLeft")
    check b.anchors == {akTop, akRight}
    check r.ins.valueTextOf("anchors") == "[akTop, akRight]"

  test "composite properties expand: font and margins":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.ins.setExpanded("font", true)
    check r.ins.indexOfProp("font.size") > 0
    check r.ins.indexOfProp("font.family") > 0
    check r.ins.indexOfProp("font.style") > 0
    r.clickValue("font.size")
    r.f.typeText("20")
    r.f.tap(keyEnter)
    check b.font.size == 20
    check not b.parentFont
    check r.changes == @["okButton.font.size"]
    check r.ins.isBold("font.size")
    r.ins.setExpanded("font.style", true)
    r.clickValue("font.style.fsBold")
    check b.font.style == {fsBold}
    r.ins.setExpanded("margins", true)
    r.clickValue("margins.left")
    r.f.typeText("6")
    r.f.tap(keyEnter)
    check b.margins.left == 6
    check r.ins.valueTextOf("margins") == "(6, 0, 0, 0)"

  test "colours: text, palette names, invalid input":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.ins.beginEdit("color", openList = false)
    check r.ins.editCombo.visible
    r.ins.editCombo.text = "#ff0000"
    check r.ins.commitEdit()
    check b.color == hex"#ff0000"
    r.ins.beginEdit("color", openList = false)
    r.ins.editCombo.text = "navy"
    check r.ins.commitEdit()
    check b.color == rgb(30, 58, 138)
    r.ins.beginEdit("color", openList = false)
    r.ins.editCombo.text = "nope"
    check not r.ins.commitEdit()
    check "not a colour" in r.ins.lastError
    check b.color == rgb(30, 58, 138)
    r.ins.cancelEdit()

  test "references to other objects":
    let r = rig()
    let e = newEdit(r.f, "", 20, 440)
    e.name = "userEdit"
    let l = newLabel(r.f, "User", 20, 470)
    l.name = "userLabel"
    r.ins.inspect(l)
    check r.ins.valueTextOf("focusControl") == "(none)"
    r.ins.beginEdit("focusControl", openList = false)
    var idx = -1
    for i in 0 ..< r.ins.editCombo.items.len:
      if r.ins.editCombo.items[i] == "userEdit": idx = i
    check idx > 0
    r.ins.editCombo.itemIndex = idx
    check r.ins.commitEdit()
    check l.focusControl == Control(e)
    check r.ins.valueTextOf("focusControl") == "userEdit"

  test "string lists call the application's editor":
    let r = rig()
    let cb = newComboBox(r.f, csDropDown, 20, 440)
    cb.name = "roles"
    var asked: seq[string]
    r.ins.onEditExtra = proc(s: Control, t: Obj, prop: string) = asked.add objectName(t) & "." & prop
    r.ins.inspect(cb)
    check r.ins.valueTextOf("items") == "(empty)"
    r.ins.selectProp("items")
    r.f.settle
    let vr = r.ins.valueRect(r.ins.indexOfProp("items"))
    r.f.click(r.ins.clientToForm(pointF(vr.right - 12, vr.y + vr.h / 2)))
    check asked == @["roles.items"]
    check not r.ins.editing
    cb.items = ["a", "b"]
    r.ins.refresh()
    check r.ins.valueTextOf("items") == "(2 lines)"

  test "several objects: common properties, one edit applies to all":
    let r = rig()
    let a = r.mkButton("a")
    let b = r.mkButton("b")
    let l = newLabel(r.f, "L", 20, 440)
    l.name = "l"
    b.caption = "Other"
    r.ins.inspect([Obj(a), Obj(b)])
    check r.ins.indexOfProp("isDefault") > 0
    check r.ins.valueTextOf("caption") == ""             # they differ: blank
    check r.ins.valueTextOf("left") == "20"              # they agree
    r.clickValue("caption")
    r.f.typeText("Same")
    r.f.tap(keyEnter)
    check a.caption == "Same" and b.caption == "Same"
    check r.changes == @["a.caption", "b.caption"]
    check r.ins.valueTextOf("caption") == "Same"
    r.ins.inspect([Obj(a), Obj(l)])
    check r.ins.indexOfProp("caption") > 0
    check r.ins.indexOfProp("isDefault") < 0             # a Label has none
    check r.ins.indexOfProp("wordWrap") < 0

  test "events: handler names, drop-down list, double click creates":
    let r = rig()
    let b = r.mkButton()
    r.ins.knownHandlers = @["okClick", "cancelClick"]
    var created: seq[string]
    r.ins.onCreateHandler = proc(s: Control, t: Obj, event: string): string =
      created.add objectName(t) & "." & event
      result = "go" & event[2 .. ^1]
    r.ins.inspect(b)
    r.ins.tab = itEvents
    check r.ins.valueTextOf("onClick") == ""
    r.ins.beginEdit("onClick", openList = false)
    check r.ins.editCombo.items.len == 2
    r.ins.editCombo.text = "okClick"
    check r.ins.commitEdit()
    check handlerNameOf(b, "onClick") == "okClick"
    check r.ins.valueTextOf("onClick") == "okClick"
    check r.ins.isBold("onClick")
    check r.changes == @["okButton.onClick"]
    # an empty row: double click asks for a new handler
    r.ins.dispatchDouble(r.ins.indexOfProp("onDblClick"))
    check created == @["okButton.onDblClick"]
    check handlerNameOf(b, "onDblClick") == "goDblClick"
    # a row that already has a handler is left alone
    r.ins.dispatchDouble(r.ins.indexOfProp("onClick"))
    check created.len == 1
    # invalid handler names are refused
    r.ins.beginEdit("onEnter", openList = false)
    r.ins.editCombo.text = "not a name"
    check not r.ins.commitEdit()
    r.ins.cancelEdit()
    # without a callback a name is made up
    r.ins.onCreateHandler = nil
    r.ins.dispatchDouble(r.ins.indexOfProp("onExit"))
    check handlerNameOf(b, "onExit") == "okButtonExit"
    # a real double click on the value cell does the same
    r.clickValue("onKeyDown", clicks = 2)
    check handlerNameOf(b, "onKeyDown") == "okButtonKeyDown"

  test "keyboard: arrows, Enter, Esc, Tab":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.ins.setFocus()
    let first = r.ins.selectedRow
    check r.ins.rowName(first) == "align"
    r.f.tap(keyDown)
    check r.ins.selectedRow == first + 1
    r.f.tap(keyUp)
    check r.ins.selectedRow == first
    r.f.tap(keyEnd)
    check r.ins.selectedRow == r.ins.rowCount - 1
    r.f.tap(keyHome)
    check r.ins.selectedRow == 0
    check r.ins.selectProp("caption")
    r.f.tap(keyEnter)
    check r.ins.editing
    r.f.typeText("Tabbed")
    r.f.tap(keyTab)                              # applies and goes on to the next row
    check b.caption == "Tabbed"
    check r.ins.editing
    check r.ins.editRow == r.ins.indexOfProp("color")
    r.f.tap(keyTab, {ssShift})
    check r.ins.editRow == r.ins.indexOfProp("caption")
    r.f.tap(keyEscape)
    check not r.ins.editing
    # Left/Right collapse and expand a category or composite
    r.ins.selectRow 0
    r.f.tap(keyLeft)
    check not r.ins.isExpanded("cat:Layout")
    r.f.tap(keyRight)
    check r.ins.isExpanded("cat:Layout")
    check r.ins.selectProp("anchors")
    r.f.tap(keyRight)
    check r.ins.isExpanded("anchors")
    r.f.tap(keyDown)
    r.f.tap(keySpace)                            # toggles the check box
    check b.anchors == {akTop}

  test "selection changes and re-inspection keep things consistent":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    var sels = 0
    r.ins.onSelectionChanged = proc(s: Control) = inc sels
    r.ins.selectProp("caption")
    check r.ins.selectedProp == "caption"
    check sels == 1
    r.clickValue("caption")
    check r.ins.editing
    r.f.click(r.namePoint("top"))                # clicking elsewhere applies/cancels
    check not r.ins.editing
    check r.ins.selectedProp == "top"
    r.ins.inspect(b)                             # same target again: the selection stays
    check r.ins.selectedProp == "top"

  test "works for non-visual components and menu items":
    let r = rig()
    let t = newTimer(r.f, 500)
    t.name = "tick"
    r.ins.inspect(t)
    check r.ins.valueTextOf("interval") == "500"
    r.clickValue("interval")
    r.f.typeText("250")
    r.f.tap(keyEnter)
    check t.interval == 250
    let mi = newMenuItem("Open")
    mi.name = "openItem"
    r.ins.inspect(mi)
    check r.ins.valueTextOf("caption") == "Open"
    r.ins.setValue("caption", pvString("Open..."))
    check mi.caption == "Open..."
    check r.ins.valueTextOf("shortcut") == ""
    r.ins.setValue("shortcut", pvString("Ctrl+O"))
    check mi.shortcut == shortcut("Ctrl+O")

  test "dragging the divider resizes the columns":
    let r = rig()
    r.ins.inspect(r.mkButton())
    let x0 = r.ins.splitX
    let y = r.ins.rowRect(2).y + 10
    r.f.feed(ekMouseDown, r.ins.clientToForm(pointF(x0, y)).x, r.ins.clientToForm(pointF(x0, y)).y)
    r.f.feed(ekMouseMove, r.ins.clientToForm(pointF(x0 + 40, y)).x, r.ins.clientToForm(pointF(x0, y)).y,
             shift = {ssLeft})
    r.f.feed(ekMouseUp, r.ins.clientToForm(pointF(x0 + 40, y)).x, r.ins.clientToForm(pointF(x0, y)).y)
    check r.ins.splitX == x0 + 40

suite "ObjectInspector editors":
  test "leaving an unchanged editor does not rewrite the values":
    let r = rig()
    let a = r.mkButton("a")
    let b = r.mkButton("b")
    a.caption = "One"
    b.caption = "Two"
    r.ins.inspect([Obj(a), Obj(b)])
    r.ins.beginEdit("caption")
    check r.ins.commitEdit()                    # focus left, nothing typed
    check a.caption == "One" and b.caption == "Two"
    check r.changes.len == 0
    a.onClick = proc(s: Control) = discard
    setHandlerName(Obj(a), "onClick", "aClick")
    b.onClick = proc(s: Control) = discard
    setHandlerName(Obj(b), "onClick", "bClick")
    r.ins.tab = itEvents
    r.ins.beginEdit("onClick")
    check r.ins.commitEdit()
    check handlerNameOf(Obj(a), "onClick") == "aClick"
    check handlerNameOf(Obj(b), "onClick") == "bClick"
    check a.onClick != nil and b.onClick != nil
    check r.changes.len == 0
    # a single object: an untouched editor is no change either
    r.ins.inspect(a)
    r.ins.tab = itProperties
    r.ins.beginEdit("caption")
    check r.ins.commitEdit()
    check r.changes.len == 0
    r.ins.beginEdit("caption")
    r.ins.editText.text = "Changed"
    check r.ins.commitEdit()
    check a.caption == "Changed" and r.changes == @["a.caption"]

  test "an editor closed by moving the focus away does not take it back":
    let r = rig()
    let a = r.mkButton("a")
    let other = newEdit(r.f, "", 20, 450)
    r.ins.inspect(a)
    r.ins.beginEdit("caption")
    r.ins.editText.text = "Typed"
    other.setFocus()
    check other.focused
    check not r.ins.focused
    check not r.ins.editing
    check a.caption == "Typed"

  test "a multi-selection edit reports each target that took the value":
    let r = rig()
    let a = r.mkButton("a")
    let b = r.mkButton("b")
    r.ins.inspect([Obj(a), Obj(b)])
    check not r.ins.setValue("tabOrder", pvString("x"))      # wrong kind: raises in the setter
    check r.ins.lastError.len > 0
    check r.ins.setValue("caption", pvString("Both"))
    check r.changes == @["a.caption", "b.caption"]

  test "name is not listed for several targets (N5)":
    let r = rig()
    let a = r.mkButton("a")
    let b = r.mkButton("b")
    r.ins.inspect(a)
    check r.ins.indexOfProp("name") >= 0
    r.ins.inspect([Obj(a), Obj(b)])
    check r.ins.indexOfProp("name") < 0
    check r.ins.indexOfProp("caption") >= 0

  test "names the form file cannot hold are rejected (N7)":
    let r = rig()
    let b = r.mkButton("keep")
    r.ins.inspect(b)
    for bad in ["end", "object", "true", "a b", "1x", ""]:
      check not r.ins.setValue("name", pvString(bad))
      check "valid" in r.ins.lastError
      check b.name == "keep"
    check r.ins.setValue("name", pvString("fine_1"))
    check b.name == "fine_1"
    for bad in ["inherited", "false", "on click"]:
      check not r.ins.setValue("onClick", pvEvent(bad))
      check "handler name" in r.ins.lastError
    check r.ins.setValue("onClick", pvEvent(""))
    check r.ins.setValue("onClick", pvEvent("okClick"))
    check validNfmName("okClick") and not validNfmName("end")

  test "names that shadow a member of Form are rejected (N25)":
    let r = rig()
    let b = r.mkButton("keep")
    r.ins.inspect(b)
    for bad in ["icon", "menu", "text", "sho_w", "close"]:
      check not r.ins.setValue("name", pvString(bad))
      check "reserved" in r.ins.lastError
      check b.name == "keep"
    check r.ins.setValue("name", pvString("Text"))      # another Nim identifier

  test "numbers that are not finite are rejected":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    let w = b.width
    for txt in ["inf", "-inf", "nan"]:
      r.ins.beginEdit("width")
      r.ins.editText.text = txt
      check not r.ins.commitEdit()
      check "finite" in r.ins.lastError
      check b.width == w
      r.ins.cancelEdit()

  test "a right click selects the row under the cursor and reports it":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    r.f.settle
    r.ins.selectProp("caption")
    var got: seq[string]
    var pts: seq[PointF]
    r.ins.onContextMenu = proc(s: Control, prop: string, p: PointF) =
      got.add prop
      pts.add p
    r.f.settle
    let p = r.namePoint("left")
    r.f.feed(ekMouseDown, p.x, p.y, button = mbRight)
    check r.ins.selectedProp == "left"
    r.f.feed(ekMouseUp, p.x, p.y, button = mbRight)
    check got == @["left"]
    check pts.len == 1 and pts[0].x > 0
    # over a category: the row is selected, the host hears ""
    let cat = r.ins.rowRect(0)
    let cp = r.ins.clientToForm(pointF(cat.x + 40, cat.y + cat.h / 2))
    r.f.feed(ekMouseDown, cp.x, cp.y, button = mbRight)
    r.f.feed(ekMouseUp, cp.x, cp.y, button = mbRight)
    check got == @["left", ""]
    check not r.ins.editing

  test "isOverridden marks rows, cached until refresh":
    let r = rig()
    let b = r.mkButton()
    r.ins.inspect(b)
    var calls = 0
    var over = true
    r.ins.isOverridden = proc(prop: string): bool =
      inc calls
      over and prop == "caption"
    check r.ins.overridden("caption")
    check not r.ins.overridden("left")
    let n = calls
    check r.ins.overridden("caption")
    check calls == n                       # cached
    over = false
    check r.ins.overridden("caption")      # still the cached answer
    r.ins.refresh()
    check not r.ins.overridden("caption")
    r.f.settle                             # painting with the predicate set works

# Close the windows the rigs left open, so no render context is freed after SDL has quit.
for f in openForms(): f.freeWindow()
Application.shutdown()
