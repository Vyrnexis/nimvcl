## VCL-style layout (AlignControls). Pure math over the control tree; no SDL.
##
## `layout(container)` positions the container's visible children:
##
## 1. available = client rect deflated by `padding`.
## 2. `autoSize` children take `preferredSize()` in the dimension(s) their
##    `align` lets them own (alNone/alCustom: both, alTop/alBottom: height,
##    alLeft/alRight: width, alClient: none). `constraints` clamp every size
##    (via `setBounds`), before stacking for the main axis.
## 3. alTop children stack downward from the top, then alBottom upward from the
##    bottom (each using the full remaining width minus margins), then alLeft
##    from the left and alRight from the right (using the remaining height),
##    then alClient takes what is left. Margins always apply; invisible
##    children are skipped. Several alClient children all get the same rect.
##    NOTE: VCL orders same-align siblings by their position (Top/Left); we use
##    CHILD ORDER (z-order), which is deterministic and needs no sorting.
## 4. alNone children are positioned by `anchors` relative to the DESIGN size
##    (VCL): every child remembers its `designRect` (its rect when it was last
##    placed explicitly: `setBounds`/`left=`/... outside a layout, or when it was
##    inserted) and the parent size that rect belongs to. A container's design
##    size (`designSize`) is its own explicitly set size until its first layout
##    (window-manager resizes, `hostSized`, do not count); a container never
##    explicitly sized uses its size at its first layout. Children placed before
##    the container's first layout follow `designSize`; children added/placed
##    after it are relative to the size at that moment. At layout, with
##    dw/dh = current size - base size, from the DESIGN rect: left+right
##    anchored => width += dw; right only => left += dw; neither => left += dw/2
##    (keeps its proportional centre); left only => unchanged. Vertical
##    likewise. Positions come from baseline + TOTAL delta (never incremental),
##    so any sequence of resizes is drift-free and returning to the design size
##    restores the design positions exactly. Children with the default anchors
##    {akLeft, akTop} are never touched. autoSize children keep their size.
## 5. alCustom children are handed to `customAlign` with the remaining rect.
## 6. A container whose `arrangeChildren(area)` returns true positioned its
##    children itself: steps 2-5 are skipped (children keep their `align`).
## 7. Child containers whose size changed (or that are flagged) are laid out
##    recursively.
##
## Scrolling: aligned children (anything but alNone) are laid out against the
## container's own client area (padding deflated) and are NOT scrolled, so a
## scrolling container's scrollbars (alRight/alBottom) and alClient content stay
## on screen while alNone children, which live in content coordinates, move
## with `Container.scrollOffset`. Layout itself never reads the scroll offset
## (scrolling needs no relayout). `beforeLayout` / `afterLayout` are hooks for
## containers that track a content size (ScrollingControl).
##
## Rounding policy: values stay float32, but every position and size that
## layout computes is snapped to a WHOLE logical pixel (`round`, half away from
## zero) before it is stored, and following siblings stack from the snapped
## result, so no gaps or overlaps appear. Min/max constraint values are
## applied as given (not snapped).

import std/math
import ../graphics/geometry
import ./types, ./control

proc snap(v: float32): float32 {.inline.} = round(v)

proc place(ch: Control, x, y, w, h: float32) =
  ch.setBounds(snap(x), snap(y), snap(w), snap(h))

proc applyAnchors(ch: Control, base: SizeF, cw, chh: float32) =
  ## Positions `ch` from its DESIGN rect plus the total size change since
  ## `base` (never incrementally: no rounding drift).
  let dw = cw - base.w
  let dh = chh - base.h
  var
    l = ch.designRect.x
    t = ch.designRect.y
    w = ch.designRect.w
    h = ch.designRect.h
  let a = ch.anchors
  if ch.autoSize:                  # the size is owned by preferredSize
    w = ch.width
    h = ch.height
  if akLeft in a and akRight in a:
    if not ch.autoSize: w += dw
  elif akRight in a: l += dw
  elif akLeft notin a: l += dw / 2
  if akTop in a and akBottom in a:
    if not ch.autoSize: h += dh
  elif akBottom in a: t += dh
  elif akTop notin a: t += dh / 2
  ch.place(l, t, w, h)

