## `DrawGrid` and `StringGrid` (VCL TDrawGrid / TStringGrid): a scrolling table
## of cells with frozen header rows/columns.
##
## DrawGrid
## --------
## `colCount`, `rowCount`, `fixedCols`, `fixedRows` (header cells, frozen: they
## never scroll), `defaultColWidth` (64), `defaultRowHeight` (24) and sparse
## per-slot overrides (`colWidths[c] = 90`, `rowHeights[r] = 40`). Sizes live
## in `AxisSizes` (gridmodel.nim): a uniform fast path plus prefix sums over
## the overrides, so offsets cost O(log k) and only visible cells are ever
## drawn: 1,000,000 rows x 50 columns scroll like 20. Pixel positions are
## float32 (beyond ~700,000 rows of 24 px the scroll position is quantised to
## 2 px, invisible in practice).
##
## Cells are drawn by `onDrawCell(sender, canvas, col, row, rect, state)` after
## the grid painted the cell background (header / selection / hover); `rect` is
## in the grid's client coordinates and excludes the 1 px grid line. A
## DrawGrid draws nothing else; `g.cellTextColor(state)`, `g.drawCellText` help.
##
## `options` (`GridOptions`):
##
## * `goRangeSelect` Shift+arrows / dragging select a rectangle
## * `goRowSelect`   selection is always whole rows
## * `goColSizing`, `goRowSizing` drag header borders (the cursor changes);
##   double click on a column border auto-fits it (`onMeasureColumn`, or the
##   StringGrid's text widths); widths never go below `minColWidth` (16) /
##   `minRowHeight` (8) while dragging
## * `goEditing`     in-place editor (see below)
## * `goTabs`        Tab / Shift+Tab move between cells, wrapping at row ends;
##                   at the very first/last cell Tab leaves the grid
## * `goThumbTracking` accepted for VCL compatibility; scrolling always
##                   follows the thumb
## * `goAlwaysShowEditor` the editor opens on every selected cell
##
## `goColMoving` (drag a header to reorder columns) is NOT implemented.
##
## Selection: `col`, `row` (current cell, never a fixed one), `selection` (the
## rectangle, inclusive cell ranges), `onSelectCell(sender, col, row,
## canSelect: var bool)` may veto a move, `onSelectionChanged`. `topRow`,
## `leftCol` are the first (possibly partial) scrolling row/column. Scrolling
## and `scrollPos` come from ScrollingControl (pixels of the SCROLLING area;
## the content size includes the fixed cells).
##
## Keys: arrows, Home/End (row), Ctrl+Home/End (grid), PgUp/PgDn (like ListBox:
## to the last fully visible row, then by a page), Tab, Enter / F2 (edit),
## typing (edit with that text), Delete (clear selection), Ctrl+A, Ctrl+C
## (TSV to the clipboard), Ctrl+V (paste TSV from the current cell; one value
## fills a larger selection). The clipboard is `editClipboardGet/Set` of
## edit.nim. Mouse: click, drag (range / auto-scroll one slot per move beyond
## the edge), double click edits, wheel scrolls (Shift+wheel horizontally).
##
## Editing
## -------
## With `goEditing` an `Edit` child (`g.editor`) is placed over the current
## cell: Enter / F2 / double click start it with the cell text, a typed
## character with that character. Enter commits and moves down, Tab (goTabs)
## and Up/Down commit and move, Esc cancels, losing focus (clicking elsewhere)
## commits. A commit only happens when the text changed. Text comes from
## `onGetEditText(sender, col, row, value: var string)` and goes to
## `onSetEditText(sender, col, row, value)` (fired once per commit, after the
## value was stored); both are also used for copy / paste. Subclasses override
## the methods `canEditCell`, `cellText`, `setCellText`.
##
## StringGrid
## ----------
## Sparse text storage: `g.cells[col, row]` (read/write), `g.cols[c]`,
## `g.rows[r]` (seq[string] views, assignable), `colAlignments[c]`, default
## drawing (text with ellipsis; fixed cells are bold headers), `insertRow`,
## `deleteRow`, `clearCells`, `sortByColumn(col, ascending, cmp)` (stable,
## fixed rows stay; default compare is numeric when both cells are numbers).
## `sortOnHeaderClick` makes a click on a header cell sort by that column and
## toggle the direction, with an arrow indicator; `onHeaderClick(sender, col)`
## fires first.

import std/[algorithm, parseutils, strutils]
import ./common, ./scrolling, ./edit, ./gridmodel
export scrolling, gridmodel.AxisSizes

type
  GridOption* = enum
    goRangeSelect, goRowSelect, goColSizing, goRowSizing, goEditing, goTabs,
    goThumbTracking, goAlwaysShowEditor
  GridOptions* = set[GridOption]

  GridDrawState* = enum gdSelected, gdFocused, gdFixed, gdHot
  GridDrawStates* = set[GridDrawState]

  GridCoord* = tuple[col, row: int]
  GridRect* = tuple[left, top, right, bottom: int]   ## inclusive cell range

  SelectCellEvent* = proc(sender: Control, col, row: int, canSelect: var bool)
  DrawCellEvent* = proc(sender: Control, canvas: Canvas, col, row: int,
                        rect: RectF, state: GridDrawStates)
  GetEditTextEvent* = proc(sender: Control, col, row: int, value: var string)
  SetEditTextEvent* = proc(sender: Control, col, row: int, value: string)
  GridCellEvent* = proc(sender: Control, col, row: int)
  GridIndexEvent* = proc(sender: Control, index: int)
  MeasureColumnEvent* = proc(sender: Control, col: int): float32

  DragMode = enum dmNone, dmSelect, dmColSize, dmRowSize

  DrawGrid* = ref object of ScrollingControl
    fCols, fRows: AxisSizes
    fFixedCols, fFixedRows: int
    fOptions: GridOptions
    fCol, fRow, fAnchorCol, fAnchorRow: int
    fHLines, fVLines, fHotTrack: bool
    fHotRow: int
    fMouse: PointF
    fDrag: DragMode
    fDragIdx: int
    fDragStart, fDragSize: float32
    fEditor: Edit
    fEditing: bool
    fEditCol, fEditRow: int
    fEditOrig: string
    fDownOnBorder, fMoving: bool
    minColWidth*, minRowHeight*: float32
    onSelectCell*: SelectCellEvent
    onDrawCell*: DrawCellEvent
    onGetEditText*: GetEditTextEvent
    onSetEditText*: SetEditTextEvent
    onSelectionChanged*: NotifyEvent
    onFixedCellClick*: GridCellEvent   ## click on a header cell
    onColWidthChanged*: GridIndexEvent
    onRowHeightChanged*: GridIndexEvent
    onMeasureColumn*: MeasureColumnEvent

  AxisProxy* = object
    ## `g.colWidths[c]` / `g.rowHeights[r]`.
    g: DrawGrid
    isCol: bool

