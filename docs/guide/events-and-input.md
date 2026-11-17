# Events and input

Events are public fields on the control. They are `nil` until you assign a
closure. There are no `published` properties or method pointers; use closures.

## Event types

| Type | Signature | Used by |
|---|---|---|
| `NotifyEvent` | `proc(sender: Control)` | `onClick`, `onDblClick`, `onChange`, `onEnter`, `onExit`, `onResize`, `onMouseEnter`, `onMouseLeave` |
| `MouseEvent` | `proc(sender, button: MouseButton, shift: ShiftState, x, y: float32)` | `onMouseDown`, `onMouseUp` |
| `MouseMoveEvent` | `proc(sender, shift, x, y)` | `onMouseMove` |
| `MouseWheelEvent` | `proc(sender, shift, dx, dy: float32, handled: var bool)` | `onMouseWheel` |
| `KeyEvent` | `proc(sender, key: var Key, shift: ShiftState)` | `onKeyDown`, `onKeyUp` |
| `KeyPressEvent` | `proc(sender, text: var string)` | `onKeyPress` |
| `PaintEvent` | `proc(sender, canvas: Canvas)` | `onPaint` |

Mouse coordinates are in the control's own client space. Specific controls add
their own events (`CheckBox.onChange`, `ListBox.onData`, ...), listed on their
pages.

```nim
let btn = newButton(form, "Click me", 20, 20)
btn.onClick = proc(sender: Control) =
  Button(sender).caption = "Clicked"

btn.onMouseDown = proc(sender: Control, button: MouseButton,
                       shift: ShiftState, x, y: float32) =
  if button == mbRight and ssCtrl in shift: echo "ctrl+right click at ", x, ",", y
```

`sender` is typed `Control`. Cast it, or capture the variable in the closure.

## Where to put handlers

Three patterns cover most apps.

**1. A top-level proc, assigned directly.** Best for handlers that need no
state, or only module-level state.

```nim
proc saveClicked(sender: Control) =
  echo "saved"

let btn = newButton(form, "Save", 16, 16)
btn.onClick = saveClicked
```

**2. A ref object for the UI state, plus one-line closures.** The object holds
the controls and the logic as ordinary procs. Closures only forward to it.

```nim
type
  App = ref object
    form: Form
    name: Edit
    status: Label

proc greet(a: App) =
  a.status.caption = "Hello, " & a.name.text

proc newApp(): App =
  result = App(form: newForm())
  result.form.caption = "Greeter"
  result.name = newEdit(result.form, "", 16, 16, 200)
  result.status = newLabel(result.form, "", 16, 56)
  let ok = newButton(result.form, "Greet", 16, 90)
  let app = result                          # capture a plain local
  ok.onClick = proc(sender: Control) = app.greet()

let app = newApp()
Application.run(app.form)
```

The `form` macro does the same with `self`, see [forms](../forms.md).

**3. One handler for several controls.** `sender` is the control that fired.
Use `tag` (an `int` on every control) or `name` to tell them apart.

```nim
proc sizeClicked(sender: Control) =
  echo "size ", sender.tag

for i, caption in ["Small", "Medium", "Large"]:
  let b = newButton(form, caption, float32(16 + i * 90), 16, 80, 28)
  b.tag = i
  b.onClick = sizeClicked
```

**Closures made in a `for` loop must capture the loop value.** A `for`
variable is one variable shared by every pass, so a closure that mentions it
sees the value of the last pass by the time it runs. Capture a copy with
`capture` from `std/sugar`, or build the closure in a helper proc, whose
parameters are fresh on each call:

```nim
import std/sugar

# wrong: every button reports 2
for i in 0 ..< 3:
  let b = newButton(form, "Item " & $i, 16, float32(16 + i * 34))
  b.onClick = proc(sender: Control) = echo "item ", i

# right: capture the value for this pass...
for i in 0 ..< 3:
  let b = newButton(form, "Item " & $i, 16, float32(16 + i * 34))
  capture i:
    b.onClick = proc(sender: Control) = echo "item ", i

# ...or let a helper proc own it
proc wire(b: Button, n: int) =
  b.onClick = proc(sender: Control) = echo "item ", n

for i in 0 ..< 3:
  wire(newButton(form, "Item " & $i, 16, float32(16 + i * 34)), i)
```

The same goes for `onChange`, `onTimer`, menu item handlers and every other
closure made inside a loop. Pattern 3 above (one shared handler and `tag`)
avoids the problem altogether.

## Keyboard

