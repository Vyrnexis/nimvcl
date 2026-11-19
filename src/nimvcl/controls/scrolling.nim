## `ScrollingControl`: the reusable base for controls that scroll content
## (ScrollBox, ListBox; ComboBox drop-downs and Memo/grids build on it).
##
## It is a Container that owns two embedded `ScrollBar` children (`hScrollBar`,
## `vScrollBar`, aligned alBottom / alRight inside the padding, so they do not
## scroll) and keeps them in sync with:
##
## * `contentSize`: the size of the scrollable content in pixels; subclasses
##   set it with `setContentSize` (ListBox: rows, ScrollBox: children extent).
## * `viewport`: the client area minus padding and the visible bars. Bars are
##   shown per axis by `hScrollMode` / `vScrollMode`: `sbmAuto` (only while the
##   content exceeds the viewport; showing one bar shrinks the viewport and can
##   make the other necessary), `sbmAlways`, `sbmNever`. Bars take space (12 px).
## * `scrollPos`: the scroll position in content pixels, always clamped to
##   `0 .. contentSize - viewport`. Change it with `scrollTo` / `scrollBy` /
##   `scrollIntoView`; read the pixel range with `maxScroll`.
##
## Precision: positions and content sizes are kept as float64 internally, so
## a list of millions of rows scrolls to the exact pixel. `scrollPos`,
## `contentSize` and `maxScroll` return float32 (rounded; fine for small
## content); use `scrollPosX/Y`, `contentW/H` and `maxScrollX/Y` (float64)
## when you compute row positions for huge content, and convert to float32
## only after subtracting the scroll position (viewport-relative values are
## small).
##
## What scrolling DOES to the display is a subclass choice:
##
## * `scrollsChildren = true` (ScrollBox): the Container scroll offset follows
##   `scrollPos`, so alNone children move (clipped to `viewport`; see
##   control.nim).
## * otherwise (ListBox, Memo): nothing moves automatically; the subclass paints
##   its own content shifted by `scrollPos` and overrides `contentScrolled`
##   (call `procCall` first) to react.
##
## Wheel (`doMouseWheel`): a notch scrolls `wheelLines` (3) lines, where a line
## is `scrollLineSize` pixels (override per control; default 20x20); fractional
## deltas from touchpads scroll fractionally. Shift+wheel (or horizontal `dx`)
## scrolls horizontally. The event is `handled` only when the position actually
## moved along an axis the wheel asked for; at the limit it bubbles to the
## enclosing scroller. ScrollBar children scroll this control through
## `onChange`.
##
## Subclass protocol: call `initScrollingControl`, override `scrollLineSize` /
## `contentScrolled`, call `setContentSize` when the content changes, use
## `viewport` for painting/hit-testing (client coordinates).

import ./common, ./scrollbar
export scrollbar

type
  ScrollBarMode* = enum sbmAuto, sbmAlways, sbmNever

  ScrollingControl* = ref object of Container
    fHBar, fVBar: ScrollBar
    fHMode, fVMode: ScrollBarMode
    fContentW, fContentH: float64
    fPosX, fPosY: float64
    fNeedH, fNeedV: bool
    fScrollsChildren: bool
    fWheelLines: int
    fInit, fSyncing: bool
    onScroll*: NotifyEvent      ## `scrollPos` changed

func hScrollBar*(c: ScrollingControl): ScrollBar = c.fHBar
func vScrollBar*(c: ScrollingControl): ScrollBar = c.fVBar
func hScrollMode*(c: ScrollingControl): ScrollBarMode = c.fHMode
func vScrollMode*(c: ScrollingControl): ScrollBarMode = c.fVMode
func contentSize*(c: ScrollingControl): SizeF =
  sizeF(float32(c.fContentW), float32(c.fContentH))
func scrollPos*(c: ScrollingControl): PointF =
  pointF(float32(c.fPosX), float32(c.fPosY))
func contentW*(c: ScrollingControl): float64 = c.fContentW
func contentH*(c: ScrollingControl): float64 = c.fContentH
func scrollPosX*(c: ScrollingControl): float64 = c.fPosX
  ## `scrollPos.x` without float32 rounding.
func scrollPosY*(c: ScrollingControl): float64 = c.fPosY
  ## `scrollPos.y` without float32 rounding.