const CellPad = 6'f32
const BorderZone = 3'f32

# ---------------------------------------------------------------- hooks

method sizeChanged*(g: DrawGrid) {.base.} =
  ## colCount / rowCount changed (subclasses with storage trim it).
  discard

method canEditCell*(g: DrawGrid, col, row: int): bool {.base.} =
  goEditing in g.fOptions and col >= g.fFixedCols and row >= g.fFixedRows and
    col < g.fCols.count and row < g.fRows.count and g.isEnabled

method cellText*(g: DrawGrid, col, row: int): string {.base.} =
  ## Text of a cell for the editor and for copy: `onGetEditText` (a DrawGrid
  ## stores no text).
  if g.onGetEditText != nil: g.onGetEditText(g, col, row, result)

method setCellText*(g: DrawGrid, col, row: int, text: string) {.base.} =
  ## An edit was committed or text was pasted.
  if g.onSetEditText != nil: g.onSetEditText(g, col, row, text)

method measureColumn*(g: DrawGrid, col: int): float32 {.base.} =
  ## Width wanted by auto-fit.
  if g.onMeasureColumn != nil: g.onMeasureColumn(g, col)
  else: g.fCols.defaultSize

method drawCell*(g: DrawGrid, canvas: Canvas, col, row: int, rect: RectF,
                 state: GridDrawStates) {.base.} =
  if g.onDrawCell != nil: g.onDrawCell(g, canvas, col, row, rect, state)

method fixedCellClicked*(g: DrawGrid, col, row: int) {.base.} =
  if g.onFixedCellClick != nil: g.onFixedCellClick(g, col, row)

# ------------------------------------------------------------ properties

func colCount*(g: DrawGrid): int = g.fCols.count
func rowCount*(g: DrawGrid): int = g.fRows.count
func fixedCols*(g: DrawGrid): int = g.fFixedCols
func fixedRows*(g: DrawGrid): int = g.fFixedRows
func defaultColWidth*(g: DrawGrid): float32 = g.fCols.defaultSize
func defaultRowHeight*(g: DrawGrid): float32 = g.fRows.defaultSize
func options*(g: DrawGrid): GridOptions = g.fOptions
func horzLines*(g: DrawGrid): bool = g.fHLines
func vertLines*(g: DrawGrid): bool = g.fVLines
func hotTrack*(g: DrawGrid): bool = g.fHotTrack
func col*(g: DrawGrid): int = g.fCol
func row*(g: DrawGrid): int = g.fRow
func editing*(g: DrawGrid): bool = g.fEditing
func editor*(g: DrawGrid): Edit = g.fEditor
func editCell*(g: DrawGrid): GridCoord = (g.fEditCol, g.fEditRow)

func colWidth*(g: DrawGrid, c: int): float32 = g.fCols.size(c)
func rowHeight*(g: DrawGrid, r: int): float32 = g.fRows.size(r)

proc refreshContent(g: DrawGrid) =
  g.setContentSize(float32(g.fCols.total), float32(g.fRows.total))
  g.invalidate()

method scrollLineSize*(g: DrawGrid): SizeF =
  sizeF(max(g.fCols.defaultSize / 2, 8), max(g.fRows.defaultSize, 8))

proc fixedW(g: DrawGrid): float64 = g.fCols.offset(g.fFixedCols)
proc fixedH(g: DrawGrid): float64 = g.fRows.offset(g.fFixedRows)

proc scrollArea*(g: DrawGrid): RectF =
  ## Client rect where the scrolling cells show (viewport minus fixed cells).
  let v = g.viewport
  let fw = float32(g.fixedW)
  let fh = float32(g.fixedH)
  rectF(v.x + fw, v.y + fh, max(v.w - fw, 0), max(v.h - fh, 0))

proc colX*(g: DrawGrid, c: int): float32 =
  ## Client x of the left edge of column `c` as currently scrolled.
  let v = g.viewport
  let o = g.fCols.offset(c)
  if c < g.fFixedCols: v.x + float32(o)
  else: v.x + float32(o - float64(g.scrollPos.x))

proc rowY*(g: DrawGrid, r: int): float32 =
  let v = g.viewport
  let o = g.fRows.offset(r)
  if r < g.fFixedRows: v.y + float32(o)
  else: v.y + float32(o - float64(g.scrollPos.y))

proc cellRect*(g: DrawGrid, c, r: int): RectF =
  ## The cell slot (grid line included) in client coordinates, as scrolled.
  rectF(g.colX(c), g.rowY(r), g.fCols.size(c), g.fRows.size(r))

proc visibleCols(g: DrawGrid): GridCoord =
  ## First and last (possibly partial) scrolling column; (1, 0) when none.
  let a = g.scrollArea
  if a.w <= 0 or g.fFixedCols >= g.fCols.count: return (1, 0)
  let start = float64(g.scrollPos.x) + g.fixedW
  let first = g.fCols.indexAt(start)
  if first < 0: return (1, 0)
  var last = g.fCols.indexAt(start + float64(a.w) - 0.001)
  if last < 0: last = g.fCols.count - 1
  (max(first, g.fFixedCols), last)

proc visibleRows(g: DrawGrid): GridCoord =
  let a = g.scrollArea
  if a.h <= 0 or g.fFixedRows >= g.fRows.count: return (1, 0)
  let start = float64(g.scrollPos.y) + g.fixedH
  let first = g.fRows.indexAt(start)
  if first < 0: return (1, 0)
  var last = g.fRows.indexAt(start + float64(a.h) - 0.001)
  if last < 0: last = g.fRows.count - 1
  (max(first, g.fFixedRows), last)

proc leftCol*(g: DrawGrid): int =
  ## First (possibly partial) scrolling column.
  let v = g.visibleCols
  if v.col > v.row: g.fFixedCols else: v.col
proc topRow*(g: DrawGrid): int =
  let v = g.visibleRows
  if v.col > v.row: g.fFixedRows else: v.col

proc `leftCol=`*(g: DrawGrid, c: int) =
  let k = min(max(c, g.fFixedCols), max(g.fCols.count - 1, 0))
  g.scrollTo(float32(g.fCols.offset(k) - g.fixedW), g.scrollPos.y)
proc `topRow=`*(g: DrawGrid, r: int) =
  let k = min(max(r, g.fFixedRows), max(g.fRows.count - 1, 0))
  g.scrollTo(g.scrollPos.x, float32(g.fRows.offset(k) - g.fixedH))

