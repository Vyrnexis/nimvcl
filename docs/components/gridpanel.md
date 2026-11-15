# GridPanel

A panel that places children in a grid of rows and columns
(Delphi `TGridPanel`). Children fill their cell, minus margins.

## Quick example

```nim
let grid = newGridPanel(form, 16, 16, 360, 100)
grid.columns = @[gsAbsolute(90), gsPercent(100)]   # fixed, then the rest
grid.rows = @[gsAuto(), gsAuto()]                  # as tall as the content
grid.padding = spacing(8)

discard newLabel(grid, "Name:")                    # cell 0,0
discard newEdit(grid)                              # cell 0,1
discard newLabel(grid, "City:")                    # cell 1,0
discard newEdit(grid)                              # cell 1,1
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `columns`, `rows` | `seq[GridSize]` | The tracks. `addColumn(size)` and `addRow(size)` append |
| `padding` | `Spacing` | Space inside the panel |

Track sizes:

| Constructor | Meaning |
|---|---|
| `gsAbsolute(n)` | `n` logical pixels |
| `gsAuto()` | As large as the biggest child (preferred size plus margins) in that track |
| `gsPercent(p)` | Share of what is left after absolute and auto tracks. Over 100 in total is normalized |

## Events

Only the common ones.

## Methods

| Method | Description |
|---|---|
| `setCell(ctrl, row, col, rowSpan = 1, colSpan = 1)` | Put a child in a specific cell |
| `clearCell(ctrl)` | Back to automatic placement |
| `cellRect(row, col, rowSpan, colSpan)` | A cell's rectangle |

## Tips

* Children without `setCell` take the free cells in row-major order. Children
  beyond the last cell are not placed.
* No columns or rows means one 100% track on that axis.
* A child's `margins` make a gap inside its cell.

[Back to the index](../README.md)
