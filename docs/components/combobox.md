# ComboBox

An edit or a display box plus a drop-down list (Delphi `TComboBox`).

## Quick example

```nim
let combo = newComboBox(form, csDropDownList, 16, 16, 200)
combo.items = ["Red", "Green", "Blue"]
combo.itemIndex = 0
combo.onChange = proc(sender: Control) =
  let c = ComboBox(sender)
  echo "picked ", c.text, " (", c.itemIndex, ")"

let free = newComboBox(form, csDropDown, 16, 56, 200)  # editable
free.add "apple"
free.add "banana"
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `style` | `ComboStyle` | `csDropDown` (editable, default) or `csDropDownList` |
| `items` | `ComboItems` | `items.add`, `insert`, `delete`, `clear`, `items[i]`, `items.len`, `items.indexOf(s)`, `items = [...]`. The combo owns its strings (the drop-down `ListBox` is only a view), so this is not the ListBox's item list |
| `itemIndex` | int | Selected item; -1 for none (clears the text of a `csDropDown`) |
| `text` | string | The shown text |
| `count` | int | Number of items |
| `sorted` | bool | Keep items ordered (case-insensitive) |
| `autoComplete` | bool | Complete typed text from the items (`csDropDown`) |
| `dropDownCount` | int | Visible rows in the list (default 8) |
| `dropDownWidth` | float32 | List width; 0 = same as the box |
| `dropStyle`, `onDrawItem` | `ListBoxStyle`, event | `lbOwnerDraw` draws the drop-down rows with `onDrawItem` (same signature as [ListBox](listbox.md)); the face of the combo is not owner drawn |
| `typeAheadTimeout` | int | Milliseconds before a typed prefix is forgotten (1000), list style |
| `color` | Color | Own background: the field and the drop-down list; default `theme.surface`. Set it and `parentColor` turns off |
| `font.color` | Color | Text color (VCL `Font.Color`); alpha 0 (the default) uses the theme's text color. `fontColor` is a shortcut |

Shortcuts also exist directly on the combo: `add`, `insert`, `delete`, `clear`,
`combo[i]`.

## Events

| Event | Description |
|---|---|
| `onChange` | The text or selected item changed, by anyone |
| `onSelect` | The **user** picked an item (fires after `onChange`) |
| `onDropDown` | Just before the list opens: fill items here |
| `onCloseUp` | After the list closed |

## Methods

| Method | Description |
|---|---|
| `dropDown()`, `closeUp()` | Open or close the list |
| `dropList` | The popup's `ListBox` while open, nil when closed (a view made for each opening) |

## Tips

* Use `onSelect` when you only care about user choices. `onChange` also fires for
  `itemIndex =` and `text =`.
* In `csDropDown`, `itemIndex` is the item equal to the text, else -1.
* Keys: Alt+Down or F4 opens it. In list style, typing letters selects by prefix
  (the ListBox type-ahead), also while the list is open.
* The drop-down list is made for each opening and freed on close, so keep no
  reference to `dropList` across openings. Items changed while it is open show
  in it.

[Back to the index](../README.md)
