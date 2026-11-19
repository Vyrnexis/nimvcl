## `TrackBar` (VCL TTrackBar): a slider with `min`, `max`, `position`,
## `frequency` (tick marks every n units), `lineSize` (arrow keys) and
## `pageSize` (PgUp/PgDn and clicks on the track), horizontal or vertical.
##
## Mouse: dragging the thumb (the pointer is captured), a click on the track
## moves the thumb by `pageSize` towards the pointer. Keys (focused): Left/Up
## -line, Right/Down +line, PageUp/PageDown +-page, Home/End. The minimum is at
## the left (horizontal) or the top (vertical, like Windows).
## `onChange` fires whenever `position` changes.

import ./common

type
  TrackBar* = ref object of Control
    fMin, fMax, fPos, fFreq, fLine, fPage: int
    fOrient: Orientation
    fDragging, fHot: bool
    fGrab: float32        # pointer offset inside the thumb along the axis
    onChange*: NotifyEvent

const
  ThumbSize = 16'f32
  MinTickGap = 4'f32      ## ticks closer than this (px) are thinned out
  GrooveThick = 4'f32

func min*(t: TrackBar): int = t.fMin
func max*(t: TrackBar): int = t.fMax
func position*(t: TrackBar): int = t.fPos
func frequency*(t: TrackBar): int = t.fFreq
func lineSize*(t: TrackBar): int = t.fLine
func pageSize*(t: TrackBar): int = t.fPage
func orientation*(t: TrackBar): Orientation = t.fOrient
func isDragging*(t: TrackBar): bool = t.fDragging

proc `position=`*(t: TrackBar, v: int) =
  let nv = system.max(t.fMin, system.min(t.fMax, v))
  if nv == t.fPos: return
  t.fPos = nv
  t.invalidate()
  let h = t.onChange        # copy: the handler may clear or replace itself
  if h != nil: h(t)

proc `min=`*(t: TrackBar, v: int) =
  t.fMin = v
  if t.fMax < v: t.fMax = v
  t.invalidate()
  t.position = t.fPos       # re-clamps; fires onChange when it moved

proc `max=`*(t: TrackBar, v: int) =
  t.fMax = v
  if t.fMin > v: t.fMin = v
  t.invalidate()
  t.position = t.fPos

proc `frequency=`*(t: TrackBar, v: int) =
  t.fFreq = system.max(v, 0)
  t.invalidate()
proc `lineSize=`*(t: TrackBar, v: int) = t.fLine = system.max(v, 1)
proc `pageSize=`*(t: TrackBar, v: int) = t.fPage = system.max(v, 1)

proc `orientation=`*(t: TrackBar, v: Orientation) =
  if v == t.fOrient: return
  t.fOrient = v
  if (v == orVertical) != (t.height > t.width):
    t.setBounds(t.left, t.top, t.height, t.width)
  t.invalidate()

# ---------------------------------------------------------------- geometry

func horiz(t: TrackBar): bool = t.fOrient == orHorizontal

func axisLen(t: TrackBar): float32 = (if t.horiz: t.width else: t.height)

func travel(t: TrackBar): float32 =
  ## Distance the thumb centre moves from min to max.
  system.max(t.axisLen - ThumbSize, 1)

func posToAxis*(t: TrackBar, pos: int): float32 =
  ## Centre of the thumb for `pos`, along the main axis.
  let span = t.fMax - t.fMin
  let f = if span <= 0: 0'f32 else: float32(pos - t.fMin) / float32(span)
  ThumbSize / 2 + f * t.travel

func axisToPos(t: TrackBar, a: float32): int =
  let span = t.fMax - t.fMin
  if span <= 0: return t.fMin
  let f = clamp((a - ThumbSize / 2) / t.travel, 0'f32, 1'f32)
  t.fMin + int(round(f * float32(span)))

func lineCoord(t: TrackBar): float32 =
  ## Cross-axis centre of the groove and thumb.
  if t.horiz: (if t.fFreq > 0: t.height * 0.4 else: t.height / 2)
  else: (if t.fFreq > 0: t.width * 0.4 else: t.width / 2)

func thumbRect*(t: TrackBar): RectF =
  ## The thumb in client coordinates.
  let a = t.posToAxis(t.fPos)
  let l = t.lineCoord
  if t.horiz: rectF(a - ThumbSize / 2, l - ThumbSize / 2, ThumbSize, ThumbSize)
  else: rectF(l - ThumbSize / 2, a - ThumbSize / 2, ThumbSize, ThumbSize)

proc axisOf(t: TrackBar, x, y: float32): float32 = (if t.horiz: x else: y)

# ---------------------------------------------------------------- behaviour

method canFocus*(t: TrackBar): bool = t.isVisible and t.isEnabled

method doMouseEnter*(t: TrackBar) =
  t.fHot = true
  t.invalidate()
  procCall doMouseEnter(Control(t))

method doMouseLeave*(t: TrackBar) =
  t.fHot = false
  t.invalidate()
  procCall doMouseLeave(Control(t))