proc fullRows(g: DrawGrid): GridCoord =
  ## First and last completely visible scrolling row ((1, 0): none).
  let v = g.visibleRows
  if v.col > v.row: return (1, 0)
  let a = g.scrollArea
  var first = v.col
  var last = v.row
  let top = float64(g.scrollPos.y) + g.fixedH
  if g.fRows.offset(first) < top - 0.01: inc first
  if g.fRows.offset(last + 1) > top + float64(a.h) + 0.01: dec last
  (first, last)

proc visibleRowCount*(g: DrawGrid): int =
  ## Completely visible scrolling rows (at least 1 for paging).
  let f = g.fullRows
  max(f.row - f.col + 1, 1)

proc makeVisible*(g: DrawGrid, col, row: int) =
  ## Scrolls the minimum distance that shows the (scrolling) cell completely.
  let a = g.scrollArea
  var nx = g.scrollPos.x
  var ny = g.scrollPos.y
  if col >= g.fFixedCols and col < g.fCols.count:
    let l = float32(g.fCols.offset(col) - g.fixedW)
    let r = float32(g.fCols.offset(col + 1) - g.fixedW)
    if r - l > a.w or l < nx: nx = l
    elif r > nx + a.w: nx = r - a.w
  if row >= g.fFixedRows and row < g.fRows.count:
    let t = float32(g.fRows.offset(row) - g.fixedH)
    let b = float32(g.fRows.offset(row + 1) - g.fixedH)
    if b - t > a.h or t < ny: ny = t
    elif b > ny + a.h: ny = b - a.h
  g.scrollTo(nx, ny)

# ------------------------------------------------------------- hit testing

proc colAtX(g: DrawGrid, x: float32): int =
  let v = g.viewport
  if x < v.x or x >= v.x + v.w: return -1
  let px = float64(x - v.x)
  let fw = g.fixedW
  if px < fw: g.fCols.indexAt(px)
  else: g.fCols.indexAt(px + float64(g.scrollPos.x))

proc rowAtY(g: DrawGrid, y: float32): int =
  let v = g.viewport
  if y < v.y or y >= v.y + v.h: return -1
  let py = float64(y - v.y)
  let fh = g.fixedH
  if py < fh: g.fRows.indexAt(py)
  else: g.fRows.indexAt(py + float64(g.scrollPos.y))

proc cellAt*(g: DrawGrid, p: PointF): GridCoord =
  ## The cell under `p` (client coordinates); (-1, -1) outside the cells.
  let c = g.colAtX(p.x)
  let r = g.rowAtY(p.y)
  if c < 0 or r < 0: (-1, -1) else: (c, r)

proc colBorderAt*(g: DrawGrid, p: PointF): int =
  ## The column whose right border is within 3 px of `p` inside the header
  ## rows; -1 when none. Only meaningful with fixed rows.
  let v = g.viewport
  if g.fFixedRows == 0 or p.y < v.y or p.y >= v.y + float32(g.fixedH): return -1
  let area = g.scrollArea
  let c = g.colAtX(p.x)
  if c < 0: return -1
  let x0 = g.colX(c)
  let x1 = x0 + g.fCols.size(c)
  if x1 - p.x <= BorderZone and (c < g.fFixedCols or x1 > area.x + 1 - 1e-3) and
     g.fCols.size(c) > 0 and x1 <= v.right + 0.01:
    return c
  if p.x - x0 <= BorderZone and c > 0 and
     (c - 1 < g.fFixedCols or x0 >= area.x) and g.fCols.size(c - 1) > 0:
    return c - 1
  -1

proc rowBorderAt*(g: DrawGrid, p: PointF): int =
  let v = g.viewport
  if g.fFixedCols == 0 or p.x < v.x or p.x >= v.x + float32(g.fixedW): return -1
  let area = g.scrollArea
  let r = g.rowAtY(p.y)
  if r < 0: return -1
  let y0 = g.rowY(r)
  let y1 = y0 + g.fRows.size(r)
  if y1 - p.y <= BorderZone and (r < g.fFixedRows or y1 > area.y + 1 - 1e-3) and
     g.fRows.size(r) > 0 and y1 <= v.bottom + 0.01:
    return r
  if p.y - y0 <= BorderZone and r > 0 and
     (r - 1 < g.fFixedRows or y0 >= area.y) and g.fRows.size(r - 1) > 0:
    return r - 1
  -1

# ------------------------------------------------------------- selection

proc selection*(g: DrawGrid): GridRect =
  ## The selected cells (inclusive). Empty (right < left) without scrolling cells.
  if g.fCols.count <= g.fFixedCols or g.fRows.count <= g.fFixedRows:
    return (1, 1, 0, 0)
  let rangeSel = goRangeSelect in g.fOptions
  let r0 = if rangeSel: min(g.fAnchorRow, g.fRow) else: g.fRow
  let r1 = if rangeSel: max(g.fAnchorRow, g.fRow) else: g.fRow
  if goRowSelect in g.fOptions:
    (g.fFixedCols, r0, g.fCols.count - 1, r1)
  else:
    let c0 = if rangeSel: min(g.fAnchorCol, g.fCol) else: g.fCol
    let c1 = if rangeSel: max(g.fAnchorCol, g.fCol) else: g.fCol
    (c0, r0, c1, r1)

proc isSelected*(g: DrawGrid, col, row: int): bool =
  let s = g.selection
  col >= s.left and col <= s.right and row >= s.top and row <= s.bottom

proc clampCurrent(g: DrawGrid) =
  g.fCol = min(max(g.fCol, g.fFixedCols), max(g.fCols.count - 1, g.fFixedCols))
  g.fRow = min(max(g.fRow, g.fFixedRows), max(g.fRows.count - 1, g.fFixedRows))
  g.fAnchorCol = min(max(g.fAnchorCol, g.fFixedCols), max(g.fCols.count - 1, g.fFixedCols))
  g.fAnchorRow = min(max(g.fAnchorRow, g.fFixedRows), max(g.fRows.count - 1, g.fFixedRows))

proc selectionChanged(g: DrawGrid) =
  g.invalidate()
  if g.onSelectionChanged != nil: g.onSelectionChanged(g)

# ------------------------------------------------------------------ editing

proc positionEditor(g: DrawGrid) =
  if not g.fEditing or g.fEditor == nil: return
  let a = g.scrollArea
  let r = g.cellRect(g.fEditCol, g.fEditRow)
  let vis = r.intersect(a)
  if vis.isEmpty:
    g.fEditor.setBounds(-100, -100, 1, 1)
  else:
    g.fEditor.setBounds(vis.x, vis.y, vis.w, vis.h)

proc endEdit*(g: DrawGrid, commit: bool, refocus = true) =
  ## Closes the editor, storing the text when `commit` and it changed.
  if not g.fEditing: return
  g.fEditing = false
  let txt = g.fEditor.text
  let c = g.fEditCol
  let r = g.fEditRow
  if commit and txt != g.fEditOrig: g.setCellText(c, r, txt)
  let had = g.fEditor.focused
  g.fEditor.visible = false
  if refocus and had: g.setFocus()
  g.invalidate()

