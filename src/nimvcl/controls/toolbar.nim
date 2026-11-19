## `ToolBar` and `ToolButton` (VCL TToolBar / TToolButton).
##
## `ToolBar` is an `alTop` container (autosized in height) that flows its
## buttons left to right in one row. Buttons are created with
## `newToolButton(bar, ...)`; they are `alCustom` children, which the bar
## places itself (vertically centred, in child order, honouring margins). Any
## other control can be put on the bar by setting its `align` to `alCustom`.
##
## `ToolButton`
## * `kind`: `tbsButton` (push), `tbsCheck` (toggles `down`), `tbsSeparator`
##   (blank gap) or `tbsDivider` (a thin vertical line).
## * Content: `caption` (shown unless `showCaption` is false), plus an icon
##   either as `glyph` (a callback that draws into a rectangle, in the given
##   colour), an `image`, or an `imageIndex` into the bar's `images`
##   (`ToolBar.images`, an ImageList; drawn faded when disabled). Glyph wins
##   over image, image over imageIndex.
## * `groupIndex` > 0 puts check buttons into a radio group (siblings with the
##   same index): pressing one releases the others; `allowAllUp` lets the
##   pressed one be released again.
## * `hint` is a plain string property (tooltips are shown by the hint
##   system, not here). Buttons never take keyboard focus (as in the VCL).
## * `onClick` fires after the state change.
## `flat` (ToolBar) draws buttons without a face until hovered (default).

import ../graphics/image
import ./common, ./imagelist

export image, imagelist

type
  ToolButtonKind* = enum tbsButton, tbsCheck, tbsSeparator, tbsDivider
  GlyphProc* = proc(c: Canvas, r: RectF, color: Color)

  ToolButton* = ref object of ClickableControl
    fKind: ToolButtonKind
    fDown, fAllowAllUp, fShowCaption: bool
    fGroup: int
    fGlyph: GlyphProc
    fImage: Image
    fImageIndex: int

  ToolBar* = ref object of Container
    fFlat: bool
    fImages: ImageListRef

const
  GlyphSize = 16'f32
  BtnPad = 7'f32
  SepWidth = 8'f32

# -------------------------------------------------------------- ToolButton

func kind*(b: ToolButton): ToolButtonKind = b.fKind
proc `kind=`*(b: ToolButton, v: ToolButtonKind) =
  if v == b.fKind: return
  b.fKind = v
  b.invalidate()
  b.requestLayout()

func down*(b: ToolButton): bool = b.fDown
proc `down=`*(b: ToolButton, v: bool) =
  ## Sets the pressed state of a check button; pressing a grouped one releases
  ## its group mates.
  if b.fKind != tbsCheck or v == b.fDown: return
  b.fDown = v
  if v and b.fGroup > 0 and b.parent != nil:
    for c in b.parent.children:
      if c != Control(b) and c of ToolButton:
        let o = ToolButton(c)
        if o.fKind == tbsCheck and o.fGroup == b.fGroup and o.fDown:
          o.fDown = false
          o.invalidate()
  b.invalidate()

func groupIndex*(b: ToolButton): int = b.fGroup
proc `groupIndex=`*(b: ToolButton, v: int) = b.fGroup = v
func allowAllUp*(b: ToolButton): bool = b.fAllowAllUp
proc `allowAllUp=`*(b: ToolButton, v: bool) = b.fAllowAllUp = v

func showCaption*(b: ToolButton): bool = b.fShowCaption
proc `showCaption=`*(b: ToolButton, v: bool) =
  b.fShowCaption = v
  b.invalidate()
  b.requestLayout()

func glyph*(b: ToolButton): GlyphProc = b.fGlyph
proc `glyph=`*(b: ToolButton, v: GlyphProc) =
  b.fGlyph = v
  b.invalidate()
  b.requestLayout()

func image*(b: ToolButton): Image = b.fImage
proc `image=`*(b: ToolButton, v: Image) =
  b.fImage = v
  b.invalidate()
  b.requestLayout()

