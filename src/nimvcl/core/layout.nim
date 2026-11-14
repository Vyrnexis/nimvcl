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
## 4. alNone children are only adjusted by `anchors` when the container's size
##    changed since its previous layout (`lastLayoutSize`; the first layout just
##    records it). dw/dh = size change. Horizontal: left+right anchored =>
##    width += dw; right only => left += dw; neither => left += dw/2 (keeps its
##    proportional centre); left only => unchanged. Vertical likewise.
## 5. alCustom children are handed to `customAlign` with the remaining rect.
## 6. Child containers whose size changed (or that are flagged) are laid out
##    recursively.
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

proc applyAnchors(ch: Control, dw, dh: float32) =
  var
    l = ch.left
    t = ch.top
    w = ch.width
    h = ch.height
  let a = ch.anchors
  if akLeft in a and akRight in a: w += dw
  elif akRight in a: l += dw
  elif akLeft notin a: l += dw / 2
  if akTop in a and akBottom in a: h += dh
  elif akBottom in a: t += dh
  elif akTop notin a: t += dh / 2
  ch.place(l, t, w, h)

proc layout*(c: Container) =
  ## Aligns the children of `c` (see the module docs), then recurses into child
  ## containers that need it. Clears `needsLayout`/`childNeedsLayout`.
  if c.layouting: return
  c.layouting = true
  let kids = c.children          # copy: handlers may touch the tree
  let pad = c.padding
  var r = rectF(pad.left, pad.top, max(c.width - pad.horizontal, 0),
                max(c.height - pad.vertical, 0))

  # autoSize first (sizes only; positions come from the passes below)
  for ch in kids:
    if not ch.visible or not ch.autoSize: continue
    let ps = ch.preferredSize()
    case ch.align
    of alNone, alCustom: ch.place(ch.left, ch.top, ps.w, ps.h)
    of alTop, alBottom: ch.place(ch.left, ch.top, ch.width, ps.h)
    of alLeft, alRight: ch.place(ch.left, ch.top, ps.w, ch.height)
    of alClient: discard

  for pass in [alTop, alBottom, alLeft, alRight]:
    for ch in kids:
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
    if not ch.visible: continue
    let m = ch.margins
    case ch.align
    of alClient:
      ch.place(r.x + m.left, r.y + m.top, max(r.w - m.horizontal, 0),
               max(r.h - m.vertical, 0))
    of alNone:
      if c.layoutInitialized:
        let dw = c.width - c.lastLayoutSize.w
        let dh = c.height - c.lastLayoutSize.h
        if dw != 0 or dh != 0: ch.applyAnchors(dw, dh)
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

proc layoutIfNeeded*(c: Container) =
  ## `layout(c)` only when `c` or a descendant is flagged. The form calls this
  ## before painting (after the host's `requestLayout`).
  if c.needsLayout or c.childNeedsLayout: layout(c)
