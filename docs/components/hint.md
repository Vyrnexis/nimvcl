# Hint

Tooltips (Delphi `Hint` / `ShowHint`). Set `hint` on a control and a small
popup appears when the mouse rests on it.

## Quick example

```nim
let save = newButton(form, "Save", 16, 16, 90, 30)
save.hint = "Save the document (Ctrl+S)"

let panel = newPanel(form, "", 16, 60, 200, 80)
panel.hint = "Applies to everything inside"      # children inherit it

Application.hintPause = 400                      # ms before the first hint
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `Control.hint` | string | The text. Empty means "use the parent's hint" |
| `Application.showHint` | bool | Turn all hints off with `false` (default true) |
| `Application.hintPause` | int | Rest time in ms before the first hint (default 600) |

## Events

None.

## Methods

| Method | Description |
|---|---|
| `hintFor(control)` | The text that would show for a control |
| `hideHint()`, `hintVisible()`, `hintText()` | Inspect or dismiss the current hint |

## Tips

* The hint text is the `hint` of the control under the mouse, else of its nearest
  ancestor that has one.
* A hint hides when the mouse leaves, on click, wheel or key press, when the window
  loses focus, and never shows while a menu is open.
* Moving from one hinted control to another shortly after a hint shows the next
  one after only 100 ms.
* Importing `nimvcl` is enough to enable hints. Colors come from the theme
  (`tooltipBg`, `tooltipText`, `tooltipBorder`).
* Action-linked controls get their hint from the action.

[Back to the index](../README.md)