func imageIndex*(b: ToolButton): int = b.fImageIndex
  ## Index into the parent ToolBar's `images` (-1: none).
proc `imageIndex=`*(b: ToolButton, v: int) =
  if v == b.fImageIndex: return
  b.fImageIndex = v
  b.invalidate()
  b.requestLayout()

func barImages(b: ToolButton): ImageList =
  if b.parent != nil and b.parent of ToolBar: ToolBar(b.parent).fImages.list else: nil

func listIcon(b: ToolButton): bool =
  let il = b.barImages
  b.fGlyph == nil and b.fImage == nil and il != nil and il.image(b.fImageIndex) != nil

func hasIcon(b: ToolButton): bool = b.fGlyph != nil or b.fImage != nil or b.listIcon

func iconSize(b: ToolButton): SizeF =
  if b.listIcon: sizeF(b.barImages.width, b.barImages.height)
  else: sizeF(GlyphSize, GlyphSize)

method preferredSize*(b: ToolButton): SizeF =
  let h = b.theme.controlHeight
  case b.fKind
  of tbsSeparator, tbsDivider: sizeF(SepWidth, h)
  else:
    var w = 2 * BtnPad
    let showText = b.fShowCaption and b.caption.len > 0
    if b.hasIcon: w += b.iconSize.w
    if showText:
      if b.hasIcon: w += 5
      w += b.textWidth(b.caption, b.font)
    sizeF(max(w, h), h)

method canFocus*(b: ToolButton): bool = false    # never takes the keyboard focus

method hitTest*(b: ToolButton, p: PointF): bool =
  b.fKind in {tbsButton, tbsCheck}

method doClick*(b: ToolButton) =
  if b.fKind == tbsCheck:
    if b.fGroup > 0:
      if not b.fDown: b.down = true
      elif b.fAllowAllUp: b.down = false
    else:
      b.down = not b.fDown
  procCall doClick(Control(b))

