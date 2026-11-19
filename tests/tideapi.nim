## API added for tool builders: component hash, inspector veto, CodeEdit
## external edits, PageControl tab position, borderStyle of list-like controls,
## event signatures in the registry. Headless (offscreen SDL).

import std/[unittest, os, strutils, tables, sets]
import nimvcl
import nimvcl/controls/inspector
import nimvcl/dsl/nfm

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: 1, shift: shift))
proc click(f: Form, x, y: float32) =
  f.feed(ekMouseDown, x, y)
  f.feed(ekMouseUp, x, y)
proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k, shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k, shift: shift))
proc typeText(f: Form, s: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id, text: s))
proc settle(f: Form) =
  discard f.paintIfDirty()
  f.layoutIfNeeded()

proc shotOf(f: Form, name: string): Image =
  let path = getTempDir() / name
  doAssert f.screenshot(path, full = true)
  result = loadImage(path)
  removeFile path

proc differs(a, b: Color, tol = 6): bool =
  abs(int(a.r) - int(b.r)) > tol or abs(int(a.g) - int(b.g)) > tol or
    abs(int(a.b) - int(b.b)) > tol

suite "component hash":
  test "tables and sets keyed by components and controls":
    Application.init()
    let a = newButton(nil, "a")
    let b = newButton(nil, "b")
    var t: Table[Control, int]
    t[a] = 1
    t[b] = 2
    check t[a] == 1 and t[b] == 2 and t.len == 2
    var s: HashSet[Component]
    s.incl a
    s.incl a
    s.incl newComponent()
    check s.len == 2 and a in s
    var m: Table[Component, string]
    m[newTimer()] = "t"
    check m.len == 1

suite "inspector veto":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  proc setupRig(): (Form, ObjectInspector, Button) =
    let f = newForm(nil, 420, 640)
    f.show()
    let ins = newObjectInspector(f, 10, 10, 340, 600)
    let b = newButton(f, "OK", 20, 400)
    b.name = "okButton"
    f.settle
    ins.inspect(b)
    (f, ins, b)

  test "a refused edit keeps the old value and shows the message":
    let (f, ins, b) = setupRig()
    var asked: seq[string]
    var changed = 0
    ins.onPropertyChanged = proc(s: Control, t: Obj, p: string) = inc changed
    ins.onPropertyChanging = proc(s: Control, t: Obj, p: string, v: PropValue,
                                  accept: var bool, message: var string) =
      asked.add p & "=" & (if v.kind == pkString: v.s else: $v.kind)
      if p == "name":
        accept = false
        message = "the name is used by the code"
    check not ins.setValue("name", pvString("other"))
    check b.name == "okButton"
    check ins.lastError == "the name is used by the code"
    check changed == 0
    check asked == @["name=other"]
    # other properties pass
    check ins.setValue("caption", pvString("Go"))
    check b.caption == "Go" and ins.lastError == "" and changed == 1
    # no message given: a default one
    ins.onPropertyChanging = proc(s: Control, t: Obj, p: string, v: PropValue,
                                  accept: var bool, message: var string) =
      accept = false
    check not ins.setValue("caption", pvString("Stop"))
    check b.caption == "Go" and "caption" in ins.lastError
    # the message is painted in the inspector (not only kept in lastError)
    discard f.paintIfDirty()
    f.freeWindow()

  test "a refused typed edit leaves the editor open; Esc closes it and clears the message":
    let (f, ins, b) = setupRig()
    ins.onPropertyChanging = proc(s: Control, t: Obj, p: string, v: PropValue,
                                  accept: var bool, message: var string) =
      if p == "tabOrder":
        accept = false
        message = "no"
    let i = ins.indexOfProp("tabOrder")
    ins.selectProp("tabOrder")
    let vr = ins.valueRect(ins.indexOfProp("tabOrder"))
    let pt = ins.clientToForm(pointF(vr.x + 24, vr.y + vr.h / 2))
    f.click(pt.x, pt.y)
    check ins.editing
    f.typeText("7")
    f.tap(keyEnter)
    check ins.editing and ins.lastError == "no" and b.tabOrder == 0
    f.tap(keyEscape)
    check not ins.editing and ins.lastError == ""
    check i >= 0
    f.freeWindow()

  test "with several targets one refusal stops them all; double click handler creation is vetoed too":
    let (f, ins, b) = setupRig()
    let b2 = newButton(f, "Two", 20, 440)
    b2.name = "two"
    ins.inspect([Obj(b), Obj(b2)])
    ins.onPropertyChanging = proc(s: Control, t: Obj, p: string, v: PropValue,
                                  accept: var bool, message: var string) =
      if t == Obj(b2): accept = false
    check not ins.setValue("caption", pvString("X"))
    check b.caption == "OK" and b2.caption == "Two"
    ins.inspect(b)
    ins.onPropertyChanging = proc(s: Control, t: Obj, p: string, v: PropValue,
                                  accept: var bool, message: var string) =
      if p == "onClick" and v.kind == pkEvent:
        accept = false
        message = "handlers are generated elsewhere"
    ins.tab = itEvents
    let r = ins.rowRect(ins.indexOfProp("onClick"))
    ins.selectProp("onClick")
    ins.dispatchDouble(ins.indexOfProp("onClick"))
    check handlerNameOf(b, "onClick") == ""
    check "elsewhere" in ins.lastError
    f.freeWindow()
    check r.h > 0

