# CheckBox

A box with a caption that can be on, off or (optionally) grayed
(Delphi `TCheckBox`).

## Quick example

```nim
let wrap = newCheckBox(form, "&Word wrap", checked = true, left = 16, top = 16)
wrap.onChange = proc(sender: Control) =
  echo "wrap is ", CheckBox(sender).checked

let tri = newCheckBox(form, "Three states", left = 16, top = 48)
tri.allowGrayed = true
tri.state = cbGrayed
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `caption` | string | Label text, `&` for a mnemonic |
| `checked` | bool | True when `state == cbChecked` |
| `state` | `CheckBoxState` | `cbUnchecked`, `cbChecked`, `cbGrayed` |
| `allowGrayed` | bool | Clicking cycles through the gray state too |
| `autoSize` | bool | Size to box and caption (default, off with an explicit size) |
| `color` | Color | Own background: the area behind the box and caption; none by default (follows the parent). Set it and `parentColor` turns off |
| `font.color` | Color | Text color (VCL `Font.Color`); alpha 0 (the default) uses the theme's text color. `fontColor` is a shortcut |

## Events

| Event | Description |
|---|---|
| `onChange` | `state` changed, by the user or by code |
| `onClick` | The user clicked it (not fired by code changes) |

## Methods

| Method | Description |
|---|---|
| `toggle()` | Advance the state like a click |

## Tips

* To react to code changes as well as clicks, use `onChange`.
* Space toggles at key release, like a button.
* Sharing one [Action](../guide/actions.md) with a menu item keeps both in sync.

[Back to the index](../README.md)
