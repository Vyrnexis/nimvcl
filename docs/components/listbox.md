# ListBox

A scrolling list of one-line items (Delphi `TListBox`), with multi-select, owner
draw and a virtual mode for huge lists.

## Quick example

```nim
let list = newListBox(form, 16, 16, 200, 160)
list.items = ["Apples", "Pears", "Plums"]
list.add "Cherries"
list.itemIndex = 0
list.onChange = proc(sender: Control) =
  let lb = ListBox(sender)
  if lb.itemIndex >= 0: echo "selected: ", lb[lb.itemIndex]
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `items` | list | `add`, `insert(i, s)`, `delete(i)`, `clear`, `items[i]`, `len`, `indexOf(s)` |
| `itemIndex` | int | Focused row; -1 for none. In single mode this is the selection |
| `count` | int | Number of items; settable in virtual mode |
| `multiSelect` | bool | Several rows selectable |
| `extendedSelect` | bool | With `multiSelect`: Ctrl and Shift click ranges (default true) |
| `sorted` | bool | Keep sorted (case-insensitive) |
| `itemHeight` | float32 | Row height |
| `style` | `ListBoxStyle` | `lbStandard` or `lbOwnerDraw` (with `onDrawItem`) |
| `topIndex` | int | First visible row |

## Events

| Event | Description |
|---|---|
| `onChange` | Selection changed |
| `onDblClick` | Row double-clicked |
| `onData(sender, index): string` | Virtual mode: supply item text |
| `onDrawItem` | Owner draw an item |

## Methods

| Method | Description |
|---|---|
| `selected(i)`, `selectedIndices()`, `selCount` | Read the selection |
| `setSelected(i, v)`, `setSelection(indices)`, `selectAll()`, `clearSelection()` | Change it |
| `makeVisible(i)` | Scroll a row into view |
| `indexAt(point)`, `itemRect(i)` | Hit testing |

## Tips

* **Virtual mode**: set `onData` and `count = 1_000_000`. Nothing is stored, and
  only visible rows are asked. `add`, `insert` and `sorted` do nothing then.

  ```nim
  list.onData = proc(sender: Control, index: int): string = "Row " & $index
  list.count = 1_000_000
  ```
* With `sorted`, `insert` ignores the index.
* ListBox scrolls on its own. Wheel and keyboard scrolling work out of the box.

[Back to the index](../README.md)
