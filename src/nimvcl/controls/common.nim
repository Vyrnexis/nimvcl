## Shared helpers for the stock controls (phase 3). Small and stable: any
## control module may import it.
##
## Constructor convention
## ----------------------
## Every stock control has
##
##   proc newXxx*(parent: Container = nil, <main property> = "", ...,
##                left = 0'f32, top = 0'f32,
##                width = -1'f32, height = -1'f32): Xxx {.discardable.}
##
## The constructors are `{.discardable.}`: the parent owns the control (VCL
## style), so `newLabel(form, "Hi", 10, 10)` works as a statement.
##
## * `parent` is also the Component owner. When non-nil the control is
##   appended to `parent`'s children (`insertControl`). With nil the control is
##   detached; add it later with `parent.insertControl c` or `c.parent = p`.
## * the main property is `caption` for text controls (Label, Button, CheckBox,
##   RadioButton, Panel, GroupBox).
## * `left`/`top` are applied always; `width`/`height` only when >= 0 (a
##   negative value keeps the control's own default size).
## * Everything else is set by assigning properties afterwards.
## * Subclass constructors call `initXxx(c, parent)` (not `new`), then
##   `placeControl(c, parent, left, top, width, height)`.
##
## Drawing rules
## -------------
## * Colours come from `control.theme` at paint time, never cached.
## * `drawFocusRing` paints the ring INSIDE the given rect (like
##   `strokeRoundRect`), over the control's own border. Faces are not inset,
##   so focusing never moves anything.
## * Text measuring needs the form's RenderContext: `measure` returns
##   `canMeasure(c) == false` and the zero size while the control is not in a
##   form that has a window; callers then keep their current size.

import std/[math, strutils, unicode]
import ../graphics/[geometry, color, font, canvas, context]
import ../core/[types, control, theme, input]
export math, geometry, color, font, canvas, types, control, theme, input

type
  TextStyle* = object
    ## Text colour role of a control (`Label`, `Panel`): the theme's text, or a
    ## `ThemeColor` role resolved at paint time. A fixed colour is the control's
    ## `font.color`, which takes precedence over the role.
    role: ThemeColor

  VisualState* = enum
    ## What a clickable control looks like.
    vsNormal, vsHover, vsPressed, vsDisabled

func role*(s: TextStyle): ThemeColor = s.role
proc setRole*(s: var TextStyle, v: ThemeColor) = s.role = v
proc reset*(s: var TextStyle) = s = TextStyle()
func resolve*(s: TextStyle, t: Theme): Color =
  ## The colour to draw with under theme `t`.
  t.resolve(s.role)

# ---------------------------------------------------------------- creation

proc placeControl*[T: Control](c: T, parent: Container,
                               left, top, width, height: float32): T {.discardable.} =
  ## Applies the common constructor arguments (see the module comment).
  # A container left at its constructor's default size has no design size
  # of its own: its first layout decides (see layout.nim, step 4).
  let defaultSize = width < 0 and height < 0 and Control(c) of Container
  c.setBounds(left, top,
              (if width >= 0: width else: c.width),
              (if height >= 0: height else: c.height))
  if defaultSize:
    let k = Container(Control(c))
    if not k.layoutInitialized: k.designSet = false
  if parent != nil: parent.insertControl c
  c

# ---------------------------------------------------------------- mnemonics

func mnemonicRune*(caption: string, at: int): Rune =
  ## The lowercased rune starting at byte `at` of `caption`.
  toLower(runeAt(caption, at))

func parseMnemonic*(caption: string): tuple[text: string, index: int, ch: Rune] =
  ## Removes the `&` markers: `text` is what is drawn, `index` the byte
  ## position of the mnemonic character in it (-1: none), `ch` that character
  ## lowercased (a `Rune`: case-insensitive for any script via unicode `toLower`;
  ## Rune(0) when there is none). `&&` is a literal `&`.
  result.index = -1
  var i = 0
  while i < caption.len:
    if caption[i] == '&':
      if i + 1 < caption.len and caption[i + 1] == '&':
        result.text.add '&'
        i += 2
      else:
        if i + 1 < caption.len and result.index < 0:
          result.index = result.text.len
          result.ch = mnemonicRune(caption, i + 1)
        inc i
    else:
      result.text.add caption[i]
      inc i

func displayText*(caption: string): string =
  ## The caption without `&` markers.
  if '&' in caption: parseMnemonic(caption).text else: caption

func mnemonicOf*(caption: string): Rune =
  ## The lowercase mnemonic character of `caption`, Rune(0) when there is none.
  if '&' in caption: parseMnemonic(caption).ch else: Rune(0)

