## DrawGrid / StringGrid (+ gridmodel). Headless (offscreen SDL), events built
## by hand and routed through Application.dispatch like the loop does.

import std/[unittest, monotimes, times, strutils, sequtils, random, tables]
import nimvcl
import nimvcl/controls/[scrolling, grids, gridmodel, edit]

var clip = ""
editClipboardGet = proc(): string = clip
editClipboardSet = proc(s: string) = clip = s

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))
proc click(f: Form, x, y: float32, shift: ShiftState = {}, clicks = 1) =
  f.feed(ekMouseDown, x, y, shift = shift, clicks = clicks)
  f.feed(ekMouseUp, x, y, shift = shift)
proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k,
                                     shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k,
                                     shift: shift))
proc typeText(f: Form, s: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id, text: s))
proc settle(f: Form) =
  discard f.paintIfDirty()
  f.layoutIfNeeded()

const GX = 10'f32      # grid position in the form
const GY = 10'f32

proc formPt(g: DrawGrid, c, r: int): (float32, float32) =
  ## Centre of a cell in form coordinates.
  let rc = g.cellRect(c, r)
  let p = g.clientToForm(pointF(rc.x + rc.w / 2, rc.y + rc.h / 2))
  (p.x, p.y)

proc clickCell(f: Form, g: DrawGrid, c, r: int, shift: ShiftState = {}, clicks = 1) =
  let (x, y) = g.formPt(c, r)
  f.click(x, y, shift, clicks)

proc newShown(): Form =
  result = newForm(nil, 500, 320)
  result.show()

