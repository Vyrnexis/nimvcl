## Huge virtual lists: float64 scroll precision (5,000,000 rows, far beyond the
## 16.7M pixels float32 can address exactly) and the batched selection event.
## Headless (offscreen SDL), events built by hand.

import std/[unittest, sequtils]
import nimvcl
import nimvcl/controls/[scrolling, listbox, listview, grids, treeview]

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))
proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k,
                                     shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k,
                                     shift: shift))
proc settle(f: Form) =
  discard f.paintIfDirty()
  f.layoutIfNeeded()
  discard f.paintIfDirty()
proc newShown(w = 500'f32, h = 400'f32): Form =
  result = newForm(nil, w, h)
  result.show()

const N = 5_000_000

suite "huge scroll precision":
  test "ListBox: 5,000,000 rows scroll to the exact pixel":
    let f = newShown()
    let lb = newListBox(f, 10, 10, 200, 302)
    lb.itemHeight = 26
    var maxAsked = -1
    var minAsked = high(int)
    lb.onData = proc(s: Control, i: int): string =
      maxAsked = max(maxAsked, i)
      minAsked = min(minAsked, i)
      "Row " & $i
    lb.count = N
    f.settle()
    check lb.contentH == float64(N) * 26
    let vp = lb.viewport
    # the end: the last row's bottom edge is the viewport bottom, exactly
    lb.scrollTo(0, 1e18)
    check lb.scrollPosY == lb.maxScrollY
    check lb.scrollPosY == float64(N) * 26 - float64(vp.h)
    check lb.itemRect(N - 1).bottom == vp.bottom
    check lb.indexAt(pointF(vp.x + 3, vp.bottom - 2)) == N - 1
    minAsked = high(int); maxAsked = -1
    lb.invalidate()
    discard f.paintIfDirty()
    check maxAsked == N - 1 and minAsked >= N - 14
    # arbitrary rows: the row painted at the top is exactly that row
    for row in [1, 777_777, 1_234_567, 2_500_001, 3_333_333, 4_999_000, 4_999_980]:
      lb.topIndex = row
      check lb.topIndex == row
      check lb.itemRect(row).y == vp.y
      check lb.scrollPosY == float64(row) * 26
      for k in 0 .. 5:
        let r = lb.itemRect(row + k)
        check r.y == vp.y + float32(k * 26)
        check lb.indexAt(pointF(vp.x + 3, r.y + 5)) == row + k
      minAsked = high(int); maxAsked = -1
      lb.invalidate()
      discard f.paintIfDirty()
      check minAsked == row and maxAsked <= row + 12
    # PageDown steps exactly one page, many times, at a huge offset
    lb.itemIndex = 3_000_000
    lb.setFocus()
    var prev = lb.itemIndex
    f.tap keyPageDown
    let step = lb.itemIndex - prev
    check step > 0
    for k in 0 ..< 6:
      prev = lb.itemIndex
      f.tap keyPageDown
      check lb.itemIndex - prev == step
      let r = lb.itemRect(lb.itemIndex)
      check r.y >= vp.y and r.bottom <= vp.bottom
      check lb.indexAt(pointF(vp.x + 3, r.y + 4)) == lb.itemIndex
    f.tap keyEnd
    check lb.itemIndex == N - 1
    check lb.itemRect(N - 1).bottom == vp.bottom
    f.tap keyHome
    check lb.itemIndex == 0 and lb.scrollPosY == 0
    # the wheel moves exactly 3 lines of 26 px at a huge offset
    lb.topIndex = 4_000_000
    let before = lb.scrollPosY
    Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: f.win.id,
                                       x: 50, y: 50, dx: 0, dy: -1))
    check lb.scrollPosY - before == 78.0

  test "ScrollBar position is float64 and drives the control":
    let f = newShown()
    let lb = newListBox(f, 10, 10, 200, 302)
    lb.itemHeight = 26
    lb.onData = proc(s: Control, i: int): string = $i
    lb.count = N
    f.settle()
    let bar = lb.vScrollBar
    check bar.position64 == 0
    bar.setPosition64(1e12)
    check lb.scrollPosY == lb.maxScrollY
    check bar.position64 == lb.maxScrollY
    bar.setPosition64(65_000_001.0)          # odd pixel: float32 would round it
    check lb.scrollPosY == 65_000_001.0

  test "ListView report: 5,000,000 rows":
    let f = newShown()
    let lv = newListView(f, 10, 10, 340, 224)
    lv.itemHeight = 20
    lv.columns.add("Name", 140)
    lv.viewStyle = vsReport
    lv.ownerData = true
    var maxAsked = -1
    var minAsked = high(int)
    lv.onData = proc(s: Control, it: ListItem) =
      maxAsked = max(maxAsked, it.index)
      minAsked = min(minAsked, it.index)
      it.caption = "R" & $it.index
    lv.itemsCount = N
    f.settle()
    check lv.contentH == float64(N) * 20
    let vp = lv.viewport
    lv.scrollTo(0, 1e18)
    check lv.scrollPosY == lv.maxScrollY
    check lv.itemRect(N - 1).bottom == vp.bottom
    check lv.itemAt(pointF(vp.x + 5, vp.bottom - 2)) == N - 1
    for row in [3, 999_999, 1_234_567, 2_222_223, 4_999_900]:
      lv.itemIndex = row                   # makeVisible, selects
      let r = lv.itemRect(row)
      check r.y >= vp.y and r.bottom <= vp.bottom
      check lv.itemAt(pointF(vp.x + 5, r.y + 3)) == row
      check lv.itemAt(pointF(vp.x + 5, r.bottom - 1)) == row
      lv.scrollTo(0, float64(row) * 20)
      check lv.itemRect(row).y == vp.y
      minAsked = high(int); maxAsked = -1
      lv.invalidate()
      discard f.paintIfDirty()
      check minAsked == row and maxAsked <= row + 12
    lv.setFocus()
    lv.itemIndex = 2_000_000
    var prev = lv.itemIndex
    f.tap keyPageDown
    let step = lv.itemIndex - prev
    check step > 0
    for k in 0 ..< 5:
      prev = lv.itemIndex
      f.tap keyPageDown
      check lv.itemIndex - prev == step
      check lv.itemAt(pointF(vp.x + 5, lv.itemRect(lv.itemIndex).y + 3)) == lv.itemIndex

  test "ListView icon and list styles: 5,000,000 items":
    let f = newShown()
    let lv = newListView(f, 10, 10, 340, 224)
    lv.ownerData = true
    lv.onData = proc(s: Control, it: ListItem) = it.caption = "I" & $it.index
    lv.itemsCount = N
    for st in [vsIcon, vsSmallIcon, vsList]:
      lv.viewStyle = st
      f.settle()
      let vp = lv.viewport
      lv.scrollTo(1e18, 1e18)
      check lv.scrollPosX == lv.maxScrollX and lv.scrollPosY == lv.maxScrollY
      let r = lv.itemRect(N - 1)
      check r.right <= vp.right + 0.01 and r.bottom <= vp.bottom + 0.01
      check lv.itemAt(pointF(r.x + 2, r.y + 2)) == N - 1
      for row in [12_345, 2_500_000, 4_999_999]:
        lv.itemIndex = row
        let q = lv.itemRect(row)
        check q.x >= vp.x - 0.01 and q.right <= vp.right + 0.01
        check q.y >= vp.y - 0.01 and q.bottom <= vp.bottom + 0.01
        check lv.itemAt(pointF(q.x + 2, q.y + 2)) == row

  test "DrawGrid: 5,000,000 rows":
    let f = newShown()
    let g = newDrawGrid(f, 10, 10, 400, 300)
    g.colCount = 3
    g.rowCount = N
    g.fixedRows = 1
    f.settle()
    let vp = g.viewport
    check g.contentH == float64(N) * 24
    g.scrollTo(0, 1e18)
    check g.scrollPosY == g.maxScrollY
    check g.rowY(N - 1) + 24 == vp.bottom
    check g.cellAt(pointF(vp.x + 70, vp.bottom - 2)) == (1, N - 1)
    for row in [2, 1_000_003, 2_500_000, 4_999_900]:
      g.topRow = row
      check g.topRow == row
      check g.rowY(row) == vp.y + 24
      check g.cellAt(pointF(vp.x + 70, g.rowY(row) + 3)) == (1, row)
      check g.cellAt(pointF(vp.x + 70, g.rowY(row + 3) + 23)) == (1, row + 3)
    g.makeVisible(0, 3_100_000)
    check g.rowY(3_100_000) >= vp.y + 24 and g.rowY(3_100_000) + 24 <= vp.bottom
    g.row = 3_000_000
    g.setFocus()
    f.settle()
    var prev = g.row
    f.tap keyPageDown
    let step = g.row - prev
    check step > 0
    for k in 0 ..< 6:
      prev = g.row
      f.tap keyPageDown
      check g.row - prev == step
      let y = g.rowY(g.row)
      check y >= vp.y + 24 and y + 24 <= vp.bottom
      check g.cellAt(pointF(vp.x + 70, y + 3)) == (1, g.row)

  test "TreeView: 1,000,000 rows (22 px: 22,000,000 px)":
    let f = newShown()
    let tv = newTreeView(f, 10, 10, 220, 222)
    tv.itemHeight = 22
    tv.beginUpdate()
    for i in 0 ..< 1_000_000: tv.items.addChild(nil, "n")
    tv.endUpdate()
    f.settle()
    let vp = tv.viewport
    check tv.contentH == 22_000_000.0
    tv.scrollTo(0, 1e18)
    check tv.scrollPosY == tv.maxScrollY
    let last = tv.items.top(999_999)
    check tv.nodeRect(last).bottom == vp.bottom
    check tv.rowAt(pointF(vp.x + 5, vp.bottom - 2)) == 999_999
    for row in [5, 777_777, 999_990]:
      tv.makeRowVisible(row)
      let r = tv.nodeRect(tv.items.top(row))
      check r.y >= vp.y and r.bottom <= vp.bottom
      check tv.rowAt(pointF(vp.x + 5, r.y + 3)) == row