proc moveCurrent*(g: DrawGrid, col, row: int, extend = false): bool {.discardable.}

proc editorKey(g: DrawGrid, key: var Key, shift: ShiftState) =
  let r = g.fEditRow
  let c = g.fEditCol
  var dc, dr = 0
  if key == keyEnter: dr = 1
  elif key == keyDown and shift * {ssCtrl, ssAlt} == {}: dr = 1
  elif key == keyUp and shift * {ssCtrl, ssAlt} == {}: dr = -1
  elif key == keyEscape:
    key = Key(0)
    g.endEdit(false)
    return
  elif key == keyTab and goTabs in g.fOptions and shift * {ssCtrl, ssAlt} == {}:
    if ssShift in shift:
      dc = -1
    else:
      dc = 1
  else: return
  key = Key(0)
  g.endEdit(true)
  var nc = c + dc
  var nr = r + dr
  if dc != 0:
    if nc >= g.fCols.count: nc = g.fFixedCols; nr = r + 1
    elif nc < g.fFixedCols: nc = g.fCols.count - 1; nr = r - 1
  g.moveCurrent(nc, nr)

proc ensureEditor(g: DrawGrid) =
  if g.fEditor != nil: return
  let e = newEdit(g)
  e.visible = false
  e.tabStop = false
  e.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
    if g.fEditing: g.editorKey(k, sh)
  e.onExit = proc(s: Control) =
    if g.fEditing and not g.fEditor.focused: g.endEdit(true, refocus = false)
  g.fEditor = e

proc startEdit*(g: DrawGrid, initial = "", useInitial = false): bool {.discardable.} =
  ## Opens the editor on the current cell (`initial` replaces the cell text
  ## when `useInitial`). False when the cell cannot be edited.
  if g.fEditing: return true
  if not g.canEditCell(g.fCol, g.fRow): return false
  g.makeVisible(g.fCol, g.fRow)
  g.ensureEditor()
  g.fEditCol = g.fCol
  g.fEditRow = g.fRow
  g.fEditOrig = g.cellText(g.fCol, g.fRow)
  g.fEditing = true
  let e = g.fEditor
  e.text = if useInitial: initial else: g.fEditOrig
  e.visible = true
  g.positionEditor()
  e.setFocus()
  if not e.focused:                       # cannot take focus (no window yet)
    g.fEditing = false
    e.visible = false
    return false
  e.select(e.text.len, 0)
  g.invalidate()
  true

proc cancelEdit*(g: DrawGrid) = g.endEdit(false)

# ------------------------------------------------------------ cell access

proc moveCurrent*(g: DrawGrid, col, row: int, extend = false): bool {.discardable.} =
  ## Moves the current cell (clamped to the scrolling cells), asking
  ## `onSelectCell`; `extend` grows the range selection (needs goRangeSelect).
  if g.fCols.count <= g.fFixedCols or g.fRows.count <= g.fFixedRows: return false
  let nc = min(max(col, g.fFixedCols), g.fCols.count - 1)
  let nr = min(max(row, g.fFixedRows), g.fRows.count - 1)
  let ext = extend and goRangeSelect in g.fOptions
  if nc == g.fCol and nr == g.fRow:
    if not ext and (g.fAnchorCol != nc or g.fAnchorRow != nr):
      g.fAnchorCol = nc
      g.fAnchorRow = nr
      g.selectionChanged()
    return true
  if g.fEditing:
    g.fMoving = true
    g.endEdit(true)
    g.fMoving = false
  var ok = true
  if g.onSelectCell != nil: g.onSelectCell(g, nc, nr, ok)
  if not ok: return false
  g.fCol = nc
  g.fRow = nr
  if not ext:
    g.fAnchorCol = nc
    g.fAnchorRow = nr
  g.makeVisible(nc, nr)
  g.selectionChanged()
  if goAlwaysShowEditor in g.fOptions: g.startEdit()
  true

proc selectCell*(g: DrawGrid, col, row: int): bool {.discardable.} =
  g.moveCurrent(col, row)

proc `col=`*(g: DrawGrid, c: int) = g.moveCurrent(c, g.fRow)
proc `row=`*(g: DrawGrid, r: int) = g.moveCurrent(g.fCol, r)

proc setSelection*(g: DrawGrid, left, top, right, bottom: int) =
  ## Programmatic range: the anchor is (left, top), the current cell (right,
  ## bottom). Without goRangeSelect only the current cell is selected.
  if g.fCols.count <= g.fFixedCols or g.fRows.count <= g.fFixedRows: return
  if not g.moveCurrent(right, bottom): return
  g.fAnchorCol = min(max(left, g.fFixedCols), g.fCols.count - 1)
  g.fAnchorRow = min(max(top, g.fFixedRows), g.fRows.count - 1)
  g.selectionChanged()

proc selectAll*(g: DrawGrid) =
  if goRangeSelect notin g.fOptions: return
  let sp = g.scrollPos                 # selecting everything does not scroll
  g.setSelection(g.fFixedCols, g.fFixedRows, g.fCols.count - 1, g.fRows.count - 1)
  g.scrollTo(sp.x, sp.y)

# --------------------------------------------------------- sizes and counts

proc `colCount=`*(g: DrawGrid, n: int) =
  if g.fEditing: g.endEdit(false)
  g.fCols.setCount(n)
  g.fFixedCols = min(g.fFixedCols, g.fCols.count)
  g.clampCurrent()
  g.sizeChanged()
  g.refreshContent()

proc `rowCount=`*(g: DrawGrid, n: int) =
  if g.fEditing: g.endEdit(false)
  g.fRows.setCount(n)
  g.fFixedRows = min(g.fFixedRows, g.fRows.count)
  g.clampCurrent()
  g.sizeChanged()
  g.refreshContent()

proc `fixedCols=`*(g: DrawGrid, n: int) =
  g.fFixedCols = min(max(n, 0), g.fCols.count)
  g.clampCurrent()
  g.refreshContent()

proc `fixedRows=`*(g: DrawGrid, n: int) =
  g.fFixedRows = min(max(n, 0), g.fRows.count)
  g.clampCurrent()
  g.refreshContent()

proc `defaultColWidth=`*(g: DrawGrid, w: float32) =
  g.fCols.setDefaultSize(w)
  g.refreshContent()
proc `defaultRowHeight=`*(g: DrawGrid, h: float32) =
  g.fRows.setDefaultSize(h)
  g.refreshContent()

proc setColWidth*(g: DrawGrid, c: int, w: float32) =
  if c < 0 or c >= g.fCols.count or g.fCols.size(c) == max(w, 0): return
  g.fCols.setSize(c, w)
  g.refreshContent()
  g.positionEditor()
  if g.onColWidthChanged != nil: g.onColWidthChanged(g, c)

