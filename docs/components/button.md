# Button

A push button (Delphi `TButton`). It supports mouse, Enter and Space, default and
cancel roles, and a flat style.

## Quick example

```nim
let ok = newButton(form, "&OK", 16, 16, 90, 30)
ok.isDefault = true                       # Enter anywhere clicks it
ok.onClick = proc(sender: Control) =
  showMessage("Saved")

let closeBtn = newButton(form, "Close", 116, 16, 90, 30)
closeBtn.modalResult = mrCancel              # closes a modal form
closeBtn.isCancel = true                     # Esc clicks it
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `caption` | string | Text; `&` marks a mnemonic (Alt+letter clicks) |
| `isDefault` | bool | Enter clicks this button from anywhere in the form |
| `isCancel` | bool | Esc clicks this button |
| `modalResult` | `ModalResult` | When set, a click also closes a modal form with this result |
| `flat` | bool | No face until hovered |
| `autoSize` | bool | Width follows the caption |
| `enabled` | bool | Disabled buttons ignore input |
| `action` | Action | Share caption, hint and enabled with an [Action](../guide/actions.md) |

## Events

| Event | Description |
|---|---|
| `onClick` | Clicked by mouse, Enter, Space or mnemonic |
| `onMouseDown`, `onMouseUp`, `onEnter`, `onExit` | The usual control events |

## Methods

| Method | Description |
|---|---|
| `click()` | Behave as if the user clicked |
| `setFocus()` | Give it the keyboard focus |

## Tips

* The Delphi names `Default` and `Cancel` clash with Nim, so use `isDefault` and
  `isCancel`.
* Enter (or Space) clicks once per press: holding the key down does not repeat
  the click. For the default button, Enter's auto-repeat is ignored too.
* A focused button handles Enter itself, so the default button only gets Enter
  when another kind of control has the focus.
* `modalResult` runs after `onClick`.

[Back to the index](../README.md)