proc mkString(f: Form, cols = 5, rows = 20, h = 130'f32): StringGrid =
  result = newStringGrid(f, GX, GY, 400, h)
  result.colCount = cols
  result.rowCount = rows
  for c in 1 ..< cols: result.cells[c, 0] = "H" & $c
  for r in 1 ..< rows: result.cells[0, r] = $r
  for r in 1 ..< rows:
    for c in 1 ..< cols: result.cells[c, r] = "r" & $r & "c" & $c
  f.settle()
  f.activeControl = result

suite "axis sizes":
  test "offsets and lookup with overrides":
    var a = initAxis(10, 20)
    check a.total == 200.0
    a.setSize(3, 50)
    a.setSize(7, 0)
    check a.size(3) == 50 and a.size(0) == 20 and a.size(7) == 0
    check a.offset(0) == 0.0 and a.offset(3) == 60.0 and a.offset(4) == 110.0
    check a.offset(7) == 170.0 and a.offset(8) == 170.0
    check a.total == 210.0
    check a.indexAt(-1) == -1 and a.indexAt(0) == 0 and a.indexAt(59.9) == 2
    check a.indexAt(60) == 3 and a.indexAt(109) == 3 and a.indexAt(110) == 4
    check a.indexAt(a.total) == -1
    a.setCount(5)
    check a.overrideCount == 1 and a.total == 20.0 * 3 + 50 + 20
    a.setSize(3, 20)                          # back to default drops the override
    check a.overrideCount == 0

  test "matches a naive model":
    randomize(7)
    var a = initAxis(500, 17)
    var sizes = newSeq[float32](500)
    for i in 0 ..< 500: sizes[i] = 17
    for k in 0 ..< 60:
      let i = rand(499)
      let s = float32(rand(40))
      a.setSize(i, s)
      sizes[i] = s
    var acc = 0.0
    for i in 0 ..< 500:
      check abs(a.offset(i) - acc) < 1e-6
      acc += sizes[i]
    check abs(a.total - acc) < 1e-6
    for k in 0 ..< 300:
      let p = rand(acc - 0.01)
      let i = a.indexAt(p)
      check a.offset(i) <= p and p < a.offset(i + 1)

suite "grids":
  setup:
    Application.init()
    Application.forceScale = 0
    clip = ""
  teardown:
    Application.theme = themeLight()
    for f in openForms(): f.freeWindow()

  test "geometry with mixed widths and heights":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 400, 200)
    g.colCount = 6
    g.rowCount = 5
    g.colWidths[2] = 100
    g.rowHeights[3] = 40
    f.settle()
    check g.colWidths[2] == 100 and g.colWidths[1] == 64 and g.rowHeights[3] == 40
    check g.cellRect(0, 0) == rectF(1, 1, 64, 24)
    check g.cellRect(1, 1) == rectF(65, 25, 64, 24)
    check g.cellRect(2, 1) == rectF(129, 25, 100, 24)
    check g.cellRect(3, 1).x == 229
    check g.cellRect(1, 3) == rectF(65, 73, 64, 40)
    check g.cellRect(1, 4).y == 113
    check g.contentSize == sizeF(420, 136)
    g.defaultColWidth = 50
    check g.colWidths[1] == 50 and g.colWidths[2] == 100
    g.resetSizes()
    check g.colWidths[2] == 50 and g.rowHeights[3] == 24

  test "frozen panes do not scroll, scrolling cells do":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 400, 200)
    g.colCount = 20
    g.rowCount = 100
    g.fixedCols = 2
    g.fixedRows = 2
    f.settle()
    let before = (g.cellRect(0, 5), g.cellRect(5, 0), g.cellRect(1, 1), g.cellRect(3, 5))
    g.scrollTo(100, 50)
    check g.scrollPos == pointF(100, 50)
    check g.cellRect(0, 5).x == before[0].x and g.cellRect(1, 5).x == 65
    check g.cellRect(5, 0).y == before[1].y and g.cellRect(5, 1).y == 25
    check g.cellRect(1, 1) == before[2]
    check g.cellRect(0, 5).y == before[0].y - 50
    check g.cellRect(5, 0).x == before[1].x - 100
    check g.cellRect(3, 5).x == before[3].x - 100
    check g.leftCol == 3 and g.topRow == 4
    # painted rects agree: fixed cells keep their place
    var seen: seq[(int, int, RectF)]
    g.onDrawCell = proc(s: Control, c: Canvas, col, row: int, r: RectF,
                        st: GridDrawStates) =
      seen.add (col, row, r)
      if col < 2 or row < 2: check gdFixed in st
      else: check gdFixed notin st
    g.invalidate()
    f.settle()
    var found = false
    for (c, r, rc) in seen:
      if c == 0 and r == 5:
        found = true
        check rc.x == 1 and rc.y == g.cellRect(0, 5).y
      if c == 6 and r == 0: check rc.y == 1
    check found
    # scrolling cells never draw under the fixed area: none of the drawn
    # scrolling cells is entirely hidden behind it
    for (c, r, rc) in seen:
      if c >= 2 and r >= 2:
        check rc.right > g.scrollArea.x and rc.bottom > g.scrollArea.y

  test "topRow / leftCol setters and scroll limits":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 400, 200)
    g.colCount = 20
    g.rowCount = 100
    f.settle()
    g.topRow = 10
    check g.topRow == 10 and g.scrollPos.y == 9 * 24
    g.leftCol = 5
    check g.leftCol == 5 and g.scrollPos.x == 4 * 64
    g.topRow = 1000
    check g.scrollPos.y == g.maxScroll.y
    g.topRow = 0
    check g.topRow == 1

  test "hit testing: cells, fixed areas, resize zones":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 400, 200)
    g.colCount = 20
    g.rowCount = 100
    g.fixedCols = 2
    g.fixedRows = 2
    f.settle()
    g.scrollTo(100, 50)
    check g.cellAt(pointF(10, 10)) == (0, 0)
    check g.cellAt(pointF(30, 80)) == (0, 5)
    check g.cellAt(pointF(300, 10)) == (6, 0)
    check g.cellAt(pointF(300, 100)) == (6, 6)
    check g.cellAt(pointF(-5, -5)) == (-1, -1)
    check g.cellAt(pointF(0, 10)) == (-1, -1)         # the padding
    # a column border in the header rows: +-3 px
    check g.colBorderAt(pointF(64, 10)) == 0
    check g.colBorderAt(pointF(66, 10)) == 0
    check g.colBorderAt(pointF(100, 10)) == -1
    check g.colBorderAt(pointF(64, 80)) == -1         # not in the header
    check g.colBorderAt(pointF(128, 10)) == 1
    # scrolling column borders: col 3 spans 93+64.. in the scrolled view
    let x3 = g.cellRect(3, 0).right
    check g.colBorderAt(pointF(x3 - 1, 10)) == 3
    # a border hidden under the fixed columns is not offered
    check g.colBorderAt(pointF(g.cellRect(2, 0).right - 1, 10)) == -1
    check g.rowBorderAt(pointF(10, 24)) == 0
    check g.rowBorderAt(pointF(10, 26)) == 0
    check g.rowBorderAt(pointF(200, 24)) == -1        # not in the fixed columns
    # content hit testing past the end
    let h = newDrawGrid(f, 300, 250, 150, 60)
    h.colCount = 2
    h.rowCount = 2
    f.settle()
    check h.cellAt(pointF(140, 30)) == (-1, -1)

  test "keyboard navigation: arrows, home/end, edges":
    let f = newShown()
    let g = mkString(f)
    check (g.col, g.row) == (1, 1)
    f.tap(keyLeft)
    f.tap(keyUp)
    check (g.col, g.row) == (1, 1)
    f.tap(keyRight)
    f.tap(keyDown)
    check (g.col, g.row) == (2, 2)
    f.tap(keyEnd)
    check (g.col, g.row) == (4, 2)
    f.tap(keyRight)
    check g.col == 4
    f.tap(keyHome)
    check (g.col, g.row) == (1, 2)
    f.tap(keyEnd, {ssCtrl})
    check (g.col, g.row) == (4, 19)
    f.tap(keyDown)
    check g.row == 19
    check g.topRow + g.visibleRowCount - 1 >= 19 - 1
    f.tap(keyHome, {ssCtrl})
    check (g.col, g.row) == (1, 1) and g.topRow == 1

  test "PgUp / PgDn with partial pages":
    let f = newShown()
    let g = mkString(f)             # 4 full rows + a partial one
    check g.visibleRowCount == 4
    var seq1: seq[int]
    f.tap(keyPageDown); seq1.add g.row
    f.tap(keyPageDown); seq1.add g.row
    f.tap(keyPageUp); seq1.add g.row
    f.tap(keyPageUp); seq1.add g.row
    check seq1 == @[4, 7, 4, 1]
    for i in 0 ..< 10: f.tap(keyPageDown)
    check g.row == 19
    # the current row is always completely visible
    let rc = g.cellRect(g.col, g.row)
    check rc.y >= g.scrollArea.y - 0.01 and rc.bottom <= g.scrollArea.bottom + 0.01

  test "scrolling follows the current cell horizontally too":
    let f = newShown()
    let g = newStringGrid(f, GX, GY, 300, 130)
    g.colCount = 12
    g.rowCount = 5
    f.settle()
    f.activeControl = g
    for i in 0 ..< 11: f.tap(keyRight)
    check g.col == 11
    let rc = g.cellRect(11, 1)
    check rc.right <= g.scrollArea.right + 0.01 and rc.x >= g.scrollArea.x - 0.01
    f.tap(keyHome)
    check g.scrollPos.x == 0

  test "range selection by keys, mouse and clicks":
    let f = newShown()
    let g = mkString(f)
    var changes = 0
    g.onSelectionChanged = proc(s: Control) = inc changes
    f.tap(keyRight, {ssShift})
    f.tap(keyRight, {ssShift})
    f.tap(keyDown, {ssShift})
    check g.selection == (1, 1, 3, 2)
    check g.isSelected(2, 2) and not g.isSelected(4, 2)
    f.tap(keyDown)
    check g.selection == (3, 3, 3, 3)
    f.clickCell(g, 2, 2)
    f.clickCell(g, 4, 3, {ssShift})
    check g.selection == (2, 2, 4, 3)
    f.tap('a'.key, {ssCtrl})
    check g.selection == (1, 1, 4, 19)
    # drag
    f.clickCell(g, 1, 1)
    let (x0, y0) = g.formPt(1, 1)
    let (x1, y1) = g.formPt(3, 3)
    f.feed(ekMouseDown, x0, y0)
    f.feed(ekMouseMove, x1, y1)
    f.feed(ekMouseUp, x1, y1)
    check g.selection == (1, 1, 3, 3)
    check changes > 3
    # no goRangeSelect: Shift does nothing
    g.options = g.options - {goRangeSelect}
    f.tap(keyRight, {ssShift})
    check g.selection.left == g.selection.right

  test "row select":
    let f = newShown()
    let g = mkString(f)
    g.options = g.options + {goRowSelect}
    f.clickCell(g, 2, 3)
    check g.selection == (1, 3, 4, 3)
    f.tap(keyDown, {ssShift})
    check g.selection == (1, 3, 4, 4)

  test "tabs wrap between rows; ends leave the grid":
    let f = newShown()
    let g = mkString(f)
    let other = newEdit(f, "x", 10, 250, 100)
    f.settle()
    g.col = 4
    f.tap(keyTab)
    check (g.col, g.row) == (1, 2)
    f.tap(keyTab, {ssShift})
    check (g.col, g.row) == (4, 1)
    g.col = 1
    f.tap(keyTab, {ssShift})                  # first cell: focus leaves
    check (g.col, g.row) == (1, 1) and f.activeControl == other
    f.activeControl = g
    g.moveCurrent(4, 19)
    f.tap(keyTab)
    check (g.col, g.row) == (4, 19) and f.activeControl == other
    f.activeControl = g
    g.options = g.options - {goTabs}
    g.moveCurrent(1, 1)
    f.tap(keyTab)
    check f.activeControl == other and (g.col, g.row) == (1, 1)

  test "onSelectCell can veto":
    let f = newShown()
    let g = mkString(f)
    var asked: seq[(int, int)]
    g.onSelectCell = proc(s: Control, c, r: int, can: var bool) =
      asked.add (c, r)
      can = c != 3
    f.tap(keyRight)
    check g.col == 2
    f.tap(keyRight)
    check g.col == 2 and asked == @[(2, 1), (3, 1)]
    f.clickCell(g, 3, 4)
    check (g.col, g.row) == (2, 1)
    f.clickCell(g, 4, 4)
    check (g.col, g.row) == (4, 4)
    check not g.moveCurrent(3, 4)

  test "column resize by dragging, minimum width, double click auto-fit":
    let f = newShown()
    let g = mkString(f)
    var changed: seq[int]
    g.onColWidthChanged = proc(s: Control, c: int) = changed.add c
    let hy = GY + 1 + 12
    let bx = GX + 1 + 64 + 64                       # border of column 1
    f.feed(ekMouseMove, bx - 1, hy)
    check g.cursor == crSizeWE
    f.feed(ekMouseDown, bx - 1, hy)
    f.feed(ekMouseMove, bx + 29, hy)
    check g.colWidths[1] == 94
    f.feed(ekMouseUp, bx + 29, hy)
    check g.colWidths[1] == 94 and g.col == 1 and g.row == 1   # no selection change
    check changed.len > 0 and changed[^1] == 1
    f.feed(ekMouseMove, GX + 100, GY + 100)
    check g.cursor == crDefault
    let bx2 = bx + 30
    f.feed(ekMouseDown, bx2 - 1, hy)
    f.feed(ekMouseMove, 40, hy)
    check g.colWidths[1] == g.minColWidth
    f.feed(ekMouseUp, 40, hy)
    # the following columns moved
    check g.cellRect(2, 1).x == 1 + 64 + g.minColWidth
    # auto-fit through the callback
    g.onMeasureColumn = proc(s: Control, c: int): float32 = 140
    let bx3 = GX + 1 + 64 + g.minColWidth
    f.click(bx3 - 1, hy, clicks = 2)
    check g.colWidths[1] == 140
    # without a callback the StringGrid measures its text
    g.onMeasureColumn = nil
    g.cells[1, 3] = "a rather long cell text, wider than the default column"
    g.autoFitColumn(1)
    check g.colWidths[1] > 200
    g.cells[1, 3] = ""
    g.cells[1, 0] = "H"
    g.cells[1, 2] = ""
    for r in 1 ..< 20: g.cells[1, r] = ""
    g.autoFitColumn(1)
    check g.colWidths[1] < 64 and g.colWidths[1] >= g.minColWidth
    # without goColSizing nothing happens
    g.options = g.options - {goColSizing}
    let w = g.colWidths[2]
    let b2 = GX + 1 + g.cellRect(2, 0).right - 1
    f.feed(ekMouseDown, b2, hy)
    f.feed(ekMouseMove, b2 + 20, hy)
    f.feed(ekMouseUp, b2 + 20, hy)
    check g.colWidths[2] == w

  test "row resize":
    let f = newShown()
    let g = mkString(f)
    g.options = g.options + {goRowSizing}
    let bx = GX + 1 + 20
    let by = GY + 1 + 24
    f.feed(ekMouseMove, bx, by - 1)
    check g.cursor == crSizeNS
    f.feed(ekMouseDown, bx, by - 1)
    f.feed(ekMouseMove, bx, by + 15)
    f.feed(ekMouseUp, bx, by + 15)
    check g.rowHeights[0] == 40
    check g.cellRect(1, 1).y == 41.0

  test "editing: Enter, type, commit with Enter, Esc, F2":
    let f = newShown()
    let g = mkString(f)
    var sets: seq[(int, int, string)]
    g.onSetEditText = proc(s: Control, c, r: int, v: string) = sets.add (c, r, v)
    g.moveCurrent(2, 2)
    f.tap(keyEnter)
    check g.editing and g.editor.visible and f.activeControl == g.editor
    check g.editor.text == "r2c2" and g.editCell == (2, 2)
    check g.editor.boundsRect == g.cellRect(2, 2)
    f.typeText("!")
    check g.editor.text == "r2c2!"
    f.tap(keyEnter)
    check not g.editing and not g.editor.visible and f.activeControl == g
    check g.cells[2, 2] == "r2c2!" and (g.col, g.row) == (2, 3)
    check sets == @[(2, 2, "r2c2!")]
    # F2 + Escape cancels
    f.tap(keyF2)
    check g.editing and g.editCell == (2, 3)
    f.typeText("zzz")
    f.tap(keyEscape)
    check not g.editing and g.cells[2, 3] == "r3c2" and f.activeControl == g
    check (g.col, g.row) == (2, 3) and sets.len == 1
    # unchanged text commits nothing
    f.tap(keyF2)
    f.tap(keyEnter)
    check sets.len == 1 and (g.col, g.row) == (2, 4)

  test "editing: a typed character starts it with that text":
    let f = newShown()
    let g = mkString(f)
    f.typeText("q")
    check g.editing and g.editor.text == "q" and f.activeControl == g.editor
    f.typeText("w")
    check g.editor.text == "qw"
    f.tap(keyEnter)
    check g.cells[1, 1] == "qw" and g.row == 2
    # fixed cells never edit
    g.options = g.options + {goRangeSelect}
    check not g.canEditCell(0, 3) and not g.canEditCell(2, 0)
    check g.canEditCell(2, 3)

  test "editing: needs goEditing":
    let f = newShown()
    let g = mkString(f)
    g.options = g.options - {goEditing}
    f.tap(keyEnter)
    f.tap(keyF2)
    f.typeText("x")
    check not g.editing and g.cells[1, 1] == "r1c1"

  test "editing: double click, Tab / arrows commit and move":
    let f = newShown()
    let g = mkString(f)
    f.clickCell(g, 2, 2)
    check not g.editing
    f.clickCell(g, 2, 2, clicks = 2)
    check g.editing and g.editCell == (2, 2)
    f.typeText("A")
    f.tap(keyTab)
    check not g.editing and g.cells[2, 2] == "r2c2A" and (g.col, g.row) == (3, 2)
    f.tap(keyF2)
    f.typeText("B")
    f.tap(keyUp)
    check g.cells[3, 2] == "r2c3B" and (g.col, g.row) == (3, 1)
    # Tab at the row end wraps to the next row
    g.moveCurrent(4, 2)
    f.tap(keyF2)
    f.tap(keyTab)
    check (g.col, g.row) == (1, 3) and f.activeControl == g
    # Shift+Tab goes back
    f.tap(keyF2)
    f.tap(keyTab, {ssShift})
    check (g.col, g.row) == (4, 2)

  test "editing: focus loss and clicking elsewhere commit":
    let f = newShown()
    let g = mkString(f)
    let other = newEdit(f, "x", 10, 250, 100)
    f.settle()
    var sets = 0
    g.onSetEditText = proc(s: Control, c, r: int, v: string) = inc sets
    f.tap(keyF2)
    f.typeText("1")
    f.activeControl = other
    check not g.editing and g.cells[1, 1] == "r1c11" and sets == 1
    check f.activeControl == other
    # clicking another cell commits too
    g.moveCurrent(2, 2)
    f.activeControl = g
    f.tap(keyF2)
    f.typeText("2")
    f.clickCell(g, 3, 3)
    check not g.editing and g.cells[2, 2] == "r2c22" and (g.col, g.row) == (3, 3)
    check f.activeControl == g
    # clicking another control
    f.tap(keyF2)
    f.typeText("3")
    f.click(other.left + 20, other.top + 10)
    check not g.editing and g.cells[3, 3] == "r3c33" and f.activeControl == other

  test "editing: onGetEditText, programmatic moves commit, goAlwaysShowEditor":
    let f = newShown()
    let g = mkString(f)
    g.onGetEditText = proc(s: Control, c, r: int, v: var string) =
      if c == 2: v = "<" & v & ">"
    g.moveCurrent(2, 1)
    f.tap(keyF2)
    check g.editor.text == "<r1c2>"
    f.typeText("x")
    g.moveCurrent(3, 1)                         # code moves: commits
    check not g.editing and g.cells[2, 1] == "<r1c2>x"
    g.options = g.options + {goAlwaysShowEditor}
    g.moveCurrent(1, 5)
    check g.editing and g.editCell == (1, 5)
    g.moveCurrent(1, 6)
    check g.editing and g.editCell == (1, 6)
    check g.editor.boundsRect == g.cellRect(1, 6)

  test "editing: scrolling keeps the editor on its cell":
    let f = newShown()
    let g = mkString(f, rows = 60)
    g.moveCurrent(2, 5)
    f.tap(keyF2)
    g.scrollBy(0, 24)
    check g.editor.visible
    check g.editor.boundsRect == g.cellRect(2, 5).intersect(g.scrollArea)
    g.endEdit(false)
    check not g.editing

  test "DrawGrid editing through events only":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 400, 130)
    g.options = g.options + {goEditing}
    var store: array[5, array[5, string]]
    g.onGetEditText = proc(s: Control, c, r: int, v: var string) = v = store[c][r]
    g.onSetEditText = proc(s: Control, c, r: int, v: string) = store[c][r] = v
    f.settle()
    f.activeControl = g
    f.typeText("k")
    f.tap(keyEnter)
    check store[1][1] == "k"
    f.tap(keyUp)
    f.tap(keyF2)
    check g.editor.text == "k"
    f.tap(keyEscape)

  test "TSV copy and paste":
    let f = newShown()
    let g = mkString(f, rows = 12, h = 300)
    f.clickCell(g, 1, 1)
    f.clickCell(g, 2, 2, {ssShift})
    f.tap('c'.key, {ssCtrl})
    check clip == "r1c1\tr1c2\nr2c1\tr2c2"
    g.cells[1, 1] = "a\tb"
    g.cells[2, 1] = "x\ny"
    f.tap('c'.key, {ssCtrl})
    check clip.startsWith("a b\tx y\n")
    # paste a block at the current cell
    f.clickCell(g, 2, 3)
    clip = "p\tq\r\nr\ts\r\n"
    f.tap('v'.key, {ssCtrl})
    check g.cells[2, 3] == "p" and g.cells[3, 3] == "q"
    check g.cells[2, 4] == "r" and g.cells[3, 4] == "s"
    check g.selection == (2, 3, 3, 4)
    # nothing grows: the part outside is dropped
    g.moveCurrent(4, 10)
    clip = "u\tv\nw\tx\ny\tz"
    f.tap('v'.key, {ssCtrl})
    check g.cells[4, 10] == "u" and g.cells[4, 11] == "w"
    check g.colCount == 5 and g.rowCount == 12
    # a single value fills the selection
    f.clickCell(g, 1, 6)
    f.clickCell(g, 2, 7, {ssShift})
    clip = "fill"
    f.tap('v'.key, {ssCtrl})
    check g.cells[1, 6] == "fill" and g.cells[2, 7] == "fill" and g.cells[3, 7] != "fill"
    # fixed cells are never written
    f.clickCell(g, 1, 1)
    g.setSelection(0, 0, 1, 1)
    check g.selection == (1, 1, 1, 1)
    # Delete clears the selection
    f.clickCell(g, 1, 6)
    f.clickCell(g, 2, 7, {ssShift})
    f.tap(keyDelete)
    check g.cells[1, 6] == "" and g.cells[2, 7] == ""
    # read-only grids copy but do not paste
    g.options = g.options - {goEditing}
    f.clickCell(g, 1, 8)
    clip = "nope"
    f.tap('v'.key, {ssCtrl})
    check g.cells[1, 8] == "r8c1"
    f.tap('c'.key, {ssCtrl})
    check clip == "r8c1"

  test "StringGrid storage, cols / rows, insert / delete":
    let f = newShown()
    let g = newStringGrid(f, GX, GY, 400, 130)
    g.colCount = 3
    g.rowCount = 4
    g.cells[1, 1] = "x"
    check g.cells[1, 1] == "x" and g.cells[2, 2] == ""
    g.cells[9, 9] = "ignored"
    check g.cells[9, 9] == ""
    g.cols[2] = @["h", "1", "2", "3", "too many"]
    check g.cols[2] == @["h", "1", "2", "3"]
    g.rows[0] = @["a", "b"]
    check g.rows[0] == @["a", "b", "h"]
    g.insertRow(2)
    check g.rowCount == 5 and g.rows[2] == @["", "", ""] and g.cells[2, 3] == "2"
    g.deleteRow(2)
    check g.rowCount == 4 and g.cells[2, 2] == "2"
    g.deleteRow(0)                       # fixed rows stay
    check g.rowCount == 4
    g.rowCount = 2
    g.rowCount = 4
    check g.cells[2, 3] == "" and g.cells[2, 1] == "1"
    g.colAlignments[1] = taRight
    check g.colAlignments[1] == taRight and g.colAlignments[0] == taLeft
    g.clearCells()
    check g.cells[1, 1] == ""

  test "row heights follow their rows on insertRow, deleteRow and sort":
    let f = newShown()
    let g = newStringGrid(f, GX, GY, 400, 200)
    g.colCount = 1
    g.rowCount = 8
    for r in 0 ..< 8: g.cells[0, r] = $(7 - r)           # 7 6 5 4 3 2 1 0
    g.rowHeights[5] = 60                                  # the row holding "2"
    g.insertRow(2)
    check g.rowHeights[6] == 60 and g.rowHeights[5] == g.defaultRowHeight
    g.deleteRow(2)
    check g.rowHeights[5] == 60 and g.rowHeights[6] == g.defaultRowHeight
    g.deleteRow(5)                                        # the tall row itself
    check g.rowHeights[5] == g.defaultRowHeight
    g.rowHeights[1] = 50                                  # the row holding "6"
    let tall = g.cells[0, 1]
    g.sortByColumn(0)
    var tallRows = 0
    for r in 0 ..< g.rowCount:
      if g.rowHeights[r] == 50:
        inc tallRows
        check g.cells[0, r] == tall
    check tallRows == 1

  test "sortByColumn orders like compareCells":
    let f = newShown()
    let g = newStringGrid(f, GX, GY, 400, 200)
    g.colCount = 1
    let words = @["b", "10", "A", "9", "", "c", "1e2", "abc", "AB", "-3", "nan", "B"]
    g.rowCount = words.len
    for r, w in words: g.cells[0, r] = w
    g.sortByColumn(0)
    for r in 2 ..< words.len:                         # row 0 is the fixed row
      check compareCells(g.cells[0, r - 1], g.cells[0, r]) <= 0

  test "sortByColumn: numeric, text, custom, descending, stable, fixed rows stay":
    let f = newShown()
    let g = newStringGrid(f, GX, GY, 400, 130)
    g.colCount = 2
    g.rowCount = 6
    let data = [("name", "n"), ("b", "10"), ("a", "9"), ("C", "100"), ("a", "2"), ("d", "")]
    for r, (a, b) in data:
      g.cells[0, r] = a
      g.cells[1, r] = b
    g.sortByColumn(1)
    check g.cols[1] == @["n", "2", "9", "10", "100", ""]
    check g.cells[0, 0] == "name"
    g.sortByColumn(1, ascending = false)
    check g.cols[1] == @["n", "", "100", "10", "9", "2"]
    g.sortByColumn(0)                           # case-insensitive text
    check g.cols[0] == @["name", "a", "a", "b", "C", "d"]
    check g.cells[1, 1] == "100" or g.cells[1, 1] == "10" or g.cells[1, 1] == "9"
    # stable: the two "a" rows keep the order they had (9 above 2 after the
    # descending numeric sort)
    check g.cols[1].filterIt(it in ["2", "9"]) == @["9", "2"]
    g.sortByColumn(1)
    g.sortByColumn(0)
    check g.cols[1].filterIt(it in ["2", "9"]) == @["2", "9"]
    g.sortByColumn(0, true, proc(a, b: string): int = cmp(b, a))
    check g.cells[0, 1] == "d" and g.cells[0, 5] == "C"
    check g.sortColumn == 0 and g.sortAscending

  test "header click sorts and toggles, onHeaderClick fires":
    let f = newShown()
    let g = mkString(f, cols = 3, rows = 6)
    for r in 1 ..< 6: g.cells[1, r] = $((r * 7) mod 5)
    var clicked: seq[int]
    var fixedClicks = 0
    g.onHeaderClick = proc(s: Control, c: int) = clicked.add c
    g.onFixedCellClick = proc(s: Control, c, r: int) = inc fixedClicks
    g.sortOnHeaderClick = true
    f.clickCell(g, 1, 0)
    check g.sortColumn == 1 and g.sortAscending
    check g.cols[1][1 .. ^1] == @["0", "1", "2", "3", "4"]
    f.clickCell(g, 1, 0)
    check not g.sortAscending and g.cols[1][1] == "4"
    f.clickCell(g, 2, 0)
    check g.sortColumn == 2 and g.sortAscending
    check clicked == @[1, 1, 2] and fixedClicks == 3
    check (g.col, g.row) == (1, 1)               # headers do not move the selection
    # clicking a row header is only a fixed-cell click
    f.clickCell(g, 0, 3)
    check fixedClicks == 4 and clicked.len == 3

  test "draw states and owner draw":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 400, 200)
    g.options = g.options + {goRangeSelect}
    g.colCount = 4
    g.rowCount = 4
    g.hotTrack = true
    f.settle()
    f.activeControl = g
    g.setSelection(1, 1, 2, 2)
    var states: Table[(int, int), GridDrawStates]
    g.onDrawCell = proc(s: Control, c: Canvas, col, row: int, r: RectF,
                        st: GridDrawStates) =
      states[(col, row)] = st
      check r.w == g.colWidth(col) - 1 and r.h == g.rowHeight(row) - 1
    g.invalidate()
    f.settle()
    check states[(0, 0)] == {gdFixed}
    check gdSelected in states[(1, 1)] and gdFocused notin states[(1, 1)]
    check states[(2, 2)] == {gdSelected, gdFocused}
    check states[(3, 3)] == {}
    let (hx, hy) = g.formPt(3, 3)
    f.feed(ekMouseMove, hx, hy)
    g.invalidate()
    f.settle()
    check states[(3, 3)] == {gdHot} and states[(1, 3)] == {gdHot}

  test "dark theme paints":
    let f = newShown()
    let g = mkString(f)
    Application.theme = themeDark()
    g.invalidate()
    f.settle()
    check g.theme.name == "dark"
    g.sortByColumn(2)
    g.invalidate()
    f.settle()

  test "1,000,000 x 50: only the visible cells are drawn":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 400, 200)
    g.colCount = 50
    g.rowCount = 1_000_000
    var calls = 0
    var maxRow, maxCol = 0
    g.onDrawCell = proc(s: Control, c: Canvas, col, row: int, r: RectF,
                        st: GridDrawStates) =
      inc calls
      maxRow = max(maxRow, row)
      maxCol = max(maxCol, col)
    f.settle()
    check calls > 10 and calls < 70
    check g.contentSize.h == 24_000_000 and g.contentSize.w == 3200
    calls = 0
    g.topRow = 500_000
    f.settle()
    check calls < 70 and g.topRow == 500_000 and maxRow < 500_020 and maxRow >= 500_000
    calls = 0
    g.moveCurrent(49, 999_999)
    f.settle()
    check calls < 70 and maxRow == 999_999 and maxCol == 49
    check g.topRow + g.visibleRowCount >= 999_999
    # odd sizes deep in the grid do not break the lookups
    g.rowHeights[500_000] = 60
    g.colWidths[25] = 200
    g.topRow = 499_999
    g.leftCol = 1
    f.settle()
    check g.cellRect(1, 500_000).h == 60
    let c2 = g.cellRect(1, 500_001)
    check g.cellAt(pointF(c2.x + 5, c2.y + 5)) == (1, 500_001)
    # keyboard on a huge grid
    g.moveCurrent(1, 1)
    f.activeControl = g
    f.tap(keyEnd, {ssCtrl})
    check (g.col, g.row) == (49, 999_999)
    f.tap(keyPageUp)
    check g.row < 999_999 and g.row > 999_990

  test "1,000,000 x 50: per-frame cost":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 400, 200)
    g.colCount = 50
    g.rowCount = 1_000_000
    g.rowHeights[123] = 40
    g.rowHeights[777_777] = 10
    g.onDrawCell = proc(s: Control, c: Canvas, col, row: int, r: RectF,
                        st: GridDrawStates) =
      let gg = DrawGrid(s)
      gg.drawCellText(c, r, $row & "," & $col, st)
    f.settle()
    let frames = 300
    let t0 = getMonoTime()
    var y = 0'f32
    for i in 0 ..< frames:
      y += 24 * 37 + 5
      g.scrollTo(float32((i * 7) mod 50) * 20, y)
      discard f.paintIfDirty()
    let ms = float((getMonoTime() - t0).inNanoseconds) / 1e6 / frames.float
    echo "  [grid perf] 1Mx50 scroll+paint: ", ms.formatFloat(ffDecimal, 3),
         " ms/frame (", (when defined(release): "release" else: "debug"), ")"
    check ms < (when defined(release): 20.0 else: 80.0)
    # lookups alone are cheap even with overrides
    let t1 = getMonoTime()
    var acc = 0
    for i in 0 ..< 20000:
      acc += g.cellAt(pointF(30 + float32(i mod 300), 40 + float32(i mod 150))).row
    let us = float((getMonoTime() - t1).inNanoseconds) / 1e3 / 20000
    echo "  [grid perf] cellAt: ", us.formatFloat(ffDecimal, 2), " us/call"
    check acc > 0
    check us < 200

