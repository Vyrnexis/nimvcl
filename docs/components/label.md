# Label

Static text (Delphi `TLabel`). It is not focusable, but it can forward focus to
another control through a mnemonic.

## Quick example

```nim
let nameLbl = newLabel(form, "&Name:", 16, 20)
let nameEdit = newEdit(form, "", 80, 16, 200)
nameLbl.focusControl = nameEdit          # Alt+N focuses the edit

let note = newLabel(form, "Long text that wraps inside the label.", 16, 60, 200, 60)
note.wordWrap = true
note.textColor = hex"#5b6470"
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `caption` (`text`) | string | The text. `&` marks a mnemonic |
| `alignment` | `HAlign` | `taLeft`, `taCenter`, `taRight` |
| `layout` | `VAlign` | `vaTop`, `vaCenter`, `vaBottom` |
| `wordWrap` | bool | Wrap at the label width; the height follows the text |
| `autoSize` | bool | Size to the text. True by default, off when you pass a width or height |
| `transparent` | bool | Do not paint a background |
| `textColor` | Color | Overrides the theme text color; `resetTextColor()` undoes it |
| `focusControl` | Control | Gets the focus on Alt+mnemonic or a click |
| `font` | FontSpec | e.g. `font(size = 20, style = {fsBold})` |

## Events

| Event | Description |
|---|---|
| `onClick` | The label was clicked (also `onDblClick`, mouse events) |

## Methods

Only the common `Control` ones (`setBounds`, `invalidate`, ...).

## Tips

* Without `wordWrap`, text wider than the label is cut with an ellipsis.
* `autoSize` needs a shown form to measure text. Before that the label keeps its
  size.
* In a `form` macro: `Label title: caption = "Title"`.

[Back to the index](../README.md)
