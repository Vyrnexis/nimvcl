## `PaintBox` (VCL TPaintBox): a blank control that draws through `onPaint`.
## The handler gets the canvas with its origin at the control's top-left and
## the clip set to the control, so it draws in client coordinates.

import ./common

type
  PaintBox* = ref object of Control

method paint*(p: PaintBox, c: Canvas) =
  if p.onPaint != nil: p.onPaint(p, c)

proc initPaintBox*(p: PaintBox, owner: Component = nil) =
  p.initControl(owner)
  p.setBounds(0, 0, 100, 100)

proc newPaintBox*(parent: Container = nil, left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): PaintBox =
  new result
  result.initPaintBox(parent)
  result.placeControl(parent, left, top, width, height)