suite "CodeEdit external edits":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "replaceRange goes through the model: undo, repaint, onChange":
    let f = newForm(nil, 640, 480)
    f.show()
    let e = newCodeEdit(f, "", 10, 10, 600, 400)
    e.text = "alpha\nbeta\ngamma\n"
    var changes = 0
    e.onChange = proc(s: Control) = inc changes
    f.settle
    check e.replaceRange((1, 0), (1, 4), "BETA!")
    check e.text == "alpha\nBETA!\ngamma\n"
    check changes == 1
    check e.modified
    check e.caretPos == (1, 5)                     # after the inserted text
    check f.ui.needsPaint
    discard f.paintIfDirty()
    check e.undo()
    check e.text == "alpha\nbeta\ngamma\n"
    check changes == 2
    check e.redo()
    check e.text == "alpha\nBETA!\ngamma\n"
    # unchanged text: nothing happens
    changes = 0
    check not e.replaceRange((0, 0), (0, 5), "alpha")
    check changes == 0
    # insertion, reversed range, positions past the end are clamped
    check e.insertAt((0, 5), "!")
    check e.lineAt(0) == "alpha!"
    check e.replaceRange((2, 5), (2, 0), "G")
    check e.lineAt(2) == "G"

  test "keepSelection leaves the user's selection alone":
    let f = newForm(nil, 640, 480)
    f.show()
    let e = newCodeEdit(f, "", 10, 10, 600, 400)
    e.text = "one\ntwo\nthree"
    e.select((2, 0), (2, 5))
    check e.replaceRange((0, 0), (0, 3), "ONE", keepSelection = true)
    check e.lineAt(0) == "ONE"
    check e.selection.startPos == (2, 0) and e.selection.endPos == (2, 5)
    # inserting lines above moves the selection down with the text
    check e.insertAt((0, 0), "new\n", keepSelection = true)
    check e.selection.startPos == (3, 0)
    check e.selectedText == "three"

  test "undo groups merge several external edits":
    let f = newForm(nil, 640, 480)
    f.show()
    let e = newCodeEdit(f, "", 10, 10, 600, 400)
    e.text = "a\nb\nc"
    e.beginUndoGroup()
    e.replaceRange((0, 0), (0, 1), "A")
    e.replaceRange((1, 0), (1, 1), "B")
    e.replaceRange((2, 0), (2, 1), "C")
    e.endUndoGroup()
    check e.text == "A\nB\nC"
    check e.undo()
    check e.text == "a\nb\nc"
    check e.redo()
    check e.text == "A\nB\nC"

  test "read-only editors refuse; touched() resyncs a direct model edit":
    let f = newForm(nil, 640, 480)
    f.show()
    let e = newCodeEdit(f, "", 10, 10, 600, 400)
    e.text = "abc"
    e.readOnly = true
    check not e.replaceRange((0, 0), (0, 1), "X")
    check e.text == "abc"
    e.readOnly = false
    var changes = 0
    e.onChange = proc(s: Control) = inc changes
    discard e.model.replace((0, 3), (0, 3), "def")
    check changes == 0
    e.touched()
    check changes == 1 and e.text == "abcdef"

