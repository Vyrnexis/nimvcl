## `Frame` (VCL TFrame): a transparent container used as the base type of
## reusable composite controls. The `frame` macro (dsl/formmacro.nim) derives
## from it. It draws nothing itself and its children inherit the colour of the
## frame's parent, so it can be dropped on any surface.

import ./common, ./panel

type
  Frame* = ref object of Panel

method inheritedColor*(f: Frame): Color =
  if f.parent != nil: f.parent.color else: f.theme.window

method paint*(f: Frame, c: Canvas) =
  procCall paint(Control(f), c)

proc initFrame*(f: Frame, owner: Component = nil) =
  f.initPanel(owner)
  f.borderStyle = pbNone

proc newFrame*(parent: Container = nil, left = 0'f32, top = 0'f32,
               width = -1'f32, height = -1'f32): Frame {.discardable.} =
  new result
  result.initFrame(parent)
  result.placeControl(parent, left, top, width, height)
