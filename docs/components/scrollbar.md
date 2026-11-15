# ScrollBar

A thin, modern scrollbar (Delphi `TScrollBar`). Most scrolling controls have
their own bars. Use this one for custom scrolling.

## Quick example

```nim
let bar = newScrollBar(form, sbVertical, 300, 16, 12, 200)
bar.setRange(0, 1000, pageSize = 100)     # position goes 0 .. 900
bar.smallChange = 10
bar.largeChange = 100
bar.onChange = proc(sender: Control) =
  echo "top is ", ScrollBar(sender).position
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `kind` | `ScrollBarKind` | `sbHorizontal`, `sbVertical` (set in the constructor) |
| `min`, `max` | float32 | The range |
| `pageSize` | float32 | Visible part of the range; sets the thumb length |
| `position` | float32 | Within `min .. max - pageSize` |
| `smallChange` | float32 | One line: arrow click, wheel notch is 3 lines |
| `largeChange` | float32 | One page: track click (0 = `pageSize`) |
| `showArrows` | bool | Add arrow buttons (off by default) |

## Events

| Event | Description |
|---|---|
| `onChange` | `position` changed |
| `onScroll(sender, code, pos: var float32)` | Before the change; may adjust `pos` |

## Methods

| Method | Description |
|---|---|
| `setRange(min, max, pageSize = 0)` | Set the range in one go |
| `scrollBy(code, delta)` | Move programmatically |
| `canScroll` | False when everything is visible |

## Tips

* Values are floats, so you can scroll by pixels.
* The thumb grows and gets a track while the mouse is over it.
* Not focusable. The wheel scrolls it too.
* For a scrollable area with ready-made bars use [ScrollBox](scrollbox.md).

[Back to the index](../README.md)