# ------------------------------------------------------ review regressions

suite "axis sizes (incremental)":
  test "interleaved sets, resets, counts and queries match a naive model":
    randomize(11)
    var a = initAxis(300, 20)
    var sizes = newSeq[float32](300)
    var follows = newSeq[bool](300)        # slot without an own override
    for i in 0 ..< 300:
      sizes[i] = 20
      follows[i] = true
    var def = 20'f32
    for k in 0 ..< 600:
      case rand(9)
      of 0:                                   # reset one slot to the default
        let i = rand(299)
        a.setSize(i, def)
        sizes[i] = def
        follows[i] = true
      of 1:                                   # new default: overrides keep sizes
        let newDef = float32(10 + rand(20))
        for i in 0 ..< 300:
          if follows[i]: sizes[i] = newDef
        a.setDefaultSize(newDef)
        def = newDef
      else:
        let i = rand(299)
        let s = float32(rand(50))
        a.setSize(i, s)
        sizes[i] = s
        follows[i] = s == def
      if k mod 7 == 0:                        # queries between the changes
        var acc = 0.0
        for i in 0 ..< 300:
          check abs(a.offset(i) - acc) < 1e-3
          acc += float64(sizes[i])
        check abs(a.total - acc) < 1e-3
    # shrinking drops the overrides beyond the new count and keeps the sums
    a.setCount(100)
    var acc = 0.0
    for i in 0 ..< 100: acc += float64(sizes[i])
    check abs(a.total - acc) < 1e-3 and abs(a.offset(100) - acc) < 1e-3
    a.resetSizes()
    check a.total == 100.0 * float64(def)

