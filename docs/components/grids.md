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
| `options` | `GridOptions` | `goRangeSelect`, `goRowSelect`, `goColSizing`, `goRowSizing`, `goEditing`, `goTabs`, `goAlwaysShowEditor` |
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

## Methods

| Method | Description |
|---|---|
| `cellRect(c, r)`, `cellAt(point)`, `makeVisible(col, row)` | Geometry and scrolling |
| `setSelection(l, t, r, b)`, `selectCell(c, r)`, `selectAll()` | Selection |
| `startEdit()`, `endEdit(commit)`, `cancelEdit()` | In-place editor |
| `autoFitColumn(c)`, `setColWidth`, `setRowHeight`, `resetSizes()` | Sizes |
| `copySelection()`, `pasteFromClipboard()`, `clearSelectedCells()` | Clipboard (tab separated) |
| StringGrid: `insertRow`, `deleteRow`, `clearCells`, `sortByColumn(col, ascending)` | Data |

## Tips

* Only visible cells are drawn, so a million rows scroll fine.
* Fixed cells never become the current cell.
* In a DrawGrid, `rect` excludes the 1 px grid line. Use `cellTextColor(state)` and
  `drawCellText` for theme-correct text.
* Without `goEditing`, cells are read-only. Enter or F2 starts editing.
* Not implemented: column dragging (`goColMoving`).

[Back to the index](../README.md)
