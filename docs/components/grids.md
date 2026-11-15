# DrawGrid and StringGrid

Scrolling tables with frozen header rows and columns (Delphi `TDrawGrid` and
`TStringGrid`). `StringGrid` stores text per cell. `DrawGrid` stores nothing: you
paint each cell yourself, so it suits big or computed data.

## Quick example

```nim
let grid = newStringGrid(form, 16, 16, 420, 200)
grid.colCount = 3
grid.rowCount = 4
grid.fixedRows = 1                              # header row
grid.cells[0, 0] = "Item"
grid.cells[1, 0] = "Qty"
grid.cells[2, 0] = "Price"
grid.cells[0, 1] = "Pen"
grid.cells[1, 1] = "12"
grid.options = {goColSizing, goEditing, goTabs} # resize columns, edit in place
grid.colWidths[0] = 160
grid.onSelectionChanged = proc(sender: Control) =
  echo "cell ", grid.col, ",", grid.row, " = ", grid.cells[grid.col, grid.row]
```

A `DrawGrid`:

```nim
let big = newDrawGrid(form, 16, 230, 420, 120)
big.colCount = 50
big.rowCount = 1_000_000
big.fixedRows = 1
big.onDrawCell = proc(sender: Control, c: Canvas, col, row: int,
                      rect: RectF, state: GridDrawStates) =
  big.drawCellText(c, rect, $col & "," & $row, state)
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `colCount`, `rowCount` | int | Size, including fixed cells |
| `fixedCols`, `fixedRows` | int | Frozen header cells |
| `defaultColWidth`, `defaultRowHeight` | float32 | Defaults (64 and 24) |
| `colWidths[c]`, `rowHeights[r]` | float32 | Per-slot overrides |
| `options` | `GridOptions` | `goRangeSelect`, `goRowSelect`, `goColSizing`, `goRowSizing`, `goColMoving`, `goEditing`, `goTabs`, `goAlwaysShowEditor` |
| `col`, `row` | int | Current cell (never a fixed one) |
| `selection` | `GridRect` | Selected range (inclusive) |
| `horzLines`, `vertLines`, `hotTrack` | bool | Look |
| `StringGrid.cells[c, r]` | string | Cell text. Also `rows[r]`, `cols[c]` as `seq[string]` |
| `StringGrid.colAlignments[c]` | `HAlign` | Column text alignment |
| `StringGrid.sortOnHeaderClick` | bool | Click a header to sort |

## Events

| Event | Description |
|---|---|
| `onSelectCell(sender, col, row, canSelect: var bool)` | Veto a move |
| `onSelectionChanged` | The selection moved |
| `onDrawCell(sender, canvas, col, row, rect, state)` | DrawGrid: paint a cell |
| `onGetEditText`, `onSetEditText` | Editing hooks for a DrawGrid |
| `onFixedCellClick(sender, col, row)` | A header cell was clicked |
| `onColWidthChanged`, `onRowHeightChanged` | After a resize |
| `onColumnMoved(sender, fromCol, toCol)` | After a column was moved (`goColMoving` or `moveColumn`) |

## Methods

| Method | Description |
|---|---|
| `cellRect(c, r)`, `cellAt(point)`, `makeVisible(col, row)` | Geometry and scrolling |
| `setSelection(l, t, r, b)`, `selectCell(c, r)`, `selectAll()` | Selection |
| `startEdit()`, `endEdit(commit)`, `cancelEdit()` | In-place editor |
| `autoFitColumn(c)`, `setColWidth`, `setRowHeight`, `resetSizes()` | Sizes |
| `moveColumn(fromCol, toCol)` | Reorder a scrolling column (what dragging a header does) |
| `copySelection()`, `pasteFromClipboard()`, `clearSelectedCells()` | Clipboard (tab separated) |
| StringGrid: `insertRow`, `deleteRow`, `clearCells`, `sortByColumn(col, ascending)` | Data |

## Tips

* Only visible cells are drawn, so a million rows scroll fine.
* Fixed cells never become the current cell.
* In a DrawGrid, `rect` excludes the 1 px grid line. Use `cellTextColor(state)` and
  `drawCellText` for theme-correct text.
* Without `goEditing`, cells are read-only. Enter or F2 starts editing.
* `autoFitColumn` measures the header rows and at most 400 rows below the first
  visible one; for exact auto-fit of huge grids handle `onMeasureColumn`.
* **Column dragging**: add `goColMoving` to `options`, then drag a header cell
  (a cell of the fixed rows) sideways. A bar shows where the column lands, the
  grid scrolls at the edges, and the column ends up where you let go. A click
  without movement is still a header click, but it fires on release (so a
  sorting header and a draggable header can be the same cell). Fixed columns
  never move and nothing moves into them.

  A StringGrid moves the cells, widths, alignments and the sort arrow by
  itself. A DrawGrid owns no data, so you remap yours in `onColumnMoved`; the
  column that was `fromCol` is now `toCol` and those in between shifted by one:

  ```nim
  var order = @[0, 1, 2, 3, 4]            # which data column each grid column shows
  grid.options = grid.options + {goColMoving}
  grid.onColumnMoved = proc(sender: Control, fromCol, toCol: int) =
    let v = order[fromCol]
    order.delete(fromCol)
    order.insert(v, toCol)
  grid.onDrawCell = proc(sender: Control, c: Canvas, col, row: int,
                         rect: RectF, state: GridDrawStates) =
    grid.drawCellText(c, rect, $order[col] & "," & $row, state)
  ```

  The current cell and the selection follow the moved column.
* Scrolling is exact for millions of rows: positions are float64 inside
  (`scrollPosY`, `contentH`), `cellRect` / `cellAt` / `topRow` agree at any
  offset.

[Back to the index](../README.md)
