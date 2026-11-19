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
import ./[common, edit, rangevalue]

type
  SpinButtons* = ref object of Control
    ## The pair of arrow buttons (internal to SpinEdit, public for tests).
    hotDir, pressedDir: int        # -1 down, 0 none, +1 up
    onPress*: proc(dir: int)
    onRelease*: proc()

  SpinField = ref object of Edit
    spin: SpinEdit                 ## the inner edit follows the spin edit's `color`

  SpinEdit* = ref object of Container
    edit*: Edit
    buttons*: SpinButtons
    fRng: RangeValue
    fInc: int
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
    let h = b.onPress       # copy: the handler may clear or replace itself
    if h != nil: h(b.pressedDir)
  procCall doMouseDown(Control(b), button, shift, x, y)

method doMouseUp*(b: SpinButtons, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft and b.pressedDir != 0:
    b.pressedDir = 0
    b.invalidate()
    let h = b.onRelease
    if h != nil: h()
  procCall doMouseUp(Control(b), button, shift, x, y)

method captureLost*(b: SpinButtons) =
  ## The press ended without a mouse-up: the auto-repeat must stop.
  if b.pressedDir != 0:
    b.pressedDir = 0
    b.invalidate()
    let h = b.onRelease
    if h != nil: h()
  procCall captureLost(Control(b))

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

method colorOwner*(e: SpinField): Control = e.spin

method paint*(b: SpinButtons, c: Canvas) =
  let t = b.theme
  let sp = if b.parent != nil: Control(b.parent) else: Control(b)
  let bg = sp.fieldFill(t, b.isEnabled)
  let en = b.isEnabled
  let r = b.clientRect
  for dir in [1, -1]:
    let half = if dir == 1: rectF(0, 0, r.w, r.h / 2) else: rectF(0, r.h / 2, r.w, r.h / 2)
    var fill = clTransparent
    if en and b.pressedDir == dir and b.hotDir == dir:
      fill = if sp.ownColor: shade(bg, 0.18'f32) else: t.pressed
    elif en and b.hotDir == dir and b.pressedDir == 0: fill = sp.rowHover(t, bg)
    if fill.a > 0:
      c.pushClip(half)
      c.fillRoundRect(r.inflate(-1), t.radius, fill)
      c.popClip()
    let ctr = pointF(r.w / 2, half.y + half.h / 2)
    c.drawArrow(ctr, 3.5, if dir == 1: adUp else: adDown,
                b.ink(t, bg, en))
  procCall paint(Control(b), c)

# ------------------------------------------------------------- SpinEdit

method paint*(s: SpinEdit, c: Canvas) =
  ## One field: the face, the border and the focus ring around the edit AND the
  ## buttons (the edit child is borderless, the buttons draw only their arrows).
  let t = s.theme
  let enabled = s.isEnabled
  let r = s.clientRect
  let foc = s.edit.focused and enabled
  c.fillRoundRect(r, t.radius, s.fieldFill(t, enabled))
  c.strokeRoundRect(r, t.radius,
                    if not enabled: t.border elif foc: t.accent else: t.borderStrong,
                    t.borderWidth)
  if foc: drawFocusRing(c, r, t)
  procCall paint(Control(s), c)

func minValue*(s: SpinEdit): int = s.fRng.lo
func maxValue*(s: SpinEdit): int = s.fRng.hi
func value*(s: SpinEdit): int = s.fRng.pos
func increment*(s: SpinEdit): int = s.fInc

proc stopRepeat(s: SpinEdit) =
  s.repeatDir = 0
  s.repeat.enabled = false

proc syncText(s: SpinEdit) =
  let txt = $s.fRng.pos
  if s.edit.text != txt: s.edit.text = txt

proc moved(s: SpinEdit, changed: bool) =
  s.syncText()               # also restores text the user messed up
  if changed:
    let h = s.onChange        # copy: the handler may clear or replace itself
    if h != nil: h(s)

proc `value=`*(s: SpinEdit, v: int) =
  s.moved(s.fRng.setPos(v))

proc `minValue=`*(s: SpinEdit, v: int) =
  s.moved(s.fRng.setMin(v))
proc `maxValue=`*(s: SpinEdit, v: int) =
  s.moved(s.fRng.setMax(v))
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
  let d = dir * count * s.fInc
  s.value =                      # saturating: a range up to high(int) cannot overflow
    if d > 0 and s.fRng.pos > high(int) - d: high(int)
    elif d < 0 and s.fRng.pos < low(int) - d: low(int)
    else: s.fRng.pos + d

proc repeatTick*(s: SpinEdit) =
  ## One auto-repeat step (the timer's handler); no-op, and the repeat stops,
  ## when no button is held.
  if s.repeatDir == 0: return
  if s.buttons.pressedDir == 0:
    s.stopRepeat()
    return
  s.stepBy(s.repeatDir)
  if s.repeat.interval != RepeatRateMs: s.repeat.interval = RepeatRateMs

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
  s.fRng.lo = 0
  s.fRng.hi = 100
  s.fInc = 1
  s.setBounds(0, 0, 100, currentTheme().controlHeight)
  s.repeat = newTimer(nil, RepeatDelayMs)
  s.repeat.onTimer = proc(t: Timer) = s.repeatTick()
  s.padding = spacing(2)
  let e = SpinField(spin: s)
  e.initEdit(s)
  s.insertControl e
  e.borderStyle = ebNone
  e.align = alClient
  e.text = "0"
  s.edit = e
  e.onKeyPress = proc(sender: Control, text: var string) =
    var d = ""
    for i, ch in text:
      if ch in {'0'..'9'} or (ch == '-' and s.fRng.lo < 0 and i == 0): d.add ch
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
    s.stopRepeat()
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
                  width = -1'f32, height = -1'f32): SpinEdit {.discardable.} =
  new result
  result.initSpinEdit(parent)
  result.value = value
  result.placeControl(parent, left, top, width, height)