proc altHeld*(c: Control): bool =
  ## An Alt key is down in the window of `c` (mnemonics are underlined).
  let h = c.host
  h of UiRoot and UiRoot(h).altHeld

const MnemonicUnderlineGap = 2'f32   ## baseline to the mnemonic underline

proc drawMnemonic*(c: Canvas, caption: string, f: FontSpec, rect: RectF,
                   col: Color, underline: bool, align = taLeft, valign = vaCenter,
                   wrap = false) =
  ## Draws `caption` without its `&` markers; the mnemonic character is
  ## underlined when `underline` (single line only, not when wrapped).
  if '&' notin caption:                  # nothing to strip or underline
    c.textRect(caption, f, rect, col, align, valign, wrap = wrap)
    return
  let (txt, idx, _) = parseMnemonic(caption)
  c.textRect(txt, f, rect, col, align, valign, wrap = wrap)
  if underline and not wrap and idx >= 0 and idx < txt.len:
    var n = 1
    while idx + n < txt.len and (uint8(txt[idx + n]) and 0xC0) == 0x80: inc n
    let before = c.measureText(txt[0 ..< idx], f).w
    let w = c.measureText(txt[idx ..< idx + n], f).w
    let size = c.measureText(txt, f)
    if size.w > rect.w: return           # elided: the position is not reliable
    let x0 =
      case align
      of taLeft: rect.x
      of taCenter: rect.x + (rect.w - size.w) / 2
      of taRight: rect.right - size.w
    let top =
      case valign
      of vaTop: rect.y
      of vaCenter: rect.y + (rect.h - size.h) / 2
      of vaBottom: rect.bottom - size.h
    let y = top + c.fontMetrics(f).ascent + MnemonicUnderlineGap
    c.fillRect(rectF(x0 + before, y, max(w, 1), 1), col)

# --------------------------------------------------------------- measuring

proc renderCtx*(c: Control): RenderContext =
  ## The RenderContext of the form `c` is in; nil when there is none yet.
  let h = c.host
  if h of UiRoot: UiRoot(h).ctx else: nil

proc canMeasure*(c: Control): bool =
  let ctx = c.renderCtx
  ctx != nil and not ctx.isClosed

proc measure*(c: Control, text: string, f: FontSpec,
              maxWidth: float32 = 0): SizeF =
  ## Logical size of `text`; `maxWidth` > 0 wraps there. Zero size when
  ## `canMeasure` is false.
  if not c.canMeasure: return sizeF(0, 0)
  let ctx = c.renderCtx
  let wrap = if maxWidth > 0: int(floor(maxWidth * ctx.scale)) else: 0
  let (w, h) = ctx.measureDevice(text, f, wrap)
  sizeF(w / ctx.scale, h / ctx.scale)

# ------------------------------------------------------------------ colours

proc visualState*(c: Control, hot, down: bool): VisualState =
  if not c.isEnabled: vsDisabled
  elif down: vsPressed
  elif hot: vsHover
  else: vsNormal

func faceColor*(t: Theme, s: VisualState, flat = false): Color =
  ## Fill of a neutral button-like face (flat: transparent until interacted).
  case s
  of vsNormal: (if flat: clTransparent else: t.surface)
  of vsHover: t.hover
  of vsPressed: t.pressed
  of vsDisabled: (if flat: clTransparent else: t.surfaceAlt)

func accentFaceColor*(t: Theme, s: VisualState): Color =
  ## Fill of an accent (default button, checked indicator) face.
  case s
  of vsNormal: t.accent
  of vsHover: mix(t.accent, t.accentText, 0.14)
  of vsPressed: mix(t.accent, clBlack, 0.22)
  of vsDisabled: mix(t.accent, t.surface, 0.6)

func borderColorFor*(t: Theme, s: VisualState): Color =
  if s == vsDisabled: t.border else: t.borderStrong

func textColorFor*(t: Theme, s: VisualState): Color =
  if s == vsDisabled: t.textDisabled else: t.text

# ------------------------------------------------- hover, press, activation

type
  ClickableControl* = ref object of Control
    ## Base of the push-like controls (Button, CheckBox, RadioButton,
    ## ToolButton): hover, the press that is shown while the mouse button or
    ## Space is held, and activation by key and mnemonic. A subclass paints
    ## from `visualState` and reacts to `doClick`; `activate` is the single
    ## place where a completed gesture (Space released, Alt+letter) becomes a
    ## click.
    fHot, fMouseDown, fKeyDown: bool

func isHot*(b: ClickableControl): bool = b.fHot
  ## The pointer is over the control.

func isPressed*(b: ClickableControl): bool =
  ## Shown pressed: mouse held down inside it, or Space held while focused.
  (b.fMouseDown and b.fHot) or b.fKeyDown

