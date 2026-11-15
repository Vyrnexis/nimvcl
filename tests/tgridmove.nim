## goColMoving: dragging grid column headers. Headless (offscreen SDL), events
## built by hand and routed through Application.dispatch.

import std/[unittest]
import nimvcl
import nimvcl/controls/[scrolling, grids]

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, button = mbLeft,
          clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))
proc settle(f: Form) =
  discard f.paintIfDirty()
  f.layoutIfNeeded()
  discard f.paintIfDirty()

const GX = 10'f32
const GY = 10'f32

proc formPt(g: DrawGrid, c, r: int): (float32, float32) =
  let rc = g.cellRect(c, r)
  let p = g.clientToForm(pointF(rc.x + rc.w / 2, rc.y + rc.h / 2))
  (p.x, p.y)

proc drag(f: Form, g: DrawGrid, fromCol, toCol: int, row = 0, release = true) =
  ## Press on a header cell, move in a few steps, release over `toCol`.
  let (x0, y0) = g.formPt(fromCol, row)
  let (x1, _) = g.formPt(toCol, row)
  f.feed(ekMouseDown, x0, y0)
  let steps = 6
  for k in 1 .. steps:
    f.feed(ekMouseMove, x0 + (x1 - x0) * float32(k) / float32(steps), y0, shift = {ssLeft})
  if release: f.feed(ekMouseUp, x1, y0)

proc newShown(): Form =
  result = newForm(nil, 500, 320)
  result.show()

proc mkString(f: Form, cols = 5, rows = 6): StringGrid =
  result = newStringGrid(f, GX, GY, 460, 150)
  result.colCount = cols
  result.rowCount = rows
  result.options = result.options + {goColMoving}
  for c in 0 ..< cols:
    result.cells[c, 0] = "H" & $c
    for r in 1 ..< rows: result.cells[c, r] = $c & "." & $r
  f.settle()

