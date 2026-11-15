## `Button` (VCL TButton): push button with hover/pressed visuals, default and
## cancel roles, `modalResult`, and a flat style.
##
## Activation: left click (press and release inside), Enter, and Space (the
## press is shown on key down, the click fires on key up).
##
## Default / cancel (properties `isDefault`, `isCancel`; the VCL names clash
## with Nim's `default`): Enter anywhere in the form clicks the first visible,
## enabled default button, Esc the first cancel button. They are reached
## through the key-handler chain (`UiRoot.addKeyHandler`), so they only see
## keys the focused control did not use; a focused Button handles Enter itself
## (clicking itself). The handler is installed lazily (when a default/cancel
## button is set or first painted).
##
## Mnemonic: `&` in the caption underlines a letter while Alt is held;
## Alt+letter clicks the button.
##
## `modalResult`: when not `mrNone`, a click also sets it on the button's form
## (which closes it when shown with `showModal`).

import ../core/form
import ./common

type
  Button* = ref object of Control
    fDefault, fCancel, fFlat: bool
    fModalResult: ModalResult
    fHot, fMouseDown, fKeyDown, fHooked: bool

const ButtonPadding = 16'f32      ## horizontal text padding for autoSize

# ----------------------------------------------------------- dialog keys

proc findDialogButton(c: Control, cancel: bool): Button =
  ## First visible, enabled default/cancel button in `c`'s subtree (tree order).
  if c of Button:
    let b = Button(c)
    if (if cancel: b.fCancel else: b.fDefault) and b.isVisible and b.isEnabled:
      return b
  if c of Container:
    for ch in Container(c).children:
      result = findDialogButton(ch, cancel)
      if result != nil: return

proc click*(b: Button) =
  ## Programmatic click (VCL Click): ignored while hidden or disabled.
  if b.isVisible and b.isEnabled: b.doClick()

proc handleDialogKey*(root: Control, key: var Key, shift: ShiftState) =
  ## Enter -> default button, Esc -> cancel button (no Ctrl/Alt). Sets `key`
  ## to `Key(0)` when a button was clicked.
  if shift * {ssCtrl, ssAlt, ssSuper} != {}: return
  if key == keyEnter or key == keyEscape:
    let b = findDialogButton(root, key == keyEscape)
    if b != nil:
      key = Key(0)
      b.click()

proc installDialogKeys*(ui: UiRoot) =
  ## Routes unhandled Enter/Esc of `ui`'s form or host to its default/cancel
  ## buttons, through the key-handler chain (id "dialog"; idempotent), so it
  ## coexists with menu shortcuts and the application's own `onUnhandledKey`.
  ui.addKeyHandler("dialog", proc(key: var Key, shift: ShiftState) =
    handleDialogKey(ui.root, key, shift))

proc ensureHook(b: Button) =
  if b.fHooked: return
  let h = b.host
  if h of UiRoot:
    installDialogKeys(UiRoot(h))
    b.fHooked = true

# ------------------------------------------------------------- properties

func isDefault*(b: Button): bool = b.fDefault
proc `isDefault=`*(b: Button, v: bool) =
  if v == b.fDefault: return
  b.fDefault = v
  if v: b.ensureHook()
  b.invalidate()

func isCancel*(b: Button): bool = b.fCancel
proc `isCancel=`*(b: Button, v: bool) =
  if v == b.fCancel: return
  b.fCancel = v
  if v: b.ensureHook()

func flat*(b: Button): bool = b.fFlat
proc `flat=`*(b: Button, v: bool) =
  if v == b.fFlat: return
  b.fFlat = v
  b.invalidate()

func modalResult*(b: Button): ModalResult = b.fModalResult
proc `modalResult=`*(b: Button, v: ModalResult) = b.fModalResult = v

func isPressed*(b: Button): bool =
  ## Shown pressed: mouse held down inside it, or Space held while focused.
  (b.fMouseDown and b.fHot) or b.fKeyDown

