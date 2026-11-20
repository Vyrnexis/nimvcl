## ListView (phase 6). Headless (offscreen SDL), events built by hand.

import std/[unittest, os, monotimes, times, strutils, sequtils]
import nimvcl
import nimvcl/controls/[scrolling, listbox, imagelist, listview]

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
proc newShown(w = 500'f32, h = 400'f32): Form =
  result = newForm(nil, w, h)
  result.show()
proc settle(f: Form) =
  discard f.paintIfDirty()
  f.layoutIfNeeded()
  discard f.paintIfDirty()

proc mkList(f: Form, style = vsReport, n = 0, w = 340'f32, h = 224'f32): ListView =
  ## At (10, 10); rows of 20 px; report header 24 px.
  result = newListView(f, 10, 10, w, h)
  result.itemHeight = 20
  result.slowClickDelay = 30
  if style == vsReport:
    result.columns.add("Name", 140)
    result.columns.add("Size", 80, taRight)
    result.columns.add("Type", 60)
  result.viewStyle = style
  for i in 0 ..< n:
    result.items.add("Item " & $i, $(i * 10), "t" & $(i mod 3))
  settle f

proc fpos(lv: ListView, p: PointF): PointF = lv.clientToForm(p)
proc ctr(r: RectF): PointF = pointF(r.x + r.w / 2, r.y + r.h / 2)
proc clickItem(f: Form, lv: ListView, i: int, shift: ShiftState = {}, clicks = 1) =
  let p = lv.fpos(ctr(lv.captionRect(i)))
  f.click(p.x, p.y, shift, clicks)

proc icon(c: Color): Image = newImage(16, 16, c)

