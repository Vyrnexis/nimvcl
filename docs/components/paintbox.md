# PaintBox

A blank control that draws through `onPaint` (Delphi `TPaintBox`). Use it for
charts, previews and any custom drawing without writing a subclass.

## Quick example

```nim
let box = newPaintBox(form, 16, 16, 240, 120)
var level = 0.6'f32

box.onPaint = proc(sender: Control, c: Canvas) =
  let r = sender.clientRect
  c.fillRoundRect(r, 6, rgb(30, 41, 59))
  c.fillRoundRect(rectF(0, 0, r.w * level, r.h), 6, rgb(34, 197, 94))
  c.textRect($int(level * 100) & "%", font(size = 16), r, clWhite,
             taCenter, vaCenter)

box.onClick = proc(sender: Control) =
  level = if level > 0.9: 0.1 else: level + 0.1
  sender.invalidate()                     # ask for a repaint
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `onPaint` | `PaintEvent` | `proc(sender: Control, canvas: Canvas)` |
| `width`, `height`, `align`, `anchors` | | Normal layout properties |
| `cursor` | `Cursor` | e.g. `crCross` |

## Events

| Event | Description |
|---|---|
| `onPaint` | Draw here. Origin is the top-left, clipped to the control |
| `onMouseDown`, `onMouseMove`, `onMouseUp`, `onMouseWheel`, `onKeyDown` | Interact |
| `onResize` | The size changed |

## Methods

| Method | Description |
|---|---|
| `invalidate()` | Repaint the whole control |
| `invalidate(rect)` | Repaint a part (client coordinates) |

## Tips

* Nothing repaints by itself. Call `invalidate()` when your data changes.
* Draw in logical pixels, and take colors from `sender.theme`.
* To make it focusable or to override methods, write a subclass instead, see
  [Painting](../guide/painting.md).

[Back to the index](../README.md)