proc visualState*(b: ClickableControl): VisualState =
  b.visualState(b.fHot, b.isPressed)

method activate*(b: ClickableControl) {.base.} =
  ## The user completed an activation gesture without the mouse: clicks the
  ## control unless it is hidden or disabled.
  if b.isVisible and b.isEnabled: b.doClick()

method canFocus*(b: ClickableControl): bool = b.isVisible and b.isEnabled

method activateMnemonic*(b: ClickableControl, ch: Rune): bool =
  if mnemonicOf(b.caption) != ch: return false
  setFocus(b)
  b.activate()
  true

method doMouseEnter*(b: ClickableControl) =
  b.fHot = true
  b.invalidate()
  procCall doMouseEnter(Control(b))

method doMouseLeave*(b: ClickableControl) =
  b.fHot = false
  b.invalidate()
  procCall doMouseLeave(Control(b))

method doMouseDown*(b: ClickableControl, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    b.fMouseDown = true
    b.invalidate()
  procCall doMouseDown(Control(b), button, shift, x, y)

method doMouseMove*(b: ClickableControl, shift: ShiftState, x, y: float32) =
  if b.fMouseDown and ssLeft notin shift:   # the release was missed (focus lost)
    b.fMouseDown = false
    b.invalidate()
  procCall doMouseMove(Control(b), shift, x, y)

method doMouseUp*(b: ClickableControl, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft and b.fMouseDown:
    b.fMouseDown = false
    b.invalidate()
  procCall doMouseUp(Control(b), button, shift, x, y)

method captureLost*(b: ClickableControl) =
  if b.fMouseDown:
    b.fMouseDown = false
    b.invalidate()
  procCall captureLost(Control(b))

method doKeyDown*(b: ClickableControl, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(b), key, shift)
  if key == keySpace and shift * {ssCtrl, ssAlt} == {}:
    key = Key(0)
    if not b.fKeyDown:
      b.fKeyDown = true
      b.invalidate()

method doKeyUp*(b: ClickableControl, key: var Key, shift: ShiftState) =
  procCall doKeyUp(Control(b), key, shift)
  if key == keySpace and b.fKeyDown:
    key = Key(0)
    b.fKeyDown = false
    b.invalidate()
    b.activate()

method doExit*(b: ClickableControl) =
  b.fKeyDown = false
  b.invalidate()
  procCall doExit(Control(b))

# -------------------------------------------- own colour and font colour

func luminance*(c: Color): float32 =
  (0.2126'f32 * float32(c.r) + 0.7152'f32 * float32(c.g) + 0.0722'f32 * float32(c.b)) / 255

func contrastText*(base: Color): Color =
  ## Dark or white text, whichever reads on `base`.
  if luminance(base) > 0.6: rgb(20, 20, 20) else: clWhite

func shade*(base: Color, amount: float32): Color =
  ## `base` moved toward black or white (its contrast side): hover and
  ## header tones derived from a colour the program chose.
  mix(base, (if luminance(base) > 0.5: clBlack else: clWhite), amount)

func legible*(fg, bg: Color): Color =
  ## `fg`, unless it hardly differs from `bg`: then the contrast text of `bg`.
  if abs(luminance(fg) - luminance(bg)) >= 0.4'f32: fg else: contrastText(bg)

method colorOwner*(c: Control): Control {.base.} =
  ## The control whose `color` this one's fill follows: itself, except for the
  ## inner edit of a combo box or spin edit.
  c

proc ownColor*(c: Control): bool =
  ## True when the program set `color` on `c` (it does not follow the parent).
  let o = c.colorOwner
  not o.parentColor and o.color.a > 0

proc hasFontColor*(c: Control): bool = c.font.color.a > 0

proc fieldFill*(c: Control, t: Theme, enabled: bool): Color =
  ## Background of an input-like control: its own `color`, else the theme's
  ## `surface`; a disabled one fades toward the disabled surface.
  if c.ownColor:
    let col = c.colorOwner.color
    if enabled: col else: mix(col, t.surfaceAlt, 0.6)
  elif enabled: t.surface
  else: t.surfaceAlt

proc ink*(c: Control, t: Theme, backdrop: Color, enabled = true,
          themeText = clTransparent): Color =
  ## Text colour of `c` over `backdrop`: the disabled colour, else `font.color`
  ## when set, else `themeText` (default `t.text`) made legible on `backdrop`.
  if not enabled: t.textDisabled
  elif c.font.color.a > 0: c.font.color
  else: legible(if themeText.a == 0: t.text else: themeText, backdrop)

proc rowHover*(c: Control, t: Theme, base: Color): Color =
  ## Hover tone of a list row: the theme's, or a shade of an own colour.
  if c.ownColor: shade(base, 0.10'f32) else: t.hover

proc headerFill*(c: Control, t: Theme, base: Color): Color =
  ## Header/fixed-area tone: `surfaceAlt`, or a shade of an own colour.
  if c.ownColor: shade(base, 0.06'f32) else: t.surfaceAlt

proc effectiveFont*(c: Control, bold = false): FontSpec =
  if bold: c.font.bold else: c.font

# --------------------------------------------------------------- focus ring

proc drawFocusRing*(canvas: Canvas, rect: RectF, t: Theme, radius = -1'f32,
                    onFilled = false) =
  ## Rounded focus ring of `focusRingWidth` drawn inside `rect` (radius
  ## defaults to `t.radius`). `onFilled` adds a thin inner line in
  ## `accentText` so the ring stays visible on accent-coloured faces.
  let r = if radius < 0: t.radius else: radius
  canvas.strokeRoundRect(rect, r, t.focusRing, t.focusRingWidth)
  if onFilled:
    canvas.strokeRoundRect(rect.inflate(-t.focusRingWidth), max(r - t.focusRingWidth, 0),
                           t.accentText.withAlpha(200), 1)

# ------------------------------------------- check box / radio button layout

const IndicatorSize* = 16'f32   ## side of the box/circle of CheckBox, RadioButton

func indicatorRect*(c: Control): RectF =
  ## The box/circle: at the left, vertically centred.
  rectF(0, floor((c.height - IndicatorSize) / 2), IndicatorSize, IndicatorSize)

func indicatorCaptionRect*(c: Control, t: Theme): RectF =
  let x = IndicatorSize + t.spacing
  rectF(x, 0, max(c.width - x, 0), c.height)

proc indicatorPreferredSize*(c: Control): SizeF =
  ## Box + gap + caption; the current size when text cannot be measured.
  if not c.canMeasure: return sizeF(c.width, c.height)
  let t = c.theme
  let s = c.measure(displayText(c.caption), c.font)
  let gap = if c.caption.len > 0: t.spacing else: 0'f32
  sizeF(IndicatorSize + gap + (if c.caption.len > 0: ceil(s.w) + 1 else: 0'f32),
        max(IndicatorSize + 4, ceil(s.h)))

# ------------------------------------------------- shared by the phase 5 set

type
  Orientation* = enum orHorizontal, orVertical
  ArrowDir* = enum adUp, adDown, adLeft, adRight

proc drawArrow*(c: Canvas, center: PointF, size: float32, dir: ArrowDir,
                color: Color) =
  ## Small filled triangle of half-width `size` centred on `center`.
  let h = size * 0.6
  case dir
  of adUp:
    c.fillPolygon([pointF(center.x - size, center.y + h / 2),
                   pointF(center.x + size, center.y + h / 2),
                   pointF(center.x, center.y - h / 2)], color)
  of adDown:
    c.fillPolygon([pointF(center.x - size, center.y - h / 2),
                   pointF(center.x + size, center.y - h / 2),
                   pointF(center.x, center.y + h / 2)], color)
  of adLeft:
    c.fillPolygon([pointF(center.x + h / 2, center.y - size),
                   pointF(center.x + h / 2, center.y + size),
                   pointF(center.x - h / 2, center.y)], color)
  of adRight:
    c.fillPolygon([pointF(center.x - h / 2, center.y - size),
                   pointF(center.x - h / 2, center.y + size),
                   pointF(center.x + h / 2, center.y)], color)

proc textWidth*(c: Control, text: string, f: FontSpec): float32 =
  ## Measured logical width of `text`; a rough estimate without a window.
  if text.len == 0: return 0
  if c.canMeasure: ceil(c.measure(text, f).w)
  else: ceil(float32(text.len) * f.size * 0.55'f32)

proc textHeight*(c: Control, f: FontSpec): float32 =
  if c.canMeasure: ceil(c.measure("Ag", f).h) else: ceil(f.size * 1.25'f32)

# ------------------------------------------------------------- frame helpers

proc fillFrame*(c: Canvas, r: RectF, t: Theme, style: BorderStyle, col: Color) =
  ## Fills a bordered control's background: rounded like its border, or square
  ## and edge to edge with `bsNone`.
  if style == bsNone: c.fillRect(r, col) else: c.fillRoundRect(r, t.radius, col)

proc strokeFrame*(c: Canvas, r: RectF, t: Theme, style: BorderStyle, col: Color,
                  width: float32) =
  ## The border of a control; nothing with `bsNone`.
  if style != bsNone: c.strokeRoundRect(r, t.radius, col, width)