suite "PageControl tab position":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "bottom tabs: strip under the body, pages above it, clicks on the strip":
    let f = newForm(nil, 400, 300)
    f.show()
    let pc = newPageControl(f, 20, 20, 360, 240)
    let a = newTabSheet(pc, "One")
    let b = newTabSheet(pc, "Two")
    let sh = pc.stripHeight
    f.settle
    check pc.tabPosition == tpTop
    check a.top >= sh and pc.tabRect(0).y < sh
    pc.tabPosition = tpBottom
    f.settle
    check a.top <= 2 and a.height <= pc.height - sh
    check a.top + a.height <= pc.height - sh + 1
    let r0 = pc.tabRect(0)
    let r1 = pc.tabRect(1)
    check r0.y >= pc.height - sh and r0.bottom <= pc.height
    check r1.x == r0.right
    check pc.tabAt(r1.x + 4, r1.y + r1.h / 2) == 1
    check pc.tabAt(r1.x + 4, 5) == -1                    # the top is body now
    let p = pc.clientToForm(pointF(r1.x + 4, r1.y + r1.h / 2))
    f.click(p.x, p.y)
    check pc.activePage == b
    f.tap(keyLeft)
    check pc.activePage == a
    pc.tabPosition = tpTop
    f.settle
    check a.top >= sh

  test "the strip is painted along the bottom edge":
    let f = newForm(nil, 400, 300)
    f.show()
    let pc = newPageControl(f, 20, 20, 360, 240)
    newTabSheet(pc, "One")
    newTabSheet(pc, "Two")
    pc.tabPosition = tpBottom
    f.settle
    let img = f.shotOf("nimvcl_tabs_bottom.png")
    let th = f.theme
    let sh = pc.stripHeight
    let s = float32(img.width) / f.width                     # pixels per logical px
    # the unselected tab (Two) is drawn with surfaceAlt in the lower strip
    let r1 = pc.tabRect(1)
    let q = pc.clientToForm(pointF(r1.x + 6, r1.y + r1.h - 5))
    let px = img.getPixel(int(q.x * s), int(q.y * s))
    check not differs(px, th.surfaceAlt, 14)
    # the same spot at the top of the control is page background, not a tab
    let top = pc.clientToForm(pointF(r1.x + 6, 6))
    let pt = img.getPixel(int(top.x * s), int(top.y * s))
    check differs(pt, th.surfaceAlt, 3) or differs(pt, th.surface, 3) == false
    check sh > 0

  test "overflowing tabs scroll with the arrows at the bottom too":
    let f = newForm(nil, 300, 200)
    f.show()
    let pc = newPageControl(f, 10, 10, 160, 150)
    for i in 1 .. 8: newTabSheet(pc, "Page " & $i)
    pc.tabPosition = tpBottom
    f.settle
    check pc.overflowing
    check pc.tabAt(pc.width - 5, pc.height - 5) == -3      # right arrow
    let p = pc.clientToForm(pointF(pc.width - 5, pc.height - 5))
    f.click(p.x, p.y)
    check pc.firstVisibleTab == 1

  test "tabPosition is a registered property and round-trips through .nfm":
    let f = newForm(nil, 300, 200)
    f.name = "F"
    let pc = newPageControl(f, 0, 0, 200, 150)
    pc.name = "pages"
    pc.tabPosition = tpBottom
    let text = formToNfm(f)
    check "tabPosition = tpBottom" in text
    let g = loadNfm(text)
    check PageControl(g.findComponent("pages")).tabPosition == tpBottom
    pc.tabPosition = tpTop
    check "tabPosition" notin formToNfm(f)