func scrollsChildren*(c: ScrollingControl): bool = c.fScrollsChildren
func wheelLines*(c: ScrollingControl): int = c.fWheelLines
proc `wheelLines=`*(c: ScrollingControl, v: int) =
  c.fWheelLines = max(v, 1)
  if c.fHBar != nil: c.fHBar.wheelLines = c.fWheelLines   # the embedded bars agree
  if c.fVBar != nil: c.fVBar.wheelLines = c.fWheelLines

method scrollLineSize*(c: ScrollingControl): SizeF {.base.} =
  ## Pixels of one line: width = horizontal step, height = vertical step.
  sizeF(20, 20)

method contentScrolled*(c: ScrollingControl) {.base.} =
  ## `scrollPos` changed (after the bars were synced). Base: moves the
  ## Container scroll offset when `scrollsChildren`, repaints and fires
  ## `onScroll`. Subclasses call `procCall` then update their own state.
  if c.fScrollsChildren: c.setScrollOffset(float32(c.fPosX), float32(c.fPosY))
  else: c.invalidate()
  if c.onScroll != nil: c.onScroll(c)

proc computeNeeds(c: ScrollingControl) =
  let pad = c.padding
  let aw = max(c.width - pad.horizontal, 0)
  let ah = max(c.height - pad.vertical, 0)
  let bs = DefaultScrollBarSize
  template need(mode: ScrollBarMode, content: float64, avail: float32): bool =
    mode == sbmAlways or (mode == sbmAuto and content > float64(avail))
  var nv = need(c.fVMode, c.fContentH, ah)
  var nh = need(c.fHMode, c.fContentW, aw - (if nv: bs else: 0))
  nv = need(c.fVMode, c.fContentH, ah - (if nh: bs else: 0))
  c.fNeedH = nh
  c.fNeedV = nv

func viewport*(c: ScrollingControl): RectF =
  ## Visible content area in client coordinates (padding and bars excluded).
  let pad = c.padding
  let bs = DefaultScrollBarSize
  rectF(pad.left, pad.top,
        max(c.width - pad.horizontal - (if c.fNeedV: bs else: 0), 0),
        max(c.height - pad.vertical - (if c.fNeedH: bs else: 0), 0))

func maxScrollX*(c: ScrollingControl): float64 =
  max(c.fContentW - float64(c.viewport.w), 0.0)
func maxScrollY*(c: ScrollingControl): float64 =
  max(c.fContentH - float64(c.viewport.h), 0.0)

func maxScroll*(c: ScrollingControl): PointF =
  pointF(float32(c.maxScrollX), float32(c.maxScrollY))

method viewportRect*(c: ScrollingControl): RectF = c.viewport

proc syncBars(c: ScrollingControl) =
  let v = c.viewport
  let ls = c.scrollLineSize()
  c.fSyncing = true
  c.fVBar.visible = c.fNeedV
  c.fHBar.visible = c.fNeedH
  c.fHBar.margins = spacing(0, 0, (if c.fNeedV: DefaultScrollBarSize else: 0), 0)
  c.fVBar.smallChange = ls.h
  c.fHBar.smallChange = ls.w
  c.fVBar.largeChange = max(v.h - ls.h, ls.h)
  c.fHBar.largeChange = max(v.w - ls.w, ls.w)
  c.fVBar.setRange64(0, max(c.fContentH, 0.0), float64(v.h))
  c.fHBar.setRange64(0, max(c.fContentW, 0.0), float64(v.w))
  c.fVBar.setPosition64(c.fPosY)
  c.fHBar.setPosition64(c.fPosX)
  c.fSyncing = false

proc applyPos(c: ScrollingControl, x, y: float64) =
  let nx = min(max(x, 0.0), c.maxScrollX)
  let ny = min(max(y, 0.0), c.maxScrollY)
  if nx == c.fPosX and ny == c.fPosY: return
  c.fPosX = nx
  c.fPosY = ny
  c.fSyncing = true
  c.fVBar.setPosition64(ny)
  c.fHBar.setPosition64(nx)
  c.fSyncing = false
  c.contentScrolled()

