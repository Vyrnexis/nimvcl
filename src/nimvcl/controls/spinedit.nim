## `SpinEdit` (VCL TSpinEdit): an integer `Edit` with up/down buttons.
##
## Composition: a Container holding an `Edit` (`s.edit`, alClient) and a
## `SpinButtons` control (alRight, 20 px). Focus lives in the edit child
## (`s.edit.setFocus()`).
##
## `value` is always within `minValue .. maxValue` and changes by `increment`
## per Up/Down key, wheel notch (while the edit has focus) or button press; PageUp/Down
## step by 10 increments. Holding a button repeats: first after 400 ms, then
## every 50 ms (`repeatTick` is what the timer calls). The text is parsed on
## Enter and when the edit loses focus: an out-of-range number is clamped,
## unparsable text reverts to the current value. `onChange` fires when `value`
## changes.

import std/strutils
import ../core/timer
import ./[common, edit]

type
  SpinButtons* = ref object of Control
    ## The pair of arrow buttons (internal to SpinEdit, public for tests).
    hotDir, pressedDir: int        # -1 down, 0 none, +1 up
    onPress*: proc(dir: int)
    onRelease*: proc()

  SpinEdit* = ref object of Container
    edit*: Edit
    buttons*: SpinButtons
    fMin, fMax, fValue, fInc: int
    repeat: Timer
    repeatDir: int
    onChange*: NotifyEvent

const
  SpinButtonWidth = 20'f32
  RepeatDelayMs* = 400
  RepeatRateMs* = 50

# ---------------------------------------------------------- SpinButtons

func halfAt(b: SpinButtons, y: float32): int =
  if y < b.height / 2: 1 else: -1