proc setRowHeight*(g: DrawGrid, r: int, h: float32) =
  if r < 0 or r >= g.fRows.count or g.fRows.size(r) == max(h, 0): return
  g.fRows.setSize(r, h)
  g.refreshContent()
  g.positionEditor()
  if g.onRowHeightChanged != nil: g.onRowHeightChanged(g, r)

proc resetSizes*(g: DrawGrid) =
  ## Back to the default widths and heights.
  g.fCols.resetSizes()
  g.fRows.resetSizes()
  g.refreshContent()
  g.positionEditor()

func colWidths*(g: DrawGrid): AxisProxy = AxisProxy(g: g, isCol: true)
func rowHeights*(g: DrawGrid): AxisProxy = AxisProxy(g: g, isCol: false)
proc `[]`*(p: AxisProxy, i: int): float32 =
  if p.isCol: p.g.colWidth(i) else: p.g.rowHeight(i)
proc `[]=`*(p: AxisProxy, i: int, v: float32) =
  if p.isCol: p.g.setColWidth(i, v) else: p.g.setRowHeight(i, v)

proc autoFitColumn*(g: DrawGrid, c: int) =
  ## Sets the width to `measureColumn(c)` (at least `minColWidth`).
  if c < 0 or c >= g.fCols.count: return
  g.setColWidth(c, max(g.measureColumn(c), g.minColWidth))

proc `options=`*(g: DrawGrid, v: GridOptions) =
  g.fOptions = v
  if goEditing notin v and g.fEditing: g.endEdit(false)
  if goRangeSelect notin v:
    g.fAnchorCol = g.fCol
    g.fAnchorRow = g.fRow
  g.invalidate()

proc `horzLines=`*(g: DrawGrid, v: bool) =
  g.fHLines = v
  g.invalidate()
proc `vertLines=`*(g: DrawGrid, v: bool) =
  g.fVLines = v
  g.invalidate()
proc `hotTrack=`*(g: DrawGrid, v: bool) =
  g.fHotTrack = v
  g.fHotRow = -1
  g.invalidate()

proc updateHot(g: DrawGrid) =
  var h = -1
  if g.fHotTrack and g.isEnabled:
    let cell = g.cellAt(g.fMouse)
    if cell.row >= g.fFixedRows: h = cell.row
  if h != g.fHotRow:
    g.fHotRow = h
    g.invalidate()

method contentScrolled*(g: DrawGrid) =
  procCall contentScrolled(ScrollingControl(g))
  g.positionEditor()
  g.updateHot()

method beforeLayout*(g: DrawGrid) =
  g.refreshContent()
  procCall beforeLayout(ScrollingControl(g))

method doResize*(g: DrawGrid) =
  procCall doResize(ScrollingControl(g))
  g.positionEditor()

# ------------------------------------------------------------- clipboard

proc copyText*(g: DrawGrid): string =
  ## The selection as TSV (tabs / line breaks inside cells become spaces).
  let s = g.selection
  for r in s.top .. s.bottom:
    for c in s.left .. s.right:
      var t = g.cellText(c, r)
      for ch in t.mitems:
        if ch in {'\t', '\r', '\n'}: ch = ' '
      result.add t
      if c < s.right: result.add '\t'
    if r < s.bottom: result.add '\n'

proc copySelection*(g: DrawGrid) =
  if g.selection.right < g.selection.left: return
  editClipboardSet(g.copyText())

func parseTsv*(s: string): seq[seq[string]] =
  var text = s.replace("\r\n", "\n").replace('\r', '\n')
  if text.endsWith("\n"): text.setLen(text.len - 1)
  if s.len == 0: return
  for line in text.split('\n'): result.add line.split('\t')

proc pasteText*(g: DrawGrid, text: string): bool {.discardable.} =
  ## Writes TSV `text` starting at the top-left of the selection (a single
  ## value fills the whole selection); only editable cells are written and
  ## nothing grows. The pasted block becomes the selection.
  let block0 = parseTsv(text)
  if block0.len == 0 or g.selection.right < g.selection.left: return false
  let s = g.selection
  var changed = false
  if block0.len == 1 and block0[0].len == 1 and
     (s.right > s.left or s.bottom > s.top):
    for r in s.top .. s.bottom:
      for c in s.left .. s.right:
        if g.canEditCell(c, r):
          g.setCellText(c, r, block0[0][0])
          changed = true
  else:
    var maxC = s.left
    var maxR = s.top
    for dr, line in block0:
      for dc, v in line:
        let c = s.left + dc
        let r = s.top + dr
        if c < g.fCols.count and r < g.fRows.count and g.canEditCell(c, r):
          g.setCellText(c, r, v)
          changed = true
          maxC = max(maxC, c)
          maxR = max(maxR, r)
    if changed and goRangeSelect in g.fOptions and
       (maxC > s.left or maxR > s.top):
      g.setSelection(s.left, s.top, maxC, maxR)
  if changed: g.invalidate()
  changed

proc pasteFromClipboard*(g: DrawGrid) =
  discard g.pasteText(editClipboardGet())

proc clearSelectedCells*(g: DrawGrid) =
  let s = g.selection
  for r in s.top .. s.bottom:
    for c in s.left .. s.right:
      if g.canEditCell(c, r) and g.cellText(c, r).len > 0: g.setCellText(c, r, "")
  g.invalidate()

# ---------------------------------------------------------------- user input

method canFocus*(g: DrawGrid): bool = g.isVisible and g.isEnabled
method wantsTextInput*(g: DrawGrid): bool = goEditing in g.fOptions
method textInputRect*(g: DrawGrid): RectF = g.cellRect(g.fCol, g.fRow)

method doEnter*(g: DrawGrid) =
  procCall doEnter(Control(g))
  g.invalidate()
  if goAlwaysShowEditor in g.fOptions and not g.fEditing and not g.fMoving and
     g.fDrag == dmNone:
    g.startEdit()

method doExit*(g: DrawGrid) =
  g.fDrag = dmNone
  g.invalidate()
  procCall doExit(Control(g))

method doMouseLeave*(g: DrawGrid) =
  g.fMouse = pointF(-1, -1)
  if g.fDrag == dmNone and g.cursor != crDefault: g.cursor = crDefault
  g.updateHot()
  procCall doMouseLeave(Control(g))

proc updateCursor(g: DrawGrid, p: PointF) =
  let cur =
    if goColSizing in g.fOptions and g.colBorderAt(p) >= 0: crSizeWE
    elif goRowSizing in g.fOptions and g.rowBorderAt(p) >= 0: crSizeNS
    else: crDefault
  if g.cursor != cur: g.cursor = cur

