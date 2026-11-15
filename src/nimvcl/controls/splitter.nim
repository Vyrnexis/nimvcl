## `Splitter` (VCL TSplitter): a draggable divider between aligned controls.
##
## Give it the same `align` as the control it resizes and add it right AFTER
## that control (layout stacks same-aligned siblings in child order): an
## `alLeft` panel, then an `alLeft` splitter, then an `alClient` control. The
## splitter resizes the previous visible sibling with the same `align`:
## width for alLeft/alRight, height for alTop/alBottom. Updating is live
## (VCL `rsUpdate`).
##
## The new size honours the neighbour's `constraints`, `minSize` (smallest
## size of the resized control, default 30) and keeps `minSize` px for the
## space that is left over for the rest of the parent (what an `alClient`
## sibling gets). Default `align` is alLeft, width 6. `onMoved` fires after a
## drag step changed the size.

import ./common

type
  Splitter* = ref object of Control
    fMinSize: float32
    fHot, fDrag: bool
    fStartPos: float32      # pointer position (form coords, main axis) at press
    fStartSize: float32
    onMoved*: NotifyEvent

func minSize*(s: Splitter): float32 = s.fMinSize
proc `minSize=`*(s: Splitter, v: float32) = s.fMinSize = max(v, 0)
func isDragging*(s: Splitter): bool = s.fDrag

func vertical(s: Splitter): bool = s.align in {alTop, alBottom}  ## a horizontal bar

proc neighbour*(s: Splitter): Control =
  ## The control this splitter resizes (nil when there is none).
  let p = s.parent
  if p == nil or s.align notin {alLeft, alRight, alTop, alBottom}: return nil
  let i = p.children.find(s)
  for j in countdown(i - 1, 0):
    let c = p.children[j]
    if c.visible and c.align == s.align: return c

proc sizeOf(c: Control, s: Splitter): float32 =
  if s.vertical: c.height else: c.width

proc maxAllowed(s: Splitter, n: Control): float32 =
  ## Largest size for `n`: what the parent has, minus the other aligned
  ## siblings, minus `minSize` kept for the remainder.
  let p = s.parent
  let pad = p.padding
  var avail = if s.vertical: p.height - pad.vertical else: p.width - pad.horizontal
  for c in p.children:
    if c == n or not c.visible: continue
    let onAxis = if s.vertical: c.align in {alTop, alBottom}
                 else: c.align in {alLeft, alRight}
    if onAxis:
      let m = c.margins
      avail -= (if s.vertical: c.height + m.vertical else: c.width + m.horizontal)
  let m = n.margins
  avail -= (if s.vertical: m.vertical else: m.horizontal)
  max(avail - s.fMinSize, s.fMinSize)

proc resizeTo*(s: Splitter, size: float32) =
  ## Sets the neighbour's size (clamped as described in the module comment).
  let n = s.neighbour
  if n == nil: return
  let target = clamp(round(size), s.fMinSize, s.maxAllowed(n))
  let before = sizeOf(n, s)
  if s.vertical: n.height = target else: n.width = target
  let h = s.onMoved         # copy: the handler may clear or replace itself
  if sizeOf(n, s) != before and h != nil: h(s)

method doMouseEnter*(s: Splitter) =
  s.fHot = true
  s.invalidate()
  procCall doMouseEnter(Control(s))

method doMouseLeave*(s: Splitter) =
  s.fHot = false
  s.invalidate()
  procCall doMouseLeave(Control(s))

proc mainAxis(s: Splitter, x, y: float32): float32 =
  let p = s.clientToForm(pointF(x, y))
  if s.vertical: p.y else: p.x

method doMouseDown*(s: Splitter, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    let n = s.neighbour
    if n != nil:
      s.fDrag = true
      s.fStartPos = s.mainAxis(x, y)
      s.fStartSize = sizeOf(n, s)
      s.invalidate()
  procCall doMouseDown(Control(s), button, shift, x, y)

method doMouseMove*(s: Splitter, shift: ShiftState, x, y: float32) =
  if s.fDrag:
    if ssLeft notin shift: s.fDrag = false
    else:
      let d = s.mainAxis(x, y) - s.fStartPos
      # right/bottom aligned neighbours grow when the pointer moves left/up
      s.resizeTo(s.fStartSize + (if s.align in {alLeft, alTop}: d else: -d))
  procCall doMouseMove(Control(s), shift, x, y)

method doMouseUp*(s: Splitter, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft and s.fDrag:
    s.fDrag = false
    s.invalidate()
  procCall doMouseUp(Control(s), button, shift, x, y)

method captureLost*(s: Splitter) =
  if s.fDrag:
    s.fDrag = false
    s.invalidate()
  procCall captureLost(Control(s))

method paint*(s: Splitter, c: Canvas) =
  let t = s.theme
  # the resize cursor follows the orientation (align can change at any time)
  let want = if s.vertical: crSizeNS else: crSizeWE
  if s.cursor != want: s.cursor = want
  let r = s.clientRect
  if s.fDrag: c.fillRect(r, t.accent.withAlpha(60))
  elif s.fHot: c.fillRect(r, t.hover)
  let col = if s.fDrag: t.accent else: t.borderStrong
  # a hairline plus three grip dots
  if s.vertical:
    c.line(0, r.h / 2, r.w, r.h / 2, t.border, 1)
    for i in -1 .. 1:
      c.fillEllipse(rectF(r.w / 2 + float32(i) * 6 - 1, r.h / 2 - 1, 2, 2), col)
  else:
    c.line(r.w / 2, 0, r.w / 2, r.h, t.border, 1)
    for i in -1 .. 1:
      c.fillEllipse(rectF(r.w / 2 - 1, r.h / 2 + float32(i) * 6 - 1, 2, 2), col)
  procCall paint(Control(s), c)

proc initSplitter*(s: Splitter, owner: Component = nil) =
  s.initControl(owner)
  s.fMinSize = 30
  s.setBounds(0, 0, 6, 6)
  s.align = alLeft
  s.cursor = crSizeWE

proc newSplitter*(parent: Container = nil, align = alLeft,
                  left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): Splitter {.discardable.} =
  ## Convention note: the main property is `align` (the edge it splits at).
  new result
  result.initSplitter(parent)
  result.align = align
  result.placeControl(parent, left, top, width, height)