proc updateScrollBars*(c: ScrollingControl) =
  ## Re-evaluates bar visibility, ranges and the clamping of `scrollPos`.
  ## Called automatically on resize, layout, mode and content size changes.
  let was = (c.fNeedH, c.fNeedV)
  c.computeNeeds()
  c.syncBars()
  if (c.fNeedH, c.fNeedV) != was: c.invalidate()
  c.applyPos(c.fPosX, c.fPosY)

proc scrollTo*(c: ScrollingControl, x, y: float64) =
  ## Sets `scrollPos` (clamped).
  c.applyPos(x, y)

proc scrollBy*(c: ScrollingControl, dx, dy: float64) =
  c.applyPos(c.fPosX + dx, c.fPosY + dy)

proc scrollIntoView*(c: ScrollingControl, rx, ry, rw, rh: float64) =
  ## float64 form of `scrollIntoView(RectF)` (exact for huge content).
  let v = c.viewport
  var x = c.fPosX
  var y = c.fPosY
  if rw > float64(v.w) or rx < x: x = rx
  elif rx + rw > x + float64(v.w): x = rx + rw - float64(v.w)
  if rh > float64(v.h) or ry < y: y = ry
  elif ry + rh > y + float64(v.h): y = ry + rh - float64(v.h)
  c.applyPos(x, y)

proc scrollIntoView*(c: ScrollingControl, r: RectF) =
  ## Scrolls the minimum distance that shows `r` (CONTENT coordinates) in the
  ## viewport; a rect larger than the viewport is aligned at its top-left.
  c.scrollIntoView(float64(r.x), float64(r.y), float64(r.w), float64(r.h))

proc setContentSize*(c: ScrollingControl, w, h: float64) =
  if w == c.fContentW and h == c.fContentH: return
  c.fContentW = w
  c.fContentH = h
  c.updateScrollBars()

proc `hScrollMode=`*(c: ScrollingControl, v: ScrollBarMode) =
  if v == c.fHMode: return
  c.fHMode = v
  c.updateScrollBars()
  c.relayout()
proc `vScrollMode=`*(c: ScrollingControl, v: ScrollBarMode) =
  if v == c.fVMode: return
  c.fVMode = v
  c.updateScrollBars()
  c.relayout()

method doResize*(c: ScrollingControl) =
  if c.fInit: c.updateScrollBars()
  procCall doResize(Control(c))

method beforeLayout*(c: ScrollingControl) =
  c.updateScrollBars()

method doMouseWheel*(c: ScrollingControl, shift: ShiftState, dx, dy: float32,
                     handled: var bool) =
  procCall doMouseWheel(Control(c), shift, dx, dy, handled)
  if handled or not c.isEnabled: return
  var mx = dx
  var my = dy
  if ssShift in shift and mx == 0:
    mx = dy
    my = 0
  let ls = c.scrollLineSize()
  let lines = float64(c.fWheelLines)
  let mxs = c.maxScrollX
  let mys = c.maxScrollY
  var nx = c.fPosX
  var ny = c.fPosY
  var moved = false
  if my != 0 and mys > 0:
    let t = min(max(ny - float64(my) * lines * float64(ls.h), 0.0), mys)
    if t != ny:
      ny = t
      moved = true
  if mx != 0 and mxs > 0:
    let t = min(max(nx - float64(mx) * lines * float64(ls.w), 0.0), mxs)
    if t != nx:
      nx = t
      moved = true
  if moved:
    c.applyPos(nx, ny)
    handled = true

proc initScrollingControl*(c: ScrollingControl, owner: Component = nil,
                           scrollsChildren = false) =
  c.initContainer(owner)
  c.fScrollsChildren = scrollsChildren
  c.fWheelLines = 3
  c.fHMode = sbmAuto
  c.fVMode = sbmAuto
  let onBar = proc(s: Control) =
    let sc = ScrollingControl(s.parent)
    if sc == nil or sc.fSyncing: return
    sc.applyPos(sc.fHBar.position64, sc.fVBar.position64)
  c.fVBar = newScrollBar(c, sbVertical)
  c.fVBar.align = alRight
  c.fVBar.visible = false
  c.fVBar.onChange = onBar
  c.fHBar = newScrollBar(c, sbHorizontal)
  c.fHBar.align = alBottom
  c.fHBar.visible = false
  c.fHBar.onChange = onBar
  c.fInit = true