method doMouseDown*(g: DrawGrid, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  g.fDownOnBorder = false
  if button == mbLeft:
    let p = pointF(x, y)
    g.fMouse = p
    let cb = if goColSizing in g.fOptions: g.colBorderAt(p) else: -1
    let rb = if cb < 0 and goRowSizing in g.fOptions: g.rowBorderAt(p) else: -1
    if cb >= 0:
      g.fDownOnBorder = true
      if ssDouble in shift: g.autoFitColumn(cb)
      else:
        g.fDrag = dmColSize
        g.fDragIdx = cb
        g.fDragStart = x
        g.fDragSize = g.fCols.size(cb)
    elif rb >= 0:
      g.fDownOnBorder = true
      if ssDouble in shift: g.setRowHeight(rb, g.fRows.defaultSize)
      else:
        g.fDrag = dmRowSize
        g.fDragIdx = rb
        g.fDragStart = y
        g.fDragSize = g.fRows.size(rb)
    else:
      let cell = g.cellAt(p)
      if cell.col >= 0:
        if cell.col < g.fFixedCols or cell.row < g.fFixedRows:
          g.fixedCellClicked(cell.col, cell.row)
        else:
          g.fDrag = dmSelect
          g.moveCurrent(cell.col, cell.row, extend = ssShift in shift)
  procCall doMouseDown(Control(g), button, shift, x, y)

method doMouseMove*(g: DrawGrid, shift: ShiftState, x, y: float32) =
  let p = pointF(x, y)
  g.fMouse = p
  if g.fDrag != dmNone and ssLeft notin shift:
    g.fDrag = dmNone
  case g.fDrag
  of dmColSize:
    g.setColWidth(g.fDragIdx, max(g.fDragSize + x - g.fDragStart, g.minColWidth))
  of dmRowSize:
    g.setRowHeight(g.fDragIdx, max(g.fDragSize + y - g.fDragStart, g.minRowHeight))
  of dmSelect:
    let a = g.scrollArea
    let vc = g.visibleCols
    let vr = g.visibleRows
    var c = g.colAtX(x)
    var r = g.rowAtY(y)
    if x >= a.right: c = min(vc.row + 1, g.fCols.count - 1)
    elif x < a.x: c = max(vc.col - 1, g.fFixedCols)
    if y >= a.bottom: r = min(vr.row + 1, g.fRows.count - 1)
    elif y < a.y: r = max(vr.col - 1, g.fFixedRows)
    if c < 0: c = g.fCol
    if r < 0: r = g.fRow
    g.moveCurrent(c, r, extend = true)
  of dmNone:
    g.updateCursor(p)
    g.updateHot()
  procCall doMouseMove(Control(g), shift, x, y)

method doMouseUp*(g: DrawGrid, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft:
    g.fDrag = dmNone
    g.updateCursor(pointF(x, y))
  procCall doMouseUp(Control(g), button, shift, x, y)

method doDblClick*(g: DrawGrid) =
  if not g.fDownOnBorder and goEditing in g.fOptions and not g.fEditing:
    let cell = g.cellAt(g.fMouse)
    if cell.col == g.fCol and cell.row == g.fRow: g.startEdit()
  procCall doDblClick(Control(g))

proc moveTab(g: DrawGrid, forward: bool): bool =
  var c = g.fCol
  var r = g.fRow
  if forward:
    inc c
    if c >= g.fCols.count:
      c = g.fFixedCols
      inc r
      if r >= g.fRows.count: return false
  else:
    dec c
    if c < g.fFixedCols:
      c = g.fCols.count - 1
      dec r
      if r < g.fFixedRows: return false
  g.moveCurrent(c, r)
  true

method doKeyDown*(g: DrawGrid, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(g), key, shift)
  if key == Key(0) or not g.isEnabled or g.fEditing: return
  if shift * {ssAlt, ssSuper} != {}: return
  if g.fCols.count <= g.fFixedCols or g.fRows.count <= g.fFixedRows: return
  let ctrl = ssCtrl in shift
  let ext = ssShift in shift
  var handled = true
  if key == keyLeft: g.moveCurrent(g.fCol - 1, g.fRow, ext)
  elif key == keyRight: g.moveCurrent(g.fCol + 1, g.fRow, ext)
  elif key == keyUp: g.moveCurrent(g.fCol, g.fRow - 1, ext)
  elif key == keyDown: g.moveCurrent(g.fCol, g.fRow + 1, ext)
  elif key == keyHome:
    g.moveCurrent(g.fFixedCols, if ctrl: g.fFixedRows else: g.fRow, ext)
  elif key == keyEnd:
    g.moveCurrent(g.fCols.count - 1, if ctrl: g.fRows.count - 1 else: g.fRow, ext)
  elif key == keyPageDown or key == keyPageUp:
    let f = g.fullRows
    let span = max(f.row - f.col, 1)
    var target: int
    if key == keyPageDown:
      target = if g.fRow < f.row: f.row else: g.fRow + span
    else:
      target = if g.fRow > f.col: f.col else: g.fRow - span
    g.moveCurrent(g.fCol, target, ext)
  elif key == keyTab and goTabs in g.fOptions and shift * {ssCtrl} == {}:
    handled = g.moveTab(not ext)
  elif key == keyEnter or key == keyF2:
    handled = g.startEdit()
  elif key == keyDelete and goEditing in g.fOptions:
    g.clearSelectedCells()
  elif ctrl and key == 'a'.key: g.selectAll()
  elif ctrl and key == 'c'.key: g.copySelection()
  elif ctrl and key == 'v'.key and goEditing in g.fOptions: g.pasteFromClipboard()
  else: handled = false
  if handled: key = Key(0)

method doKeyPress*(g: DrawGrid, text: var string) =
  procCall doKeyPress(Control(g), text)
  if text.len > 0 and goEditing in g.fOptions and not g.fEditing and
     text[0] >= ' ' and text[0] != '\x7f' and g.canEditCell(g.fCol, g.fRow):
    if g.startEdit(text, true): text = ""

# -------------------------------------------------------------------- paint

proc cellTextColor*(g: DrawGrid, state: GridDrawStates): Color =
  let t = g.theme
  if not g.isEnabled: t.textDisabled
  elif gdSelected in state and (g.focused or g.fEditing): t.selectionText
  else: t.text

proc drawCellText*(g: DrawGrid, c: Canvas, rect: RectF, text: string,
                   state: GridDrawStates, align = taLeft, bold = false) =
  ## Standard cell text: padded, vertically centred, ellipsis when too long.
  var r = rect
  r.x += CellPad
  r.w = max(r.w - 2 * CellPad, 0)
  c.textRect(text, if bold: g.font.bold else: g.font, r, g.cellTextColor(state),
             align, vaCenter)

proc paintPane(g: DrawGrid, c: Canvas, cols, rows: GridCoord, clip: RectF,
               fixedPane: bool, sel: GridRect, focused: bool) =
  if cols.col > cols.row or rows.col > rows.row or clip.isEmpty: return
  let t = g.theme
  c.pushClip(clip)
  c.fillRect(clip, if fixedPane: t.surfaceAlt else: t.surface)
  let vl = g.fVLines
  let hl = g.fHLines
  let enabled = g.isEnabled
  for r in rows.col .. rows.row:
    let y = g.rowY(r)
    let h = g.fRows.size(r)
    if h <= 0: continue
    let rowFixed = r < g.fFixedRows
    for cc in cols.col .. cols.row:
      let w = g.fCols.size(cc)
      if w <= 0: continue
      let x = g.colX(cc)
      let isFixed = rowFixed or cc < g.fFixedCols
      var st: GridDrawStates
      if isFixed: st.incl gdFixed
      else:
        if cc >= sel.left and cc <= sel.right and r >= sel.top and r <= sel.bottom:
          st.incl gdSelected
        if g.fHotTrack and r == g.fHotRow: st.incl gdHot
        if focused and cc == g.fCol and r == g.fRow and goRowSelect notin g.fOptions:
          st.incl gdFocused
      let slot = rectF(x, y, w, h)
      if gdSelected in st:
        c.fillRect(slot, if focused and enabled: t.selection else: t.selectionInactive)
      elif gdHot in st:
        c.fillRect(slot, t.hover)
      let rect = rectF(x, y, max(w - (if vl or isFixed: 1 else: 0), 0),
                       max(h - (if hl or isFixed: 1 else: 0), 0))
      g.drawCell(c, cc, r, rect, st)
      if gdFocused in st:
        c.frameRect(rect, t.focusRing, t.focusRingWidth)
  # grid lines
  let lineCol = if fixedPane: t.borderStrong else: t.border
  if vl or fixedPane:
    for cc in cols.col .. cols.row:
      let w = g.fCols.size(cc)
      if w <= 0: continue
      c.fillRect(rectF(g.colX(cc) + w - 1, clip.y, 1, clip.h),
                 if cc < g.fFixedCols: t.borderStrong else: lineCol)
  if hl or fixedPane:
    for r in rows.col .. rows.row:
      let h = g.fRows.size(r)
      if h <= 0: continue
      c.fillRect(rectF(clip.x, g.rowY(r) + h - 1, clip.w, 1),
                 if r < g.fFixedRows: t.borderStrong else: lineCol)
  c.popClip()

method paint*(g: DrawGrid, c: Canvas) =
  let t = g.theme
  let enabled = g.isEnabled
  let r = g.clientRect
  c.fillRoundRect(r, t.radius, if enabled: t.surface else: t.surfaceAlt)
  let v = g.viewport
  let a = g.scrollArea
  let fw = float32(g.fixedW)
  let fh = float32(g.fixedH)
  let focused = g.focused or g.fEditing
  let sel = g.selection
  let vc = g.visibleCols
  let vr = g.visibleRows
  let fc = (0, g.fFixedCols - 1)
  let fr = (0, g.fFixedRows - 1)
  g.paintPane(c, vc, vr, a, false, sel, focused)
  g.paintPane(c, fc, vr, rectF(v.x, a.y, min(fw, v.w), a.h), true, sel, focused)
  g.paintPane(c, vc, fr, rectF(a.x, v.y, a.w, min(fh, v.h)), true, sel, focused)
  g.paintPane(c, fc, fr, rectF(v.x, v.y, min(fw, v.w), min(fh, v.h)), true, sel, focused)
  c.strokeRoundRect(r, t.radius, if g.focused: t.focusRing else: t.borderStrong,
                    if g.focused: t.focusRingWidth else: t.borderWidth)
  procCall paint(Control(g), c)

# ------------------------------------------------------------ construction

proc initDrawGrid*(g: DrawGrid, owner: Component = nil) =
  g.initScrollingControl(owner)
  g.fCols = initAxis(5, 64)
  g.fRows = initAxis(5, 24)
  g.fFixedCols = 1
  g.fFixedRows = 1
  g.fOptions = {goThumbTracking, goColSizing}
  g.fHLines = true
  g.fVLines = true
  g.fHotRow = -1
  g.minColWidth = 16
  g.minRowHeight = 8
  g.fCol = 1
  g.fRow = 1
  g.fAnchorCol = 1
  g.fAnchorRow = 1
  g.tabStop = true
  g.padding = spacing(1)
  g.setBounds(0, 0, 320, 160)
  g.refreshContent()

proc newDrawGrid*(parent: Container = nil, left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): DrawGrid =
  new result
  result.initDrawGrid(parent)
  result.placeControl(parent, left, top, width, height)

# ================================================================ StringGrid

type
  StringGrid* = ref object of DrawGrid
    fData: seq[seq[string]]            # [row][col], sparse (short / empty rows)
    fAligns: seq[HAlign]
    fSortCol: int
    fSortAsc: bool
    fSortOnHeader: bool
    onHeaderClick*: GridIndexEvent

  CellsProxy* = object
    g: StringGrid
  LinesProxy* = object
    g: StringGrid
    byCol: bool
  AlignProxy* = object
    g: StringGrid

func cellOf(g: StringGrid, col, row: int): string =
  if row >= 0 and row < g.fData.len and col >= 0 and col < g.fData[row].len:
    g.fData[row][col]
  else: ""

proc putCell(g: StringGrid, col, row: int, v: string) =
  if col < 0 or row < 0 or col >= g.colCount or row >= g.rowCount: return
  if row >= g.fData.len:
    if v.len == 0: return
    g.fData.setLen(row + 1)
  if col >= g.fData[row].len:
    if v.len == 0: return
    g.fData[row].setLen(col + 1)
  g.fData[row][col] = v

method sizeChanged*(g: StringGrid) =
  if g.fData.len > g.rowCount: g.fData.setLen(g.rowCount)
  for r in 0 ..< g.fData.len:
    if g.fData[r].len > g.colCount: g.fData[r].setLen(g.colCount)
  if g.fSortCol >= g.colCount: g.fSortCol = -1

func cells*(g: StringGrid): CellsProxy = CellsProxy(g: g)
proc `[]`*(p: CellsProxy, col, row: int): string = p.g.cellOf(col, row)
proc `[]=`*(p: CellsProxy, col, row: int, v: string) =
  if p.g.cellOf(col, row) == v: return
  p.g.putCell(col, row, v)
  p.g.invalidate(p.g.cellRect(col, row))

func cols*(g: StringGrid): LinesProxy = LinesProxy(g: g, byCol: true)
func rows*(g: StringGrid): LinesProxy = LinesProxy(g: g, byCol: false)

proc `[]`*(p: LinesProxy, i: int): seq[string] =
  ## All cells of column / row `i` (a copy).
  if p.byCol:
    result = newSeq[string](p.g.rowCount)
    for r in 0 ..< result.len: result[r] = p.g.cellOf(i, r)
  else:
    result = newSeq[string](p.g.colCount)
    for c in 0 ..< result.len: result[c] = p.g.cellOf(c, i)

proc `[]=`*(p: LinesProxy, i: int, v: openArray[string]) =
  ## Assigns the first cells of column / row `i`; extra values are ignored,
  ## missing ones are left unchanged.
  if p.byCol:
    for r in 0 ..< min(v.len, p.g.rowCount): p.g.putCell(i, r, v[r])
  else:
    for c in 0 ..< min(v.len, p.g.colCount): p.g.putCell(c, i, v[c])
  p.g.invalidate()

func colAlignments*(g: StringGrid): AlignProxy = AlignProxy(g: g)
proc `[]`*(p: AlignProxy, c: int): HAlign =
  if c >= 0 and c < p.g.fAligns.len: p.g.fAligns[c] else: taLeft
proc `[]=`*(p: AlignProxy, c: int, a: HAlign) =
  if c < 0 or c >= p.g.colCount: return
  if c >= p.g.fAligns.len: p.g.fAligns.setLen(c + 1)
  p.g.fAligns[c] = a
  p.g.invalidate()

func sortColumn*(g: StringGrid): int = g.fSortCol
func sortAscending*(g: StringGrid): bool = g.fSortAsc
func sortOnHeaderClick*(g: StringGrid): bool = g.fSortOnHeader
proc `sortOnHeaderClick=`*(g: StringGrid, v: bool) = g.fSortOnHeader = v

proc clearCells*(g: StringGrid) =
  g.fData.setLen(0)
  g.invalidate()

proc insertRow*(g: StringGrid, at: int) =
  ## Inserts an empty row at `at` (clamped to the scrolling rows).
  let i = min(max(at, g.fixedRows), g.rowCount)
  g.endEdit(false)
  if i < g.fData.len: g.fData.insert(newSeq[string](), i)
  g.rowCount = g.rowCount + 1
  g.invalidate()

proc deleteRow*(g: StringGrid, at: int) =
  if at < g.fixedRows or at >= g.rowCount: return
  g.endEdit(false)
  if at < g.fData.len: g.fData.delete(at)
  g.rowCount = g.rowCount - 1
  g.invalidate()

proc compareCells*(a, b: string): int =
  ## Default sort order: numbers before text, numbers by value, text without
  ## regard to case.
  var fa, fb: float
  let na = a.len > 0 and parseFloat(a, fa) == a.len
  let nb = b.len > 0 and parseFloat(b, fb) == b.len
  if na and nb: cmp(fa, fb)
  elif na: -1
  elif nb: 1
  else: cmpIgnoreCase(a, b)

proc sortByColumn*(g: StringGrid, col: int, ascending = true,
                   cmpProc: proc(a, b: string): int = nil) =
  ## Stable sort of the scrolling rows by column `col` (the fixed rows stay).
  if col < 0 or col >= g.colCount: return
  g.endEdit(false)
  let first = g.fixedRows
  let n = g.rowCount - first
  if n > 1:
    if g.fData.len < g.rowCount: g.fData.setLen(g.rowCount)
    var order = newSeq[int](n)
    for i in 0 ..< n: order[i] = first + i
    let f = if cmpProc != nil: cmpProc else: compareCells
    let data = g.fData
    order.sort(proc(x, y: int): int =
      let a = if col < data[x].len: data[x][col] else: ""
      let b = if col < data[y].len: data[y][col] else: ""
      result = f(a, b)
      if not ascending: result = -result
      if result == 0: result = cmp(x, y))
    for i in 0 ..< n: g.fData[first + i] = data[order[i]]
  g.fSortCol = col
  g.fSortAsc = ascending
  g.invalidate()

method cellText*(g: StringGrid, col, row: int): string =
  result = g.cellOf(col, row)
  if g.onGetEditText != nil: g.onGetEditText(g, col, row, result)

method setCellText*(g: StringGrid, col, row: int, text: string) =
  g.cells[col, row] = text
  procCall setCellText(DrawGrid(g), col, row, text)

method measureColumn*(g: StringGrid, col: int): float32 =
  if g.onMeasureColumn != nil: return g.onMeasureColumn(g, col)
  var w = 0'f32
  let top = g.topRow
  let last = min(g.rowCount - 1, top + 400)
  proc see(g: StringGrid, r: int, w: var float32) =
    let s = g.cellOf(col, r)
    if s.len > 0:
      let bold = r < g.fixedRows or col < g.fixedCols
      w = max(w, g.textWidth(s, if bold: g.font.bold else: g.font))
  for r in 0 ..< g.fixedRows: g.see(r, w)
  for r in top .. last: g.see(r, w)
  w + 2 * CellPad + 2 + (if g.fSortCol == col and g.fixedRows > 0: 14'f32 else: 0'f32)

method drawCell*(g: StringGrid, c: Canvas, col, row: int, rect: RectF,
                 state: GridDrawStates) =
  if g.onDrawCell != nil:
    g.onDrawCell(g, c, col, row, rect, state)
    return
  var r = rect
  let isHeader = gdFixed in state
  let sorted = isHeader and col == g.fSortCol and row == g.fixedRows - 1 and
               col >= g.fixedCols
  if sorted:
    r.w = max(r.w - 14, 0)
    let t = g.theme
    c.drawArrow(pointF(rect.right - 10, rect.y + rect.h / 2), 4,
                if g.fSortAsc: adUp else: adDown, t.textMuted)
  g.drawCellText(c, r, g.cellOf(col, row), state, g.colAlignments[col], isHeader)

method fixedCellClicked*(g: StringGrid, col, row: int) =
  procCall fixedCellClicked(DrawGrid(g), col, row)
  if row == g.fixedRows - 1 and col >= g.fixedCols:
    if g.onHeaderClick != nil: g.onHeaderClick(g, col)
    if g.fSortOnHeader:
      g.sortByColumn(col, not (g.fSortCol == col and g.fSortAsc))

proc initStringGrid*(g: StringGrid, owner: Component = nil) =
  g.initDrawGrid(owner)
  g.fSortCol = -1
  g.fSortAsc = true
  g.fOptions = {goThumbTracking, goColSizing, goRangeSelect, goEditing, goTabs}

proc newStringGrid*(parent: Container = nil, left = 0'f32, top = 0'f32,
                    width = -1'f32, height = -1'f32): StringGrid =
  new result
  result.initStringGrid(parent)
  result.placeControl(parent, left, top, width, height)
