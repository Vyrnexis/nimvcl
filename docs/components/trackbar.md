# TrackBar

A slider for choosing an integer in a range (Delphi `TTrackBar`).

## Quick example

```nim
let volume = newTrackBar(form, 16, 16, 220, 32)
volume.min = 0
volume.max = 100
volume.frequency = 10                     # tick mark every 10
volume.position = 40
volume.onChange = proc(sender: Control) =
  echo "volume ", TrackBar(sender).position
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `position` | int | Current value |
| `min`, `max` | int | Range (default 0..10) |
| `frequency` | int | Tick mark spacing |
| `lineSize` | int | Step for the arrow keys (default 1) |
| `pageSize` | int | Step for PageUp/PageDown and track clicks (default 2) |
| `orientation` | `Orientation` | `orHorizontal` (default) or `orVertical` |

## Events

| Event | Description |
|---|---|
| `onChange` | `position` changed, also while dragging |

## Methods

| Method | Description |
|---|---|
| `isDragging` | True while the thumb is held |

## Tips

* `onChange` fires on every step while dragging. For heavy work, check
  `isDragging` or use a [Timer](timer.md) to debounce.
* The minimum is at the left, or at the top when vertical.
* Home and End jump to the ends.

[Back to the index](../README.md)