func isHot*(b: Button): bool = b.fHot

proc state(b: Button): VisualState =
  b.visualState(b.fHot, b.isPressed)

# --------------------------------------------------------------- behaviour

method canFocus*(b: Button): bool = b.isVisible and b.isEnabled

method activateMnemonic*(b: Button, ch: Rune): bool =
  if mnemonicOf(b.caption) != ch: return false
  b.click()
  true

method preferredSize*(b: Button): SizeF =
  if not b.canMeasure: return sizeF(b.width, b.height)
  let t = b.theme
  let s = b.measure(displayText(b.caption), b.font)
  sizeF(max(ceil(s.w) + 2 * ButtonPadding, 64),
        max(t.controlHeight, ceil(s.h) + t.spacing))

method doMouseEnter*(b: Button) =
  b.fHot = true
  b.invalidate()
  procCall doMouseEnter(Control(b))

method doMouseLeave*(b: Button) =
  b.fHot = false
  b.invalidate()
  procCall doMouseLeave(Control(b))

method doMouseDown*(b: Button, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    b.fMouseDown = true
    b.invalidate()
  procCall doMouseDown(Control(b), button, shift, x, y)

method doMouseMove*(b: Button, shift: ShiftState, x, y: float32) =
  if b.fMouseDown and ssLeft notin shift:   # release was missed (focus lost)
    b.fMouseDown = false
    b.invalidate()
  procCall doMouseMove(Control(b), shift, x, y)

method doMouseUp*(b: Button, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft and b.fMouseDown:
    b.fMouseDown = false
    b.invalidate()
  procCall doMouseUp(Control(b), button, shift, x, y)

method doKeyDown*(b: Button, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(b), key, shift)
  if key == keySpace and shift * {ssCtrl, ssAlt} == {}:
    key = Key(0)
    if not b.fKeyDown:
      b.fKeyDown = true
      b.invalidate()
  elif key == keyEnter:
    key = Key(0)
    if not b.keyIsRepeat: b.click()      # once per press, not per auto-repeat

method doKeyUp*(b: Button, key: var Key, shift: ShiftState) =
  procCall doKeyUp(Control(b), key, shift)
  if key == keySpace and b.fKeyDown:
    key = Key(0)
    b.fKeyDown = false
    b.invalidate()
    b.click()

method doExit*(b: Button) =
  if b.fKeyDown:
    b.fKeyDown = false
  b.invalidate()
  procCall doExit(Control(b))

method doClick*(b: Button) =
  procCall doClick(Control(b))
  if b.fModalResult != mrNone:
    let r = b.root
    if r of Form: Form(r).modalResult = b.fModalResult

# ------------------------------------------------------------------- paint

method paint*(b: Button, c: Canvas) =
  b.ensureHook()
  let t = b.theme
  let st = b.state
  let accent = b.fDefault and st != vsDisabled
  let r = b.clientRect
  let fill = if accent: accentFaceColor(t, st) else: faceColor(t, st, b.fFlat)
  c.fillRoundRect(r, t.radius, fill)
  if not accent and not b.fFlat:
    c.strokeRoundRect(r, t.radius, borderColorFor(t, st), t.borderWidth)
  let txt = if accent: t.accentText else: textColorFor(t, st)
  c.drawMnemonic(b.caption, b.font, r.inflate(-t.spacing + 2), txt, b.altHeld,
                 taCenter, vaCenter)
  if b.focused: drawFocusRing(c, r, t, onFilled = accent)
  procCall paint(Control(b), c)

proc initButton*(b: Button, owner: Component = nil) =
  b.initControl(owner)
  b.setBounds(0, 0, 88, currentTheme().controlHeight)
  b.tabStop = true

proc newButton*(parent: Container = nil, caption = "", left = 0'f32, top = 0'f32,
                width = -1'f32, height = -1'f32): Button {.discardable.} =
  new result
  result.initButton(parent)
  result.caption = caption
  result.placeControl(parent, left, top, width, height)