method doMouseDown*(b: SpinButtons, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    b.pressedDir = b.halfAt(y)
    b.hotDir = b.pressedDir
    b.invalidate()
    if b.onPress != nil: b.onPress(b.pressedDir)
  procCall doMouseDown(Control(b), button, shift, x, y)

method doMouseUp*(b: SpinButtons, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft and b.pressedDir != 0:
    b.pressedDir = 0
    b.invalidate()
    if b.onRelease != nil: b.onRelease()
  procCall doMouseUp(Control(b), button, shift, x, y)

method doMouseMove*(b: SpinButtons, shift: ShiftState, x, y: float32) =
  let h = if y >= 0 and y < b.height and x >= 0 and x < b.width: b.halfAt(y) else: 0
  if h != b.hotDir:
    b.hotDir = h
    b.invalidate()
  procCall doMouseMove(Control(b), shift, x, y)

method doMouseLeave*(b: SpinButtons) =
  b.hotDir = 0
  b.invalidate()
  procCall doMouseLeave(Control(b))

method paint*(b: SpinButtons, c: Canvas) =
  let t = b.theme
  let en = b.isEnabled
  let r = b.clientRect
  for dir in [1, -1]:
    let half = if dir == 1: rectF(0, 0, r.w, r.h / 2) else: rectF(0, r.h / 2, r.w, r.h / 2)
    var fill = clTransparent
    if en and b.pressedDir == dir and b.hotDir == dir: fill = t.pressed
    elif en and b.hotDir == dir and b.pressedDir == 0: fill = t.hover
    if fill.a > 0:
      c.pushClip(half)
      c.fillRoundRect(r.inflate(-1), t.radius, fill)
      c.popClip()
    let ctr = pointF(r.w / 2, half.y + half.h / 2)
    c.drawArrow(ctr, 3.5, if dir == 1: adUp else: adDown,
                if en: t.text else: t.textDisabled)
  procCall paint(Control(b), c)

# ------------------------------------------------------------- SpinEdit

method paint*(s: SpinEdit, c: Canvas) =
  ## One field: the face, the border and the focus ring around the edit AND the
  ## buttons (the edit child is borderless, the buttons draw only their arrows).
  let t = s.theme
  let enabled = s.isEnabled
  let r = s.clientRect
  let foc = s.edit.focused and enabled
  c.fillRoundRect(r, t.radius, if enabled: t.surface else: t.surfaceAlt)
  c.strokeRoundRect(r, t.radius,
                    if not enabled: t.border elif foc: t.accent else: t.borderStrong,
                    t.borderWidth)
  if foc: drawFocusRing(c, r, t)
  procCall paint(Control(s), c)

func minValue*(s: SpinEdit): int = s.fMin
func maxValue*(s: SpinEdit): int = s.fMax
func value*(s: SpinEdit): int = s.fValue
func increment*(s: SpinEdit): int = s.fInc

proc syncText(s: SpinEdit) =
  let txt = $s.fValue
  if s.edit.text != txt: s.edit.text = txt

proc `value=`*(s: SpinEdit, v: int) =
  let nv = clamp(v, s.fMin, s.fMax)
  if nv == s.fValue:
    s.syncText()           # also restores text the user messed up
    return
  s.fValue = nv
  s.syncText()
  if s.onChange != nil: s.onChange(s)

proc `minValue=`*(s: SpinEdit, v: int) =
  s.fMin = v
  if s.fMax < v: s.fMax = v
  s.value = s.fValue
proc `maxValue=`*(s: SpinEdit, v: int) =
  s.fMax = v
  if s.fMin > v: s.fMin = v
  s.value = s.fValue
proc `increment=`*(s: SpinEdit, v: int) = s.fInc = max(v, 1)

proc commit*(s: SpinEdit) =
  ## Applies the edit's text: clamps a number, reverts anything else.
  let txt = s.edit.text.strip
  var n: int
  var ok = txt.len > 0 and txt != "-"
  if ok:
    try: n = parseInt(txt)
    except ValueError: ok = false
  if ok: s.value = n
  else: s.syncText()

proc stepBy*(s: SpinEdit, dir: int, count = 1) =
  ## Commits pending text, then moves `value` by `dir * count * increment`.
  s.commit()
  s.value = s.fValue + dir * count * s.fInc

proc repeatTick*(s: SpinEdit) =
  ## One auto-repeat step (the timer's handler); no-op when no button is held.
  if s.repeatDir == 0: return
  s.stepBy(s.repeatDir)
  if s.repeat.interval != RepeatRateMs: s.repeat.interval = RepeatRateMs

proc stopRepeat(s: SpinEdit) =
  s.repeatDir = 0
  s.repeat.enabled = false

method doMouseWheel*(s: SpinEdit, shift: ShiftState, dx, dy: float32,
                     handled: var bool) =
  if not handled and dy != 0 and s.edit.focused:
    let n = max(int(abs(dy)), 1)
    s.stepBy(if dy > 0: 1 else: -1, n)
    handled = true
  procCall doMouseWheel(Control(s), shift, dx, dy, handled)

method doExit*(s: SpinEdit) =
  s.stopRepeat()
  procCall doExit(Control(s))

method focusTarget*(s: SpinEdit): Control = s.edit

proc initSpinEdit*(s: SpinEdit, owner: Component = nil) =
  s.initContainer(owner)
  s.fMin = 0
  s.fMax = 100
  s.fInc = 1
  s.setBounds(0, 0, 100, currentTheme().controlHeight)
  s.repeat = newTimer(s, RepeatDelayMs)
  s.repeat.onTimer = proc(t: Timer) = s.repeatTick()
  s.padding = spacing(2)
  let e = newEdit(s)
  e.borderStyle = ebNone
  e.align = alClient
  e.text = "0"
  s.edit = e
  e.onKeyPress = proc(sender: Control, text: var string) =
    var d = ""
    for i, ch in text:
      if ch in {'0'..'9'} or (ch == '-' and s.fMin < 0 and i == 0): d.add ch
    text = d
  e.onKeyDown = proc(sender: Control, key: var Key, shift: ShiftState) =
    if shift * {ssCtrl, ssAlt, ssSuper} != {}: return
    if key == keyUp: s.stepBy(1)
    elif key == keyDown: s.stepBy(-1)
    elif key == keyPageUp: s.stepBy(1, 10)
    elif key == keyPageDown: s.stepBy(-1, 10)
    elif key == keyEnter:
      s.commit()
      e.selectAll()
      return                        # Enter stays available to a default button
    else: return
    e.selectAll()
    key = Key(0)
  e.onEnter = proc(sender: Control) = s.invalidate()      # the focus ring is the spin's
  e.onExit = proc(sender: Control) =
    s.commit()
    s.invalidate()
  let b = SpinButtons()
  b.initControl(s)
  b.setBounds(0, 0, SpinButtonWidth, s.height)
  b.align = alRight
  b.onPress = proc(dir: int) =
    s.edit.setFocus()
    s.stepBy(dir)
    s.repeatDir = dir
    s.repeat.interval = RepeatDelayMs
    s.repeat.enabled = true
  b.onRelease = proc() = s.stopRepeat()
  s.insertControl b
  s.buttons = b

proc newSpinEdit*(parent: Container = nil, value = 0, left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): SpinEdit =
  new result
  result.initSpinEdit(parent)
  result.value = value
  result.placeControl(parent, left, top, width, height)