suite "grids (review fixes)":
  setup:
    Application.init()
    Application.forceScale = 0
    clip = ""
  teardown:
    Application.theme = themeLight()
    for f in openForms(): f.freeWindow()

  test "20,000 rowHeights[r]= in a loop stay fast":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 400, 130)
    g.colCount = 3
    g.rowCount = 30000
    let t0 = getMonoTime()
    for r in 1 ..< 20000: g.rowHeights[r] = 20 + float32(r mod 7)
    let ms = float((getMonoTime() - t0).inNanoseconds) / 1e6
    echo "  [grid perf] 20k rowHeights[r]=: ", ms.formatFloat(ffDecimal, 1), " ms"
    check ms < (when defined(release): 500.0 else: 4000.0)
    var expect = 24.0 + 0.0                      # row 0 keeps the default
    for r in 1 ..< 20000: expect += float64(20 + float32(r mod 7))
    expect += 10000.0 * 24.0
    check abs(g.contentSize.h.float64 - expect) < 1.0
    f.settle()
    check g.rowHeight(5) == 25 and g.rowY(1) == g.viewport.y + 24

  test "colCount= / rowCount= keep the requested fixed counts":
    let f = newShown()
    let g = newStringGrid(f, GX, GY, 400, 130)
    g.colCount = 5
    g.rowCount = 10
    g.fixedCols = 2
    g.colCount = 0
    g.rowCount = 0
    check g.fixedCols == 0 and g.fixedRows == 0
    g.colCount = 5
    g.rowCount = 10
    check g.fixedCols == 2 and g.fixedRows == 1
    g.colCount = 1                               # clamped at use, not forgotten
    check g.fixedCols == 1
    g.colCount = 4
    check g.fixedCols == 2
    g.fixedCols = 1                              # an explicit request replaces it
    g.colCount = 0
    g.colCount = 4
    check g.fixedCols == 1

  test "Tab in the editor at the first / last cell commits and leaves the grid":
    let f = newShown()
    let g = mkString(f, cols = 4, rows = 4)
    let other = newEdit(f, "x", 10, 250, 100)
    f.settle()
    f.activeControl = g
    g.selectCell(3, 3)
    check g.startEdit()
    g.editor.text = "LAST"
    f.tap(keyTab)
    check not g.editing and g.cells[3, 3] == "LAST"
    check (g.col, g.row) == (3, 3) and f.activeControl == other
    f.activeControl = g
    g.selectCell(1, 1)
    check g.startEdit()
    f.tap(keyTab, {ssShift})
    check not g.editing and (g.col, g.row) == (1, 1) and f.activeControl == other
    # inside the grid it still moves on
    f.activeControl = g
    g.selectCell(1, 1)
    check g.startEdit()
    f.tap(keyTab)
    check (g.col, g.row) == (2, 1) and g.editing == false

  test "the current cell moving on its own fires the selection events":
    let f = newShown()
    let g = mkString(f)
    g.selectCell(3, 4)
    var cells, changes = 0
    g.onSelectCell = proc(s: Control, c, r: int, ok: var bool) = inc cells
    g.onSelectionChanged = proc(s: Control) = inc changes
    g.rowCount = 3                               # row 4 is gone
    check g.row == 2 and cells == 1 and changes == 1
    g.colCount = 2
    check g.col == 1 and cells == 2 and changes == 2
    g.rowCount = 8                               # nothing moved
    check cells == 2 and changes == 2
    g.selectCell(1, 4)
    cells = 0; changes = 0
    g.insertRow(2)
    check g.row == 5 and cells == 1 and changes == 1
    g.deleteRow(2)
    check g.row == 4 and cells == 2 and changes == 2

  test "setSelection and a paste fire onSelectionChanged once":
    let f = newShown()
    let g = mkString(f)
    var cnt = 0
    g.onSelectionChanged = proc(s: Control) = inc cnt
    g.setSelection(1, 1, 3, 3)
    check cnt == 1 and g.selection == (1, 1, 3, 3)
    g.setSelection(2, 2, 4, 4)
    check cnt == 2
    g.setSelection(2, 2, 4, 4)                   # nothing changed
    check cnt == 2
    g.onSelectCell = proc(s: Control, c, r: int, ok: var bool) = ok = false
    g.setSelection(1, 1, 2, 2)                   # vetoed
    check cnt == 2
    g.onSelectCell = nil
    g.setSelection(1, 1, 1, 1)
    cnt = 0
    clip = "a\tb\nc\td"
    g.pasteFromClipboard()
    check cnt == 1 and g.selection == (1, 1, 2, 2)

  test "a double click on a header does not sort twice":
    let f = newShown()
    let g = mkString(f, cols = 3, rows = 6)
    for r in 1 ..< 6: g.cells[1, r] = $((r * 7) mod 5)
    var clicked = 0
    g.onHeaderClick = proc(s: Control, c: int) = inc clicked
    g.sortOnHeaderClick = true
    f.clickCell(g, 1, 0)
    check g.sortAscending and clicked == 1
    f.clickCell(g, 1, 0, shift = {ssDouble}, clicks = 2)
    check g.sortAscending and clicked == 1 and g.sortColumn == 1

  test "Delete on a million-row selection only visits stored cells":
    let f = newShown()
    let g = newStringGrid(f, GX, GY, 400, 130)
    g.colCount = 50
    g.rowCount = 1_000_000
    g.cells[2, 5] = "keep?"
    g.cells[49, 999_999] = "far"
    f.settle()
    f.activeControl = g
    var sets = 0
    g.onSetEditText = proc(s: Control, c, r: int, v: string) = inc sets
    let t0 = getMonoTime()
    f.tap('a'.key, {ssCtrl})
    f.tap(keyDelete)
    let ms = float((getMonoTime() - t0).inNanoseconds) / 1e6
    check g.cells[2, 5] == "" and g.cells[49, 999_999] == "" and sets == 2
    check ms < (when defined(release): 300.0 else: 2000.0)

  test "compareCells: nan / inf are text, not numbers":
    check compareCells("nan", "5") > 0 and compareCells("5", "nan") < 0
    check compareCells("inf", "5") > 0 and compareCells("-inf", "5") > 0
    check compareCells("2", "10") < 0
    check compareCells("nan", "apple") > 0      # compared as text (n > a)
    check compareCells("Infinity", "9") > 0

  test "cells[]= outside the grid does not repaint; insert / delete row shift the cursor":
    let f = newShown()
    let g = mkString(f, cols = 3, rows = 6)
    f.settle()
    discard f.paintIfDirty()
    g.cells[9, 9] = "x"
    check not f.paintIfDirty()
    g.sortByColumn(1)
    g.selectCell(2, 4)
    g.insertRow(2)                               # above the current row
    check g.row == 5 and g.sortColumn == -1
    g.sortByColumn(1)
    g.deleteRow(2)
    check g.row == 4 and g.sortColumn == 1        # order of the rest is kept
    g.selectCell(2, 3)
    g.deleteRow(3)                               # the current row itself
    check g.row == 3
    g.selectCell(2, 1)
    g.insertRow(4)                               # below: unchanged
    check g.row == 1