suite "goColMoving":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "StringGrid: dragging a header moves the column data":
    let f = newShown()
    let g = f.mkString()
    var moves: seq[(int, int)]
    g.onColumnMoved = proc(s: Control, a, b: int) = moves.add (a, b)
    g.colWidths[2] = 100
    g.colAlignments[2] = taRight
    f.drag(g, 2, 4)
    check moves == @[(2, 4)]
    check g.cols[4] == @["H2", "2.1", "2.2", "2.3", "2.4", "2.5"]
    check g.cols[2] == @["H3", "3.1", "3.2", "3.3", "3.4", "3.5"]
    check g.cols[3] == @["H4", "4.1", "4.2", "4.3", "4.4", "4.5"]
    check g.cols[1][0] == "H1" and g.cols[0][0] == "H0"
    # the width and the alignment travel with the column
    check g.colWidths[4] == 100 and g.colWidths[2] == 64
    check g.colAlignments[4] == taRight and g.colAlignments[2] == taLeft
    # and back to the left
    f.drag(g, 4, 1)
    check moves == @[(2, 4), (4, 1)]
    check g.cols[1][0] == "H2" and g.cols[2][0] == "H1" and g.cols[3][0] == "H3" and
          g.cols[4][0] == "H4"
    check g.colWidths[1] == 100

  test "the current cell and the sort column follow the column":
    let f = newShown()
    let g = f.mkString()
    g.sortOnHeaderClick = true
    f.settle()
    g.sortByColumn(3, true)
    g.col = 3
    g.row = 2
    f.drag(g, 3, 1)
    check g.col == 1 and g.row == 2
    check g.sortColumn == 1
    check g.cells[1, 2][0] == '3'
    # a column the move passes over shifts by one
    g.col = 1
    f.drag(g, 4, 1)
    check g.col == 2

  test "a click without movement is still a header click (fired on release)":
    let f = newShown()
    let g = f.mkString()
    var clicks = 0
    var moves = 0
    g.onFixedCellClick = proc(s: Control, c, r: int) = inc clicks
    g.onColumnMoved = proc(s: Control, a, b: int) = inc moves
    g.sortOnHeaderClick = true
    let (x, y) = g.formPt(2, 0)
    f.feed(ekMouseDown, x, y)
    check clicks == 0                         # waits for the release
    f.feed(ekMouseUp, x, y)
    check clicks == 1 and moves == 0 and g.sortColumn == 2
    # a drag of one pixel is a click as well, a drag back onto itself moves nothing
    f.feed(ekMouseDown, x, y)
    f.feed(ekMouseMove, x + 2, y, shift = {ssLeft})
    f.feed(ekMouseUp, x + 2, y)
    check clicks == 2 and moves == 0
    # dragged away and back onto its own column: neither a move nor a click
    let (x3, _) = g.formPt(4, 0)
    f.feed(ekMouseDown, x, y)
    f.feed(ekMouseMove, x3, y, shift = {ssLeft})
    f.feed(ekMouseMove, x, y, shift = {ssLeft})
    f.feed(ekMouseUp, x, y)
    check moves == 0 and clicks == 2 and g.cols[2][0] == "H2"

  test "a real drag does not sort":
    let f = newShown()
    let g = f.mkString()
    g.sortOnHeaderClick = true
    var clicks = 0
    g.onFixedCellClick = proc(s: Control, c, r: int) = inc clicks
    f.drag(g, 1, 3)
    check clicks == 0 and g.sortColumn == -1

  test "fixed columns neither move nor receive a column":
    let f = newShown()
    let g = f.mkString()
    var moves: seq[(int, int)]
    g.onColumnMoved = proc(s: Control, a, b: int) = moves.add (a, b)
    f.drag(g, 0, 3)                            # the fixed column header
    check moves.len == 0 and g.cells[0, 0] == "H0"
    f.drag(g, 3, 0)                            # dropped on the fixed column: clamps to column 1
    check moves == @[(3, 1)]
    check g.cols[1][0] == "H3" and g.cols[0][0] == "H0"
    g.moveColumn(2, 0)                         # code: into a fixed column is ignored
    g.moveColumn(0, 2)
    check moves.len == 1

  test "without goColMoving nothing moves; the header click is immediate":
    let f = newShown()
    let g = f.mkString()
    g.options = g.options - {goColMoving}
    var clicks = 0
    g.onFixedCellClick = proc(s: Control, c, r: int) = inc clicks
    let (x, y) = g.formPt(2, 0)
    f.feed(ekMouseDown, x, y)
    check clicks == 1
    f.feed(ekMouseUp, x, y)
    f.drag(g, 2, 4)
    check g.cols[2][0] == "H2" and g.cols[4][0] == "H4"

  test "cells below the headers do not start a column drag":
    let f = newShown()
    let g = f.mkString()
    g.onColumnMoved = proc(s: Control, a, b: int) = check false
    f.drag(g, 2, 4, row = 2)
    check g.cols[2][0] == "H2"

  test "DrawGrid fires onColumnMoved and moves the widths; the app remaps its data":
    let f = newShown()
    let g = newDrawGrid(f, GX, GY, 460, 150)
    g.colCount = 5
    g.rowCount = 4
    g.options = g.options + {goColMoving}
    var order = @[0, 1, 2, 3, 4]               # the application's column order
    g.onDrawCell = proc(s: Control, cv: Canvas, c, r: int, rc: RectF, st: GridDrawStates) = discard
    g.colWidths[1] = 30
    g.colWidths[3] = 90
    var seen: seq[(int, int)]
    g.onColumnMoved = proc(s: Control, a, b: int) =
      seen.add (a, b)
      let v = order[a]
      order.delete(a)
      order.insert(v, b)
    f.settle()
    f.drag(g, 1, 3)
    check seen == @[(1, 3)] and order == @[0, 2, 3, 1, 4]
    check g.colWidths[3] == 30 and g.colWidths[1] == 64 and g.colWidths[2] == 90
    f.drag(g, 4, 1)
    check seen == @[(1, 3), (4, 1)] and order == @[0, 4, 2, 3, 1]

  test "the drop marker is painted during the drag; release clears it":
    let f = newShown()
    let g = f.mkString()
    let (x0, y0) = g.formPt(1, 0)
    let (x1, _) = g.formPt(3, 0)
    f.feed(ekMouseDown, x0, y0)
    f.feed(ekMouseMove, x1, y0, shift = {ssLeft})
    discard f.paintIfDirty()                   # paints the marker without errors
    f.feed(ekMouseUp, x1, y0)
    check g.cols[3][0] == "H1"
    discard f.paintIfDirty()

  test "autoscroll: dragging to the right edge scrolls and the target is visible":
    let f = newShown()
    let g = newStringGrid(f, GX, GY, 300, 150)
    g.colCount = 30
    g.rowCount = 4
    g.options = g.options + {goColMoving}
    for c in 0 ..< 30: g.cells[c, 0] = "H" & $c
    f.settle()
    let (x0, y0) = g.formPt(2, 0)
    f.feed(ekMouseDown, x0, y0)
    for k in 1 .. 20:
      f.feed(ekMouseMove, GX + 299, y0, shift = {ssLeft})
    let sx = g.scrollPosX
    check sx > 0
    f.feed(ekMouseUp, GX + 299, y0)
    check g.cols[2][0] != "H2"                  # it moved somewhere to the right
    var at = -1
    for c in 0 ..< 30:
      if g.cells[c, 0] == "H2": at = c
    check at > 2
