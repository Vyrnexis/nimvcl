## TreeView (phase 6). Headless (offscreen SDL), events built by hand.

import std/[unittest, os, monotimes, times, strutils]
import nimvcl
import nimvcl/controls/[scrolling, listbox, imagelist, treeview]

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))
proc click(f: Form, x, y: float32, shift: ShiftState = {}, clicks = 1) =
  var sh = shift
  if clicks > 1: sh.incl ssDouble
  f.feed(ekMouseDown, x, y, shift = sh, clicks = clicks)
  f.feed(ekMouseUp, x, y, shift = shift)
proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k,
                                     shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k,
                                     shift: shift))
proc newShown(w = 400'f32, h = 300'f32): Form =
  result = newForm(nil, w, h)
  result.show()
proc settle(f: Form) =
  discard f.paintIfDirty()
  f.layoutIfNeeded()

proc mkTree(f: Form, h = 222'f32): TreeView =
  ## 220 wide, rows of 20 px (viewport = h - 2).
  result = newTreeView(f, 10, 10, 220, h)
  result.itemHeight = 20
  result.slowClickDelay = 30
  settle f

proc at(tv: TreeView, r: RectF): PointF =
  tv.clientToForm(pointF(r.x + r.w / 2, r.y + r.h / 2))
proc clickLabel(f: Form, tv: TreeView, n: TreeNode, shift: ShiftState = {},
                clicks = 1) =
  let p = tv.at(tv.labelRect(n))
  f.click(p.x, p.y, shift, clicks)
proc clickButton(f: Form, tv: TreeView, n: TreeNode) =
  let p = tv.at(tv.expanderRect(n))
  f.click(p.x, p.y)

proc sample(tv: TreeView): tuple[alpha, a1, a2, x, y, z, a3, beta, b1, gamma: TreeNode] =
  let it = tv.items
  result.alpha = it.addChild(nil, "Alpha")
  result.a1 = result.alpha.addChild("a1")
  result.a2 = result.alpha.addChild("a2")
  result.x = result.a2.addChild("x")
  result.y = result.a2.addChild("y")
  result.z = result.a2.addChild("z")
  result.a3 = result.alpha.addChild("a3")
  result.beta = it.addChild(nil, "Beta")
  result.b1 = result.beta.addChild("b1")
  discard result.beta.addChild("b2")
  result.gamma = it.addChild(nil, "Gamma")

proc rowTexts(tv: TreeView): string =
  for i in 0 ..< tv.rowCount:
    if i > 0: result.add ","
    result.add tv.nodeAtRow(i).text

suite "treeview":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "node API: levels, indexes, parents, insert, delete":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    check tv.nodeCount == 11
    check s.alpha.level == 0 and s.a1.level == 1 and s.x.level == 2
    check s.a1.parent == s.alpha and s.alpha.parent == nil
    check s.a3.index == 2 and s.beta.index == 1 and s.gamma.index == 2
    check s.alpha.childCount == 3 and s.alpha.child(1) == s.a2
    check s.alpha.hasChildren and not s.gamma.hasChildren
    check tv.items.topCount == 3 and tv.items.find("y") == s.y
    # items.add: after sibling; items.insert: before
    let d = tv.items.add(s.alpha, "Delta")
    check d.index == 1 and tv.items.top(1) == d
    let c0 = tv.items.insert(s.alpha, "Zero")
    check c0.index == 0 and s.alpha.index == 1
    let mid = s.alpha.insert(1, "mid")
    check mid.index == 1 and s.a2.index == 2 and s.a3.index == 3
    mid.delete()
    check s.a2.index == 1 and s.alpha.childCount == 3 and mid.isDetached
    check tv.nodeCount == 13
    s.a2.delete()                        # subtree of 4 nodes
    check tv.nodeCount == 9 and s.x.isDetached
    s.alpha.clear()
    check s.alpha.childCount == 0 and not s.alpha.hasChildren
    tv.items.clear()
    check tv.nodeCount == 0 and tv.rowCount == 0
    s.alpha.text = "ignored on a detached node"
    check s.alpha.addChild("n") == nil

  test "visible rows after expand, collapse, insert and delete":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    check tv.rowTexts == "Alpha,Beta,Gamma"
    s.alpha.expanded = true
    check tv.rowTexts == "Alpha,a1,a2,a3,Beta,Gamma"
    s.a2.expand()
    check tv.rowTexts == "Alpha,a1,a2,x,y,z,a3,Beta,Gamma"
    check s.z.rowIndex == 5 and s.beta.rowIndex == 7
    # collapsing the parent hides a2's expanded subtree, expanding restores it
    s.alpha.collapse()
    check tv.rowTexts == "Alpha,Beta,Gamma" and s.x.rowIndex == -1
    check s.a2.expanded and not s.a2.isVisible
    s.alpha.expand()
    check tv.rowTexts == "Alpha,a1,a2,x,y,z,a3,Beta,Gamma"
    # insert into the middle of a visible subtree, at the front and the end
    s.a2.insert(1, "xy")
    check tv.rowTexts == "Alpha,a1,a2,x,xy,y,z,a3,Beta,Gamma"
    s.alpha.insert(0, "first")
    check tv.rowTexts == "Alpha,first,a1,a2,x,xy,y,z,a3,Beta,Gamma"
    s.alpha.addChild("last")
    check tv.rowTexts == "Alpha,first,a1,a2,x,xy,y,z,a3,last,Beta,Gamma"
    # a hidden parent: no rows until it is expanded
    s.beta.addChild("b3")
    check tv.rowCount == 12
    s.beta.expand()
    check tv.rowTexts.endsWith("Beta,b1,b2,b3,Gamma")
    # delete a visible subtree / a leaf / a hidden node
    s.a2.delete()
    check tv.rowTexts == "Alpha,first,a1,a3,last,Beta,b1,b2,b3,Gamma"
    s.b1.delete()
    check tv.rowTexts == "Alpha,first,a1,a3,last,Beta,b2,b3,Gamma"
    for i in 0 ..< tv.rowCount: check tv.nodeAtRow(i).rowIndex == i
    # a node that loses its last child stops being expanded
    s.beta.clear()
    check not s.beta.expanded and tv.rowTexts == "Alpha,first,a1,a3,last,Beta,Gamma"
    # beginUpdate defers, endUpdate rebuilds once
    tv.beginUpdate()
    s.gamma.addChild("g1")
    s.gamma.expanded = true
    s.alpha.collapse()
    tv.endUpdate()
    check tv.rowTexts == "Alpha,Beta,Gamma,g1"

  test "lazy children through onExpanding":
    let f = newShown()
    let tv = mkTree(f)
    let root = tv.items.addChild(nil, "root")
    root.hasChildren = true
    var calls = 0
    var allowIt = true
    var expanded, collapsed = 0
    tv.onExpanding = proc(s: Control, n: TreeNode, allow: var bool) =
      inc calls
      allow = allowIt
      if allowIt and n == root and n.childCount == 0:
        for i in 0 ..< 3:
          let c = n.addChild("child " & $i)
          if i == 1: c.hasChildren = true
    tv.onExpanded = proc(s: Control, n: TreeNode) = inc expanded
    tv.onCollapsed = proc(s: Control, n: TreeNode) = inc collapsed
    check tv.rowCount == 1
    check tv.expanderRect(root).w > 0            # the expander shows before children exist
    allowIt = false
    f.clickButton(tv, root)                       # vetoed
    check calls == 1 and tv.rowCount == 1 and not root.expanded and expanded == 0
    allowIt = true
    f.clickButton(tv, root)
    check calls == 2 and root.expanded and tv.rowCount == 4 and expanded == 1
    f.clickButton(tv, root)                       # collapse
    check tv.rowCount == 1 and collapsed == 1
    f.clickButton(tv, root)                       # expand again: fires, no new children
    check calls == 3 and tv.rowCount == 4 and root.childCount == 3
    # a lazy node that ends up without children is a leaf
    let empty = tv.items.addChild(nil, "empty")
    empty.hasChildren = true
    f.clickButton(tv, empty)
    check not empty.expanded and not empty.hasChildren
    check tv.expanderRect(empty).w == 0

  test "keyboard: Left, Right, *, +, -, Home, End":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    tv.selected = s.alpha
    tv.setFocus()
    f.tap keyRight                                  # expand
    check s.alpha.expanded and tv.selected == s.alpha
    f.tap keyRight                                  # first child
    check tv.selected == s.a1
    f.tap keyLeft                                   # to the parent
    check tv.selected == s.alpha and s.alpha.expanded
    f.tap keyLeft                                   # collapse
    check not s.alpha.expanded and tv.selected == s.alpha
    f.tap keyLeft                                   # top level: nothing
    check tv.selected == s.alpha
    f.tap '*'.key                                   # expand everything below
    check s.alpha.expanded and s.a2.expanded and not s.beta.expanded
    check tv.rowTexts == "Alpha,a1,a2,x,y,z,a3,Beta,Gamma"
    f.tap '-'.key
    check not s.alpha.expanded
    f.tap '+'.key
    check s.alpha.expanded
    f.tap keyDown
    f.tap keyDown
    check tv.selected == s.a2
    f.tap keyRight
    check s.a2.expanded
    f.tap keyEnd
    check tv.selected == s.gamma
    f.tap keyHome
    check tv.selected == s.alpha
    f.tap keyUp                                     # stays on the first row
    check tv.selected == s.alpha
    # leaf: Right does nothing
    tv.selected = s.a1
    f.tap keyRight
    check tv.selected == s.a1
    # '*' also arrives as text input
    s.alpha.collapse(recursive = true)
    tv.selected = s.alpha
    Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id,
                                       text: "*"))
    check s.alpha.expanded and s.a2.expanded

  test "type-ahead jumps between visible rows":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    s.alpha.expand()
    tv.setFocus()
    f.tap 'b'.key
    check tv.selected == s.beta
    f.tap 'e'.key                                    # "be": still Beta
    check tv.selected == s.beta
    tv.typeAheadTimeout = 0                          # every key starts anew
    sleep 5
    f.tap 'g'.key
    check tv.selected == s.gamma
    sleep 5
    f.tap 'a'.key                                    # next 'a...' after Gamma wraps
    check tv.selected == s.alpha
    sleep 5
    f.tap 'a'.key
    check tv.selected == s.a1

  test "selection: click, Ctrl, Shift, collapse, onChanging, onChange":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    s.alpha.expand()
    var changes = 0
    var last: TreeNode
    tv.onChange = proc(sn: Control, n: TreeNode) =
      inc changes
      last = n
    f.clickLabel(tv, s.a2)
    check tv.selected == s.a2 and tv.isSelected(s.a2) and tv.selCount == 1
    check changes == 1 and last == s.a2
    f.clickLabel(tv, s.a2)                          # same node: no event
    check changes == 1
    # veto
    tv.onChanging = proc(sn: Control, n: TreeNode, allow: var bool) =
      allow = n != s.a3
    f.clickLabel(tv, s.a3)
    check tv.selected == s.a2 and changes == 1
    tv.onChanging = nil
    # single mode ignores Ctrl / Shift
    f.clickLabel(tv, s.a3, {ssCtrl})
    check tv.selCount == 1 and tv.selected == s.a3
    # multi
    tv.multiSelect = true
    f.clickLabel(tv, s.a1)
    f.clickLabel(tv, s.a3, {ssShift})
    check tv.selCount == 3                            # a1, a2, a3
    f.clickLabel(tv, s.a2, {ssCtrl})
    check tv.selCount == 2 and not tv.isSelected(s.a2)
    check tv.selectedNodes == @[s.a1, s.a3]
    f.clickLabel(tv, s.beta, {ssCtrl})
    check tv.selectedNodes == @[s.a1, s.a3, s.beta]
    tv.clearSelection()
    check tv.selCount == 0
    f.tap 'a'.key, {ssCtrl}
    check tv.selCount == tv.rowCount
    # Shift+arrow extends from the anchor, Ctrl+arrow only moves the focus
    f.clickLabel(tv, s.alpha)
    f.tap keyDown, {ssShift}
    f.tap keyDown, {ssShift}
    check tv.selCount == 3 and tv.selected == s.a2
    f.tap keyDown, {ssCtrl}
    check tv.selCount == 3 and tv.selected == s.a3
    f.tap keySpace, {ssCtrl}
    check tv.selCount == 4
    # collapsing deselects hidden descendants and moves the focus to the node
    s.alpha.collapse()
    check tv.selected == s.alpha and tv.isSelected(s.alpha)
    check not tv.isSelected(s.a1) and tv.selCount == 1
    # selecting a hidden node expands its ancestors
    tv.selected = s.x
    check s.alpha.expanded and s.a2.expanded and s.x.rowIndex >= 0
    tv.selected = nil
    check tv.selected == nil and tv.selCount == 0

  test "deleting the focused node moves the selection to a neighbour":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    s.alpha.expand()
    var changes = 0
    tv.selected = s.a2
    tv.onChange = proc(sn: Control, n: TreeNode) = inc changes
    s.a2.delete()
    check tv.selected == s.a3 and tv.isSelected(s.a3) and changes == 1
    s.a3.delete()
    check tv.selected == s.a1
    s.a1.delete()
    check tv.selected == s.alpha
    tv.items.clear()
    check tv.selected == nil

  test "mouse: expander, double click, onClick":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    var dbl, clicks = 0
    tv.onDblClick = proc(sn: Control) = inc dbl
    tv.onClick = proc(sn: Control) = inc clicks
    f.clickButton(tv, s.alpha)
    check s.alpha.expanded and tv.selected == nil     # the expander does not select
    f.clickLabel(tv, s.beta, clicks = 2)
    check s.beta.expanded and dbl == 1                 # double click toggles
    f.clickLabel(tv, s.beta, clicks = 2)
    check not s.beta.expanded and dbl == 2
    # blank space right of the label selects nothing unless rowSelect
    tv.selected = nil
    let r = tv.nodeRect(s.gamma)
    let p = tv.clientToForm(pointF(r.right - 20, r.y + r.h / 2))
    f.click(p.x, p.y)
    check tv.selected == nil
    tv.rowSelect = true
    f.click(p.x, p.y)
    check tv.selected == s.gamma
    # showRoot = false: the top level has no expander column
    tv.showRoot = false
    check tv.expanderRect(s.alpha).w == 0 and tv.expanderRect(s.a2).w > 0

  test "label edit lifecycle":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    var editing, edited = 0
    var allowEdit = true
    tv.onEditing = proc(sn: Control, n: TreeNode, allow: var bool) =
      inc editing
      allow = allowEdit
    tv.onEdited = proc(sn: Control, n: TreeNode, text: var string) =
      inc edited
      if text == "bad": text = "fixed"
    tv.selected = s.beta
    tv.setFocus()
    f.tap keyF2
    check tv.isEditing and tv.editingNode == s.beta and editing == 1
    check tv.editControl.text == "Beta" and tv.editControl.visible
    check f.activeControl == tv.editControl
    # the editor sits on the label row
    let row = tv.nodeRect(s.beta)
    check tv.editControl.top == row.y and tv.editControl.height == row.h
    tv.editControl.text = "Beta2"
    f.tap keyEnter
    check not tv.isEditing and s.beta.text == "Beta2" and edited == 1
    check f.activeControl == tv
    check not tv.editControl.visible
    # Escape cancels
    f.tap keyF2
    tv.editControl.text = "nope"
    f.tap keyEscape
    check not tv.isEditing and s.beta.text == "Beta2" and edited == 1
    # onEdited may change the text
    f.tap keyF2
    tv.editControl.text = "bad"
    f.tap keyEnter
    check s.beta.text == "fixed"
    # focus loss commits
    f.tap keyF2
    tv.editControl.text = "lost"
    let other = newEdit(f, "", 250, 10, 100, 24)
    other.setFocus()
    check not tv.isEditing and s.beta.text == "lost" and edited == 3
    # veto and readOnly
    allowEdit = false
    tv.selected = s.alpha
    tv.setFocus()
    f.tap keyF2
    check not tv.isEditing and editing == 5
    allowEdit = true
    tv.readOnly = true
    f.tap keyF2
    check not tv.isEditing
    tv.readOnly = false
    # deleting the node being edited ends the edit
    f.tap keyF2
    check tv.isEditing
    s.alpha.delete()
    check not tv.isEditing
    # code API
    check tv.beginEdit(s.gamma)
    tv.endEdit(cancel = true)
    check not tv.isEditing and s.gamma.text == "Gamma"

  test "slow second click starts editing":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    f.clickLabel(tv, s.beta)                          # select
    check not tv.isEditing
    f.clickLabel(tv, s.beta)                          # second click: slow
    check not tv.isEditing
    var n = 0
    while not tv.isEditing and n < 40:
      Application.processMessages(20)
      inc n
    check tv.isEditing and tv.editingNode == s.beta
    tv.endEdit(cancel = true)
    # another click in between cancels it
    f.clickLabel(tv, s.beta)
    f.clickLabel(tv, s.beta, clicks = 2)              # a double click is not a slow click
    sleep 80
    Application.processMessages(10)
    check not tv.isEditing

  test "check boxes, tri-state propagation":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    s.alpha.expand()
    s.a2.expand()
    tv.checkboxes = true
    var events: seq[string]
    tv.onChecked = proc(sn: Control, n: TreeNode) = events.add n.text
    let cr = tv.checkRect(s.a1)
    check cr.w > 0
    let p = tv.at(cr)
    f.click(p.x, p.y)
    check s.a1.checked == cbChecked and events == @["a1"]
    check tv.selected == nil                            # the box does not select
    f.click(p.x, p.y)
    check s.a1.checked == cbUnchecked
    events.setLen 0
    tv.selected = s.a3
    tv.setFocus()
    f.tap keySpace
    check s.a3.checked == cbChecked and events == @["a3"]
    # propagation
    tv.propagateChecks = true
    tv.toggleCheck(s.a2)
    check s.x.checked == cbChecked and s.z.checked == cbChecked
    check s.a2.checked == cbChecked
    check s.alpha.checked == cbGrayed                    # a1 unchecked, a2/a3 checked
    tv.toggleCheck(s.a1)
    check s.alpha.checked == cbChecked
    tv.toggleCheck(s.y)                                  # uncheck one grandchild
    check s.a2.checked == cbGrayed and s.alpha.checked == cbGrayed
    tv.toggleCheck(s.a2)                                 # grayed -> checked
    check s.a2.checked == cbChecked and s.y.checked == cbChecked
    s.a2.checked = false
    check s.x.checked == cbUnchecked

  test "scroll keeps the selection visible":
    let f = newShown()
    let tv = mkTree(f, 102)                               # 5 rows
    for i in 0 ..< 40: tv.items.addChild(nil, "Item " & $i)
    settle f
    check tv.vScrollBar.visible
    tv.selected = tv.items.top(30)
    check tv.scrollPos.y > 0
    let r = tv.nodeRect(tv.items.top(30))
    check r.y >= tv.viewport.y and r.bottom <= tv.viewport.bottom + 0.5
    tv.setFocus()
    f.tap keyHome
    check tv.scrollPos.y == 0 and tv.selected == tv.items.top(0)
    for i in 0 ..< 8: f.tap keyDown
    check tv.selected == tv.items.top(8)
    let r2 = tv.nodeRect(tv.selected)
    check r2.bottom <= tv.viewport.bottom + 0.5 and r2.y >= tv.viewport.y
    f.tap keyPageDown
    check tv.selected.rowIndex > 8
    f.tap keyEnd
    check tv.selected == tv.items.top(39)
    check tv.scrollPos.y == tv.maxScroll.y
    # a deep hidden node: selecting expands and scrolls
    let deep = tv.items.top(2).addChild("deep").addChild("deeper")
    tv.selected = deep
    check deep.rowIndex >= 0
    let r3 = tv.nodeRect(deep)
    check r3.y >= tv.viewport.y and r3.bottom <= tv.viewport.bottom + 0.5

  test "custom draw, images, hide selection":
    let f = newShown()
    let tv = mkTree(f)
    let s = sample(tv)
    let il = newImageList(16, 16)
    il.add newImage(16, 16, rgb(200, 60, 60))
    il.add newImage(16, 16, rgb(60, 60, 200))
    check il.count == 2 and il.image(5) == nil
    tv.images = il
    s.alpha.imageIndex = 0
    s.alpha.selectedIndex = 1
    s.alpha.expand()
    tv.selected = s.alpha
    var seen: seq[string]
    var firstState: ItemStates
    tv.onCustomDrawItem = proc(sn: Control, c: Canvas, n: TreeNode, r: RectF,
                               st: ItemStates, def: var bool) =
      seen.add n.text
      if n == s.alpha: firstState = st
      def = n.text != "a1"
    tv.invalidate()
    discard f.paintIfDirty()
    check seen.len == tv.rowCount and seen[0] == "Alpha"
    check isSelected in firstState
    tv.hideSelection = true
    seen.setLen 0
    tv.invalidate()
    discard f.paintIfDirty()
    check isSelected notin firstState                     # no focus: hidden
    tv.setFocus()
    tv.invalidate()
    discard f.paintIfDirty()
    check isSelected in firstState and isFocused in firstState
    check tv.itemHeight >= 20

  test "100,000 nodes: only visible rows are touched":
    let f = newShown(400, 300)
    let tv = mkTree(f, 262)
    var painted = 0
    tv.onCustomDrawItem = proc(sn: Control, c: Canvas, n: TreeNode, r: RectF,
                               st: ItemStates, def: var bool) = inc painted
    var t0 = getMonoTime()
    template ms(): float = float((getMonoTime() - t0).inMicroseconds) / 1000.0
    tv.beginUpdate()
    for i in 0 ..< 1000:
      let p = tv.items.addChild(nil, "Folder " & $i)
      for j in 0 ..< 100: p.addChild("Item " & $i & "." & $j)
    tv.endUpdate()
    let build = ms()
    check tv.nodeCount == 101_000 and tv.rowCount == 1000
    # expand 100 folders one by one (incremental splices)
    t0 = getMonoTime()
    for i in 0 ..< 100: tv.items.top(i * 10).expanded = true
    let expand100 = ms()
    check tv.rowCount == 1000 + 100 * 100
    # a single expand / collapse near the top of the 11,000 row list
    t0 = getMonoTime()
    for k in 0 ..< 20:
      tv.items.top(1).expand()
      tv.items.top(1).collapse()
    let toggle = ms() / 40
    check tv.rowCount == 11_000
    # append / insert into an expanded folder with many children, no beginUpdate
    let big = tv.items.top(0)
    t0 = getMonoTime()
    for k in 0 ..< 3_000: big.addChild("more " & $k)
    let append = ms()
    check tv.rowCount == 14_000
    t0 = getMonoTime()
    for k in 0 ..< 20: big.insert(0, "front " & $k)
    let insertFront = ms() / 20
    check tv.rowCount == 14_020
    for i in 0 ..< tv.rowCount:
      if i mod 997 == 0: check tv.nodeAtRow(i).rowIndex == i
    # painting touches only the visible rows
    settle f
    painted = 0
    tv.invalidate()
    t0 = getMonoTime()
    discard f.paintIfDirty()
    let paint1 = ms()
    let rowsVisible = int(ceil(tv.viewport.h / tv.itemHeight)) + 1
    check painted > 0 and painted <= rowsVisible
    # scroll to the middle and the end
    tv.scrollTo(0, tv.maxScroll.y / 2)
    painted = 0
    tv.invalidate()
    t0 = getMonoTime()
    for k in 0 ..< 50:
      tv.scrollBy(0, 20)
      discard f.paintIfDirty()
    let scrollPaint = ms() / 50
    check painted <= 50 * rowsVisible
    # selection of a deep node scrolls to it
    let last = tv.items.top(999)
    tv.selected = last
    check tv.nodeRect(last).bottom <= tv.viewport.bottom + 0.5
    # expand everything: all 101,000 rows
    t0 = getMonoTime()
    tv.expandAll()
    let expandAllMs = ms()
    check tv.rowCount == 101_000 + 3_020
    t0 = getMonoTime()
    tv.collapseAll()
    let collapseAllMs = ms()
    check tv.rowCount == 1000
    # delete a big subtree
    tv.items.top(0).expanded = true
    t0 = getMonoTime()
    tv.items.top(0).delete()
    let delMs = ms()
    check tv.rowCount == 999
    echo "  [treeview perf] build 101k nodes ", build.formatFloat(ffDecimal, 1),
         " ms, expand 100 folders ", expand100.formatFloat(ffDecimal, 2),
         " ms, toggle ", toggle.formatFloat(ffDecimal, 3),
         " ms, append 3k (11k rows after) ", append.formatFloat(ffDecimal, 1),
         " ms, insert at front (14k rows) ", insertFront.formatFloat(ffDecimal, 3),
         " ms, paint ", paint1.formatFloat(ffDecimal, 2), " ms (", rowsVisible,
         " rows max), scroll+paint ", scrollPaint.formatFloat(ffDecimal, 2),
         " ms, expandAll(", 104_020, ") ", expandAllMs.formatFloat(ffDecimal, 1),
         " ms, collapseAll ", collapseAllMs.formatFloat(ffDecimal, 1),
         " ms, delete subtree ", delMs.formatFloat(ffDecimal, 2), " ms"
    check toggle < 50 and insertFront < 100

