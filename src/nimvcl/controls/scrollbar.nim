## `ScrollBar` (VCL TScrollBar): a thin, modern scrollbar.
##
## Range model (floats, so it can scroll by pixels): `position` lives in
## `min .. max - pageSize`; `pageSize` is the visible part of the range and sets
## the thumb length (`pageSize` 0 gives a minimum-size thumb). `smallChange` is
## a line (arrow click, wheel notch = 3 lines), `largeChange` a page (click on
## the track; 0 means `pageSize`).
##
## Look: no arrows by default (`showArrows` adds them); a transparent track and
## a thin rounded thumb that grows (and gets a track) while the mouse is over
## the bar or the thumb is dragged. Colours come from the theme
## (`scrollTrack`, `scrollThumb`, `scrollThumbHover`). The bar is not focusable.
##
## Mouse: drag the thumb (the press captures the pointer), click the track to
## page toward the click, wheel scrolls (3 lines per notch; a horizontal bar
## also takes `dx` / Shift+wheel). The wheel is only `handled` when the
## position moved, so at its limits it keeps bubbling. There is no auto-repeat
## while the button is held.
##
## Events: `onChange` fires whenever `position` changes (code or user);
## `onScroll(sender, code, pos)` fires first for user actions and may change the
## new position (it is clamped afterwards).

import ./common

type
  ScrollBarKind* = enum sbHorizontal, sbVertical

  ScrollCode* = enum
    scLineUp, scLineDown, scPageUp, scPageDown, scThumbTrack, scWheel

  ScrollEvent* = proc(sender: Control, code: ScrollCode, pos: var float32)

  ScrollBar* = ref object of Control
    fKind: ScrollBarKind
    fMin, fMax, fPage, fPos: float32
    fSmall, fLarge: float32
    fArrows: bool
    fHot, fThumbHot, fDragging: bool
    fGrab: float32
    onChange*: NotifyEvent
    onScroll*: ScrollEvent

const
  DefaultScrollBarSize* = 12'f32   ## thickness of scrollbars made by default
  MinThumbLength = 24'f32

func kind*(s: ScrollBar): ScrollBarKind = s.fKind
func min*(s: ScrollBar): float32 = s.fMin
func max*(s: ScrollBar): float32 = s.fMax
func pageSize*(s: ScrollBar): float32 = s.fPage
func position*(s: ScrollBar): float32 = s.fPos
func smallChange*(s: ScrollBar): float32 = s.fSmall
func largeChange*(s: ScrollBar): float32 = s.fLarge
func showArrows*(s: ScrollBar): bool = s.fArrows

func maxPosition*(s: ScrollBar): float32 =
  ## Highest reachable position: `max - pageSize` (never below `min`).
  system.max(s.fMin, s.fMax - s.fPage)

func canScroll*(s: ScrollBar): bool = s.maxPosition > s.fMin

func effectiveLarge(s: ScrollBar): float32 =
  if s.fLarge > 0: s.fLarge
  elif s.fPage > 0: s.fPage
  else: s.fSmall * 10

proc clampPos(s: ScrollBar, v: float32): float32 =
  system.min(system.max(v, s.fMin), s.maxPosition)

proc `position=`*(s: ScrollBar, v: float32) =
  let n = s.clampPos(v)
  if n == s.fPos: return
  s.fPos = n
  s.invalidate()
  let h = s.onChange        # copy: the handler may clear or replace itself
  if h != nil: h(s)