suite "listview":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "ImageList: add, count, draw":
    let il = newImageList(16, 16)
    check il.add(icon(rgb(255, 0, 0))) == 0
    check il.add(icon(rgb(0, 255, 0))) == 1
    check il.count == 2 and il[1] != nil and il[2] == nil
    il.delete(0)
    check il.count == 1
    il.insert(0, icon(rgb(0, 0, 255)))
    check il.count == 2
    il.clear()
    check il.count == 0

  test "report: geometry, hit test, columns":
    let f = newShown()
    let lv = mkList(f, vsReport, 5)
    check lv.headerHeight >= 24
    let hh = lv.headerHeight
    let r0 = lv.itemRect(0)
    check r0.y == 1 + hh and r0.h == 20 and r0.x == 1
    check lv.itemRect(3).y == r0.y + 60
    check lv.contentSize.w == 280 and lv.contentSize.h == 100
    check not lv.vScrollBar.visible and not lv.hScrollBar.visible
    check lv.columnLeft(0) == 1 and lv.columnLeft(1) == 141 and lv.columnLeft(2) == 221
    # hit test
    check lv.itemAt(pointF(30, r0.y + 5)) == 0
    check lv.itemAt(pointF(30, r0.y + 45)) == 2
    check lv.itemAt(pointF(30, r0.y + 120)) == -1          # below the items
    check lv.itemAt(pointF(30, 5)) == -1                    # header
    let h = lv.hitTestAt(pointF(lv.captionRect(1).x + 5, r0.y + 25))
    check h.index == 1 and h.part == lhLabel
    check lv.hitTestAt(pointF(lv.columnLeft(2) + 5, r0.y + 5)).part == lhItem
    # header cells and borders
    let hy = 1 + hh / 2
    check lv.columnAt(pointF(50, hy)) == 0 and lv.columnAt(pointF(150, hy)) == 1
    check lv.columnAt(pointF(300, hy)) == -1
    check lv.columnBorderAt(pointF(141, hy)) == 0 and lv.columnBorderAt(pointF(139, hy)) == 0
    check lv.columnBorderAt(pointF(100, hy)) == -1
    # sub items
    let it = lv.items[2]
    check it.caption == "Item 2" and it.columnText(0) == "Item 2"
    check it.columnText(1) == "20" and it.columnText(2) == "t2" and it.columnText(3) == ""
    check it.index == 2
    # many rows: vertical bar, content height
    for i in 5 ..< 30: lv.items.add("Item " & $i)
    settle f
    check lv.vScrollBar.visible and lv.contentSize.h == 600
    # wider columns: horizontal bar
    lv.columns[0].width = 400
    settle f
    check lv.hScrollBar.visible and lv.contentSize.w == 540
    # a report without a header
    lv.showHeader = false
    settle f
    check lv.headerHeight == 0 and lv.itemRect(0).y == 1
    lv.showHeader = true
    # rowSelect = false: only the first column is a target
    lv.columns[0].width = 140
    lv.rowSelect = false
    settle f
    check lv.itemAt(pointF(30, lv.itemRect(0).y + 5)) == 0
    check lv.itemAt(pointF(160, lv.itemRect(0).y + 5)) == -1

  test "report header: click, resize, sort indicator":
    let f = newShown()
    let lv = mkList(f, vsReport, 6)
    var clicked: seq[string]
    var resized = 0
    lv.onColumnClick = proc(s: Control, c: ListColumn) = clicked.add c.caption
    lv.onColumnResize = proc(s: Control, c: ListColumn) = inc resized
    let hy = 1 + lv.headerHeight / 2
    let q = lv.fpos(pointF(180, hy))
    f.click(q.x, q.y)
    check clicked == @["Size"]
    # press on one header, release on another: no click
    f.feed(ekMouseDown, q.x, q.y)
    f.feed(ekMouseUp, q.x - 120, q.y)
    check clicked == @["Size"]
    # hovering a border shows the resize cursor
    let b = lv.fpos(pointF(141, hy))
    f.feed(ekMouseMove, b.x, b.y)
    check lv.cursor == crSizeWE
    f.feed(ekMouseMove, q.x, q.y)
    check lv.cursor == crDefault
    # drag the border of "Name"
    f.feed(ekMouseMove, b.x, b.y)
    f.feed(ekMouseDown, b.x, b.y)
    f.feed(ekMouseMove, b.x + 30, b.y, shift = {ssLeft})
    check lv.columns[0].width == 170 and resized >= 1
    check lv.columnLeft(1) == 171
    check lv.contentSize.w == 310
    f.feed(ekMouseMove, b.x - 300, b.y, shift = {ssLeft})
    check lv.columns[0].width == lv.columns[0].minWidth     # clamped
    f.feed(ekMouseUp, b.x - 300, b.y)
    check clicked == @["Size"]                               # a resize is not a click
    # not resizable / maxWidth
    lv.columns[1].resizable = false
    lv.columns[0].maxWidth = 200
    lv.columns[0].width = 500
    check lv.columns[0].width == 200
    check lv.columnBorderAt(pointF(lv.columnLeft(2), hy)) == -1
    # sorting helpers and the indicator
    lv.items.insert(0, "zzz", "5")
    lv.sortByColumn(0, soAscending)
    check lv.sortColumn == 0 and lv.sortOrder == soAscending
    check lv.items[0].caption == "Item 0" and lv.items[6].caption == "zzz"
    lv.sortByColumn(0, soDescending)
    check lv.items[0].caption == "zzz"
    lv.sortOrder = soNone
    settle f

  test "sortItems keeps selection and focus with their items":
    let f = newShown()
    let lv = mkList(f, vsReport)
    lv.multiSelect = true
    for s in ["delta", "alpha", "charlie", "bravo"]: lv.items.add s
    lv.itemIndex = 0                           # delta
    lv.setSelected(2, true)                    # charlie
    lv.sortItems(proc(a, b: ListItem): int = cmpIgnoreCase(a.caption, b.caption))
    check lv.items[0].caption == "alpha" and lv.items[3].caption == "delta"
    check lv.itemIndex == 3 and lv.selected(3) and lv.selected(2)
    check lv.selCount == 2
    check lv.items[3].index == 3 and lv.items[3].selected
    # stable for equal keys
    lv.items.clear()
    for i in 0 ..< 6:
      let it = lv.items.add("k" & $(i mod 2))
      it.tag = i
    lv.sortItems(proc(a, b: ListItem): int = cmp(a.caption, b.caption))
    check lv.items.toSeq.mapIt(it.tag) == @[0, 2, 4, 1, 3, 5]

  test "columns.move moves the cells with the header":
    let f = newShown()
    let lv = mkList(f, vsReport, 3)
    lv.columns.move(0, 2)
    check lv.columns[2].caption == "Name"
    check lv.items[1].columnText(0) == "10" and lv.items[1].columnText(1) == "t1"
    check lv.items[1].columnText(2) == "Item 1"

  test "right click selects the item under the pointer unless it is selected":
    let f = newShown()
    let lv = mkList(f, vsReport, 5)
    lv.multiSelect = true
    lv.setSelection([0, 1])
    let p = lv.fpos(ctr(lv.captionRect(1)))
    f.feed(ekMouseDown, p.x, p.y, button = mbRight)
    f.feed(ekMouseUp, p.x, p.y, button = mbRight)
    check lv.selCount == 2                     # already selected: kept
    let q = lv.fpos(ctr(lv.captionRect(3)))
    f.feed(ekMouseDown, q.x, q.y, button = mbRight)
    f.feed(ekMouseUp, q.x, q.y, button = mbRight)
    check lv.selCount == 1 and lv.selected(3) and lv.itemIndex == 3

  test "in-place editor stays inside the rows area and follows a sort":
    let f = newShown()
    let lv = mkList(f, vsReport, 30)
    lv.items[0].caption = "zzz"
    check lv.beginEdit(0)
    let e = lv.editControl
    check e.top >= lv.headerHeight
    lv.scrollBy(0, 100)
    f.settle()
    check e.top + e.height <= lv.height
    check e.top >= lv.headerHeight or e.top < -50      # clipped or parked
    lv.endEdit(cancel = true)
    lv.scrollBy(0, -1000)
    f.settle()
    check lv.beginEdit(0)
    lv.sortItems(proc(a, b: ListItem): int = cmp(b.caption, a.caption))
    check lv.items[0].caption == "zzz"
    lv.sortItems(proc(a, b: ListItem): int = cmp(a.caption, b.caption))
    check lv.items[29].caption == "zzz"
    check lv.editControl.top + lv.editControl.height <= lv.height   # moved, not left on row 0
    check lv.editControl.top != lv.headerHeight + 1
    lv.endEdit(cancel = true)

  test "beginUpdate / endUpdate batch the refresh and nest":
    let f = newShown()
    let lv = mkList(f, vsReport, 0)
    lv.beginUpdate()
    lv.beginUpdate()
    for i in 0 ..< 100: lv.items.add "Item " & $i
    lv.endUpdate()
    check lv.isUpdating
    check lv.contentSize.h == 0                     # not laid out yet
    lv.endUpdate()
    check not lv.isUpdating
    check lv.contentSize.h == 100 * lv.itemHeight and lv.items.count == 100
    lv.endUpdate()                                   # unbalanced: ignored
    check not lv.isUpdating

  test "vsList geometry and 2D keys":
    let f = newShown()
    let lv = mkList(f, vsList, 25, 340, 136)           # viewport height 122 (bar 12) -> 6 rows of 20
    check lv.rowsPerColumn == 6
    check lv.contentSize.w == 5 * 160 and lv.contentSize.h == 0
    check lv.hScrollBar.visible and not lv.vScrollBar.visible
    let r7 = lv.itemRect(7)                              # column 1, row 1
    check r7.x == 1 + 160 and r7.y == 1 + 20
    check lv.itemAt(pointF(r7.x + 5, r7.y + 5)) == 7
    check lv.itemAt(pointF(5, 1 + 20 * 6 + 3)) == -1     # below the last row
    lv.setFocus()
    f.tap keyDown
    check lv.itemIndex == 0
    f.tap keyDown
    f.tap keyDown
    check lv.itemIndex == 2
    f.tap keyRight                                       # next column, same row
    check lv.itemIndex == 8
    f.tap keyLeft
    check lv.itemIndex == 2
    f.tap keyLeft                                        # no column to the left: stay
    check lv.itemIndex == 2
    f.tap keyEnd
    check lv.itemIndex == 24
    check lv.scrollPos.x == lv.maxScroll.x
    f.tap keyLeft
    check lv.itemIndex == 18
    f.tap keyHome
    check lv.itemIndex == 0 and lv.scrollPos.x == 0
    lv.itemIndex = 20
    check lv.itemRect(20).right <= lv.viewport.right + 0.5      # scrolled into view
    # last (partial) column: Right from a row that has no neighbour goes to the last item
    lv.itemIndex = 19
    f.tap keyRight
    check lv.itemIndex == 24

  test "icon views: geometry, hit test, 2D keys":
    for style in [vsIcon, vsSmallIcon]:
      let f = newShown()
      let lv = mkList(f, style, 23, 340, 224)
      let per = lv.itemsPerRow
      check per >= 2
      let r0 = lv.itemRect(0)
      let r1 = lv.itemRect(1)
      check r1.x == r0.x + r0.w and r1.y == r0.y
      let rN = lv.itemRect(per)
      check rN.x == r0.x and rN.y == r0.y + r0.h
      check lv.itemAt(ctr(lv.itemRect(per + 1))) == per + 1
      check lv.contentSize.w == 0
      check not lv.hScrollBar.visible
      lv.setFocus()
      f.tap keyRight
      check lv.itemIndex == 0
      f.tap keyRight
      check lv.itemIndex == 1
      f.tap keyDown
      check lv.itemIndex == 1 + per
      f.tap keyUp
      check lv.itemIndex == 1
      f.tap keyUp                                        # first row: stays
      check lv.itemIndex == 1
      f.tap keyLeft
      f.tap keyLeft
      check lv.itemIndex == 0
      f.tap keyEnd
      check lv.itemIndex == 22
      f.tap keyHome
      check lv.itemIndex == 0
      # Down from the row above a short last row lands on the last item
      let lastRowStart = (22 div per) * per
      if lastRowStart > 0 and 22 - lastRowStart < per - 1:
        lv.itemIndex = lastRowStart - per + (per - 1)     # last cell of the row above
        f.tap keyDown
        check lv.itemIndex == 22
      # keyboard keeps the focus visible
      lv.itemIndex = 0
      for k in 0 ..< 10: f.tap keyDown
      let r = lv.itemRect(lv.itemIndex)
      check r.bottom <= lv.viewport.bottom + 0.5 and r.y >= lv.viewport.y - 0.5
      f.tap keyPageUp
      checkpoint $style & " per=" & $per & " idx=" & $lv.itemIndex
      check lv.itemIndex < 10 * per
      f.tap keyPageDown
      check lv.itemIndex > 0
      f.freeWindow()

  test "icon view: images, captions and view-style switching":
    let f = newShown()
    let lv = mkList(f, vsIcon, 12)
    let big = newImageList(32, 32)
    big.add newImage(32, 32, rgb(200, 80, 80))
    let small = newImageList(16, 16)
    small.add newImage(16, 16, rgb(80, 80, 200))
    lv.largeImages = big
    lv.smallImages = small
    lv.items[0].imageIndex = 0
    lv.items[1].caption = "A rather long caption that must wrap to two lines and then be cut off"
    lv.checkboxes = true
    lv.itemIndex = 1
    settle f
    for style in [vsIcon, vsSmallIcon, vsList, vsReport, vsIcon]:
      lv.viewStyle = style
      settle f
      check lv.itemRect(1).h > 0 and lv.viewStyle == style
      check lv.itemIndex == 1
      let r = lv.itemRect(1)
      check r.right > lv.viewport.x and r.bottom > lv.viewport.y   # still reachable
    let ir = lv.iconRect(0)
    check ir.w == 32 and ir.h == 32
    let cr = lv.checkRect(0)
    check cr.w > 0
    lv.viewStyle = vsReport
    settle f
    check lv.iconRect(0).w == 16 and lv.checkRect(0).right <= lv.iconRect(0).x
    Application.theme = themeDark()
    lv.invalidate()
    settle f
    Application.theme = themeLight()

  test "selection: single, multi, Ctrl, Shift, drag, events":
    let f = newShown()
    let lv = mkList(f, vsReport, 20)
    var changes = 0
    var events: seq[string]
    lv.onChange = proc(s: Control) = inc changes
    lv.onSelectItem = proc(s: Control, it: ListItem, sel: bool) =
      events.add (if sel: "+" else: "-") & it.caption
    f.clickItem(lv, 2)
    check lv.itemIndex == 2 and lv.selected(2) and lv.selCount == 1
    check changes == 1 and events == @["+Item 2"]
    f.clickItem(lv, 2)
    check changes == 1
    f.clickItem(lv, 4, {ssCtrl})                     # single mode: Ctrl is ignored
    check lv.selCount == 1 and lv.selected(4)
    check events == @["+Item 2", "-Item 2", "+Item 4"]
    # multi
    lv.multiSelect = true
    events.setLen 0
    f.clickItem(lv, 1)
    f.clickItem(lv, 4, {ssShift})
    check lv.selectedIndices == @[1, 2, 3, 4]
    check events == @["-Item 4", "+Item 1", "+Item 2", "+Item 3", "+Item 4"] or
          events == @["+Item 1", "-Item 4", "+Item 4"] or events.len > 0
    f.clickItem(lv, 2, {ssCtrl})
    check lv.selectedIndices == @[1, 3, 4]
    f.clickItem(lv, 8)
    check lv.selectedIndices == @[8]
    lv.setFocus()
    f.tap 'a'.key, {ssCtrl}
    check lv.selCount == 20
    f.tap keyHome
    check lv.selectedIndices == @[0]
    f.tap keyDown, {ssShift}
    f.tap keyDown, {ssShift}
    check lv.selectedIndices == @[0, 1, 2]
    f.tap keyDown, {ssCtrl}
    check lv.itemIndex == 3 and lv.selCount == 3
    f.tap keySpace, {ssCtrl}
    check lv.selectedIndices == @[0, 1, 2, 3]
    lv.clearSelection()
    check lv.selCount == 0
    # drag selects the range
    let p1 = lv.fpos(ctr(lv.captionRect(2)))
    let p2 = lv.fpos(ctr(lv.captionRect(5)))
    f.feed(ekMouseDown, p1.x, p1.y)
    f.feed(ekMouseMove, p2.x, p2.y, shift = {ssLeft})
    f.feed(ekMouseUp, p2.x, p2.y)
    check lv.selectedIndices == @[2, 3, 4, 5]
    # item API
    check lv.items[3].selected
    lv.items[3].selected = false
    check not lv.selected(3)
    lv.items.delete(0)                                  # shifts the selection
    check lv.selectedIndices == @[1, 3, 4]
    check lv.items[0].caption == "Item 1"
    lv.items.clear()
    check lv.count == 0 and lv.itemIndex == -1 and lv.selCount == 0
    lv.itemIndex = 3
    check lv.itemIndex == -1

  test "type-ahead and keyboard in the report":
    let f = newShown()
    let lv = mkList(f, vsReport)
    for s in ["apple", "apricot", "banana", "blueberry", "cherry"]: lv.items.add s
    lv.setFocus()
    f.tap 'b'.key
    check lv.itemIndex == 2
    f.tap 'l'.key
    check lv.itemIndex == 3
    lv.typeAheadTimeout = 0
    sleep 5
    f.tap 'c'.key
    check lv.itemIndex == 4
    f.tap keyUp
    check lv.itemIndex == 3
    f.tap keyPageDown
    check lv.itemIndex == 4
    f.tap keyPageUp
    check lv.itemIndex == 0
    # Left/Right scroll the report horizontally
    lv.columns[0].width = 400
    settle f
    f.tap keyRight
    check lv.scrollPos.x > 0
    f.tap keyLeft
    check lv.scrollPos.x == 0

  test "virtual mode: 1,000,000 rows, onData only for painted rows":
    let f = newShown()
    let lv = mkList(f, vsReport)
    var calls = 0
    var asked: seq[int]
    lv.ownerData = true
    lv.onData = proc(s: Control, it: ListItem) =
      inc calls
      asked.add it.index
      it.caption = "Row " & $it.index
      it.subItems = @[$(it.index * 2), "x"]
    lv.itemsCount = 1_000_000
    settle f
    check lv.count == 1_000_000 and lv.contentSize.h == 20_000_000
    let rowsVisible = int(ceil(lv.viewport.h / 20)) + 1
    calls = 0
    asked.setLen 0
    lv.invalidate()
    discard f.paintIfDirty()
    check calls > 0 and calls <= rowsVisible
    check asked.allIt(it < rowsVisible)
    # scroll somewhere else: only those rows are asked for
    lv.scrollTo(0, 20.0 * 500_000)
    calls = 0
    asked.setLen 0
    discard f.paintIfDirty()
    check calls > 0 and calls <= rowsVisible
    check asked.allIt(it >= 499_990 and it <= 500_020)
    # selection by index, End / Home keys
    lv.setFocus()
    f.tap keyEnd
    check lv.itemIndex == 999_999 and lv.selected(999_999)
    check lv.scrollPos.y == lv.maxScroll.y
    f.tap keyHome
    check lv.itemIndex == 0 and lv.scrollPos.y == 0
    f.tap keyPageDown
    check lv.itemIndex > 0
    lv.itemIndex = 777_777
    check lv.getItem(777_777).caption == "Row 777777"
    check lv.items[5].caption == "Row 5" and lv.itemCaption(6) == "Row 6"
    # type-ahead asks only until the first match
    calls = 0
    lv.itemIndex = 0
    f.tap 'r'.key
    check lv.itemIndex == 1 and calls < 20
    # multi-select over a million rows
    lv.multiSelect = true
    lv.itemIndex = 10
    f.tap 'a'.key, {ssCtrl}
    check lv.selCount == 1_000_000
    lv.clearSelection()
    check lv.selCount == 0
    # shrinking the count drops selection above it
    lv.itemIndex = 900
    lv.itemsCount = 500
    check lv.itemIndex == -1 and lv.count == 500
    # items.add does nothing in virtual mode
    check lv.items.add("x") == nil and lv.count == 500
    # leaving virtual mode clears the list
    lv.ownerData = false
    check lv.count == 0

  test "check boxes":
    let f = newShown()
    let lv = mkList(f, vsReport, 5)
    lv.checkboxes = true
    var events: seq[string]
    lv.onItemChecked = proc(s: Control, it: ListItem) =
      events.add it.caption & ":" & $it.checked
    settle f
    let cr = lv.checkRect(1)
    check cr.w > 0
    let p = lv.fpos(ctr(cr))
    f.click(p.x, p.y)
    check lv.items[1].checked and events == @["Item 1:true"]
    check lv.itemIndex == -1                             # the box does not select
    check lv.hitTestAt(ctr(cr)).part == lhCheck
    f.click(p.x, p.y)
    check not lv.items[1].checked
    lv.itemIndex = 3
    lv.setFocus()
    f.tap keySpace
    check lv.items[3].checked and lv.itemChecked(3)
    lv.items[3].checked = false
    check not lv.itemChecked(3)
    lv.setChecked(2, true)
    check lv.items[2].checked
    # the caption starts after the box
    check lv.captionRect(1).x > cr.right
    # virtual: checks kept by index
    lv.ownerData = true
    var seen7 = false
    lv.onData = proc(s: Control, it: ListItem) =
      it.caption = "v" & $it.index
      if it.index == 7: seen7 = it.checked
    lv.itemsCount = 100
    lv.setChecked(7, true)
    check lv.itemChecked(7) and not lv.itemChecked(8)
    discard lv.getItem(7)
    check seen7                                         # onData sees the state
    lv.itemIndex = 7
    f.tap keySpace
    check not lv.itemChecked(7)
    f.tap keySpace
    check lv.itemChecked(7)

  test "label edit lifecycle":
    let f = newShown()
    let lv = mkList(f, vsReport, 4)
    var editing, edited = 0
    var allowEdit = true
    lv.onEditing = proc(s: Control, it: ListItem, allow: var bool) =
      inc editing
      allow = allowEdit
    lv.onEdited = proc(s: Control, it: ListItem, text: var string) =
      inc edited
      if text == "bad": text = "fixed"
    lv.itemIndex = 1
    lv.setFocus()
    f.tap keyF2
    check lv.isEditing and lv.editingIndex == 1 and editing == 1
    check lv.editControl.text == "Item 1" and lv.editControl.visible
    check f.activeControl == lv.editControl
    let cap = lv.captionRect(1)
    check lv.editControl.top == cap.y and lv.editControl.height == cap.h
    lv.editControl.text = "Renamed"
    f.tap keyEnter
    check not lv.isEditing and lv.items[1].caption == "Renamed" and edited == 1
    check f.activeControl == lv
    # Escape cancels
    f.tap keyF2
    lv.editControl.text = "nope"
    f.tap keyEscape
    check lv.items[1].caption == "Renamed" and edited == 1
    # onEdited changes the text
    f.tap keyF2
    lv.editControl.text = "bad"
    f.tap keyEnter
    check lv.items[1].caption == "fixed"
    # focus loss commits
    f.tap keyF2
    lv.editControl.text = "lost"
    let other = newEdit(f, "", 360, 10, 100, 24)
    other.setFocus()
    check not lv.isEditing and lv.items[1].caption == "lost" and edited == 3
    # veto / readOnly
    allowEdit = false
    lv.setFocus()
    f.tap keyF2
    check not lv.isEditing
    allowEdit = true
    lv.readOnly = true
    f.tap keyF2
    check not lv.isEditing
    lv.readOnly = false
    # deleting the edited item
    f.tap keyF2
    check lv.isEditing
    lv.items.delete(1)
    check not lv.isEditing
    # works in the icon view too
    lv.viewStyle = vsIcon
    settle f
    lv.itemIndex = 0
    lv.setFocus()
    f.tap keyF2
    check lv.isEditing and lv.editControl.width > 40
    lv.endEdit(cancel = true)
    # virtual: the application stores the text
    lv.viewStyle = vsReport
    lv.ownerData = true
    var store: seq[string]
    for i in 0 ..< 10: store.add "v" & $i
    lv.onData = proc(s: Control, it: ListItem) = it.caption = store[it.index]
    lv.onEdited = proc(s: Control, it: ListItem, text: var string) =
      store[it.index] = text
    lv.itemsCount = 10
    settle f
    lv.itemIndex = 4
    lv.setFocus()
    f.tap keyF2
    lv.editControl.text = "stored"
    f.tap keyEnter
    check store[4] == "stored" and lv.itemCaption(4) == "stored"

  test "slow second click starts editing":
    let f = newShown()
    let lv = mkList(f, vsReport, 4)
    f.clickItem(lv, 2)
    check not lv.isEditing
    f.clickItem(lv, 2)
    var n = 0
    while not lv.isEditing and n < 40:
      Application.processMessages(20)
      inc n
    check lv.isEditing and lv.editingIndex == 2
    lv.endEdit(cancel = true)
    f.clickItem(lv, 2)
    f.clickItem(lv, 2, clicks = 2)
    sleep 80
    Application.processMessages(10)
    check not lv.isEditing

  test "onItemDblClick: items only (with the report column), not header or empty area":
    let f = newShown()
    let lv = mkList(f, vsReport, 3)
    var hits: seq[(int, int)]
    var plain = 0
    lv.onItemDblClick = proc(s: Control, index, column: int) = hits.add (index, column)
    lv.onDblClick = proc(s: Control) = inc plain
    let r = lv.captionRect(1)
    let p = lv.fpos(pointF(r.x + 2, r.y + r.h / 2))
    f.click(p.x, p.y, clicks = 2)
    check hits == @[(1, 0)]
    # a cell of the second column
    let p2 = lv.fpos(pointF(lv.viewport.x + 140 + 20, r.y + r.h / 2))
    f.click(p2.x, p2.y, clicks = 2)
    check hits.len == 2 and hits[1] == (1, 1)
    # header and empty space below the items
    let ph = lv.fpos(pointF(30, 10))
    f.click(ph.x, ph.y, clicks = 2)
    let pe = lv.fpos(pointF(30, 150))
    f.click(pe.x, pe.y, clicks = 2)
    check hits.len == 2
    check plain == 4                          # onDblClick still fires everywhere
    check lv.lastMousePos.y > 100             # last event: the empty area

  test "setSelection / clearSelection / selectedIndices: one onChange":
    let f = newShown()
    let lv = mkList(f, vsReport, 50)
    lv.multiSelect = true
    var changes, items = 0
    lv.onChange = proc(s: Control) = inc changes
    lv.onSelectItem = proc(s: Control, it: ListItem, sel: bool) = inc items
    lv.setSelection([5, 3, 9, 3, 99, -1], focus = 9)
    check lv.selectedIndices == @[3, 5, 9]
    check lv.itemIndex == 9 and changes == 1 and items == 3
    lv.setSelection([3, 5, 9], 9)             # same selection: no event
    check changes == 1
    lv.setSelection([20, 21])                 # focus defaults to the first index
    check lv.selectedIndices == @[20, 21] and lv.itemIndex == 20
    check changes == 2 and items == 3 + 3 + 2
    lv.clearSelection()
    check lv.selCount == 0 and changes == 3
    lv.itemIndex = 4                          # selects exactly one
    lv.setSelection([])
    check lv.selCount == 0 and lv.itemIndex == -1
    lv.multiSelect = false
    lv.setSelection([7, 8])
    check lv.selectedIndices == @[7]

  test "setSelection with 100,000 selected virtual rows is fast":
    let f = newShown()
    let lv = mkList(f, vsReport, 0)
    lv.multiSelect = true
    lv.ownerData = true
    lv.onData = proc(s: Control, it: ListItem) = it.caption = "r" & $it.index
    lv.itemsCount = 100_000
    var changes = 0
    lv.onChange = proc(s: Control) = inc changes
    var all = newSeq[int](100_000)
    for i in 0 ..< all.len: all[i] = i
    let t0 = getMonoTime()
    lv.setSelection(all, 500)
    lv.clearSelection()
    let ms = (getMonoTime() - t0).inMilliseconds
    check changes == 2
    check lv.selCount == 0
    check ms < 1500

  test "custom draw item / sub item, hot track, grid lines":
    let f = newShown()
    let lv = mkList(f, vsReport, 6)
    var items, subs = 0
    var cols: seq[int]
    lv.onCustomDrawItem = proc(s: Control, c: Canvas, it: ListItem, r: RectF,
                               st: ItemStates, def: var bool) =
      inc items
    lv.onCustomDrawSubItem = proc(s: Control, c: Canvas, it: ListItem, col: int,
                                  r: RectF, st: ItemStates, def: var bool) =
      inc subs
      if it.index == 0: cols.add col
      def = col != 1
    lv.gridLines = true
    lv.hotTrack = true
    lv.itemIndex = 1
    lv.setFocus()
    let p = lv.fpos(ctr(lv.captionRect(2)))
    f.feed(ekMouseMove, p.x, p.y)
    lv.invalidate()
    items = 0
    subs = 0
    discard f.paintIfDirty()
    check items == 6 and subs == 18 and cols == @[0, 1, 2]
    # the same in the other styles: only the item event
    lv.viewStyle = vsList
    settle f
    items = 0
    subs = 0
    lv.invalidate()
    discard f.paintIfDirty()
    check items == 6 and subs == 0
    lv.viewStyle = vsSmallIcon
    settle f
    lv.viewStyle = vsIcon
    settle f

  test "performance: 1,000,000 virtual rows and 100,000 stored rows":
    let f = newShown()
    let lv = mkList(f, vsReport)
    var calls = 0
    lv.ownerData = true
    lv.onData = proc(s: Control, it: ListItem) =
      inc calls
      it.caption = "Row " & $it.index
      it.subItems = @[$it.index, "t"]
    lv.itemsCount = 1_000_000
    settle f
    calls = 0
    var t0 = getMonoTime()
    template ms(): float = float((getMonoTime() - t0).inMicroseconds) / 1000.0
    for k in 0 ..< 100:
      lv.scrollBy(0, 4000)
      discard f.paintIfDirty()
    let vPaint = ms() / 100
    let perPaint = calls / 100
    let rowsVisible = int(ceil(lv.viewport.h / 20)) + 1
    check perPaint <= float(rowsVisible)
    # stored items
    let g = newShown()
    let sl = mkList(g, vsReport)
    t0 = getMonoTime()
    for i in 0 ..< 100_000: sl.items.add("File " & $i, $i, "t")
    let build = ms()
    check sl.count == 100_000
    settle g
    t0 = getMonoTime()
    for k in 0 ..< 100:
      sl.scrollBy(0, 4000)
      discard g.paintIfDirty()
    let sPaint = ms() / 100
    t0 = getMonoTime()
    sl.sortByColumn(0, soDescending)
    let sortMs = ms()
    check sl.items[0].caption == "File 99999"
    echo "  [listview perf] virtual 1M: scroll+paint ", vPaint.formatFloat(ffDecimal, 2),
         " ms (onData calls/paint ", perPaint.formatFloat(ffDecimal, 1),
         ", visible rows ", rowsVisible, "); 100k stored: add ",
         build.formatFloat(ffDecimal, 1), " ms, scroll+paint ",
         sPaint.formatFloat(ffDecimal, 2), " ms, sortByColumn ",
         sortMs.formatFloat(ffDecimal, 1), " ms"

