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
## (clicking itself). The handler is installed when a default/cancel button is
## set, or when such a button gets into a form.
##
## Mnemonic: `&` in the caption underlines a letter while Alt is held;
## Alt+letter clicks the button.
##
## Image: `images` (an `ImageList`) and `imageIndex` draw an icon next to the
## caption; `imageAlignment` (`iaLeft` default, `iaRight`, `iaTop`, `iaBottom`)
## says on which side of the caption. The icon is drawn faded while the button
## is disabled; `preferredSize` makes room for it.
##
## `modalResult`: when not `mrNone`, a click first sets it on the button's form
## (which closes it when shown with `showModal`), then runs `onClick`: the
## handler can veto closing by setting `form.modalResult = mrNone`.

import ../core/form
import ./common, ./imagelist

type
  ImageAlignment* = enum iaLeft, iaRight, iaTop, iaBottom
    ## Side of the caption an image is drawn on.

  Button* = ref object of ClickableControl
    fDefault, fCancel, fFlat: bool
    fModalResult: ModalResult
    fImages: ImageListRef
    fImageIndex: int                 ## into `images`; -1: none
    fImageAlign: ImageAlignment

const
  ButtonPadding = 16'f32      ## horizontal text padding for autoSize
  ImageGap = 6'f32            ## between the image and the caption

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
  b.activate()

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
    handleDialogKey(ui.root, key, shift), onRepeat = false)  # once per press

proc ensureHook(b: Button) =
  ## Makes sure the form `b` is in handles Enter/Esc (also after `b` moved to
  ## another form).
  let h = b.host
  if h of UiRoot and not UiRoot(h).hasKeyHandler("dialog"):
    installDialogKeys(UiRoot(h))

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

func images*(b: Button): ImageList = b.fImages.list
proc `images=`*(b: Button, v: ImageList) =
  ## The image list `imageIndex` refers to (repaints when it changes).
  let btn = b
  b.fImages.attach(v, proc() =
    btn.invalidate()
    btn.requestLayout())
  b.invalidate()
  b.requestLayout()

method releaseResources*(b: Button) =
  b.fImages.detach()

func imageIndex*(b: Button): int = b.fImageIndex
proc `imageIndex=`*(b: Button, v: int) =
  let v = max(v, -1)
  if v == b.fImageIndex: return
  b.fImageIndex = v
  b.invalidate()
  b.requestLayout()

func imageAlignment*(b: Button): ImageAlignment = b.fImageAlign
proc `imageAlignment=`*(b: Button, v: ImageAlignment) =
  if v == b.fImageAlign: return
  b.fImageAlign = v
  b.invalidate()
  b.requestLayout()

func hasImage(b: Button): bool =
  let il = b.fImages.list
  il != nil and il.image(b.fImageIndex) != nil

func modalResult*(b: Button): ModalResult = b.fModalResult
proc `modalResult=`*(b: Button, v: ModalResult) = b.fModalResult = v

# --------------------------------------------------------------- behaviour

method visibilityChanged*(b: Button) =
  if b.fDefault or b.fCancel: b.ensureHook()   # inserted into a form
  procCall visibilityChanged(Control(b))

method preferredSize*(b: Button): SizeF =
  if not b.canMeasure: return sizeF(b.width, b.height)
  let t = b.theme
  let s = b.measure(displayText(b.caption), b.font)
  var w = ceil(s.w) + 2 * ButtonPadding
  var h = ceil(s.h) + t.spacing
  if b.hasImage:
    let il = b.fImages.list
    let gap = if b.caption.len > 0: ImageGap else: 0'f32
    if b.fImageAlign in {iaLeft, iaRight}:
      w += il.width + gap
      h = max(h, il.height + t.spacing)
    else:
      w = max(w, il.width + 2 * ButtonPadding)
      h += il.height + gap
  sizeF(max(w, 64), max(t.controlHeight, h))

method doKeyDown*(b: Button, key: var Key, shift: ShiftState) =
  procCall doKeyDown(ClickableControl(b), key, shift)
  if key == keyEnter:
    key = Key(0)
    if not b.keyIsRepeat: b.click()      # once per press, not per auto-repeat