suite "treeview (review fixes)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "collapse(recursive) rebuilds the rows once (fast)":
    let f = newShown()
    let tv = mkTree(f)
    tv.beginUpdate()
    let root = tv.items.addChild(nil, "root")
    for i in 0 ..< 3000:
      let d = root.addChild("d" & $i)
      for j in 0 ..< 10: d.addChild("x")
    tv.endUpdate()
    root.expand(recursive = true)
    check tv.rowCount == 1 + 3000 + 30000
    let t0 = getMonoTime()
    root.collapse(recursive = true)
    let ms = float((getMonoTime() - t0).inNanoseconds) / 1e6
    echo "  [treeview perf] collapse(recursive) 33k rows: ", ms, " ms"
    check tv.rowCount == 1 and not root.expanded
    check ms < (when defined(release): 500.0 else: 3000.0)

  test "clear drops focus once and fires onChange once":
    let f = newShown()
    let tv = mkTree(f)
    for i in 0 ..< 1000: tv.items.addChild(nil, "n" & $i)
    var cnt = 0
    tv.onChange = proc(s: Control, n: TreeNode) = inc cnt
    tv.selected = tv.items.top(999)
    cnt = 0
    tv.items.clear()
    check cnt == 1 and tv.selected == nil and tv.selCount == 0
    cnt = 0
    tv.items.clear()                                # nothing left: silent
    check cnt == 0
    # node.clear with the focus inside: one change, focus on the node
    let a = tv.items.addChild(nil, "A")
    for i in 0 ..< 50: a.addChild("k" & $i)
    a.expand()
    tv.selected = a.child(30)
    cnt = 0
    a.clear()
    check cnt == 1 and tv.selected == a and tv.isSelected(a) and a.childCount == 0

  test "collapse moves a hidden focus to the owner without onChanging, keeps others":
    let f = newShown()
    let tv = mkTree(f)
    tv.multiSelect = true
    let a = tv.items.addChild(nil, "A")
    let b = tv.items.addChild(nil, "B")
    let b1 = b.addChild("b1")
    b.expand()
    tv.selected = b1
    tv.setSelected(a, true)
    var changing = 0
    tv.onChanging = proc(s: Control, n: TreeNode, allow: var bool) =
      inc changing
      allow = false
    b.collapse()
    check changing == 0
    check tv.selected == b and a.selected and b.selected and not b1.selected
    check tv.selCount == 2

  test "selected = nil with nothing selected fires nothing":
    let f = newShown()
    let tv = mkTree(f)
    var cnt = 0
    tv.onChange = proc(s: Control, n: TreeNode) = inc cnt
    tv.selected = nil
    check cnt == 0
    let n = tv.items.addChild(nil, "n")
    tv.selected = n
    cnt = 0
    tv.selected = nil
    check cnt == 1

  test "the horizontal extent shrinks after the wide node goes":
    let f = newShown()
    let tv = mkTree(f)
    tv.items.addChild(nil, "short")
    let wide = tv.items.addChild(nil, "W".repeat(120))
    f.settle()
    discard f.paintIfDirty()
    let w0 = tv.contentSize.w
    check w0 > tv.viewport.w
    wide.delete()
    discard f.paintIfDirty()
    check tv.contentSize.w < w0 and tv.contentSize.w <= tv.viewport.w + 1
    # collapse of a wide subtree shrinks it too
    let p = tv.items.addChild(nil, "P")
    p.addChild("V".repeat(120))
    p.expand()
    discard f.paintIfDirty()
    let w1 = tv.contentSize.w
    check w1 > tv.viewport.w
    p.collapse()
    discard f.paintIfDirty()
    check tv.contentSize.w < w1

  test "collapse during beginUpdate prunes hidden selection at endUpdate":
    let f = newShown()
    let tv = mkTree(f)
    tv.multiSelect = true
    let s = sample(tv)
    s.alpha.expand()
    tv.selected = s.a1
    tv.setSelected(s.a3, true)
    tv.setSelected(s.gamma, true)
    var cnt = 0
    tv.onChange = proc(s: Control, n: TreeNode) = inc cnt
    tv.beginUpdate()
    s.alpha.collapse()
    check cnt == 0
    tv.endUpdate()
    check not s.a1.selected and not s.a3.selected and s.gamma.selected
    check tv.selected == s.alpha and s.alpha.selected
    check cnt == 1
    check tv.rowTexts == "Alpha,Beta,Gamma"

  test "keypad + - * handled on key down are not repeated by the text event":
    let f = newShown()
    let tv = mkTree(f)
    let n = tv.items.addChild(nil, "lazy")
    n.hasChildren = true
    var asked = 0
    tv.onExpanding = proc(s: Control, x: TreeNode, allow: var bool) =
      inc asked
      allow = false
    tv.selected = n
    tv.setFocus()
    f.tap Key(0x40000057)                           # keypad +
    Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id,
                                       text: "+"))
    check asked == 1
    f.tap Key(0x40000055)                           # keypad *
    Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id,
                                       text: "*"))
    check asked == 2
    # text alone still works
    Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id,
                                       text: "+"))
    check asked == 3

  test "type-ahead ignores shifted symbols but accepts shifted letters":
    let f = newShown()
    let tv = mkTree(f)
    let a = tv.items.addChild(nil, "Apple")
    let b = tv.items.addChild(nil, "Banana")
    let c = tv.items.addChild(nil, "1st")
    tv.selected = a
    tv.setFocus()
    f.tap 'b'.key, {ssShift}
    check tv.selected == b
    f.tap '1'.key, {ssShift}
    check tv.selected == b

  test "ImageList changes repaint / re-measure the view":
    let f = newShown()
    let tv = mkTree(f)
    let il = newImageList(16, 16)
    tv.images = il
    tv.itemHeight = 0
    tv.items.addChild(nil, "x")
    f.settle()
    discard f.paintIfDirty()
    let h0 = tv.contentSize.h
    il.height = 40
    check f.paintIfDirty()
    f.settle()
    check tv.contentSize.h > h0
    let v0 = il.version
    il.add(newImage(16, 16, rgb(1, 2, 3)))
    check il.version == v0 + 1
    tv.images = nil
    discard f.paintIfDirty()
    il.add(newImage(16, 16, rgb(1, 2, 3)))          # no longer listened to
    check not f.paintIfDirty()
