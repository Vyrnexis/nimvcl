## Shared helpers for the stock controls (phase 3). Small and stable: any
## control module may import it.
##
## Constructor convention
## ----------------------
## Every stock control has
##
##   proc newXxx*(parent: Container = nil, <main property> = "", ...,
##                left = 0'f32, top = 0'f32,
##                width = -1'f32, height = -1'f32): Xxx
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

import std/math
import ../graphics/[geometry, color, font, canvas, context]
import ../core/[types, control, theme, input]
export math, geometry, color, font, canvas, types, control, theme, input

type
  VisualState* = enum
    ## What a clickable control looks like.
    vsNormal, vsHover, vsPressed, vsDisabled

# ---------------------------------------------------------------- creation

proc placeControl*[T: Control](c: T, parent: Container,
                               left, top, width, height: float32): T {.discardable.} =
  ## Applies the common constructor arguments (see the module comment).
  c.setBounds(left, top,
              (if width >= 0: width else: c.width),
              (if height >= 0: height else: c.height))
  if parent != nil: parent.insertControl c
  c

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
  case s
  of vsNormal: t.borderStrong
  of vsHover: t.borderStrong
  of vsPressed: t.borderStrong
  of vsDisabled: t.border

func textColorFor*(t: Theme, s: VisualState): Color =
  if s == vsDisabled: t.textDisabled else: t.text

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
  let s = c.measure(c.caption, c.font)
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