method doClick*(b: Button) =
  if b.fModalResult != mrNone:         # before `onClick`, which may veto it
    let r = b.root
    if r of Form: Form(r).modalResult = b.fModalResult
  procCall doClick(Control(b))

# ------------------------------------------------------------------- paint

func customFace(base: Color, s: VisualState, t: Theme): Color =
  ## Face of a button with its own `color`: hover and pressed shade the colour
  ## toward its contrast side, disabled fades it into the surface.
  let away = if luminance(base) > 0.5: clBlack else: clWhite
  case s
  of vsNormal: base
  of vsHover: mix(base, away, 0.12)
  of vsPressed: mix(base, clBlack, 0.22)
  of vsDisabled: mix(base, t.surface, 0.6)

method paint*(b: Button, c: Canvas) =
  let t = b.theme
  let st = b.visualState
  let own = not b.parentColor and b.color.a > 0   # a colour set by the program
  let accent = b.fDefault and st != vsDisabled and not own
  let r = b.clientRect
  let fill =
    if own: customFace(b.color, st, t)
    elif accent: accentFaceColor(t, st)
    else: faceColor(t, st, b.fFlat)
  c.fillRoundRect(r, t.radius, fill)
  if own:
    c.strokeRoundRect(r, t.radius, mix(fill, clBlack, 0.18), t.borderWidth)
  elif not accent and not b.fFlat:
    c.strokeRoundRect(r, t.radius, borderColorFor(t, st), t.borderWidth)
  let txt =
    if b.hasFontColor and st != vsDisabled: b.font.color
    elif own: (if st == vsDisabled: mix(contrastText(b.color), fill, 0.5)
             else: contrastText(b.color))
    elif accent: t.accentText
    else: textColorFor(t, st)
  let box = r.inflate(-t.spacing + 2)
  if b.hasImage:
    let il = b.fImages.list
    let en = st != vsDisabled
    let hasText = b.caption.len > 0
    let gap = if hasText: ImageGap else: 0'f32
    let tsz = if hasText: b.measure(displayText(b.caption), b.font) else: sizeF(0, 0)
    if b.fImageAlign in {iaLeft, iaRight}:
      let tw = min(ceil(tsz.w), max(box.w - il.width - gap, 0))
      let x0 = box.x + max((box.w - (il.width + gap + tw)) / 2, 0)
      let (ix, tx) = if b.fImageAlign == iaLeft: (x0, x0 + il.width + gap)
                     else: (x0 + tw + gap, x0)
      il.draw(c, b.fImageIndex, ix, box.y + (box.h - il.height) / 2, en)
      if hasText:
        c.drawMnemonic(b.caption, b.font, rectF(tx, box.y, tw + 1, box.h), txt,
                       b.altHeld, taLeft, vaCenter)
    else:
      let th = ceil(tsz.h)
      let y0 = box.y + max((box.h - (il.height + gap + th)) / 2, 0)
      let (iy, ty) = if b.fImageAlign == iaTop: (y0, y0 + il.height + gap)
                     else: (y0 + th + gap, y0)
      il.draw(c, b.fImageIndex, box.x + (box.w - il.width) / 2, iy, en)
      if hasText:
        c.drawMnemonic(b.caption, b.font, rectF(box.x, ty, box.w, th), txt,
                       b.altHeld, taCenter, vaTop)
  else:
    c.drawMnemonic(b.caption, b.font, box, txt, b.altHeld, taCenter, vaCenter)
  if b.focused: drawFocusRing(c, r, t, onFilled = accent)
  procCall paint(Control(b), c)

proc initButton*(b: Button, owner: Component = nil) =
  b.initControl(owner)
  b.setBounds(0, 0, 88, currentTheme().controlHeight)
  b.fImageIndex = -1
  b.tabStop = true

proc newButton*(parent: Container = nil, caption = "", left = 0'f32, top = 0'f32,
                width = -1'f32, height = -1'f32): Button {.discardable.} =
  new result
  result.initButton(parent)
  result.caption = caption
  result.placeControl(parent, left, top, width, height)