method doMouseDown*(t: TrackBar, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    let th = t.thumbRect
    if th.contains(pointF(x, y)):
      t.fDragging = true
      t.fGrab = t.axisOf(x, y) - t.posToAxis(t.fPos)
    else:
      let a = t.axisOf(x, y)
      let cur = t.posToAxis(t.fPos)
      if a < cur: t.position = t.fPos - t.fPage
      else: t.position = t.fPos + t.fPage
    t.invalidate()
  procCall doMouseDown(Control(t), button, shift, x, y)

method doMouseMove*(t: TrackBar, shift: ShiftState, x, y: float32) =
  if t.fDragging:
    if ssLeft notin shift:
      t.fDragging = false
      t.invalidate()
    else: t.position = t.axisToPos(t.axisOf(x, y) - t.fGrab)
  procCall doMouseMove(Control(t), shift, x, y)

method doMouseUp*(t: TrackBar, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft and t.fDragging:
    t.fDragging = false
    t.invalidate()
  procCall doMouseUp(Control(t), button, shift, x, y)

method doKeyDown*(t: TrackBar, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(t), key, shift)
  if key == Key(0) or shift * {ssCtrl, ssAlt, ssSuper} != {}: return
  var handled = true
  if key == keyLeft or key == keyUp: t.position = t.fPos - t.fLine
  elif key == keyRight or key == keyDown: t.position = t.fPos + t.fLine
  elif key == keyPageUp: t.position = t.fPos - t.fPage
  elif key == keyPageDown: t.position = t.fPos + t.fPage
  elif key == keyHome: t.position = t.fMin
  elif key == keyEnd: t.position = t.fMax
  else: handled = false
  if handled: key = Key(0)

method doExit*(t: TrackBar) =
  t.fDragging = false
  t.invalidate()
  procCall doExit(Control(t))

method captureLost*(t: TrackBar) =
  if t.fDragging:
    t.fDragging = false
    t.invalidate()
  procCall captureLost(Control(t))

method preferredSize*(t: TrackBar): SizeF =
  if t.horiz: sizeF(t.width, 32) else: sizeF(32, t.height)

# ------------------------------------------------------------------- paint

method paint*(t: TrackBar, c: Canvas) =
  let th = t.theme
  let en = t.isEnabled
  let l = t.lineCoord
  let len = t.axisLen
  let g = GrooveThick
  let groove =
    if t.horiz: rectF(ThumbSize / 2, l - g / 2, system.max(len - ThumbSize, 0), g)
    else: rectF(l - g / 2, ThumbSize / 2, g, system.max(len - ThumbSize, 0))
  if t.ownColor: c.fillRect(t.clientRect, t.color)   # the area behind
  c.fillRoundRect(groove, g / 2, if t.ownColor: shade(t.color, 0.12'f32) else: th.surfaceAlt)
  c.strokeRoundRect(groove, g / 2, th.border, 1)
  # filled part up to the thumb
  let a = t.posToAxis(t.fPos)
  let part =
    if t.horiz: rectF(groove.x, groove.y, a - groove.x, g)
    else: rectF(groove.x, groove.y, g, a - groove.y)
  if part.w > 0 and part.h > 0:
    c.fillRoundRect(part, g / 2, if en: th.accent else: th.textDisabled)
  # ticks
  if t.fFreq > 0 and t.fMax > t.fMin:
    var v = t.fMin
    let tickCol = if en: th.borderStrong else: th.border
    let off = if t.horiz: t.height * 0.4 else: t.width * 0.4
    # at most one tick per MinTickGap px: a huge range with a small frequency
    # must not draw thousands of lines on every paint
    let travel = (if t.horiz: t.width else: t.height) - ThumbSize
    let ticks = (t.fMax - t.fMin) div t.fFreq + 1
    let skip = system.max(1, int(ceil(MinTickGap * ticks.float32 / system.max(travel, 1'f32))))
    let step = t.fFreq * skip
    while v <= t.fMax:
      let p = t.posToAxis(v)
      if t.horiz:
        c.line(p, off + ThumbSize / 2 + 3, p, off + ThumbSize / 2 + 8, tickCol, 1)
      else:
        c.line(off + ThumbSize / 2 + 3, p, off + ThumbSize / 2 + 8, p, tickCol, 1)
      if t.fMax - v < step: break      # no overflow near high(int)
      v += step
  # thumb
  let r = t.thumbRect
  let st = t.visualState(t.fHot, t.fDragging)
  let fill = if st == vsDisabled: th.surfaceAlt
             elif t.fDragging: th.pressed
             elif t.fHot: th.hover
             else: th.surface
  c.fillEllipse(r, fill)
  c.strokeEllipse(r, if en: th.accent else: th.border, 2)
  if t.focused: c.strokeEllipse(r.inflate(2), th.focusRing, th.focusRingWidth)
  procCall paint(Control(t), c)

proc initTrackBar*(t: TrackBar, owner: Component = nil) =
  t.initControl(owner)
  t.fMin = 0
  t.fMax = 10
  t.fFreq = 1
  t.fLine = 1
  t.fPage = 2
  t.tabStop = true
  t.setBounds(0, 0, 150, 32)

proc newTrackBar*(parent: Container = nil, left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): TrackBar {.discardable.} =
  new result
  result.initTrackBar(parent)
  result.placeControl(parent, left, top, width, height)
