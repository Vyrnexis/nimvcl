# FlowPanel

A panel that flows its children in rows or columns and wraps them
(Delphi `TFlowPanel`). It positions children itself and ignores their `align`.

## Quick example

```nim
let flow = newFlowPanel(form, 16, 16, 320, 160)
flow.hGap = 8
flow.vGap = 8
flow.padding = spacing(8)
for i in 1 .. 10:
  newButton(flow, "Item " & $i, 0, 0, 80, 28)   # wraps at the panel width
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `flowStyle` | `FlowStyle` | `fsLeftRightTopBottom` (rows, default) or `fsTopBottomLeftRight` (columns) |
| `hGap`, `vGap` | float32 | Space between neighbors (default 0) |
| `padding` | `Spacing` | Space inside the panel |
| `borderStyle`, `color` | | As on [Panel](panel.md); FlowPanel is a Panel |

## Events

Only the common ones.

## Methods

Add children by passing the panel as `parent`, or with `insertControl`.

## Tips

* Children keep their own size and flow in child order.
* A child's `margins` are part of its slot. Hidden children are skipped.
* Reorder with `bringToFront` / `sendToBack` on a child.
* For rows and columns that line up use [GridPanel](gridpanel.md).

[Back to the index](../README.md)
