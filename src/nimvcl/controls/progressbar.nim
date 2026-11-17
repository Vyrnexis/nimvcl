## `ProgressBar` (VCL TProgressBar): `min`, `max`, `position`, `step` /
## `stepIt`, horizontal or vertical, smooth rounded look.
##
## `style = pbsMarquee` shows a block sliding back and forth; it is driven by
## a Timer that only runs while the bar is showing: it is started and stopped by
## `visibilityChanged` (the bar or an ancestor hidden/shown, the bar inserted
## into or removed from a tree, the form shown/hidden), with no polling.
## `advanceMarquee` moves it one step (also what the timer calls).

import ../core/timer
import ./common

type
  ProgressStyle* = enum pbsNormal, pbsMarquee

  ProgressBar* = ref object of Control
    fMin, fMax, fPos, fStep: int
    fStyle: ProgressStyle
    fOrient: Orientation
    fPhase: float32           # marquee block position 0..1 (bouncing)
    fDir: float32
    fTimer: Timer
    onChange*: NotifyEvent

const MarqueeMs = 30

func min*(p: ProgressBar): int = p.fMin
func max*(p: ProgressBar): int = p.fMax
func position*(p: ProgressBar): int = p.fPos
func step*(p: ProgressBar): int = p.fStep
func style*(p: ProgressBar): ProgressStyle = p.fStyle
func orientation*(p: ProgressBar): Orientation = p.fOrient
func marqueePhase*(p: ProgressBar): float32 = p.fPhase

proc `position=`*(p: ProgressBar, v: int) =
  let nv = system.max(p.fMin, system.min(p.fMax, v))
  if nv == p.fPos: return
  p.fPos = nv
  p.invalidate()
  if p.onChange != nil: p.onChange(p)

proc `min=`*(p: ProgressBar, v: int) =
  p.fMin = v
  if p.fMax < v: p.fMax = v
  p.invalidate()
  p.position = p.fPos      # clamps into the new range and fires onChange

proc `max=`*(p: ProgressBar, v: int) =
  p.fMax = v
  if p.fMin > v: p.fMin = v
  p.invalidate()
  p.position = p.fPos      # clamps into the new range and fires onChange

proc `step=`*(p: ProgressBar, v: int) = p.fStep = v

proc stepIt*(p: ProgressBar) =
  ## Advances `position` by `step` (clamped).
  p.position = p.fPos + p.fStep

proc stepBy*(p: ProgressBar, delta: int) = p.position = p.fPos + delta

func fraction*(p: ProgressBar): float32 =
  ## 0..1 share of the range that is filled.
  if p.fMax <= p.fMin: 0'f32
  else: float32(p.fPos - p.fMin) / float32(p.fMax - p.fMin)

proc advanceMarquee*(p: ProgressBar, delta = 0.02'f32) =
  p.fPhase += p.fDir * delta
  if p.fPhase >= 1: p.fPhase = 1; p.fDir = -1
  elif p.fPhase <= 0: p.fPhase = 0; p.fDir = 1
  p.invalidate()

proc runsMarquee*(p: ProgressBar): bool =
  ## Whether the animation timer is currently running.
  p.fTimer != nil and p.fTimer.enabled

proc syncTimer(p: ProgressBar) =
  ## The timer runs while the style is marquee and the bar is showing.
  if p.fStyle == pbsMarquee and p.isShowing:
    if p.fTimer == nil:
      p.fTimer = newTimer(nil, MarqueeMs)
      p.fTimer.onTimer = proc(t: Timer) = p.advanceMarquee()
    p.fTimer.enabled = true
  elif p.fTimer != nil:
    p.fTimer.enabled = false

method visibilityChanged*(p: ProgressBar) =
  p.syncTimer()

proc `style=`*(p: ProgressBar, v: ProgressStyle) =
  if v == p.fStyle: return
  p.fStyle = v
  p.syncTimer()
  p.invalidate()

proc `orientation=`*(p: ProgressBar, v: Orientation) =
  if v == p.fOrient: return
  p.fOrient = v
  if (v == orVertical) != (p.height > p.width):
    p.setBounds(p.left, p.top, p.height, p.width)
  p.invalidate()

method paint*(p: ProgressBar, c: Canvas) =
  let t = p.theme
  let r = p.clientRect
  let horiz = p.fOrient == orHorizontal
  let thick = if horiz: r.h else: r.w
  let rad = min(thick / 2, t.radius + 2)
  let en = p.isEnabled
  c.fillRoundRect(r, rad, t.surfaceAlt)
  c.strokeRoundRect(r, rad, t.border, t.borderWidth)
  let inner = r.inflate(-t.borderWidth - 1)
  let fill = if en: t.accent else: t.textDisabled
  let len = if horiz: inner.w else: inner.h
  var a, b: float32       # filled span along the main axis, from the start
  if p.fStyle == pbsMarquee:
    let bw = len * 0.3
    a = (len - bw) * p.fPhase
    b = a + bw
  else:
    a = 0
    b = len * p.fraction
  if b - a >= 1:
    let seg =
      if horiz: rectF(inner.x + a, inner.y, b - a, inner.h)
      else: rectF(inner.x, inner.bottom - b, inner.w, b - a)   # grows upwards
    c.fillRoundRect(seg, system.max(rad - 1, 0), fill)
  procCall paint(Control(p), c)

proc initProgressBar*(p: ProgressBar, owner: Component = nil) =
  p.initControl(owner)
  p.fMin = 0
  p.fMax = 100
  p.fStep = 10
  p.fDir = 1
  p.setBounds(0, 0, 150, 18)

proc newProgressBar*(parent: Container = nil, left = 0'f32, top = 0'f32,
                     width = -1'f32, height = -1'f32): ProgressBar {.discardable.} =
  new result
  result.initProgressBar(parent)
  result.placeControl(parent, left, top, width, height)
