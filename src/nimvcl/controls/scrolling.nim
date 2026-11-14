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
    fContent: SizeF
    fPos: PointF
    fNeedH, fNeedV: bool
    fScrollsChildren: bool
    fWheelLines: int
    fInit, fSyncing: bool
    onScroll*: NotifyEvent      ## `scrollPos` changed

func hScrollBar*(c: ScrollingControl): ScrollBar = c.fHBar
func vScrollBar*(c: ScrollingControl): ScrollBar = c.fVBar
func hScrollMode*(c: ScrollingControl): ScrollBarMode = c.fHMode
func vScrollMode*(c: ScrollingControl): ScrollBarMode = c.fVMode
func contentSize*(c: ScrollingControl): SizeF = c.fContent
func scrollPos*(c: ScrollingControl): PointF = c.fPos
func scrollsChildren*(c: ScrollingControl): bool = c.fScrollsChildren
func wheelLines*(c: ScrollingControl): int = c.fWheelLines
proc `wheelLines=`*(c: ScrollingControl, v: int) = c.fWheelLines = max(v, 1)

method scrollLineSize*(c: ScrollingControl): SizeF {.base.} =
  ## Pixels of one line: width = horizontal step, height = vertical step.
  sizeF(20, 20)

method contentScrolled*(c: ScrollingControl) {.base.} =
  ## `scrollPos` changed (after the bars were synced). Base: moves the
  ## Container scroll offset when `scrollsChildren`, repaints and fires
  ## `onScroll`. Subclasses call `procCall` then update their own state.
  if c.fScrollsChildren: c.setScrollOffset(c.fPos.x, c.fPos.y)
  else: c.invalidate()
  if c.onScroll != nil: c.onScroll(c)

proc computeNeeds(c: ScrollingControl) =
  let pad = c.padding
  let aw = max(c.width - pad.horizontal, 0)
  let ah = max(c.height - pad.vertical, 0)
  let bs = DefaultScrollBarSize
  template need(mode: ScrollBarMode, content, avail: float32): bool =
    mode == sbmAlways or (mode == sbmAuto and content > avail)
  var nv = need(c.fVMode, c.fContent.h, ah)
  var nh = need(c.fHMode, c.fContent.w, aw - (if nv: bs else: 0))
  nv = need(c.fVMode, c.fContent.h, ah - (if nh: bs else: 0))
  c.fNeedH = nh
  c.fNeedV = nv

func viewport*(c: ScrollingControl): RectF =
  ## Visible content area in client coordinates (padding and bars excluded).
  let pad = c.padding
  let bs = DefaultScrollBarSize
  rectF(pad.left, pad.top,
        max(c.width - pad.horizontal - (if c.fNeedV: bs else: 0), 0),
        max(c.height - pad.vertical - (if c.fNeedH: bs else: 0), 0))

func maxScroll*(c: ScrollingControl): PointF =
  let v = c.viewport
  pointF(max(c.fContent.w - v.w, 0), max(c.fContent.h - v.h, 0))

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
  c.fVBar.setRange(0, max(c.fContent.h, 0), v.h)
  c.fHBar.setRange(0, max(c.fContent.w, 0), v.w)
  c.fVBar.position = c.fPos.y
  c.fHBar.position = c.fPos.x
  c.fSyncing = false

proc applyPos(c: ScrollingControl, x, y: float32, force = false) =
  let m = c.maxScroll
  let nx = min(max(x, 0), m.x)
  let ny = min(max(y, 0), m.y)
  if nx == c.fPos.x and ny == c.fPos.y and not force: return
  let changed = nx != c.fPos.x or ny != c.fPos.y
  c.fPos = pointF(nx, ny)
  c.fSyncing = true
  c.fVBar.position = ny
  c.fHBar.position = nx
  c.fSyncing = false
  if changed or force: c.contentScrolled()

proc updateScrollBars*(c: ScrollingControl) =
  ## Re-evaluates bar visibility, ranges and the clamping of `scrollPos`.
  ## Called automatically on resize, layout, mode and content size changes.
  let was = (c.fNeedH, c.fNeedV)
  c.computeNeeds()
  c.syncBars()
  if (c.fNeedH, c.fNeedV) != was: c.invalidate()
  c.applyPos(c.fPos.x, c.fPos.y)

proc scrollTo*(c: ScrollingControl, x, y: float32) =
  ## Sets `scrollPos` (clamped).
  c.applyPos(x, y)

proc scrollBy*(c: ScrollingControl, dx, dy: float32) =
  c.applyPos(c.fPos.x + dx, c.fPos.y + dy)

proc scrollIntoView*(c: ScrollingControl, r: RectF) =
  ## Scrolls the minimum distance that shows `r` (CONTENT coordinates) in the
  ## viewport; a rect larger than the viewport is aligned at its top-left.
  let v = c.viewport
  var x = c.fPos.x
  var y = c.fPos.y
  if r.w > v.w or r.x < x: x = r.x
  elif r.right > x + v.w: x = r.right - v.w
  if r.h > v.h or r.y < y: y = r.y
  elif r.bottom > y + v.h: y = r.bottom - v.h
  c.applyPos(x, y)

proc setContentSize*(c: ScrollingControl, w, h: float32) =
  if w == c.fContent.w and h == c.fContent.h: return
  c.fContent = sizeF(w, h)
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
  let lines = float32(c.fWheelLines)
  let m = c.maxScroll
  var nx = c.fPos.x
  var ny = c.fPos.y
  var moved = false
  if my != 0 and m.y > 0:
    let t = min(max(ny - my * lines * ls.h, 0), m.y)
    if t != ny:
      ny = t
      moved = true
  if mx != 0 and m.x > 0:
    let t = min(max(nx - mx * lines * ls.w, 0), m.x)
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
    sc.applyPos(sc.fHBar.position, sc.fVBar.position)
  c.fVBar = newScrollBar(c, sbVertical)
  c.fVBar.align = alRight
  c.fVBar.visible = false
  c.fVBar.onChange = onBar
  c.fHBar = newScrollBar(c, sbHorizontal)
  c.fHBar.align = alBottom
  c.fHBar.visible = false
  c.fHBar.onChange = onBar
  c.fInit = true
