## `Panel` and `GroupBox` (VCL TPanel / TGroupBox): containers that draw a
## surface and/or a border.
##
## Panel: fills with its effective `color`: the one assigned, else
## `theme.surface` (resolved at paint time, so theme switches work). Children
## with `parentColor` inherit that colour. `borderStyle` pbNone (flat), pbSingle (rounded card, `border`),
## pbRaised (rounded card, `borderStrong`). A non-empty `caption` is drawn
## inside, aligned by `alignment` (centred by default) behind the children.
## `&` markers are stripped but a Panel caption has no mnemonic (not underlined,
## Alt+letter does nothing; GroupBox is the one that focuses its first child).
## `padding` defaults to 0 and only affects aligned children.
##
## GroupBox: a transparent container with a rounded border whose top line has
## the caption cut into it. Its `padding` is computed (never stale) so that
## aligned children sit below the caption; setting `padding` has no effect.
## `alNone` children are positioned from the client origin, so use
## `clientArea` as their reference rectangle. It passes the parent's colour on
## to its children. An own `color` fills the whole box behind them.

import ./common

type
  PanelBorder* = enum pbNone, pbSingle, pbRaised

  Panel* = ref object of Container
    fBorder: PanelBorder
    fAlignment: HAlign
    fText: TextStyle

  GroupBox* = ref object of Container

# ------------------------------------------------------------------ Panel

func borderStyle*(p: Panel): PanelBorder = p.fBorder
proc `borderStyle=`*(p: Panel, v: PanelBorder) =
  if v == p.fBorder: return
  p.fBorder = v
  p.invalidate()

func alignment*(p: Panel): HAlign = p.fAlignment
proc `alignment=`*(p: Panel, v: HAlign) =
  if v == p.fAlignment: return
  p.fAlignment = v
  p.invalidate()

proc textColor*(p: Panel): Color {.deprecated: "use font.color".} =
  ## Deprecated alias of `font.color` (alpha 0: none set).
  p.font.color
proc hasTextColor*(p: Panel): bool = p.hasFontColor
proc `textColor=`*(p: Panel, v: Color) {.deprecated: "use font.color".} =
  ## Deprecated alias: sets `font.color` (fixed, does not follow theme
  ## switches) and drops `textRole`. Like any own font, it ends `parentFont`.
  p.fText.reset()
  p.fontColor = v
func textRole*(p: Panel): ThemeColor = p.fText.role
proc `textRole=`*(p: Panel, v: ThemeColor) =
  ## Caption colour by theme role, resolved at paint time. An own `font.color`
  ## wins over it.
  p.fText.setRole v
  if not p.parentFont and p.hasFontColor: p.fontColor = clTransparent   # the role replaces a fixed colour
  p.invalidate()
proc resetTextColor*(p: Panel) =
  ## Back to the theme's `text` colour (clears `font.color` and `textRole`).
  p.fText.reset()
  if not p.parentFont and p.hasFontColor:
    p.fontColor = clTransparent
  p.invalidate()

method inheritedColor*(p: Panel): Color = p.theme.surface

method paint*(p: Panel, c: Canvas) =
  let t = p.theme
  let fill = p.color
  let r = p.clientRect
  case p.fBorder
  of pbNone: c.fillRect(r, fill)
  of pbSingle, pbRaised:
    c.fillRoundRect(r, t.radius, fill)
    c.strokeRoundRect(r, t.radius,
                      if p.fBorder == pbRaised: t.borderStrong else: t.border,
                      t.borderWidth)
  if p.caption.len > 0:
    let col = p.ink(t, fill, p.isEnabled, p.fText.resolve(t))
    c.drawMnemonic(p.caption, p.font, r.inflate(-t.spacing), col, false,
                   p.fAlignment, vaCenter)   # no mnemonic: a Panel never activates it
  procCall paint(Control(p), c)

proc initPanel*(p: Panel, owner: Component = nil) =
  p.initContainer(owner)
  p.fAlignment = taCenter
  p.setBounds(0, 0, 200, 100)

proc newPanel*(parent: Container = nil, caption = "", left = 0'f32, top = 0'f32,
               width = -1'f32, height = -1'f32): Panel {.discardable.} =
  new result
  result.initPanel(parent)
  result.caption = caption
  result.placeControl(parent, left, top, width, height)

# --------------------------------------------------------------- GroupBox

proc captionHeight*(g: GroupBox): float32 =
  ## Height of the caption band at the top (derived from the font size, so it
  ## is the same with or without a window).
  round(g.font.size * 1.4)

proc clientArea*(g: GroupBox): RectF =
  ## The area inside the border and below the caption.
  let t = g.theme
  let ch = g.captionHeight
  let top = if g.caption.len > 0: ch + 4 else: floor(ch / 2) + t.spacing
  rectF(t.spacing, top, max(g.width - 2 * t.spacing, 0),
        max(g.height - top - t.spacing, 0))

method padding*(g: GroupBox): Spacing =
  let a = g.clientArea
  spacing(a.x, a.y, g.width - a.right, g.height - a.bottom)

method paint*(g: GroupBox, c: Canvas) =
  let t = g.theme
  let ch = g.captionHeight
  let top = floor(ch / 2)
  let frame = rectF(0, top, g.width, g.height - top)
  if g.ownColor: c.fillRect(g.clientRect, g.color)   # the area behind
  let col = g.ink(t, g.color, g.isEnabled)
  if g.caption.len == 0:
    c.strokeRoundRect(frame, t.radius, t.border, t.borderWidth)
  else:
    let tx = t.spacing + 4
    let tw = min(c.measureText(displayText(g.caption), g.font).w, max(g.width - 2 * tx, 0))
    let gapL = tx - 4
    let gapR = tx + tw + 4
    # three disjoint clips leave a gap in the top border for the caption
    c.pushClip(rectF(0, 0, gapL, ch)); c.strokeRoundRect(frame, t.radius, t.border, t.borderWidth); c.popClip()
    c.pushClip(rectF(gapR, 0, g.width - gapR, ch)); c.strokeRoundRect(frame, t.radius, t.border, t.borderWidth); c.popClip()
    c.pushClip(rectF(0, ch, g.width, g.height - ch)); c.strokeRoundRect(frame, t.radius, t.border, t.borderWidth); c.popClip()
    c.drawMnemonic(g.caption, g.font, rectF(tx, 0, tw, ch), col, g.altHeld, taLeft,
                   vaCenter)
  procCall paint(Control(g), c)

method activateMnemonic*(g: GroupBox, ch: Rune): bool =
  ## Alt+letter focuses the first focusable control inside the box.
  if mnemonicOf(g.caption) != ch: return false
  let stops = tabStops(g)
  if stops.len == 0: return false
  setFocus(stops[0])
  true

proc initGroupBox*(g: GroupBox, owner: Component = nil) =
  g.initContainer(owner)
  g.setBounds(0, 0, 200, 100)

proc newGroupBox*(parent: Container = nil, caption = "", left = 0'f32,
                  top = 0'f32, width = -1'f32, height = -1'f32): GroupBox {.discardable.} =
  new result
  result.initGroupBox(parent)
  result.caption = caption
  result.placeControl(parent, left, top, width, height)