suite "StringGrid design-time text forms":
  Application.init()

  test "cellLines: rows of tab-separated cells, trailing empties trimmed":
    let g = newStringGrid(nil)
    g.colCount = 4
    g.rowCount = 5
    g.cells[0, 0] = "Name"
    g.cells[1, 0] = "Qty"
    g.cells[0, 1] = "Nut"
    g.cells[2, 1] = "x\ty\nz"                # tab and newline become spaces
    g.cells[3, 3] = "far"
    check g.cellLines == @["Name\tQty", "Nut\t\tx y z", "", "\t\t\tfar"]
    var empty = newStringGrid(nil)
    check empty.cellLines.len == 0

  test "cellLines= replaces the cells and drops what is outside the grid":
    let g = newStringGrid(nil)
    g.colCount = 3
    g.rowCount = 3
    g.cells[2, 2] = "old"
    g.cellLines = @["a\tb\tc\td", "", "e", "f", "g"]
    check g.cells[0, 0] == "a" and g.cells[2, 0] == "c"
    check g.cells[2, 2] == "" and g.cells[0, 2] == "e"
    check g.cellLines == @["a\tb\tc", "", "e"]
    g.cellLines = @[]
    check g.cellLines.len == 0

  test "colWidthsText / rowHeightsText":
    let g = newStringGrid(nil)
    g.colCount = 3
    check g.colWidthsText == "" and g.rowHeightsText == ""
    g.colWidths[1] = 120
    g.colWidths[2] = 33.5
    check g.colWidthsText == "64, 120, 33.5"
    let h = newStringGrid(nil)
    h.colCount = 3
    h.colWidthsText = g.colWidthsText
    check h.colWidths[0] == 64 and h.colWidths[1] == 120 and h.colWidths[2] == 33.5
    h.colWidthsText = "40"                    # missing entries: the default width
    check h.colWidths[0] == 40 and h.colWidths[1] == 64 and h.colWidths[2] == 64
    h.colWidthsText = ""
    check h.colWidthsText == ""
    h.rowHeights[2] = 40
    check h.rowHeightsText == "24, 24, 40, 24, 24"
    h.rowHeightsText = "x, 30"                 # an unreadable entry: the default
    check h.rowHeights[0] == 24 and h.rowHeights[1] == 30 and h.rowHeightsText == "24, 30, 24, 24, 24"