suite "borderStyle":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  proc edge(img: Image, f: Form, c: Control): (Color, Color) =
    ## The pixel on the control's left edge and the one just outside it.
    let s = float32(img.width) / f.width
    let o = c.formOrigin
    let y = int((o.y + c.height / 2) * s)
    (img.getPixel(int(o.x * s), y), img.getPixel(int((o.x - 2) * s), y))

  test "defaults to bsSingle; bsNone removes the border and the rounded corners":
    let f = newForm(nil, 700, 300)
    f.show()
    f.color = hex"#ffffff"
    let lv = newListView(f, 10, 10, 150, 100)
    let lb = newListBox(f, 180, 10, 150, 100)
    let tv = newTreeView(f, 350, 10, 150, 100)
    let me = newMemo(f, "", 10, 150, 150, 100)
    let ce = newCodeEdit(f, "", 180, 150, 150, 100)
    let sg = newStringGrid(f, 350, 150, 150, 100)
    let all = @[Control(lv), Control(lb), Control(tv), Control(me), Control(ce), Control(sg)]
    check lv.borderStyle == bsSingle and lb.borderStyle == bsSingle and
          tv.borderStyle == bsSingle and me.borderStyle == bsSingle and
          ce.borderStyle == bsSingle and sg.borderStyle == bsSingle
    f.settle
    let th = f.theme
    let withBorder = f.shotOf("nimvcl_border1.png")
    for c in all:
      let (e, _) = edge(withBorder, f, c)
      check differs(e, th.surface, 4)                  # the border line is drawn
    lv.borderStyle = bsNone
    lb.borderStyle = bsNone
    tv.borderStyle = bsNone
    me.borderStyle = bsNone
    ce.borderStyle = bsNone
    sg.borderStyle = bsNone
    f.settle
    check f.ui.needsPaint == false
    let flush = f.shotOf("nimvcl_border2.png")
    for c in all:
      let (e, _) = edge(flush, f, c)
      check not differs(e, th.surface, 4)              # the surface reaches the edge
    # a corner pixel is filled too (not rounded off)
    let s = float32(flush.width) / f.width
    for c in all:
      let o = c.formOrigin
      let px = flush.getPixel(int(o.x * s), int(o.y * s))
      check not differs(px, th.surface, 4)

  test "bsNone survives a form file; the default is not written":
    let f = newForm(nil, 300, 200)
    f.name = "F"
    let lv = newListView(f, 0, 0, 100, 100)
    lv.name = "lv"
    check "borderStyle" notin formToNfm(f)
    lv.borderStyle = bsNone
    let text = formToNfm(f)
    check "borderStyle = bsNone" in text
    check ListView(loadNfm(text).findComponent("lv")).borderStyle == bsNone

suite "event signatures in the registry":
  test "PropInfo.params lists the handler's parameters":
    let close = classByName("Form").findProp("onClose")
    check close.typeName == "FormCloseEvent"
    check close.params.len == 2
    check close.params[0].name == "sender" and close.params[0].typeName == "Form"
    check close.params[1].name == "action" and close.params[1].typeName == "var CloseAction"
    check close.returnType == ""
    let key = classByName("Edit").findProp("onKeyDown")
    check key.params.len == 3
    check key.params[1].name == "key" and key.params[1].typeName == "var Key"
    check key.params[2].typeName == "ShiftState"
    let click = classByName("Button").findProp("onClick")
    check click.params.len == 1 and click.params[0].typeName == "Control"
    # a non-event property has none
    check classByName("Button").findProp("caption").params.len == 0

  test "PopupEvent is public":
    let pm = newPopupMenu()
    var n = 0
    let ev: PopupEvent = proc(sender: PopupMenu) = inc n
    pm.onPopup = ev
    pm.onPopup(pm)
    check n == 1
    let p = classByName("PopupMenu").findProp("onPopup")
    check p.typeName == "PopupEvent"
    check p.params.len == 1 and p.params[0].typeName == "PopupMenu"

type WideTabs = ref object of PageControl
method sheetTabText*(p: WideTabs, s: TabSheet): string =
  s.caption & "        "

suite "tab text override":
  test "a sheetTabText override is measured, not just drawn":
    let f = newForm(nil, 400, 300)
    f.show()
    let plain = newPageControl(f, 0, 0, 400, 100)
    discard newTabSheet(plain, "Unit1")
    let wide = WideTabs()
    initPageControl(wide, f)
    wide.setBounds(0, 120, 400, 100)
    discard newTabSheet(wide, "Unit1")
    f.settle
    check wide.tabText(0) == "Unit1        "
    check wide.tabRect(0).w > plain.tabRect(0).w