proc setRange*(s: ScrollBar, min, max: float32, pageSize = 0'f32) =
  ## Sets min, max and pageSize at once (clamping `position`, one `onChange`).
  s.fMin = min
  s.fMax = system.max(max, min)
  s.fPage = system.max(pageSize, 0)
  let n = s.clampPos(s.fPos)
  s.invalidate()
  if n != s.fPos:
    s.fPos = n
    let h = s.onChange
    if h != nil: h(s)

proc `min=`*(s: ScrollBar, v: float32) = s.setRange(v, s.fMax, s.fPage)
proc `max=`*(s: ScrollBar, v: float32) = s.setRange(s.fMin, v, s.fPage)
proc `pageSize=`*(s: ScrollBar, v: float32) = s.setRange(s.fMin, s.fMax, v)
proc `smallChange=`*(s: ScrollBar, v: float32) = s.fSmall = system.max(v, 0)
proc `largeChange=`*(s: ScrollBar, v: float32) = s.fLarge = system.max(v, 0)
proc `showArrows=`*(s: ScrollBar, v: bool) =
  if v == s.fArrows: return
  s.fArrows = v
  s.invalidate()

proc scrollBy*(s: ScrollBar, code: ScrollCode, delta: float32) =
  ## A user-style move: `onScroll` may adjust the target, then `position` is set.
  var p = s.fPos + delta
  let h = s.onScroll
  if h != nil: h(s, code, p)
  s.position = p

# ---------------------------------------------------------------- geometry

func thickness(s: ScrollBar): float32 =
  if s.fKind == sbVertical: s.width else: s.height

func length(s: ScrollBar): float32 =
  if s.fKind == sbVertical: s.height else: s.width

func arrowLen(s: ScrollBar): float32 =
  if s.fArrows: system.min(s.thickness, s.length / 2) else: 0

func trackStart(s: ScrollBar): float32 = s.arrowLen
func trackLen(s: ScrollBar): float32 = system.max(s.length - 2 * s.arrowLen, 0)

func thumbLen(s: ScrollBar): float32 =
  let tl = s.trackLen
  let span = s.fMax - s.fMin
  var l = if s.fPage > 0 and span > 0: tl * s.fPage / span else: MinThumbLength
  l = system.max(l, MinThumbLength)
  system.min(l, tl)

func thumbStart(s: ScrollBar): float32 =
  ## Offset of the thumb along the bar.
  let free = s.trackLen - s.thumbLen
  let range = s.maxPosition - s.fMin
  if free <= 0 or range <= 0: return s.trackStart
  s.trackStart + (s.fPos - s.fMin) / range * free

func alongRect(s: ScrollBar, start, len: float32): RectF =
  if s.fKind == sbVertical: rectF(0, start, s.width, len)
  else: rectF(start, 0, len, s.height)

func thumbRect*(s: ScrollBar): RectF =
  ## Hit rectangle of the thumb (full thickness); empty when nothing scrolls.
  if not s.canScroll: return rectF(0, 0, 0, 0)
  s.alongRect(s.thumbStart, s.thumbLen)

func along(s: ScrollBar, x, y: float32): float32 =
  if s.fKind == sbVertical: y else: x

proc dragTo(s: ScrollBar, mouse: float32) =
  let free = s.trackLen - s.thumbLen
  if free <= 0: return
  let ts = mouse - s.fGrab
  let frac = (ts - s.trackStart) / free
  var p = s.fMin + frac * (s.maxPosition - s.fMin)
  let h = s.onScroll
  if h != nil: h(s, scThumbTrack, p)
  s.position = p

# ------------------------------------------------------------------- events

method hitTest*(s: ScrollBar, p: PointF): bool = true

method doMouseEnter*(s: ScrollBar) =
  s.fHot = true
  s.invalidate()
  procCall doMouseEnter(Control(s))

method doMouseLeave*(s: ScrollBar) =
  s.fHot = false
  s.fThumbHot = false
  s.invalidate()
  procCall doMouseLeave(Control(s))

method doMouseDown*(s: ScrollBar, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft and s.isEnabled and s.canScroll:
    let a = s.along(x, y)
    if a < s.trackStart:
      s.scrollBy(scLineUp, -s.fSmall)
    elif a >= s.trackStart + s.trackLen:
      s.scrollBy(scLineDown, s.fSmall)
    else:
      let ts = s.thumbStart
      if a >= ts and a < ts + s.thumbLen:
        s.fDragging = true
        s.fGrab = a - ts
        s.invalidate()
      elif a < ts:
        s.scrollBy(scPageUp, -s.effectiveLarge)
      else:
        s.scrollBy(scPageDown, s.effectiveLarge)
  procCall doMouseDown(Control(s), button, shift, x, y)

method doMouseMove*(s: ScrollBar, shift: ShiftState, x, y: float32) =
  if s.fDragging:
    if ssLeft in shift: s.dragTo(s.along(x, y))
    else:
      s.fDragging = false
      s.invalidate()
  else:
    let hot = s.thumbRect.contains(pointF(x, y))
    if hot != s.fThumbHot:
      s.fThumbHot = hot
      s.invalidate()
  procCall doMouseMove(Control(s), shift, x, y)

method doMouseUp*(s: ScrollBar, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft and s.fDragging:
    s.fDragging = false
    s.invalidate()
  procCall doMouseUp(Control(s), button, shift, x, y)

method doMouseWheel*(s: ScrollBar, shift: ShiftState, dx, dy: float32,
                     handled: var bool) =
  procCall doMouseWheel(Control(s), shift, dx, dy, handled)
  if handled or not s.isEnabled: return
  let d =
    if s.fKind == sbVertical: dy
    elif dx != 0: dx
    else: dy
  if d == 0: return
  let before = s.fPos
  s.scrollBy(scWheel, -d * 3 * s.fSmall)
  if s.fPos != before: handled = true

method doExit*(s: ScrollBar) =
  s.fDragging = false
  procCall doExit(Control(s))

method captureLost*(s: ScrollBar) =
  if s.fDragging:
    s.fDragging = false
    s.invalidate()
  procCall captureLost(Control(s))

# -------------------------------------------------------------------- paint

proc drawArrow(c: Canvas, r: RectF, dir: int, vertical: bool, col: Color) =
  ## dir -1 = up/left, +1 = down/right.
  let cx = r.x + r.w / 2
  let cy = r.y + r.h / 2
  let a = 3'f32
  let d = float32(dir)
  if vertical:
    c.fillPolygon([pointF(cx - a, cy + d * a / 2), pointF(cx + a, cy + d * a / 2),
                   pointF(cx, cy - d * a / 2)], col)
  else:
    c.fillPolygon([pointF(cx + d * a / 2, cy - a), pointF(cx + d * a / 2, cy + a),
                   pointF(cx - d * a / 2, cy)], col)

method paint*(s: ScrollBar, c: Canvas) =
  let t = s.theme
  let vertical = s.fKind == sbVertical
  let active = (s.fHot or s.fDragging) and s.isEnabled
  if active:
    c.fillRect(s.clientRect, t.scrollTrack)
  if s.fArrows:
    let al = s.arrowLen
    let col = if s.canScroll: t.scrollThumbHover else: t.textDisabled
    drawArrow(c, s.alongRect(0, al), -1, vertical, col)
    drawArrow(c, s.alongRect(s.length - al, al), 1, vertical, col)
  if s.canScroll and s.isEnabled:
    let tr = s.alongRect(s.thumbStart, s.thumbLen)
    let full = s.thickness
    let tw = if active: system.max(full - 4, 4'f32) else: system.max(floor(full / 3), 3'f32)
    var r = tr
    if vertical:
      r.x = floor((full - tw) / 2)
      r.w = tw
    else:
      r.y = floor((full - tw) / 2)
      r.h = tw
    let col = if s.fDragging or s.fThumbHot: t.scrollThumbHover else: t.scrollThumb
    c.fillRoundRect(r, tw / 2, col)
  procCall paint(Control(s), c)

proc initScrollBar*(s: ScrollBar, owner: Component = nil,
                    kind = sbVertical) =
  s.initControl(owner)
  s.fKind = kind
  s.fMax = 100
  s.fSmall = 1
  if kind == sbVertical: s.setBounds(0, 0, DefaultScrollBarSize, 100)
  else: s.setBounds(0, 0, 100, DefaultScrollBarSize)

proc newScrollBar*(parent: Container = nil, kind = sbVertical,
                   left = 0'f32, top = 0'f32,
                   width = -1'f32, height = -1'f32): ScrollBar =
  ## Convention note: the main property is `kind` (default 12 px thick, 100 long).
  new result
  result.initScrollBar(parent, kind)
  result.placeControl(parent, left, top, width, height)
