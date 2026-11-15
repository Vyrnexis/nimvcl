# ScrollBox

A container that scrolls its children (Delphi `TScrollBox`). Scrollbars appear
when the content is bigger than the box.

## Quick example

```nim
let box = newScrollBox(form, 16, 16, 300, 200)
for i in 0 ..< 20:
  newCheckBox(box, "Option " & $i, left = 8, top = float32(8 + i * 28))
box.vScrollMode = sbmAuto                 # bars only when needed
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `autoContentSize` | bool | Content size follows the children (default) |
| `contentSize` | `SizeF` | Set it to fix the size (turns `autoContentSize` off) |
| `hScrollMode`, `vScrollMode` | `ScrollBarMode` | `sbmAuto`, `sbmAlways`, `sbmNever` |
| `scrollPos` | `PointF` | Current scroll position (float32) |
| `scrollPosX`, `scrollPosY` | float64 | The same without rounding |
| `contentW`, `contentH`, `maxScrollX`, `maxScrollY` | float64 | Exact content size and scroll limits |
| `wheelLines` | int | Lines per wheel notch (default 3); its scrollbars follow it |
| `hScrollBar`, `vScrollBar` | `ScrollBar` | The embedded bars |

## Events

| Event | Description |
|---|---|
| `onScroll` | `scrollPos` changed |

## Methods

| Method | Description |
|---|---|
| `scrollTo(x, y)`, `scrollBy(dx, dy)` | Move the content |
| `scrollIntoView(rect)` | Reveal a rectangle (also `scrollIntoView(x, y, w, h)` in float64) |

## Tips

* Children with `align = alNone` scroll: their `left` and `top` are content
  coordinates. Aligned children do **not** scroll (a difference from Delphi).
* When focus moves into a child by Tab, the box scrolls it into view.
* Shift+wheel scrolls horizontally.
* The same scrolling API is on ListBox, TreeView, ListView, grids and Memo.
* `scrollTo`, `scrollBy` and `setContentSize` take float64, and the position is
  kept in float64: content of hundreds of millions of pixels (a list of millions
  of rows) scrolls to the exact pixel. `scrollPos` and `contentSize` return
  float32 (rounded), which is fine for ordinary content. When you paint your own
  content in a big scroller, compute `float32(y - scroller.scrollPosY)` with the
  subtraction in float64. The scrollbars (`position64`, `setPosition64`,
  `setRange64`) are float64 as well.

[Back to the index](../README.md)