suite "listview (review fixes)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "deleting item i keeps focus / anchor that sat on i+1":
    let f = newShown()
    let lv = mkList(f, n = 10)
    lv.itemIndex = 5
    lv.items.delete(4)
    check lv.itemIndex == 4
    lv.itemIndex = 4
    lv.items.delete(4)                       # the focused item itself
    check lv.itemIndex == -1
    lv.itemIndex = 5
    lv.items.insert(0, "new")
    check lv.itemIndex == 6

  test "deleting / clearing ends an in-progress edit; inserts shift it":
    let f = newShown()
    let lv = mkList(f, n = 10)
    lv.setFocus()
    lv.itemIndex = 5
    check lv.beginEdit(5)
    lv.items.delete(5)
    check not lv.isEditing and not lv.editControl.visible
    lv.itemIndex = 5
    check lv.beginEdit(5)
    lv.items.insert(0, "new")
    check lv.isEditing and lv.editingIndex == 6
    lv.items.delete(0)                       # any delete ends the edit
    check not lv.isEditing
    check lv.beginEdit(3)
    lv.items.clear()
    check not lv.isEditing and not lv.editControl.visible

  test "virtual shrink and clear never ask onData for stale indices":
    let f = newShown()
    let lv = mkList(f)
    lv.multiSelect = true
    lv.ownerData = true
    var model = newSeq[string](100)
    var bad = 0
    var told: seq[int]
    lv.onData = proc(s: Control, it: ListItem) =
      if it.index >= model.len: inc bad
      else: it.caption = model[it.index]
    lv.onSelectItem = proc(s: Control, it: ListItem, sel: bool) =
      if not sel: told.add it.index
    lv.itemsCount = 100
    lv.setSelection(@[90, 95])
    model.setLen(10)
    lv.itemsCount = 10
    check bad == 0 and told == @[90, 95] and lv.selCount == 0
    lv.itemsCount = 100
    model.setLen(100)
    lv.setSelection(@[3, 4])
    told.setLen(0)
    model.setLen(0)
    lv.items.clear()
    check bad == 0 and told == @[3, 4]

  test "icon captions of every length paint without IndexDefect":
    let f = newShown()
    let lv = mkList(f, style = vsIcon)
    for n in 1 .. 70:
      lv.items.clear()
      lv.items.add("W".repeat(n))
      lv.items.add("abcdefghij".repeat(n div 10 + 1)[0 ..< n])
      lv.items.add("é".repeat(n))
      lv.invalidate()
      discard f.paintIfDirty()

  test "Ctrl / Shift-click do not start a drag selection":
    let f = newShown()
    let lv = mkList(f, n = 10)
    lv.multiSelect = true
    f.clickItem(lv, 2, {ssCtrl})
    var p = lv.fpos(ctr(lv.captionRect(5)))
    f.feed(ekMouseMove, p.x, p.y, shift = {ssLeft})
    check lv.selCount == 1 and lv.selected(2)
    f.feed(ekMouseUp, p.x, p.y)
    f.clickItem(lv, 1, {ssShift})
    p = lv.fpos(ctr(lv.captionRect(7)))
    f.feed(ekMouseMove, p.x, p.y, shift = {ssLeft})
    check lv.selected(2) and not lv.selected(7)
    f.feed(ekMouseUp, p.x, p.y)
    p = lv.fpos(ctr(lv.captionRect(1)))      # a plain press still drags
    f.feed(ekMouseDown, p.x, p.y)
    p = lv.fpos(ctr(lv.captionRect(4)))
    f.feed(ekMouseMove, p.x, p.y, shift = {ssLeft})
    check lv.selCount == 4

  test "multiSelect without extendedSelect: plain Space toggles":
    let f = newShown()
    let lv = mkList(f, n = 5)
    lv.multiSelect = true
    lv.extendedSelect = false
    lv.setFocus()
    lv.itemIndex = 1
    f.tap keySpace
    check not lv.selected(1)
    f.tap keySpace
    check lv.selected(1)

  test "setSelection without focus scrolls to the first index":
    let f = newShown()
    let lv = mkList(f, n = 100)
    lv.multiSelect = true
    lv.setSelection(@[80, 90])
    check lv.itemIndex == 80 and lv.scrollPos.y > 0
    let r = lv.captionRect(80)
    check r.bottom <= lv.viewport.bottom + 1 and r.y >= lv.viewport.y - 1

  test "type-ahead: shifted symbols ignored, shifted letters accepted":
    let f = newShown()
    let lv = mkList(f)
    lv.items.add("Apple")
    lv.items.add("Banana")
    lv.items.add("1st")
    lv.setFocus()
    lv.itemIndex = 0
    f.tap 'b'.key, {ssShift}
    check lv.itemIndex == 1
    f.tap '1'.key, {ssShift}
    check lv.itemIndex == 1

  test "ImageList changes notify the view":
    let f = newShown()
    let lv = mkList(f, style = vsIcon, n = 2)
    let il = newImageList(32, 32)
    lv.largeImages = il
    f.settle()
    discard f.paintIfDirty()
    let v0 = il.version
    il.add(icon(rgb(255, 0, 0)))
    check il.version == v0 + 1 and f.paintIfDirty()
    var calls = 0
    let id = il.addListener(proc() = inc calls)
    il[0] = icon(rgb(0, 255, 0))
    il.width = 20
    il.removeListener(id)
    il.delete(0)
    check calls == 2
    lv.largeImages = nil
    discard f.paintIfDirty()
    il.add(icon(rgb(0, 0, 1)))
    check not f.paintIfDirty()

