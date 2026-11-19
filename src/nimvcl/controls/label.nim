## `Label`: static text (VCL TLabel). Not focusable; clicking it can forward
## focus to `focusControl`.
##
## `autoSize` defaults to true: the label sizes itself to its text during
## layout (needs a form with a window to measure; otherwise it keeps its size).
## `newLabel` turns it off when an explicit width/height is given.
## With `wordWrap` the width is kept and only the height follows the text.
## Without `wordWrap`, text wider than the label is cut with an ellipsis.
##
## Mnemonic: `&` in the caption underlines a letter while Alt is held;
## Alt+letter focuses `focusControl` (when set).

import ./common

type
  Label* = ref object of Control
    fAlignment: HAlign
    fLayout: VAlign
    fWordWrap, fTransparent: bool
    fText: TextStyle
    fFocusControl: Control

func alignment*(l: Label): HAlign = l.fAlignment
proc `alignment=`*(l: Label, v: HAlign) =
  if v == l.fAlignment: return
  l.fAlignment = v
  l.invalidate()

func layout*(l: Label): VAlign = l.fLayout
proc `layout=`*(l: Label, v: VAlign) =
  ## Vertical placement of the text inside the label.
  if v == l.fLayout: return
  l.fLayout = v
  l.invalidate()

func wordWrap*(l: Label): bool = l.fWordWrap
proc `wordWrap=`*(l: Label, v: bool) =
  if v == l.fWordWrap: return
  l.fWordWrap = v
  l.invalidate()
  if l.autoSize: l.requestLayout()

func transparent*(l: Label): bool = l.fTransparent
proc `transparent=`*(l: Label, v: bool) =
  ## Transparent (default): no background. Otherwise filled with `color`.
  if v == l.fTransparent: return
  l.fTransparent = v
  l.invalidate()

func focusControl*(l: Label): Control = l.fFocusControl
proc `focusControl=`*(l: Label, v: Control) = l.fFocusControl = v

proc textColor*(l: Label): Color {.deprecated: "use font.color".} =
  ## Deprecated alias of `font.color` (alpha 0: none set).
  l.font.color
proc hasTextColor*(l: Label): bool = l.hasFontColor
proc `textColor=`*(l: Label, v: Color) {.deprecated: "use font.color".} =
  ## Deprecated alias: sets `font.color` (a fixed colour; it does not follow
  ## theme switches) and drops `textRole`. Like any own font, it ends
  ## `parentFont`.
  l.fText.reset()
  l.fontColor = v
func textRole*(l: Label): ThemeColor = l.fText.role
proc `textRole=`*(l: Label, v: ThemeColor) =
  ## Text colour by theme role (`tcMuted`, `tcAccent`, ...), resolved at paint
  ## time so it follows theme switches. It replaces an own `font.color`.
  l.fText.setRole v
  if not l.parentFont and l.hasFontColor: l.fontColor = clTransparent   # the role replaces a fixed colour
  l.invalidate()
proc resetTextColor*(l: Label) =
  ## Back to the theme's `text` colour (clears `font.color` and `textRole`).
  l.fText.reset()
  if not l.parentFont and l.hasFontColor:
    l.fontColor = clTransparent
  l.invalidate()

func muted*(l: Label): bool = l.fText.role == tcMuted
proc `muted=`*(l: Label, v: bool) =
  ## Shortcut for `textRole = tcMuted` (true) / `resetTextColor` (false).
  if v: l.textRole = tcMuted
  elif l.muted: l.resetTextColor()
method preferredSize*(l: Label): SizeF =
  if not l.canMeasure: return sizeF(l.width, l.height)
  let txt = displayText(l.caption)
  if l.fWordWrap and l.width > 0:
    sizeF(l.width, ceil(l.measure(txt, l.font, l.width).h))
  else:
    let s = l.measure(txt, l.font)
    sizeF(ceil(s.w) + 1, ceil(s.h))

method paint*(l: Label, c: Canvas) =
  let t = l.theme
  if not l.fTransparent: c.fillRect(l.clientRect, l.color)
  let col = l.ink(t, l.color, l.isEnabled, l.fText.resolve(t))
  c.drawMnemonic(l.caption, l.font, l.clientRect, col, l.altHeld, l.fAlignment,
                 l.fLayout, wrap = l.fWordWrap)
  procCall paint(Control(l), c)

method activateMnemonic*(l: Label, ch: Rune): bool =
  if l.fFocusControl == nil or mnemonicOf(l.caption) != ch: return false
  if not (l.fFocusControl.isVisible and l.fFocusControl.isEnabled): return false
  setFocus(l.fFocusControl)
  true

method doClick*(l: Label) =
  if l.fFocusControl != nil: setFocus(l.fFocusControl)
  procCall doClick(Control(l))

proc initLabel*(l: Label, owner: Component = nil) =
  l.initControl(owner)
  l.fTransparent = true
  l.setBounds(0, 0, 40, 20)
  l.autoSize = true

proc newLabel*(parent: Container = nil, caption = "", left = 0'f32, top = 0'f32,
               width = -1'f32, height = -1'f32): Label {.discardable.} =
  new result
  result.initLabel(parent)
  result.caption = caption
  if width >= 0 or height >= 0: result.autoSize = false
  result.placeControl(parent, left, top, width, height)
