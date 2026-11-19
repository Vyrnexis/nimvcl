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
| `items` | list | `items.add`, `insert`, `delete`, `clear`, `items[i]`, `items = [...]` |
| `itemIndex` | int | Selected item; -1 for none (clears the text of a `csDropDown`) |
| `text` | string | The shown text |
| `count` | int | Number of items |
| `sorted` | bool | Keep items ordered (case-insensitive) |
| `autoComplete` | bool | Complete typed text from the items (`csDropDown`) |
| `dropDownCount` | int | Visible rows in the list (default 8) |
| `dropDownWidth` | float32 | List width; 0 = same as the box |
| `dropStyle`, `onDrawItem` | ListBoxStyle, event | `lbOwnerDraw` draws the list rows with `onDrawItem` |
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
* Keys: Alt+Down or F4 opens it. Typing selects by prefix in list style.

[Back to the index](../README.md)