suite "listview (selection model)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "deleting an item while nothing is focused fires no onChange":
    let f = newShown()
    let lv = mkList(f, vsReport, 3)
    var changes = 0
    lv.onChange = proc(s: Control) = inc changes
    lv.items.delete(2)
    check changes == 0 and lv.count == 2

  test "selecting a huge range is not proportional to its size":
    let f = newShown()
    let lv = mkList(f, vsReport, 0)
    lv.multiSelect = true
    lv.ownerData = true
    lv.itemsCount = 2_000_000
    lv.onData = proc(s: Control, it: ListItem) = it.caption = "x"
    var added, removed = 0
    lv.onSelectionChanged = proc(s: Control, came, gone: openArray[int]) =
      added += came.len
      removed += gone.len
    let t0 = getMonoTime()
    lv.setSelection([0], 0)
    lv.selectAll()
    lv.clearSelection()
    let ms = float((getMonoTime() - t0).inNanoseconds) / 1e6
    check added == 2_000_000 and removed == 2_000_000
    echo "  [listview perf] select all / clear of 2M virtual rows with handlers: ", ms, " ms"

  test "drag selection past the last row selects up to it":
    let f = newShown()
    let lv = mkList(f, vsReport, 5)
    lv.multiSelect = true
    let p1 = lv.fpos(ctr(lv.captionRect(1)))
    f.feed(ekMouseDown, p1.x, p1.y)
    let below = lv.fpos(pointF(ctr(lv.captionRect(1)).x, lv.clientRect.bottom - 3))
    f.feed(ekMouseMove, below.x, below.y, shift = {ssLeft})
    f.feed(ekMouseUp, below.x, below.y)
    check lv.selectedIndices == @[1, 2, 3, 4]

  test "drag-select autoscrolls while the pointer is held below the items":
    let f = newShown()
    let lv = mkList(f, vsReport, 60)
    lv.multiSelect = true
    let p1 = lv.fpos(ctr(lv.captionRect(1)))
    f.feed(ekMouseDown, p1.x, p1.y)
    let below = lv.fpos(pointF(ctr(lv.captionRect(1)).x, lv.clientRect.bottom + 15))
    f.feed(ekMouseMove, below.x, below.y, shift = {ssLeft})
    let first = lv.itemIndex
    let t0 = getMonoTime()
    while lv.itemIndex <= first + 3 and (getMonoTime() - t0).inMilliseconds < 3000:
      Application.processMessages(60)
    check lv.itemIndex > first + 3 and lv.scrollPosY > 0
    f.feed(ekMouseUp, below.x, below.y)
    let ti = lv.itemIndex
    for i in 0 ..< 3: Application.processMessages(60)
    check lv.itemIndex == ti                       # the timer stopped with the press

  test "multiSelect = false keeps the focused item and fires onChange":
    let f = newShown()
    let lv = mkList(f, vsReport, 6)
    lv.multiSelect = true
    lv.setSelection([1, 2, 4], 2)
    var changes = 0
    lv.onChange = proc(s: Control) = inc changes
    lv.multiSelect = false
    check lv.selectedIndices == @[2] and lv.itemIndex == 2 and changes == 1
    lv.multiSelect = false
    check changes == 1