proc layout*(c: Container) =
  ## Aligns the children of `c` (see the module docs), then recurses into child
  ## containers that need it. Clears `needsLayout`/`childNeedsLayout`.
  if c.layouting: return
  c.beforeLayout()
  c.layouting = true
  if not c.designSet:            # never explicitly sized: first layout is the design
    c.designSize = sizeF(c.width, c.height)
    c.designSet = true
  let kids = c.children          # copy: handlers may touch the tree
  let pad = c.padding
  var r = rectF(pad.left, pad.top, max(c.width - pad.horizontal, 0),
                max(c.height - pad.vertical, 0))

  let owned = c.arrangeChildren(r)   # layout owner: skips the align passes

  # autoSize first (sizes only; positions come from the passes below)
  for ch in kids:
    if owned: break
    if not ch.visible or not ch.autoSize: continue
    let ps = ch.preferredSize()
    case ch.align
    of alNone, alCustom:
      ch.place(ch.left, ch.top, ps.w, ps.h)
      ch.designRect.w = ch.width
      ch.designRect.h = ch.height
    of alTop, alBottom: ch.place(ch.left, ch.top, ch.width, ps.h)
    of alLeft, alRight: ch.place(ch.left, ch.top, ps.w, ch.height)
    of alClient: discard

  for pass in [alTop, alBottom, alLeft, alRight]:
    for ch in kids:
      if owned: break
      if not ch.visible or ch.align != pass: continue
      let m = ch.margins
      let k = ch.constraints
      case pass
      of alTop:
        ch.place(r.x + m.left, r.y + m.top, max(r.w - m.horizontal, 0),
                 k.clampHeight(snap(ch.height)))
        let used = ch.top + ch.height + m.bottom - r.y
        r.y += used
        r.h = max(r.h - used, 0)
      of alBottom:
        let h = k.clampHeight(snap(ch.height))
        ch.place(r.x + m.left, r.bottom - m.bottom - h,
                 max(r.w - m.horizontal, 0), h)
        r.h = max(ch.top - m.top - r.y, 0)
      of alLeft:
        ch.place(r.x + m.left, r.y + m.top, k.clampWidth(snap(ch.width)),
                 max(r.h - m.vertical, 0))
        let used = ch.left + ch.width + m.right - r.x
        r.x += used
        r.w = max(r.w - used, 0)
      of alRight:
        let w = k.clampWidth(snap(ch.width))
        ch.place(r.right - m.right - w, r.y + m.top, w,
                 max(r.h - m.vertical, 0))
        r.w = max(ch.left - m.left - r.x, 0)
      else: discard

  for ch in kids:
    if owned: break
    if not ch.visible: continue
    let m = ch.margins
    case ch.align
    of alClient:
      ch.place(r.x + m.left, r.y + m.top, max(r.w - m.horizontal, 0),
               max(r.h - m.vertical, 0))
    of alNone:
      if ch.anchors != DefaultAnchors:   # left+top never moves
        let base = if ch.designBaseSet: ch.designBase else: c.designSize
        ch.applyAnchors(base, c.width, c.height)
    of alCustom:
      c.customAlign(ch, r)
    else: discard

  c.lastLayoutSize = sizeF(c.width, c.height)
  c.layoutInitialized = true

  for ch in kids:
    if not ch.visible or not (ch of Container): continue
    let cc = Container(ch)
    if cc.needsLayout or cc.childNeedsLayout or not cc.layoutInitialized or
       cc.width != cc.lastLayoutSize.w or cc.height != cc.lastLayoutSize.h:
      layout(cc)

  c.needsLayout = false
  c.childNeedsLayout = false
  c.layouting = false
  c.invalidate()
  c.afterLayout()

proc layoutIfNeeded*(c: Container) =
  ## `layout(c)` only when `c` or a descendant is flagged. The form calls this
  ## before painting (after the host's `requestLayout`).
  if c.needsLayout or c.childNeedsLayout: layout(c)