`onKeyDown` gets `key: var Key`. Set it to `Key(0)` to swallow the key. (Name the
parameter something other than `key` if you also call the `key('a')` helper.)

```nim
form.keyPreview = true               # the form sees keys first
form.onKeyDown = proc(sender: Control, k: var Key, shift: ShiftState) =
  if k == keyEscape:
    form.close()
    k = Key(0)                       # consumed
  elif k == key('s') and ssCtrl in shift:
    echo "save"
    k = Key(0)
```

Key constants: `keyEnter`, `keyEscape`, `keyTab`, `keySpace`, `keyBackspace`,
`keyDelete`, `keyInsert`, `keyHome`, `keyEnd`, `keyPageUp`, `keyPageDown`,
`keyLeft/Right/Up/Down`, `keyF1`..`keyF12`. For letters use `key('a')`.
`ShiftState` is a set of `ssShift`, `ssCtrl`, `ssAlt`, `ssSuper` (and mouse
buttons `ssLeft`, `ssRight`, `ssMiddle`, `ssDouble`).

A held key sends repeated key-downs. Inside a custom control, `keyIsRepeat(c)`
tells an auto-repeat from a fresh press (the stock Button uses it so Enter
clicks once per press), see [painting](painting.md#custom-controls).

`onKeyPress` receives typed text (after the keyboard layout and IME). Set
`text = ""` to swallow it.

Keys are delivered to the focused control and do not bubble. Keys that nobody
used go through this chain: Tab focus traversal, `form.ui.onUnhandledKey`, the
registered key handlers (default/cancel buttons, menu shortcuts, PageControl
Ctrl+Tab), then Alt+letter mnemonics. You can add your own handler:

```nim
form.addKeyHandler("myhotkeys", proc(k: var Key, shift: ShiftState) =
  if k == keyF5:
    echo "refresh"
    k = Key(0))
```

## Mouse capture

While a mouse button is held, the control that got the press receives the mouse
events even outside its bounds (the capture). If the capture is taken away
without a mouse-up (the window loses focus or is hidden, or the control is
hidden, disabled or removed), the control's `captureLost` method runs. Custom
controls that track a drag override it to reset their state, see
[painting](painting.md#custom-controls).

## Focus and tab order

Tab and Shift+Tab move focus between controls that are focusable and have
`tabStop = true`. Order is by `tabOrder` within a container, then by child order.
Buttons, edits, lists and the like are tab stops by default.

```nim
let name = newEdit(form, "", 16, 16)
let city = newEdit(form, "", 16, 56)
form.activeControl = name        # or: name.setFocus()
city.tabStop = false             # skip it with Tab
echo name.focused                # true while it has the focus
```

A group of `RadioButton`s counts as one tab stop; arrow keys move inside it.
`onEnter` and `onExit` fire when a control gains or loses focus.

## Mnemonics

An `&` in a caption underlines the next letter while Alt is held. Alt+letter
activates the control: a Button is clicked, a CheckBox toggles, a Label focuses
its `focusControl`, a TabSheet is selected. Use `&&` for a literal `&`.

Mnemonics work for any script and ignore case: `&Файл` is activated by Alt+Ф
(or Alt+ф) on a Cyrillic layout. A mnemonic is a `Rune`: `parseMnemonic(caption)`
returns `(text, index, ch)` with `ch` the lowercased `Rune` (`Rune(0)` when
there is none), `mnemonicOf(caption)` returns just that, and
`keyRune(key)` gives the lowercased character of a printable key. A custom
control takes part by overriding `activateMnemonic(c, ch: Rune): bool`.

```nim
let nameLbl = newLabel(form, "&Name:", 16, 16)
let nameEdit = newEdit(form, "", 80, 12)
nameLbl.focusControl = nameEdit          # Alt+N jumps to the edit
let save = newButton(form, "&Save", 16, 60)
```

## Default and cancel buttons

On a button, `isDefault = true` makes Enter click it from anywhere in the form,
and `isCancel = true` does the same for Esc. (The VCL names `Default` and
`Cancel` clash with Nim, hence the `is` prefix.)

## Shortcuts

A `Shortcut` is a key plus Ctrl/Alt/Shift. Build one from text or code:

```nim
let a = shortcut("Ctrl+S")
let b = shortcut(keyF5)
let c = shortcut('n', {ssCtrl, ssShift})
```

Shortcuts are used by menu items and [actions](actions.md). They fire anywhere
in the form, even without a visible menu item.

## Hints

Set `hint` on any control for a tooltip. See [Hint](../components/hint.md).

[Back to the index](../README.md)
