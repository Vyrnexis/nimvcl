## ListBox (phase 5). Headless (offscreen SDL), events built by hand.

import std/[unittest, os]
import nimvcl
import nimvcl/controls/[scrollbar, scrolling, scrollbox, listbox]

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))
proc moveTo(f: Form, x, y: float32) = f.feed(ekMouseMove, x, y)
proc click(f: Form, x, y: float32, shift: ShiftState = {}, clicks = 1) =
  f.feed(ekMouseDown, x, y, shift = shift, clicks = clicks)
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

const LB = (x: 10'f32, y: 10'f32)    # list position inside the form

proc rowY(i: int): float32 = LB.y + 1 + float32(i) * 20 + 10   # centre of row i
const rowX = LB.x + 30'f32

proc mkList(f: Form, n: int, h = 202'f32): ListBox =
  ## 150 wide, `h` high (viewport = h - 2), rows of 20 px.
  result = newListBox(f, LB.x, LB.y, 150, h)
  result.itemHeight = 20
  for i in 0 ..< n: result.add "Item " & $i
  settle f

suite "listbox":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "setSelection: one onChange, focus, single mode":
    let f = newShown()
    let lb = mkList(f, 30)
    lb.multiSelect = true
    var changes = 0
    lb.onChange = proc(s: Control) = inc changes
    lb.setSelection([4, 2, 2, 50, -3], focus = 4)
    check lb.selectedIndices == @[2, 4] and lb.itemIndex == 4 and changes == 1
    lb.setSelection([2, 4], 4)
    check changes == 1
    lb.setSelection([10, 11])
    check lb.itemIndex == 10 and lb.selCount == 2 and changes == 2
    lb.setSelection([])
    check lb.selCount == 0 and lb.itemIndex == -1 and changes == 3
    lb.multiSelect = false
    lb.setSelection([6, 7])
    check lb.selectedIndices == @[6]

  test "items API and index bookkeeping":
    let f = newForm(nil, 400, 300)
    f.show()
    let lb = newListBox(f)
    lb.items.add "b"
    lb.add "c"
    lb.items.insert(0, "a")
    check lb.count == 3 and lb.items.len == 3
    check lb[0] == "a" and lb.items[2] == "c"
    lb.itemIndex = 1
    lb.items.insert(0, "z")               # shifts the focused row
    check lb.itemIndex == 2 and lb[2] == "b"
    lb.delete(0)
    check lb.itemIndex == 1
    lb.delete(1)                          # the focused row
    check lb.itemIndex == -1 and lb.selCount == 0
    lb.items = @["x", "y"]
    check lb.count == 2
    lb.clear()
    check lb.count == 0
    lb.itemIndex = 5                      # out of range
    check lb.itemIndex == -1

  test "single selection by mouse, onChange, onClick":
    let f = newShown()
    let lb = mkList(f, 20)
    var changes, clicks = 0
    lb.onChange = proc(s: Control) = inc changes
    lb.onClick = proc(s: Control) = inc clicks
    f.click(rowX, rowY(2))
    check lb.itemIndex == 2 and lb.selected(2) and lb.selCount == 1
    check changes == 1 and clicks == 1
    f.click(rowX, rowY(2))                # same row: no change event
    check changes == 1
    f.click(rowX, rowY(5), shift = {ssShift})   # single mode ignores modifiers
    check lb.itemIndex == 5 and lb.selCount == 1 and not lb.selected(2)
    check changes == 2
    check lb.focused

  test "multi + extended: ctrl toggles, shift ranges":
    let f = newShown()
    let lb = mkList(f, 20)
    lb.multiSelect = true
    f.click(rowX, rowY(1))
    f.click(rowX, rowY(3), shift = {ssCtrl})
    check lb.selectedIndices == @[1, 3]
    f.click(rowX, rowY(6), shift = {ssShift})       # anchor 3 -> 6
    check lb.selectedIndices == @[3, 4, 5, 6]
    f.click(rowX, rowY(4), shift = {ssCtrl})
    check lb.selectedIndices == @[3, 5, 6]
    f.click(rowX, rowY(0))
    check lb.selectedIndices == @[0]
    # keyboard: Shift+Down extends from the anchor, Ctrl+Down only moves focus
    f.tap(keyDown, {ssShift}); f.tap(keyDown, {ssShift})
    check lb.selectedIndices == @[0, 1, 2] and lb.itemIndex == 2
    f.tap(keyUp, {ssShift})
    check lb.selectedIndices == @[0, 1]
    f.tap(keyDown, {ssCtrl})
    check lb.selectedIndices == @[0, 1] and lb.itemIndex == 2
    f.tap(keySpace, {ssCtrl})
    check lb.selectedIndices == @[0, 1, 2]
    f.tap(keyDown)                                  # plain arrow: single again
    check lb.selectedIndices == @[3]
    f.tap('a'.key, {ssCtrl})
    check lb.selCount == 20
    lb.clearSelection()
    check lb.selCount == 0

  test "multi without extended: click toggles":
    let f = newShown()
    let lb = mkList(f, 20)
    lb.multiSelect = true
    lb.extendedSelect = false
    f.click(rowX, rowY(1))
    f.click(rowX, rowY(2))
    check lb.selectedIndices == @[1, 2]
    f.click(rowX, rowY(1))
    check lb.selectedIndices == @[2]
    f.tap(keyDown); f.tap(keyDown)                  # focus only (1 -> 3)
    check lb.itemIndex == 3 and lb.selectedIndices == @[2]
    f.tap(keySpace)
    check lb.selectedIndices == @[2, 3]

  test "drag selects":
    let f = newShown()
    let lb = mkList(f, 20)
    f.feed(ekMouseDown, rowX, rowY(1))
    f.moveTo(rowX, rowY(4))
    check lb.itemIndex == 4
    f.feed(ekMouseUp, rowX, rowY(4))
    check lb.selectedIndices == @[4]

  test "keyboard navigation, partial pages":
    let f = newShown()
    let lb = mkList(f, 100, h = 192)       # viewport 190 = 9.5 rows
    check lb.viewport.h == 190
    lb.setFocus()
    f.tap(keyDown)
    check lb.itemIndex == 0                # from "none" the first key goes to row 0
    f.tap(keyDown); f.tap(keyDown)
    check lb.itemIndex == 2
    f.tap(keyUp)
    check lb.itemIndex == 1
    f.tap(keyHome)
    check lb.itemIndex == 0 and lb.scrollPos.y == 0
    f.tap(keyPageDown)                     # to the last FULLY visible row
    check lb.itemIndex == 8 and lb.scrollPos.y == 0
    f.tap(keyPageDown)                     # a page minus one row, row 16 at the bottom
    check lb.itemIndex == 16 and lb.scrollPos.y == float32(17 * 20 - 190)
    f.tap(keyPageDown)
    check lb.itemIndex == 24
    f.tap(keyPageUp)                       # to the first fully visible row
    check lb.itemIndex == 16
    f.tap(keyPageUp)
    check lb.itemIndex == 8
    check lb.scrollPos.y == 160         # row 8 is at the top
    f.tap(keyEnd)
    check lb.itemIndex == 99
    check lb.scrollPos.y == lb.maxScroll.y and lb.maxScroll.y == 1810
    f.tap(keyDown)
    check lb.itemIndex == 99               # clamped
    f.tap(keyHome)
    check lb.itemIndex == 0 and lb.scrollPos.y == 0

  test "scroll keeps itemIndex visible":
    let f = newShown()
    let lb = mkList(f, 100)
    lb.itemIndex = 50
    let r = lb.itemRect(50)
    check r.y >= lb.viewport.y and r.bottom <= lb.viewport.bottom
    lb.itemIndex = 0
    check lb.scrollPos.y == 0
    lb.setFocus()
    for i in 0 ..< 30: f.tap(keyDown)
    let r2 = lb.itemRect(lb.itemIndex)
    check lb.itemIndex == 30
    check r2.y >= lb.viewport.y and r2.bottom <= lb.viewport.bottom
    check lb.topIndex > 0

  test "wheel scrolls three rows":
    let f = newShown()
    let lb = mkList(f, 100)
    Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: f.win.id,
                                       x: rowX, y: rowY(2), dy: -1))
    check lb.scrollPos.y == 60 and lb.topIndex == 3
    check lb.vScrollBar.visible
    check lb.vScrollBar.position == 60

  test "type-ahead":
    let f = newShown()
    let lb = newListBox(f, 10, 10, 150, 202)
    lb.items = @["apple", "Banana", "blueberry", "cherry", "Cranberry", "date"]
    settle f
    lb.typeAheadTimeout = 80
    lb.setFocus()
    f.tap('b'.key)
    check lb.itemIndex == 1
    f.tap('b'.key)                         # "bb": no match, selection stays
    check lb.itemIndex == 1
    sleep 120
    f.tap('b'.key)                         # a fresh "b": next item starting with b
    check lb.itemIndex == 2
    f.tap('l'.key)                         # "bl" within the timeout
    check lb.itemIndex == 2
    sleep 120
    f.tap('c'.key)
    check lb.itemIndex == 3
    sleep 120
    f.tap('c'.key)
    check lb.itemIndex == 4                # next "c" item, case-insensitive
    sleep 120
    f.tap('c'.key); f.tap('r'.key)
    check lb.itemIndex == 4
    sleep 120
    f.tap('z'.key)
    check lb.itemIndex == 4

  test "sorted list":
    let f = newShown()
    let lb = newListBox(f, 10, 10, 150, 202)
    lb.items = @["pear", "apple", "Cherry"]
    lb.itemIndex = 2                       # Cherry
    lb.sorted = true
    check lb.items.len == 3
    check lb[0] == "apple" and lb[1] == "Cherry" and lb[2] == "pear"
    check lb.itemIndex == 1 and lb.selected(1)       # selection follows the item
    lb.add "banana"
    lb.add "Zebra"
    lb.insert(0, "date")                   # index ignored
    check @[lb[0], lb[1], lb[2], lb[3], lb[4], lb[5]] ==
      @["apple", "banana", "Cherry", "date", "pear", "Zebra"]
    check lb.itemIndex == 2

  test "virtual mode: 1,000,000 items, paint touches only visible rows":
    let f = newShown()
    let lb = newListBox(f, 10, 10, 150, 202)
    lb.itemHeight = 20
    var calls = 0
    lb.onData = proc(s: Control, i: int): string =
      inc calls
      "Row " & $i
    lb.count = 1_000_000
    check lb.count == 1_000_000
    calls = 0
    settle f
    lb.invalidate()
    calls = 0
    check f.paintIfDirty()
    check calls > 0 and calls <= 12                  # 10 rows + partial
    check lb.contentSize.h == 20_000_000'f32
    lb.itemIndex = 999_999
    calls = 0
    lb.invalidate()
    check f.paintIfDirty()
    check calls <= 12
    check lb.topIndex >= 999_989
    check lb.itemText(999_999) == "Row 999999"
    # navigation and selection never enumerate
    lb.setFocus()
    calls = 0
    f.tap(keyHome)
    check lb.itemIndex == 0 and lb.scrollPos.y == 0
    f.tap(keyEnd)
    check lb.itemIndex == 999_999
    f.tap(keyPageUp)
    check lb.itemIndex < 999_999 - 5
    check calls == 0
    lb.itemIndex = 500_000
    lb.invalidate()
    calls = 0
    check f.paintIfDirty()
    check calls <= 12
    # type-ahead searches by onData
    lb.itemIndex = 0
    lb.typeAheadTimeout = 80
    f.tap('r'.key)                       # "r" matches the next row
    check lb.itemIndex == 1
    # shrinking the count drops the selection
    lb.count = 1
    check lb.itemIndex == -1

  test "owner draw: callback rects and states":
    let f = newShown()
    let lb = mkList(f, 20)
    lb.style = lbOwnerDraw
    var rects: seq[(int, RectF, ItemStates)]
    lb.onDrawItem = proc(s: Control, c: Canvas, i: int, r: RectF, st: ItemStates) =
      rects.add (i, r, st)
    lb.itemIndex = 1
    lb.invalidate()
    rects.setLen 0
    check f.paintIfDirty()
    check rects.len == 10                   # viewport 200 = exactly 10 rows
    check rects[0][0] == 0 and rects[9][0] == 9
    check rects[0][1] == rectF(1, 1, 136, 20)       # client coords, bar excluded
    check rects[3][1] == rectF(1, 61, 136, 20)
    check isSelected in rects[1][2] and isSelected notin rects[0][2]
    check isFocused notin rects[1][2]               # the list is not focused
    lb.setFocus()
    rects.setLen 0
    check f.paintIfDirty()
    check isFocused in rects[1][2] and isSelected in rects[1][2]
    # scrolled by half a row: partial rows at both ends are painted
    lb.scrollTo(0, 10)
    rects.setLen 0
    check f.paintIfDirty()
    check rects.len == 11
    check rects[0][0] == 0 and rects[0][1].y == -9  # row 0 starts above the viewport
    check rects[^1][0] == 10

  test "delete before the focused row keeps the focus (review 1)":
    let f = newShown()
    let lb = mkList(f, 5)
    lb.multiSelect = true
    lb.itemIndex = 2
    var changes = 0
    lb.onChange = proc(s: Control) = inc changes
    lb.delete(1)                      # row before the focus
    check lb.itemIndex == 1 and lb.itemText(1) == "Item 2"
    check lb.selectedIndices == @[1] and changes == 0
    lb.delete(0)
    check lb.itemIndex == 0 and lb.selectedIndices == @[0] and changes == 0
    lb.delete(2)                      # row after the focus
    check lb.itemIndex == 0 and changes == 0
    lb.delete(0)                      # the focused row itself
    check lb.itemIndex == -1 and lb.selCount == 0 and changes == 1
    lb.delete(0)                      # nothing focused or selected
    check changes == 1

  test "itemIndex = -1 with nothing selected does not fire":
    let f = newShown()
    let lb = mkList(f, 3)
    var changes = 0
    lb.onChange = proc(s: Control) = inc changes
    lb.itemIndex = -1
    check changes == 0
    lb.itemIndex = 1
    lb.itemIndex = -1
    check changes == 2 and lb.selCount == 0

  test "multiSelect = false collapses to the focused row and notifies":
    let f = newShown()
    let lb = mkList(f, 5)
    lb.multiSelect = true
    lb.setSelection([1, 3], focus = 3)
    var changes = 0
    lb.onChange = proc(s: Control) = inc changes
    lb.multiSelect = false
    check lb.selectedIndices == @[3] and lb.itemIndex == 3 and changes == 1
    # no focus: the (first) selected item
    lb.multiSelect = true
    lb.setSelected(0, true)
    lb.setSelected(2, true)
    lb.itemIndex = -1
    lb.multiSelect = true
    lb.setSelected(4, true)
    lb.setSelected(2, true)
    changes = 0
    lb.multiSelect = false
    check lb.selectedIndices == @[2] and lb.itemIndex == 2 and changes == 1
    # focus without selection (Ctrl+arrow in extended mode): focus becomes the selection
    lb.multiSelect = true
    lb.clearSelection()
    lb.multiSelect = false
    check lb.itemIndex == 2 and lb.selectedIndices == @[2]

  test "extended: plain Space toggles the focused row, Ctrl+Space too":
    let f = newShown()
    let lb = mkList(f, 5)
    lb.multiSelect = true
    lb.setFocus()
    lb.itemIndex = 1
    var changes = 0
    lb.onChange = proc(s: Control) = inc changes
    f.tap(keySpace)
    check lb.selCount == 0 and changes == 1
    f.tap(keySpace)
    check lb.selectedIndices == @[1] and changes == 2
    f.tap(keySpace, {ssCtrl})
    check lb.selCount == 0 and changes == 3
    check lb.itemIndex == 1

  test "Ctrl+click then drag does not discard Ctrl-selected rows":
    let f = newShown()
    let lb = mkList(f, 10)
    lb.multiSelect = true
    f.click(rowX, rowY(1))
    f.click(rowX, rowY(3), {ssCtrl})
    f.feed(ekMouseDown, rowX, rowY(5), shift = {ssCtrl})
    f.feed(ekMouseMove, rowX, rowY(7), shift = {ssCtrl, ssLeft})
    f.feed(ekMouseUp, rowX, rowY(7), shift = {ssCtrl})
    check lb.selectedIndices == @[1, 3, 5]

  test "drag-select autoscrolls while the pointer is above/below the list":
    let f = newShown()
    let lb = mkList(f, 100, 102)       # 5 rows visible
    lb.multiSelect = true
    f.feed(ekMouseDown, rowX, rowY(2))
    f.feed(ekMouseMove, rowX, 150, shift = {ssLeft})      # below the list
    let first = lb.itemIndex
    for i in 0 ..< 6: Application.processMessages(60)
    check lb.itemIndex > first + 2
    check lb.topIndex > 0
    # pointer above: scrolls back up
    f.feed(ekMouseMove, rowX, 2, shift = {ssLeft})
    for i in 0 ..< 20: Application.processMessages(60)
    check lb.topIndex == 0 and lb.itemIndex == 0
    f.feed(ekMouseUp, rowX, 2)
    let ti = lb.itemIndex
    for i in 0 ..< 3: Application.processMessages(60)
    check lb.itemIndex == ti

  test "virtual: onData setter refreshes, count before onData, clear keeps count":
    let f = newShown()
    let lb = mkList(f, 0)
    lb.count = 1000
    lb.onData = proc(s: Control, i: int): string = "V" & $i
    check lb.count == 1000 and lb.contentSize.h == 1000 * 20
    lb.clear()
    check lb.count == 1000 and lb.itemText(5) == "V5"
    lb.items = @["a"]
    check lb.count == 1000
    lb.itemIndex = 900
    lb.count = 10
    check lb.itemIndex == -1 and lb.contentSize.h == 200
    lb.onData = nil
    check lb.count == 0
