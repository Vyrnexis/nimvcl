# Bevel

A decorative box, frame or separator line (Delphi `TBevel`). It never takes
clicks; they pass through.

## Quick example

```nim
let top = newLabel(form, "Settings", 16, 12)

let line = newBevel(form, bsTopLine, 16, 40, 300, 1)   # horizontal rule
line.anchors = {akLeft, akTop, akRight}

let outline = newBevel(form, bsFrame, 16, 56, 300, 80)   # outline only
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `shape` | `BevelShape` | `bsBox` (filled), `bsFrame` (outline), `bsTopLine`, `bsBottomLine`, `bsLeftLine`, `bsRightLine`, `bsSpacer` (nothing) |
| `align`, `anchors` | | Usually `alTop` / `alBottom` with `height = 1` for a divider |

## Events

None; it is click-through.

## Methods

None.

## Tips

* A line is 1 logical pixel wide at the named edge of the control.
* Use `align = alTop` plus `height = 1` and `bsTopLine` for a divider that
  follows the form width.
* Colors come from the theme `border`.

[Back to the index](../README.md)