suite "batched selection event":
  proc mk(f: Form, n: int): ListView =
    result = newListView(f, 10, 10, 340, 224)
    result.itemHeight = 20
    result.columns.add("Name", 140)
    result.viewStyle = vsReport
    result.multiSelect = true
    result.ownerData = true
    result.onData = proc(s: Control, it: ListItem) = it.caption = "R" & $it.index
    result.itemsCount = n

  test "selectAll / clearSelection / setSelection: one call for 100,000 rows":
    let f = newShown()
    let lv = f.mk(100_000)
    var batches = 0
    var added, removed: seq[int]
    var changes = 0
    lv.onChange = proc(s: Control) = inc changes
    lv.onSelectionChanged = proc(s: Control, a, r: openArray[int]) =
      inc batches
      added = @a
      removed = @r
    lv.selectAll()
    check batches == 1 and added.len == 100_000 and removed.len == 0 and changes == 1
    check added[0] == 0 and added[^1] == 99_999
    lv.clearSelection()
    check batches == 2 and added.len == 0 and removed.len == 100_000 and changes == 2
    lv.setSelection(toSeq(10 ..< 20))
    check batches == 3 and added == toSeq(10 ..< 20) and removed.len == 0
    lv.setSelection(toSeq(15 ..< 25))
    check batches == 4 and added == toSeq(20 ..< 25) and removed == toSeq(10 ..< 15)
    lv.setSelection(toSeq(15 ..< 25))            # nothing changes: no event
    check batches == 4
    lv.itemIndex = 99
    check batches == 5 and added == @[99] and removed == toSeq(15 ..< 25)
    lv.itemsCount = 50                           # the selected item vanishes
    check batches == 6 and added.len == 0 and removed == @[99]

  test "onSelectItem still fires per item, before onSelectionChanged; nil costs nothing":
    let f = newShown()
    let lv = f.mk(1000)
    var order: seq[string]
    var items = 0
    lv.onSelectItem = proc(s: Control, it: ListItem, sel: bool) =
      inc items
      if items == 1: order.add "item"
    lv.onSelectionChanged = proc(s: Control, a, r: openArray[int]) = order.add "batch"
    lv.onChange = proc(s: Control) = order.add "change"
    lv.selectAll()
    check items == 1000 and order == @["item", "batch", "change"]
    lv.onSelectItem = nil
    items = 0
    lv.clearSelection()
    check items == 0

  test "stored items: clear fires one batch":
    let f = newShown()
    let lv = newListView(f, 10, 10, 340, 224)
    lv.columns.add("Name", 140)
    lv.viewStyle = vsReport
    lv.multiSelect = true
    for i in 0 ..< 20: lv.items.add("x" & $i)
    var removed: seq[int]
    var n = 0
    lv.onSelectionChanged = proc(s: Control, a, r: openArray[int]) =
      inc n
      removed = @r
    lv.setSelection([2, 4, 6])
    check n == 1
    lv.items.clear()
    check n == 2 and removed == @[2, 4, 6]
