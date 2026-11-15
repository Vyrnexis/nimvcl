# SpinEdit

An integer edit with up and down buttons (Delphi `TSpinEdit`).

## Quick example

```nim
let qty = newSpinEdit(form, 1, 16, 16, 100)   # initial value 1
qty.minValue = 1
qty.maxValue = 99
qty.increment = 1
qty.onChange = proc(sender: Control) =
  echo "quantity: ", SpinEdit(sender).value
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `value` | int | Current value, always within `minValue .. maxValue` |
| `minValue`, `maxValue` | int | Range (default 0..100) |
| `increment` | int | Step for arrows, wheel and buttons (PageUp/PageDown use 10 steps) |
| `edit` | `Edit` | The inner edit, for fine tuning |

## Events

| Event | Description |
|---|---|
| `onChange` | `value` changed |

## Methods

| Method | Description |
|---|---|
| `stepBy(dir, count = 1)` | Step up (`1`) or down (`-1`) |
| `commit()` | Parse the typed text now |

## Tips

* The text is parsed on Enter and when focus leaves. An out-of-range number is
  clamped and unparsable text reverts to the current value.
* Holding a button repeats after 400 ms, then every 50 ms.
* Focus lives in the inner edit. Use `label.focusControl = spin` and it
  forwards correctly.

[Back to the index](../README.md)
