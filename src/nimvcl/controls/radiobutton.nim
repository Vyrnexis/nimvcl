## `RadioButton` (VCL TRadioButton). The radio buttons that share a parent
## container form one group: checking one unchecks its RadioButton siblings.
##
## Keyboard: Up/Left select and focus the previous radio button of the group,
## Down/Right the next (wrapping); Space (at key up) checks the focused one.
## Tab visits only one stop per group: the checked button, or the first
## visible enabled one when none is checked. This is computed on demand
## (`isTabStop`), so it is always current.
##
## `autoSize` defaults to true (turned off by `newRadioButton` when an
## explicit width/height is given). `onChange` fires when `checked` changes.

import ./common

type
  RadioButton* = ref object of Control
    fChecked: bool
    fHot, fMouseDown, fKeyDown: bool
    onChange*: NotifyEvent

func checked*(r: RadioButton): bool = r.fChecked

func isUsable(c: Control): bool = c.isVisible and c.isEnabled

proc groupMembers*(r: RadioButton): seq[RadioButton] =
  ## The radio buttons of `r`'s group (same parent), in child order.
  let p = r.parent
  if p == nil: return @[r]
  for ch in p.children:
    if ch of RadioButton: result.add RadioButton(ch)

method isTabStop*(r: RadioButton): bool =
  ## One tab stop per group: the checked usable button, else the first usable.
  if not r.tabStop or not r.isUsable: return false
  let g = r.groupMembers
  for o in g:
    if o.fChecked and o.isUsable: return o == r
  for o in g:
    if o.isUsable: return o == r

proc `checked=`*(r: RadioButton, v: bool) =
  ## Checking unchecks the siblings; a checked button can only be unchecked
  ## by checking another one (code may still pass false).
  if v == r.fChecked: return
  r.fChecked = v
  var others: seq[RadioButton]
  if v:
    for o in r.groupMembers:
      if o != r and o.fChecked:
        o.fChecked = false
        others.add o
  r.invalidate()
  for o in others:
    o.invalidate()
    if o.onChange != nil: o.onChange(o)
  if r.onChange != nil: r.onChange(r)

proc isPressed*(r: RadioButton): bool = (r.fMouseDown and r.fHot) or r.fKeyDown

method canFocus*(r: RadioButton): bool = r.isVisible and r.isEnabled

method preferredSize*(r: RadioButton): SizeF = indicatorPreferredSize(r)

method doMouseEnter*(r: RadioButton) =
  r.fHot = true
  r.invalidate()
  procCall doMouseEnter(Control(r))

method doMouseLeave*(r: RadioButton) =
  r.fHot = false
  r.invalidate()
  procCall doMouseLeave(Control(r))

method doMouseDown*(r: RadioButton, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    r.fMouseDown = true
    r.invalidate()
  procCall doMouseDown(Control(r), button, shift, x, y)

method doMouseMove*(r: RadioButton, shift: ShiftState, x, y: float32) =
  if r.fMouseDown and ssLeft notin shift:
    r.fMouseDown = false
    r.invalidate()
  procCall doMouseMove(Control(r), shift, x, y)

method doMouseUp*(r: RadioButton, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft and r.fMouseDown:
    r.fMouseDown = false
    r.invalidate()
  procCall doMouseUp(Control(r), button, shift, x, y)

method doClick*(r: RadioButton) =
  r.checked = true
  procCall doClick(Control(r))

proc moveInGroup(r: RadioButton, step: int) =
  let g = r.groupMembers
  let i = g.find(r)
  if i < 0: return
  for n in 1 ..< g.len:
    let o = g[(i + step * n + g.len * n) mod g.len]
    if o.isUsable:
      o.checked = true
      setFocus(o)
      return

method doKeyDown*(r: RadioButton, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(r), key, shift)
  if shift * {ssCtrl, ssAlt} != {}: return
  if key == keyUp or key == keyLeft:
    key = Key(0)
    r.moveInGroup(-1)
  elif key == keyDown or key == keyRight:
    key = Key(0)
    r.moveInGroup(1)
  elif key == keySpace:
    key = Key(0)
    if not r.fKeyDown:
      r.fKeyDown = true
      r.invalidate()

method doKeyUp*(r: RadioButton, key: var Key, shift: ShiftState) =
  procCall doKeyUp(Control(r), key, shift)
  if key == keySpace and r.fKeyDown:
    key = Key(0)
    r.fKeyDown = false
    r.invalidate()
    if r.isEnabled: r.doClick()

method doExit*(r: RadioButton) =
  r.fKeyDown = false
  r.invalidate()
  procCall doExit(Control(r))

method paint*(r: RadioButton, c: Canvas) =
  let t = r.theme
  let st = r.visualState(r.fHot, r.isPressed)
  let box = indicatorRect(r)
  if r.fChecked:
    c.fillEllipse(box, accentFaceColor(t, st))
    let d = 6'f32
    c.fillEllipse(rectF(box.x + (box.w - d) / 2, box.y + (box.h - d) / 2, d, d),
                  if st == vsDisabled: t.surface else: t.accentText)
  else:
    c.fillEllipse(box, faceColor(t, st))
    c.strokeEllipse(box, borderColorFor(t, st), t.borderWidth)
  c.textRect(r.caption, r.font, indicatorCaptionRect(r, t), textColorFor(t, st),
             taLeft, vaCenter)
  if r.focused:
    c.strokeEllipse(box, t.focusRing, t.focusRingWidth)
    if r.fChecked:
      c.strokeEllipse(box.inflate(-t.focusRingWidth), t.accentText.withAlpha(200), 1)
  procCall paint(Control(r), c)

proc initRadioButton*(r: RadioButton, owner: Component = nil) =
  r.initControl(owner)
  r.setBounds(0, 0, 120, 20)
  r.tabStop = true
  r.autoSize = true

proc newRadioButton*(parent: Container = nil, caption = "", checked = false,
                     left = 0'f32, top = 0'f32,
                     width = -1'f32, height = -1'f32): RadioButton =
  new result
  result.initRadioButton(parent)
  result.caption = caption
  if width >= 0 or height >= 0: result.autoSize = false
  result.placeControl(parent, left, top, width, height)
  if checked: result.checked = true
