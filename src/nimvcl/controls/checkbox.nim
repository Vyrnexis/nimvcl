## `CheckBox` (VCL TCheckBox): caption, tri-state `state`, `allowGrayed`.
##
## A click on the box or the caption, or Space (acted on at key up), advances
## the state: unchecked -> checked -> (grayed, when `allowGrayed`) -> unchecked.
## `onChange` fires whenever `state` changes (user or code); `onClick` only
## for user clicks. `autoSize` defaults to true (box + caption); it is turned
## off by `newCheckBox` when an explicit width/height is given.

import ./common

type
  CheckBoxState* = enum cbUnchecked, cbChecked, cbGrayed

  CheckBox* = ref object of ClickableControl
    fState: CheckBoxState
    fAllowGrayed: bool
    onChange*: NotifyEvent

func state*(b: CheckBox): CheckBoxState = b.fState
proc `state=`*(b: CheckBox, v: CheckBoxState) =
  if v == b.fState: return
  b.fState = v
  b.invalidate()
  if b.onChange != nil: b.onChange(b)

func checked*(b: CheckBox): bool = b.fState == cbChecked
proc `checked=`*(b: CheckBox, v: bool) =
  b.state = if v: cbChecked else: cbUnchecked

func allowGrayed*(b: CheckBox): bool = b.fAllowGrayed
proc `allowGrayed=`*(b: CheckBox, v: bool) =
  b.fAllowGrayed = v
  if not v and b.fState == cbGrayed: b.state = cbUnchecked

proc toggle*(b: CheckBox) =
  ## Advances the state as a click does (without firing `onClick`).
  b.state =
    case b.fState
    of cbUnchecked: cbChecked
    of cbChecked: (if b.fAllowGrayed: cbGrayed else: cbUnchecked)
    of cbGrayed: cbUnchecked

method preferredSize*(b: CheckBox): SizeF = indicatorPreferredSize(b)

method doClick*(b: CheckBox) =
  b.toggle()
  procCall doClick(Control(b))

method paint*(b: CheckBox, c: Canvas) =
  let t = b.theme
  let st = b.visualState
  let box = indicatorRect(b)
  if b.ownColor: c.fillRect(b.clientRect, b.color)   # the area behind
  let on = b.fState != cbUnchecked
  let rad = max(t.radius - 1, 2)
  if on:
    c.fillRoundRect(box, rad, accentFaceColor(t, st))
  else:
    c.fillRoundRect(box, rad, faceColor(t, st))
    c.strokeRoundRect(box, rad, borderColorFor(t, st), t.borderWidth)
  if on:
    let mark = if st == vsDisabled: t.surface else: t.accentText
    let w = 1.8'f32
    template dot(px, py: float32) =
      c.fillEllipse(rectF(box.x + px - w / 2, box.y + py - w / 2, w, w), mark)
    if b.fState == cbChecked:
      c.line(box.x + 4, box.y + 8.4, box.x + 7, box.y + 11.2, mark, w)
      c.line(box.x + 7, box.y + 11.2, box.x + 12, box.y + 5, mark, w)
      dot(4, 8.4); dot(7, 11.2); dot(12, 5)
    else:
      c.line(box.x + 4.5, box.y + 8, box.x + 11.5, box.y + 8, mark, w)
      dot(4.5, 8); dot(11.5, 8)
  c.drawMnemonic(b.caption, b.font, indicatorCaptionRect(b, t),
                 b.ink(t, b.color, st != vsDisabled),
                 b.altHeld, taLeft, vaCenter)
  if b.focused: drawFocusRing(c, box, t, rad, onFilled = on)
  procCall paint(Control(b), c)

proc initCheckBox*(b: CheckBox, owner: Component = nil) =
  b.initControl(owner)
  b.setBounds(0, 0, 120, 20)
  b.tabStop = true
  b.autoSize = true

proc newCheckBox*(parent: Container = nil, caption = "", checked = false,
                  left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): CheckBox {.discardable.} =
  new result
  result.initCheckBox(parent)
  result.caption = caption
  if checked: result.fState = cbChecked
  if width >= 0 or height >= 0: result.autoSize = false
  result.placeControl(parent, left, top, width, height)
