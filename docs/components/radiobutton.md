# RadioButton

One choice out of several (Delphi `TRadioButton`). There is no `RadioGroup`
control: radio buttons that share a **parent container** form a group, so put
them in a `GroupBox` or `Panel`.

## Quick example

```nim
let box = newGroupBox(form, "Size", 16, 16, 180, 110)
let small = newRadioButton(box, "Small", checked = true, left = 12, top = 28)
let medium = newRadioButton(box, "Medium", left = 12, top = 54)
let large = newRadioButton(box, "Large", left = 12, top = 80)

proc picked(sender: Control) =
  if RadioButton(sender).checked: echo RadioButton(sender).caption
for r in [small, medium, large]:
  r.onChange = picked
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `caption` | string | Label text, `&` for a mnemonic |
| `checked` | bool | Checking one unchecks its siblings |
| `autoSize` | bool | Size to circle and caption |
| `color` | Color | Own background: the area behind the circle and caption; none by default (follows the parent). Set it and `parentColor` turns off |
| `font.color` | Color | Text color (VCL `Font.Color`); alpha 0 (the default) uses the theme's text color. `fontColor` is a shortcut |

## Events

| Event | Description |
|---|---|
| `onChange` | `checked` changed (fires for the one that lost it too) |
| `onClick` | The user clicked |

## Methods

| Method | Description |
|---|---|
| `groupMembers()` | The radio buttons of the group, in child order |

## Tips

* `onChange` fires on both buttons when the selection moves, so test `checked`.
* Tab visits one stop per group (the checked one). Arrow keys move inside it.
* For a data-driven group, build the buttons in a loop with the same parent and
  keep them in a `seq`. To read the choice, find the checked one in
  `groupMembers()`.
* In a `GroupBox`, `alNone` children are placed from the client origin. Use
  `align = alTop` or the box's `clientArea` to avoid the caption.

[Back to the index](../README.md)
