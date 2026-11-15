# Painting and custom controls

nimvcl draws everything itself with SDL3. You draw through a `Canvas`:
immediate-mode 2D drawing in logical pixels. The library handles HiDPI scale,
so you never multiply by the display scale.

## Canvas

The origin is the control's top-left corner and drawing is clipped to the
control.

| Call | Draws |
|---|---|
| `clear(color)` | Fills the whole target |
| `fillRect(rect, color)`, `frameRect(rect, color, width = 1)` | Rectangles |
| `fillRoundRect(rect, radius, color)`, `strokeRoundRect(...)` | Rounded rectangles |
| `fillEllipse(rect, color)`, `strokeEllipse(rect, color, width = 1)` | Ellipses |
| `line(x1, y1, x2, y2, color, width = 1)` | Anti-aliased line |
| `fillPolygon(points, color)` | Polygon of `PointF` |
| `drawImage(img, dst, src, alpha)` | An `Image` |
| `drawText(text, font, x, y, color)` | Text at a position |
| `textRect(text, font, rect, color, hAlign, vAlign, wrap, ellipsis)` | Aligned, clipped text |
| `measureText(text, font, maxWidth)` | Returns a `SizeF` |
| `pushClip(rect)` / `popClip()`, `pushTranslate(dx, dy)` / `popTranslate()` | State |

Helpers: `rectF(x, y, w, h)`, `pointF`, `sizeF`, colors `rgb(r, g, b)`,
`rgba(r, g, b, a)`, `hex"#2563eb"`, `clBlack`, `clWhite`, `clTransparent`,
and fonts `font(family, size, style)` with `fsBold`, `fsItalic`.

## PaintBox: draw without subclassing

The easy way. `PaintBox` calls `onPaint` whenever it needs drawing.

```nim
let box = newPaintBox(form, 16, 16, 200, 100)
box.onPaint = proc(sender: Control, c: Canvas) =
  let r = sender.clientRect
  c.fillRoundRect(r, 8, rgb(37, 99, 235))
  c.line(10, 10, r.w - 10, r.h - 10, clWhite, 2)
  c.textRect("Hello", font(size = 18, style = {fsBold}), r, clWhite,
             taCenter, vaCenter)
```

Call `box.invalidate()` after your data changes to repaint. See
[PaintBox](../components/paintbox.md).

## Custom controls

Subclass `Control` (or `Container` for something that holds children),
override a few methods, and write a constructor.

```nim
type
  Gauge* = ref object of Control
    fValue: float32                       # 0..1
    onChange*: NotifyEvent

proc value*(g: Gauge): float32 = g.fValue
proc `value=`*(g: Gauge, v: float32) =
  let nv = clamp(v, 0'f32, 1'f32)
  if nv == g.fValue: return
  g.fValue = nv
  g.invalidate()                          # repaint
  if g.onChange != nil: g.onChange(g)

method paint*(g: Gauge, c: Canvas) =
  let t = g.theme                         # draw only from theme colors
  let r = g.clientRect
  c.fillRoundRect(r, t.radius, t.surfaceAlt)
  c.fillRoundRect(rectF(r.x, r.y, r.w * g.fValue, r.h), t.radius, t.accent)

method preferredSize*(g: Gauge): SizeF =  # used when autoSize is on
  sizeF(160, 20)

method doMouseDown*(g: Gauge, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  g.value = x / g.width                   # click to set
  procCall doMouseDown(Control(g), button, shift, x, y)   # keep onMouseDown

proc newGauge*(parent: Container = nil, left = 0'f32, top = 0'f32,
               width = -1'f32, height = -1'f32): Gauge =
  new result
  result.initControl(parent)
  result.setBounds(0, 0, 160, 20)         # default size
  result.placeControl(parent, left, top, width, height)
```

Use it like any stock control: `let g = newGauge(form, 16, 16)`.

What to know:

* **`initControl(self, owner)`** sets up the base. Use `initContainer` for a
  container. `placeControl` applies the constructor's `left/top/width/height` and
  inserts the control into `parent`.
* **`paint(c, canvas)`** draws. Children are painted afterwards by the library.
* **`preferredSize()`** is the natural size for `autoSize`.
* **`doXxx` methods** (`doClick`, `doMouseDown`, `doKeyDown`, ...) are the event
  dispatch points. The base version fires the matching `onXxx` field, so call it
  with `procCall` when you override.
* **Focus**: override `canFocus` (return `c.isVisible and c.isEnabled`) and set
  `tabStop = true` for a control that takes keyboard input.
* **`hitTest(p)`** can return false to let clicks pass through (as `Bevel` does).
* **Properties**: use setters that call `invalidate()` for a repaint, or
  `requestLayout()` when the size or position of siblings can change.
* Read colors and metrics from `theme` so your control follows the light and dark
  themes, see [theming](theming.md).

You can also use your control as a child in the `form` macro, see
[forms](../forms.md) ("Custom controls as children").

## Images

`loadImage(path)` loads a file, `newImage(w, h, fill)` makes a blank one,
`setPixel` / `getPixel` edit it. After changing pixels call `img.touch()` to
re-upload it. See [Image](../components/image.md).

[Back to the index](../README.md)
