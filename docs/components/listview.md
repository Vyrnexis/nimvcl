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

ListItem: `caption`, `subItems`, `imageIndex`, `checked`, `selected`, `data`, `tag`, `index`.

## Events

| Event | Description |
|---|---|
| `onSelectItem(sender, item, selected)` | Selection changed |
| `onChange` | Focus or selection changed |
| `onItemDblClick(sender, index, column)` | Double click |
| `onItemChecked(sender, item)` | A check box toggled |
| `onColumnClick(sender, column)` | Header clicked: sort here |
| `onColumnResize`, `onEditing`, `onEdited` | Resize and rename |
| `onData(sender, item)` | Virtual mode: fill an item |
| `onCustomDrawItem`, `onCustomDrawSubItem` | Owner draw |

## Methods

| Method | Description |
|---|---|
| `sortByColumn(col, order)`, `sortItems(cmp)` | Sort the items |
| `selectedIndices()`, `selected(i)`, `setSelected(i, v)`, `selectAll()` | Selection |
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
* Sorting is yours: handle `onColumnClick` and call `sortByColumn`.
* Sub-item `k` is column `k + 1`; the caption is column 0.
* Drag the right edge of a column header to resize it.

[Back to the index](../README.md)
