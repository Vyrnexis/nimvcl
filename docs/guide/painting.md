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

Rectangle helpers: `r.inflate(d)` grows or shrinks every side by `d`;
`r.inflate(dx, dy)` uses `dx` left and right and `dy` top and bottom
(negative values shrink).

Helpers: `rectF(x, y, w, h)`, `pointF`, `sizeF`, colors `rgb(r, g, b)`,
`rgba(r, g, b, a)`, `hex"#2563eb"`, `clBlack`, `clWhite`, `clTransparent`,
and fonts `font(family, size, style)` with `fsBold`, `fsItalic`. A `FontSpec` also
has a `color` (alpha 0: none, the theme's text color); the Canvas text calls take
the color as an argument, so a control passes `font.color` itself when it is
set (see [theming](theming.md#per-control-colors-and-fonts)).

## Fonts

The bundled fonts are Noto Sans (regular, bold, italic) and Noto Sans Mono.
They are **embedded in the executable** at compile time and opened from memory,
so a built app needs no font files next to it. This adds about 2.4 MB to the
binary; build with `-d:nimvclNoEmbedFonts` to skip it and load the files from
the `assets` folder instead. Overrides: if `NIMVCL_ASSETS` names a folder with
`fonts/<file>.ttf`, that file is loaded from disk instead of the embedded copy,
and `registerFontFamily("sans", ...)` replaces a bundled family.
`fontSource(font("sans"))` reports "embedded", "disk" or "registered". For glyphs they lack,
nimvcl keeps a global fallback list. It holds the Noto Symbols fonts and, when
one is installed, **a system CJK font**: the first of Noto Sans CJK, Noto Serif
CJK, WenQuanYi (Micro Hei / Zen Hei) or Droid Sans Fallback found in the usual
places on Arch, Debian/Ubuntu and Fedora. Nothing is loaded until text is first
drawn, and nothing happens if no such font exists (CJK then shows as empty
boxes). `cjkFallbackFont()` tells you which file was picked (`""` for none).

For another font, add it yourself: `addFallbackFontFile("/path/to/font.ttf")`.
Missing files are ignored. (Color emoji fonts are not probed: SDL_ttf cannot
scale their bitmaps.)

## Partial repainting

A `Form` draws into a persistent backbuffer texture (device pixels) and copies
it to the window, so a repaint only needs to redraw what changed:

* `c.invalidate()` marks the whole control dirty; `c.invalidateRect(r)` (or
  `c.invalidate(r)`) marks only `r`, in the client coordinates of `c`. Rects are
  clipped to what is visible (ancestors, scroll viewports), snapped outwards to
  whole device pixels and merged when they overlap or touch; more than six
  regions collapse into their bounding box, and a region covering most of the
  form (or any `requestLayout`, scroll, theme or scale change, resize) repaints
  the whole form.
* For each dirty region the form sets the clip and paints the tree as usual
  (parents first, siblings in z-order), so your `paint` is called with a clip
  that may be smaller than the control. Draw as always; do not assume a full
  frame. A control that paints a small moving part (like the `Edit` caret)
  should invalidate that part **and** whatever it erases, e.g.
  `invalidate(caretRect.inflate(1, 1))`.
* `paint` must draw the control's whole look from its state (no "draw only the
  change"): the parent's background is repainted first, so anti-aliased and
  translucent controls composite correctly.
* Popups and `Host` (embedding) always repaint fully. A lost render target
  (`SDL_EVENT_RENDER_TARGETS_RESET`) forces a full repaint.
* `form.screenshot(path)` reads the backbuffer; `form.screenshot(path, full =
  true)` discards it and repaints everything first.
* Debug: run with `NIMVCL_DEBUG_DIRTY=1` to outline (red) the regions each frame
  repainted. The overlay is drawn on the window only, not in screenshots.

## Screenshots

`form.screenshot(path)` and `screenshotWithPopups(form, path)` render one frame
without showing a window on screen (handy with `SDL_VIDEO_DRIVER=offscreen`).
The format follows the file name: a path ending in `.png` writes a PNG, anything
else a BMP.

```nim
doAssert form.screenshot("build/form.png")
```

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
               width = -1'f32, height = -1'f32): Gauge {.discardable.} =
  new result
  result.initControl(parent)
  result.setBounds(0, 0, 160, 20)         # default size
  result.placeControl(parent, left, top, width, height)
```

Use it like any stock control: `let g = newGauge(form, 16, 16)`. Make the
constructor `{.discardable.}` like the stock ones, since the parent owns the
control.

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
* **`captureLost()`**: a control that tracks a drag (or a repeat timer) gets the
  mouse capture taken away without a mouse-up when the window loses focus or is
  hidden, or when the control itself is hidden, disabled or removed. Override it
  to reset your drag state, and call the base:

  ```nim
  method captureLost*(g: Gauge) =
    g.dragging = false                  # your own field
    g.invalidate()
    procCall captureLost(Control(g))
  ```
* **`keyIsRepeat(c)`**: true while `c` handles a key-down that is an
  auto-repeat (the key is held). Check it in `doKeyDown` when something must
  happen once per press, as the stock Button does for Enter:

  ```nim
  method doKeyDown*(g: Gauge, key: var Key, shift: ShiftState) =
    if key == keyEnter and not g.keyIsRepeat:
      g.value = 1
      key = Key(0)
    procCall doKeyDown(Control(g), key, shift)
  ```
* **Freeing**: `g.free()` removes the control from its parent for good and
  unlinks its action. Override `releaseResources` (a method on `Control`) if
  your control subscribes to something long-lived, such as an `ImageList`:
  unsubscribe there.
* **`hitTest(p)`** can return false to let clicks pass through (as `Bevel` does).
* **Properties**: use setters that call `invalidate()` for a repaint, or
  `requestLayout()` when the size or position of siblings can change. When
  only a small part changed (a caret, a progress segment), call
  `invalidateRect(r)` (same as `invalidate(r)`) with that rect in the control's
  client coordinates: see "Partial repainting" below.
* Read colors and metrics from `theme` so your control follows the light and dark
  themes, see [theming](theming.md). Honour the user's choices too: paint the
  background with `color` when `parentColor` is false (`not c.parentColor and
  c.color.a > 0`), and draw text with `c.font.color` when `c.fontColor.a > 0`.

You can also use your control as a child in the `form` macro, see
[forms](../forms.md) ("Custom controls as children").

## Images

`loadImage(path)` loads a file, `newImage(w, h, fill)` makes a blank one,
`setPixel` / `getPixel` edit it. After changing pixels call `img.touch()` to
re-upload it. See [Image](../components/image.md).

[Back to the index](../README.md)
