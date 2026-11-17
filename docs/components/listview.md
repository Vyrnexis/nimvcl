# ListView

Items shown as a report with columns, as a list, or as icons
(Delphi `TListView`).

## Quick example

```nim
let lv = newListView(form, 16, 16, 420, 200)
lv.viewStyle = vsReport
lv.columns.add("Name", 180)
lv.columns.add("Size", 80)
lv.items.add("readme.md", "2 KB")            # caption, then sub-items
lv.items.add("main.nim", "14 KB")

lv.onSelectItem = proc(sender: Control, item: ListItem, selected: bool) =
  if selected: echo item.caption, " / ", item.subItems[0]
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `viewStyle` | `ListViewStyle` | `vsReport`, `vsList`, `vsSmallIcon`, `vsIcon` |
| `columns` | `ListColumns` | `add(caption, width)`, `[i]`, `delete`, `clear` |
| `items` | `ListItems` | `add(caption, sub...)`, `insert`, `delete`, `clear`, `[i]`, `count` |
| `itemIndex` | int | Focused item; -1 for none |
| `multiSelect`, `extendedSelect` | bool | Multi-select |
| `checkboxes` | bool | A check box per item |
| `showHeader`, `gridLines`, `rowSelect`, `hotTrack` | bool | Report look |
| `smallImages`, `largeImages` | `ImageList` | Icons; items use `imageIndex` |
| `sortColumn`, `sortOrder` | int, `SortOrder` | Arrow in the header (you do the sorting) |
| `readOnly` | bool | Disable in-place rename |
| `borderStyle` | `BorderStyle` | `bsSingle` (default) or `bsNone`: no border, no focus ring and square corners, so the control can sit flush in a panel |

ListItem: `caption`, `subItems`, `imageIndex`, `checked`, `selected`, `data`, `tag`, `index`.

## Events

| Event | Description |
|---|---|
| `onSelectItem(sender, item, selected)` | One call per item whose selection changed |
| `onSelectionChanged(sender, added, removed)` | One call per selection change, with the sorted indices that became selected and the ones that no longer are |
| `onChange` | Focus or selection changed |
| `onItemDblClick(sender, index, column)` | Double click on an item (not the header or empty space); `column` is the report-view column under the pointer, -1 in other views |
| `onItemChecked(sender, item)` | A check box toggled |
| `onColumnClick(sender, column)` | Header clicked: sort here |
| `onColumnResize`, `onEditing`, `onEdited` | Resize and rename |
| `onData(sender, item)` | Virtual mode: fill an item |
| `onCustomDrawItem`, `onCustomDrawSubItem` | Owner draw |

## Methods

| Method | Description |
|---|---|
| `sortByColumn(col, order)`, `sortItems(cmp)` | Sort the items |
| `selectedIndices()`, `selected(i)`, `selCount`, `setSelected(i, v)`, `selectAll()` | Read and change the selection |
| `setSelection(indices, focus = -1)` | Replace the whole selection in one step |
| `clearSelection()` | Select nothing |
| `makeVisible(i)`, `itemAt(point)` | Scrolling and hit test |
| `beginEdit(i)` / `endEdit(cancel)` | Rename |
| `refreshData()` | Virtual mode: data changed |

## Tips

* **Virtual mode** for huge data: set `ownerData = true`, `onData` and
  `itemsCount = n`. `onData` fills `item.caption` and `item.subItems` for painted
  rows only.

  ```nim
  lv.ownerData = true
  lv.onData = proc(sender: Control, item: ListItem) =
    item.caption = "Row " & $item.index
  lv.itemsCount = 1_000_000
  ```
* `itemIndex = i` selects exactly item `i`. To select many from code, call
  `lv.setSelection([2, 5, 9], focus = 5)`: it fires `onChange` once and
  `onSelectItem` only for items whose state changed, and it is fast even with
  100,000 selected rows in virtual mode. Plain Space toggles the focused item
  when `multiSelect` is on and `extendedSelect` is off.
* **Big selections**: `selectAll()`, `clearSelection()` or `setSelection` on
  100,000 rows call `onSelectItem` 100,000 times (in virtual mode each call can
  reach `onData`). When you only need to know *that* and *what* changed, use
  `onSelectionChanged`: it fires once per change (also when selected items are
  deleted or `itemsCount` shrinks) and leaves `onSelectItem` free to stay nil,
  in which case nothing per item is computed. With both set, the per-item calls
  come first, then `onSelectionChanged`, then `onChange`.

  ```nim
  lv.onSelectionChanged = proc(sender: Control, added, removed: openArray[int]) =
    echo added.len, " selected, ", removed.len, " deselected"
  ```
* Millions of rows scroll to the exact pixel (the scroll position is float64):
  a 5,000,000-row virtual list is fine; `itemRect(i)` and `itemAt(point)` agree
  with what is painted at every position.
* Sorting is yours: handle `onColumnClick` and call `sortByColumn`.
* Sub-item `k` is column `k + 1`; the caption is column 0.
* Drag the right edge of a column header to resize it. (Dragging headers to
  reorder columns is not supported; the grids have `goColMoving`.)

[Back to the index](../README.md)
