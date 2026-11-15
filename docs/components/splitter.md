# Splitter

A draggable divider between two aligned controls (Delphi `TSplitter`).

## Quick example

```nim
let left = newPanel(form, "Left")
left.align = alLeft
left.width = 180

let split = newSplitter(form, alLeft)     # right after the control it resizes
split.minSize = 80

let right = newPanel(form, "Right")
right.align = alClient
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `align` | `Align` | Same as the control it resizes: `alLeft`, `alRight`, `alTop` or `alBottom` |
| `minSize` | float32 | Smallest size of the resized control (default 30). Also leaves this much for the rest |
| `width` | float32 | Thickness of a vertical splitter (default 6) |

## Events

| Event | Description |
|---|---|
| `onMoved` | After a drag step changed the size |

## Methods

| Method | Description |
|---|---|
| `neighbour()` | The control being resized |
| `resizeTo(size)` | Set the size in code |
| `isDragging` | True while dragging |

## Tips

* Create the splitter **right after** the control it should resize. Same-aligned
  siblings stack in creation order.
* It resizes the previous visible sibling with the same `align`, live while
  dragging.
* The neighbour's `constraints` are respected.

[Back to the index](../README.md)