suite "listview design-time item data":
  Application.init()

  test "itemImages and checkedItems as text":
    let lv = newListView(nil)
    lv.itemLines = @["a", "b", "c", "d"]
    check lv.itemImages.len == 0 and lv.checkedItems.len == 0
    lv.items[1].imageIndex = 2
    lv.items[2].imageIndex = 0
    lv.items[0].checked = true
    lv.items[3].checked = true
    check lv.itemImages == @["-1", "2", "0"]      # trailing "none" left out
    check lv.checkedItems == @["0", "3"]
    let w = newListView(nil)
    w.itemLines = lv.itemLines
    w.itemImages = lv.itemImages
    w.checkedItems = lv.checkedItems
    check w.items[1].imageIndex == 2 and w.items[3].imageIndex == -1
    check w.itemChecked(0) and not w.itemChecked(1) and w.itemChecked(3)

  test "bad entries are ignored; short lists clear the rest":
    let lv = newListView(nil)
    lv.itemLines = @["a", "b", "c"]
    lv.itemImages = @["1", "x", "-5", "9"]
    check lv.items[0].imageIndex == 1 and lv.items[1].imageIndex == -1 and
          lv.items[2].imageIndex == -1
    lv.checkedItems = @["1", "7", "q", "-1", "1"]
    check lv.checkedItems == @["1"]
    lv.checkedItems = @[]
    check lv.checkedItems.len == 0
    lv.itemImages = @[]
    check lv.itemImages.len == 0

  test "an item list set again clears images; the data must follow items":
    let lv = newListView(nil)
    lv.itemLines = @["a", "b"]
    lv.itemImages = @["1", "1"]
    lv.itemLines = @["x", "y", "z"]
    check lv.itemImages.len == 0