method paint*(b: ToolButton, c: Canvas) =
  let t = b.theme
  let r = b.clientRect
  if b.fKind == tbsSeparator: return
  if b.fKind == tbsDivider:
    c.line(r.w / 2, 5, r.w / 2, r.h - 5, t.border, 1)
    return
  let en = b.isEnabled
  let st = b.visualState
  let flat = b.parent == nil or not (b.parent of ToolBar) or ToolBar(b.parent).fFlat
  let face = r.inflate(-1)
  let own = b.parent != nil and Control(b.parent).ownColor
  let bar = if own: b.parent.color else: t.surface     # what the button sits on
  if b.fDown and en:
    c.fillRoundRect(face, t.radius, mix(t.surface, t.accent, 0.18))
    c.strokeRoundRect(face, t.radius, mix(t.border, t.accent, 0.6), 1)
    if st == vsHover: c.fillRoundRect(face, t.radius, t.hover.withAlpha(90))
    if st == vsPressed: c.fillRoundRect(face, t.radius, t.pressed.withAlpha(120))
  else:
    let fill =
      if own:
        case st
        of vsNormal: (if flat: clTransparent else: shade(bar, 0.05'f32))
        of vsHover: shade(bar, 0.10'f32)
        of vsPressed: shade(bar, 0.18'f32)
        of vsDisabled: (if flat: clTransparent else: shade(bar, 0.03'f32))
      else: faceColor(t, st, flat)
    if fill.a > 0: c.fillRoundRect(face, t.radius, fill)
    if not flat or st in {vsHover, vsPressed}:
      c.strokeRoundRect(face, t.radius, t.border, 1)
  let col = b.ink(t, bar, en)
  let showText = b.fShowCaption and b.caption.len > 0
  let tw = if showText: b.textWidth(b.caption, b.font) else: 0'f32
  let isz = b.iconSize
  let iconW = if b.hasIcon: isz.w else: 0'f32
  let gap = if b.hasIcon and showText: 5'f32 else: 0'f32
  var x = floor((r.w - (iconW + gap + tw)) / 2)
  if b.hasIcon:
    let ir = rectF(x, floor((r.h - isz.h) / 2), isz.w, isz.h)
    if b.fGlyph != nil: b.fGlyph(c, ir, col)
    elif b.fImage != nil: c.drawImage(b.fImage, ir)
    elif b.listIcon: b.barImages.draw(c, b.fImageIndex, ir.x, ir.y, en)
    x += iconW + gap
  if showText:
    c.textRect(b.caption, b.font, rectF(x, 0, tw + 1, r.h), col, taLeft, vaCenter)
  procCall paint(Control(b), c)

proc initToolButton*(b: ToolButton, owner: Component = nil) =
  b.initControl(owner)
  b.fShowCaption = true
  b.fImageIndex = -1
  b.setBounds(0, 0, currentTheme().controlHeight, currentTheme().controlHeight)
  b.align = alCustom
  b.autoSize = true

proc newToolButton*(parent: Container = nil, caption = "",
                    kind = tbsButton, glyph: GlyphProc = nil,
                    left = 0'f32, top = 0'f32,
                    width = -1'f32, height = -1'f32): ToolButton {.discardable.} =
  ## `parent` is usually a ToolBar (which positions its buttons; `left`/`top`
  ## matter only in other containers).
  new result
  result.initToolButton(parent)
  result.fKind = kind
  result.fGlyph = glyph
  result.caption = caption
  result.placeControl(parent, left, top, width, height)

# ----------------------------------------------------------------- ToolBar

func images*(t: ToolBar): ImageList = t.fImages.list
proc `images=`*(t: ToolBar, v: ImageList) =
  let bar = t
  t.fImages.attach(v, proc() =       # icons changed: repaint/relayout
    bar.invalidate()
    bar.requestLayout()
    for c in bar.children: c.requestLayout())
  t.invalidate()
  t.requestLayout()
  for c in t.children: c.requestLayout()

method releaseResources*(t: ToolBar) =
  t.fImages.detach()

func flat*(t: ToolBar): bool = t.fFlat
proc `flat=`*(t: ToolBar, v: bool) =
  t.fFlat = v
  t.invalidate()

method preferredSize*(t: ToolBar): SizeF =
  var h = t.theme.controlHeight
  for c in t.children:
    if c.visible and c.align == alCustom:
      h = max(h, c.height + c.margins.vertical)
  let p = t.padding
  sizeF(t.width, h + p.vertical)

method customAlign*(t: ToolBar, child: Control, available: RectF) =
  var x = available.x
  for c in t.children:
    if c == child: break
    if c.visible and c.align == alCustom:
      x += c.margins.left + c.width + c.margins.right
  let m = child.margins
  child.setBounds(round(x + m.left),
                  round(available.y + (available.h - child.height) / 2),
                  child.width, child.height)

method paint*(t: ToolBar, c: Canvas) =
  let th = t.theme
  let r = t.clientRect
  c.fillRect(r, if t.ownColor: t.color else: th.surface)
  c.line(0, r.h - 0.5, r.w, r.h - 0.5, th.border, 1)
  procCall paint(Control(t), c)

proc initToolBar*(t: ToolBar, owner: Component = nil) =
  t.initContainer(owner)
  t.fFlat = true
  t.setBounds(0, 0, 200, currentTheme().controlHeight + 6)
  t.padding = spacing(4, 3, 4, 3)
  t.align = alTop
  t.autoSize = true

proc newToolBar*(parent: Container = nil, left = 0'f32, top = 0'f32,
                 width = -1'f32, height = -1'f32): ToolBar {.discardable.} =
  ## The bar is `alTop` and auto-sizing: `left`/`top`/`width`/`height` matter
  ## only after changing `align` / `autoSize`.
  new result
  result.initToolBar(parent)
  result.placeControl(parent, left, top, width, height)
