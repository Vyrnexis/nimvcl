## `ScrollBox` (VCL TScrollBox): a container that scrolls its children.
##
## Children with `align = alNone` (the default) live in CONTENT coordinates:
## `left`/`top` are measured from the unscrolled content origin, and they move
## with the scroll position and are clipped to the viewport. The content size is
## the bounding box (right/bottom edge) of the visible alNone children, tracked
## automatically, unless you set `contentSize` explicitly (which turns
## `autoContentSize` off). Children with another `align` are laid out against
## the viewport and do NOT scroll (a deviation from VCL, where aligned children
## scroll too); they fill the visible area.
##
## Scrollbars (`hScrollMode` / `vScrollMode`, auto by default), wheel and
## Shift+wheel come from `ScrollingControl` (scrolling.nim). When keyboard focus
## moves into a descendant of an alNone child (Tab, `setFocus`; not a mouse
## press) the box scrolls the minimum distance that reveals it.
## The box is not focusable itself. It draws no background (set `color` via a
## Panel parent, or use a Panel and give it scrolling children yourself).

import ./common, ./scrolling
export scrolling

type
  ScrollBox* = ref object of ScrollingControl
    fAutoContent: bool
    fDirty: bool

func autoContentSize*(b: ScrollBox): bool = b.fAutoContent
proc `autoContentSize=`*(b: ScrollBox, v: bool) =
  if v == b.fAutoContent: return
  b.fAutoContent = v
  b.fDirty = v
  if v: b.relayout()

proc `contentSize=`*(b: ScrollBox, s: SizeF) =
  ## Explicit content size; turns `autoContentSize` off.
  b.fAutoContent = false
  b.setContentSize(s.w, s.h)

proc measureContent(b: ScrollBox) =
  # Children sit in client coordinates; scroll coordinates start at the padded
  # viewport origin, so the content spans from the padding to the last child
  # plus the opposite padding.
  var w, h = 0'f32
  var any = false
  for ch in b.children:
    if ch.align != alNone or not ch.visible: continue
    any = true
    w = max(w, ch.left + ch.width)
    h = max(h, ch.top + ch.height)
  let p = b.padding
  if any:
    w = max(w - p.left + p.right, 0)
    h = max(h - p.top + p.bottom, 0)
  b.fDirty = false
  b.setContentSize(w, h)

method childBoundsChanged*(b: ScrollBox, ch: Control) =
  # Aligned children are placed by layout itself (ignore those bounds changes),
  # but an align change or a manual move outside layout must refresh the content.
  if b.fAutoContent and (ch.align == alNone or not b.layouting):
    b.fDirty = true
    if not b.layouting: b.relayout()

method beforeLayout*(b: ScrollBox) =
  if b.fAutoContent and b.fDirty: b.measureContent()
  procCall beforeLayout(ScrollingControl(b))

method afterLayout*(b: ScrollBox) =
  # anchors may have moved children during this layout
  if b.fAutoContent and b.fDirty: b.relayout()

method revealControl*(b: ScrollBox, d: Control) =
  # the direct child of `b` on the path to `d`
  var top = d
  while top != nil and Control(top.parent) != Control(b): top = Control(top.parent)
  if top == nil or top.align != alNone or not d.isVisible: return
  let r = b.rectInAncestor(d)
  let o = b.scrollPos
  let p = b.padding
  b.scrollIntoView(r.offset(o.x - p.left, o.y - p.top))

method paint*(b: ScrollBox, c: Canvas) =
  if b.ownColor: c.fillRect(b.clientRect, b.color)   # drawn nothing otherwise: it shows its parent
  procCall paint(ScrollingControl(b), c)

proc initScrollBox*(b: ScrollBox, owner: Component = nil) =
  b.initScrollingControl(owner, scrollsChildren = true)
  b.setBounds(0, 0, 200, 150)
  b.fAutoContent = true
  b.fDirty = true

proc newScrollBox*(parent: Container = nil, left = 0'f32, top = 0'f32,
                   width = -1'f32, height = -1'f32): ScrollBox {.discardable.} =
  new result
  result.initScrollBox(parent)
  result.placeControl(parent, left, top, width, height)
