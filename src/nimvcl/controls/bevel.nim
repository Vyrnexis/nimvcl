## `Bevel` (VCL TBevel): a purely decorative box, frame or separator line drawn
## in the theme's `border` colour. Lines are 1 logical px at the named edge of
## the control. bsBox is a filled (`surfaceAlt`) box with a border, bsFrame only
## the rounded border, bsSpacer draws nothing.

import ./common

type
  BevelShape* = enum
    bsBox, bsFrame, bsTopLine, bsBottomLine, bsLeftLine, bsRightLine, bsSpacer

  Bevel* = ref object of Control
    fShape: BevelShape

func shape*(b: Bevel): BevelShape = b.fShape
proc `shape=`*(b: Bevel, v: BevelShape) =
  if v == b.fShape: return
  b.fShape = v
  b.invalidate()

method paint*(b: Bevel, c: Canvas) =
  let t = b.theme
  let w = b.width
  let h = b.height
  case b.fShape
  of bsBox:
    c.fillRoundRect(b.clientRect, t.radius, t.surfaceAlt)
    c.strokeRoundRect(b.clientRect, t.radius, t.border, t.borderWidth)
  of bsFrame: c.strokeRoundRect(b.clientRect, t.radius, t.border, t.borderWidth)
  of bsTopLine: c.fillRect(rectF(0, 0, w, t.borderWidth), t.border)
  of bsBottomLine: c.fillRect(rectF(0, h - t.borderWidth, w, t.borderWidth), t.border)
  of bsLeftLine: c.fillRect(rectF(0, 0, t.borderWidth, h), t.border)
  of bsRightLine: c.fillRect(rectF(w - t.borderWidth, 0, t.borderWidth, h), t.border)
  of bsSpacer: discard

method hitTest*(b: Bevel, p: PointF): bool = false   ## decorative: clicks pass through

proc initBevel*(b: Bevel, owner: Component = nil) =
  b.initControl(owner)
  b.setBounds(0, 0, 50, 50)

proc newBevel*(parent: Container = nil, shape = bsBox, left = 0'f32,
               top = 0'f32, width = -1'f32, height = -1'f32): Bevel =
  new result
  result.initBevel(parent)
  result.fShape = shape
  result.placeControl(parent, left, top, width, height)
