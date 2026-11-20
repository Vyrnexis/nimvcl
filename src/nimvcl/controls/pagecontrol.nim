## `PageControl` + `TabSheet` and `TabControl` (VCL TPageControl / TTabControl).
##
## Both draw the same tab strip (`TabBase`): tabs across the top, the selected
## one joined to the body below (`tabPosition = tpBottom` puts the strip under
## the body, tabs hanging down, like the message view of an IDE). `tabIndex` is the selected tab; changing it
## (click, keys or code) first asks `onChanging(sender, allowChange)` (set
## `allowChange = false` to veto), then fires `onChange`.
##
## Keyboard (the strip focused): Left/Right/Home/End select a tab, Ctrl+Tab /
## Ctrl+PageDown go to the next, Ctrl+Shift+Tab / Ctrl+PageUp to the previous
## (wrapping). A PageControl also registers a handler (id "pages") in the
## `UiRoot` key-handler chain when it is inserted into a form or host, so the
## Ctrl+Tab / Ctrl+PageUp/Down shortcuts work while focus is inside the active
## page, whatever the registration order of other handlers (menus, dialog keys).
##
## Disabled sheets and sheets with `tabVisible = false` (no tab shown, like VCL)
## cannot be selected by click, arrows, Home/End or Ctrl+Tab; code may still
## select a disabled sheet through `tabIndex`/`activePage`. Hiding the active
## sheet's tab moves the selection to the next selectable sheet.
##
## `showTabs = false` hides the strip (pages are then switched by code only:
## no click, arrow keys, Ctrl+Tab or Alt+letter, and the control takes no focus).
##
## Mnemonics: `&` in a sheet caption is underlined while Alt is held;
## Alt+letter selects that page (when the sheet is enabled).
##
## Closable tabs: `closeButtons = true` draws a small cross at the right end of
## every tab (highlighted under the pointer) and makes a middle click on a tab
## close it too. A click on the cross (or the middle click) calls
## `onTabClose(sender, index, allow)`; with `allow` left true the tab is then
## removed (a PageControl frees the sheet, a TabControl drops the tab), with
## `allow = false` nothing happens (or the handler removes the tab itself, for
## instance after asking to save). The tab is wider by the button, so a
## `sheetTabText` override needs no padding. `closeTab(i)` does the same from code.
##
## Overflow: when the tabs do not fit, two small arrow buttons appear at the
## right end of the strip and scroll it (selecting does not need them: the
## selected tab is always scrolled into view).
##
## PageControl: its children are the `TabSheet` pages, in tab order (child
## order). A sheet is an alClient Container; only the active one is visible
## (inactive sheets are hidden, so their controls are out of the tab order).
## The first sheet created becomes active. When the active page changes while
## focus was inside the old sheet, focus moves to the first focusable control of
## the new sheet (or to the strip when it has none). The active sheet is tracked
## by identity: removing or inserting other sheets keeps it active; removing the
## active sheet itself activates its neighbour and fires `onChange`. `activePage`,
## `activePageIndex` and `tabIndex` are the same selection.
##
## TabControl: only tabs (`tabs`, `tabIndex`); the body is a plain frame that
## children can be placed in, below the strip.

import ../core/[input, form]
import ./common

type
  TabPosition* = enum
    tpTop, tpBottom          ## where the tab strip sits

  TabChangingEvent* = proc(sender: Control, allowChange: var bool)
  TabCloseEvent* = proc(sender: Control, index: int, allow: var bool)

  StripMetrics = object
    ## Widths of the tab strip, kept until the captions, visibility, font or
    ## measuring ability change (checked when the strip is used).
    texts: seq[string]
    shown: seq[bool]
    xs: seq[float32]            # xs[i]: left edge of tab i from StripLeft; xs[n]: end
    font: FontSpec
    measured: bool
    close: bool                 # the tabs were measured with a close button
    valid: bool

  TabBase* = ref object of Container
    fMetrics: StripMetrics
    fMetricsDirty: bool         # a tab was added, removed, renamed or hidden: re-measure
    fIndex: int
    fFirst: int                 # first tab shown (strip scroll position)
    fHotTab: int                # -1 none, tab index, or -2/-3 scroll arrows
    fHotClose: int              # tab whose close button is under the pointer, -1 none
    fCloseBtn: bool
    fFillBody: bool
    fHideTabs: bool             # no strip: pages are switched by code only
    fPos: TabPosition
    fEnsure: bool               # scroll the selected tab into view on next paint
    onChange*: NotifyEvent
    onChanging*: TabChangingEvent
    onTabClose*: TabCloseEvent   ## a close button or a middle click asked to close tab `index`

  TabControl* = ref object of TabBase
    fTabs: seq[string]

  TabSheet* = ref object of Container
    fTabHidden: bool

  PageControl* = ref object of TabBase
    fActive: TabSheet           # the active sheet (tracked by identity)
    fSyncing: bool

const
  TabPad = 14'f32
  MinTabW = 44'f32
  ArrowW = 20'f32
  StripLeft = 2'f32
  CloseBox = 16'f32           # width of the close button area of a tab

# --------------------------------------------------------------- base API

method tabCount*(t: TabBase): int {.base.} = 0
method tabText*(t: TabBase, i: int): string {.base.} = ""
method tabChanged*(t: TabBase, oldIndex, newIndex: int) {.base.} =
  ## Called after the index changed (before `onChange`).
  discard
method removeTab*(t: TabBase, i: int) {.base.} =
  ## Removes tab `i` once `onTabClose` allowed it (`closeTab`).
  discard
method tabEnabled*(t: TabBase, i: int): bool {.base.} = true
method tabVisible*(t: TabBase, i: int): bool {.base.} = true
  ## Whether tab `i` is shown in the strip.
method collectTabs*(t: TabBase, texts: var seq[string], shown: var seq[bool]) {.base.} =
  ## The caption and strip visibility of every tab, in one pass.
  for i in 0 ..< t.tabCount:
    texts.add t.tabText(i)
    shown.add t.tabVisible(i)

func tabIndex*(t: TabBase): int = t.fIndex

func showTabs*(t: TabBase): bool = not t.fHideTabs
proc `showTabs=`*(t: TabBase, v: bool) =
  ## `false` hides the tab strip: the control is just a bordered page area and
  ## the user cannot switch pages (no click, arrows, Ctrl+Tab or Alt+letter);
  ## code still can (`tabIndex`, `activePage`, `cycle`). Default `true`.
  if v == not t.fHideTabs: return
  t.fHideTabs = not v
  t.fMetricsDirty = true
  t.fFirst = 0
  t.fHotTab = -1
  t.needsLayout = true      # the padding (strip height) changed
  t.requestLayout()
  t.invalidate()

func closeButtons*(t: TabBase): bool = t.fCloseBtn
proc `closeButtons=`*(t: TabBase, v: bool) =
  ## Draws a close cross on every tab and lets a middle click close a tab
  ## (see the unit comment). Default `false`.
  if v == t.fCloseBtn: return
  t.fCloseBtn = v
  t.fMetricsDirty = true
  t.fHotClose = -1
  t.invalidate()

proc closeTab*(t: TabBase, i: int) =
  ## Asks `onTabClose(t, i, allow)` and removes the tab unless `allow` was set
  ## to false. Works with or without `closeButtons`.
  if i < 0 or i >= t.tabCount: return
  var allow = true
  if t.onTabClose != nil: t.onTabClose(t, i, allow)
  if allow and i < t.tabCount: t.removeTab(i)

func tabPosition*(t: TabBase): TabPosition = t.fPos
proc `tabPosition=`*(t: TabBase, v: TabPosition) =
  ## `tpTop` (default) or `tpBottom`: the strip under the body, the selected
  ## tab joined to the body above it. Pages and children move to fit.
  if v == t.fPos: return
  t.fPos = v
  t.fHotTab = -1
  t.needsLayout = true      # the padding moved from the top to the bottom
  t.requestLayout()
  t.invalidate()

proc stripHeight*(t: TabBase): float32 =
  ## Height of the tab strip (derived from the theme, no window needed); 0
  ## when `showTabs` is false.
  if t.fHideTabs: 0'f32 else: t.theme.controlHeight

proc place(t: TabBase, r: RectF): RectF =
  ## A rectangle laid out for a strip along the top edge (y from the strip's
  ## top), in client coordinates: mirrored for `tpBottom`.
  if t.fPos == tpTop: r else: rectF(r.x, t.height - r.y - r.h, r.w, r.h)

proc refreshMetrics(t: TabBase, force = false) =
  ## Re-measures the strip when something it depends on changed. Paint
  ## (`force`) compares every tab text, so a text an override of `tabText`
  ## computes is always current; hit tests and the like reuse the cached prefix
  ## sums unless a tab was added, removed, renamed or hidden (`fMetricsDirty`)
  ## or the font changed.
  let f = t.font
  let measured = t.canMeasure
  let m = addr t.fMetrics
  let close = t.fCloseBtn
  if not force and not t.fMetricsDirty and m.valid and m.measured == measured and
     m.font == f and m.close == close: return
  var texts: seq[string]
  var shown: seq[bool]
  t.collectTabs(texts, shown)
  t.fMetricsDirty = false
  if m.valid and m.measured == measured and m.font == f and m.texts == texts and
     m.shown == shown and m.close == close: return
  m.xs.setLen(texts.len + 1)
  m.xs[0] = 0
  for i in 0 ..< texts.len:
    let w = if shown[i]: max(t.textWidth(displayText(texts[i]), f) + 2 * TabPad +
                             (if close: CloseBox else: 0'f32), MinTabW)
            else: 0'f32
    m.xs[i + 1] = m.xs[i] + w
  m.texts = texts
  m.shown = shown
  m.font = f
  m.measured = measured
  m.close = close
  m.valid = true

func tabWidth(t: TabBase, i: int): float32 =
  if i < 0 or i >= t.fMetrics.xs.len - 1: 0'f32
  else: t.fMetrics.xs[i + 1] - t.fMetrics.xs[i]

func stripTabs(t: TabBase): int = max(t.fMetrics.xs.len - 1, 0)

func isOverflowing(t: TabBase): bool =
  t.fMetrics.xs.len > 0 and StripLeft + t.fMetrics.xs[^1] > t.width - 2

proc overflowing*(t: TabBase): bool =
  t.refreshMetrics()
  t.isOverflowing

func stripRight(t: TabBase): float32 =
  ## Right edge available to tabs.
  t.width - 2 - (if t.isOverflowing: 2 * ArrowW else: 0'f32)

proc rectOf(t: TabBase, i: int): RectF =
  if i < t.fFirst or i >= t.stripTabs: return rectF(0, 0, 0, 0)
  let w = t.tabWidth(i)
  if w <= 0: return rectF(0, 0, 0, 0)
  let x = StripLeft + t.fMetrics.xs[i] - t.fMetrics.xs[min(t.fFirst, t.stripTabs)]
  let h = t.stripHeight
  if i == t.fIndex: rectF(x, 1, w, h - 1)
  else: rectF(x, 3, w, h - 3)

proc normalizeFirst(t: TabBase) =
  ## The strip is only scrolled while the tabs overflow.
  if t.fFirst != 0 and not t.isOverflowing: t.fFirst = 0

proc tabRect*(t: TabBase, i: int): RectF =
  ## Tab `i` in client coordinates; empty when scrolled out to the left or
  ## hidden.
  t.refreshMetrics()
  t.normalizeFirst()
  t.place(t.rectOf(i))

proc tabsRight(t: TabBase): float32 =
  ## Right edge of the last tab as currently scrolled.
  StripLeft + t.fMetrics.xs[^1] - t.fMetrics.xs[min(t.fFirst, t.stripTabs)]

proc arrowRect(t: TabBase, left: bool): RectF =
  let h = t.stripHeight
  let x = t.width - 2 * ArrowW - 2 + (if left: 0'f32 else: ArrowW)
  rectF(x, 3, ArrowW, h - 5)

proc closeRect(t: TabBase, i: int): RectF =
  ## The close button of tab `i` in client coordinates (empty without
  ## `closeButtons` or when the tab is not shown).
  let r = t.rectOf(i)
  if not t.fCloseBtn or r.w <= 0: return rectF(0, 0, 0, 0)
  let side = CloseBox - 2
  t.place(rectF(r.x + r.w - CloseBox - 3, r.y + (r.h - side) / 2 + 1, side, side))

proc tabAt*(t: TabBase, x, y: float32): int =
  ## Tab under the point, -1 none, -2 / -3 the left / right scroll arrow.
  let y = if t.fPos == tpTop: y else: t.height - y    # strip-local, from its outer edge
  if y < 0 or y >= t.stripHeight: return -1
  t.refreshMetrics()
  t.normalizeFirst()
  if t.isOverflowing:
    if t.arrowRect(true).contains(pointF(x, y)): return -2
    if t.arrowRect(false).contains(pointF(x, y)): return -3
  if x >= t.stripRight: return -1
  # the first tab whose right edge lies beyond x (binary search on the prefix sums)
  let xs = t.fMetrics.xs
  let target = x - StripLeft + xs[min(t.fFirst, t.stripTabs)]
  var lo = t.fFirst
  var hi = t.stripTabs
  while lo < hi:
    let mid = (lo + hi) div 2
    if xs[mid + 1] > target: hi = mid else: lo = mid + 1
  if lo < t.stripTabs and x >= StripLeft and t.tabWidth(lo) > 0: lo else: -1

proc closeAt(t: TabBase, i: int, x, y: float32): bool =
  ## The point is on the close button of tab `i`.
  i >= 0 and t.fCloseBtn and x < t.stripRight and t.closeRect(i).contains(pointF(x, y))

proc ensureVisible(t: TabBase, i: int) =
  t.refreshMetrics()
  if i < 0 or i >= t.stripTabs or t.tabWidth(i) <= 0: return
  if not t.isOverflowing:
    t.fFirst = 0
    return
  if i < t.fFirst: t.fFirst = i
  while t.fFirst < i and t.rectOf(i).right > t.stripRight:
    inc t.fFirst

proc `tabIndex=`*(t: TabBase, v: int) =
  ## Selects a tab (asks `onChanging`, then fires `onChange`).
  if v == t.fIndex or v < 0 or v >= t.tabCount: return
  var allow = true
  if t.onChanging != nil: t.onChanging(t, allow)
  if not allow: return
  let old = t.fIndex
  t.fIndex = v
  t.tabChanged(old, v)
  t.ensureVisible(v)
  t.fEnsure = true          # the width may still be a stale default: redo at paint
  t.invalidate()
  if t.onChange != nil: t.onChange(t)

proc selectable(t: TabBase, i: int): bool =
  i >= 0 and i < t.tabCount and t.tabVisible(i) and t.tabEnabled(i)

proc nextSelectable(t: TabBase, start, dir: int): int =
  ## First selectable tab from `start` (exclusive) going `dir`; -1 none.
  var i = start + dir
  while i >= 0 and i < t.tabCount:
    if t.selectable(i): return i
    i += dir
  -1

proc cycle*(t: TabBase, dir: int) =
  ## Next / previous selectable tab, wrapping.
  let n = t.tabCount
  if n < 2: return
  for k in 1 ..< n:
    let i = ((t.fIndex + dir * k) mod n + n) mod n
    if t.selectable(i):
      t.tabIndex = i
      return

proc firstVisibleTab*(t: TabBase): int =
  t.refreshMetrics()
  t.normalizeFirst()
  t.fFirst

# ---------------------------------------------------------- base behaviour

method canFocus*(t: TabBase): bool = t.isVisible and t.isEnabled and not t.fHideTabs

method doMouseDown*(t: TabBase, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbMiddle and t.fCloseBtn:
    let i = t.tabAt(x, y)
    if i >= 0:
      procCall doMouseDown(Control(t), button, shift, x, y)
      t.closeTab(i)
      return
  if button == mbLeft:
    let i = t.tabAt(x, y)
    if t.closeAt(i, x, y):
      procCall doMouseDown(Control(t), button, shift, x, y)
      t.closeTab(i)
      return
    if i >= 0:
      if t.selectable(i): t.tabIndex = i
    elif i == -2 and t.fFirst > 0:
      dec t.fFirst
      t.invalidate()
    elif i == -3 and t.tabsRight > t.stripRight:
      inc t.fFirst
      t.invalidate()
  procCall doMouseDown(Control(t), button, shift, x, y)

method doMouseMove*(t: TabBase, shift: ShiftState, x, y: float32) =
  let h = t.tabAt(x, y)
  let hc = if t.closeAt(h, x, y): h else: -1
  if h != t.fHotTab or hc != t.fHotClose:
    t.fHotTab = h
    t.fHotClose = hc
    t.invalidate()
  procCall doMouseMove(Control(t), shift, x, y)

method doMouseLeave*(t: TabBase) =
  t.fHotTab = -1
  t.fHotClose = -1
  t.invalidate()
  procCall doMouseLeave(Control(t))

proc handleTabKey(t: TabBase, key: var Key, shift: ShiftState): bool =
  ## Shortcuts shared by the focused strip and the form-level hook.
  if t.fHideTabs or ssAlt in shift or ssSuper in shift: return false
  if ssCtrl in shift:
    if key == keyTab: t.cycle(if ssShift in shift: -1 else: 1)
    elif key == keyPageDown and ssShift notin shift: t.cycle(1)
    elif key == keyPageUp and ssShift notin shift: t.cycle(-1)
    else: return false
    key = Key(0)
    return true
  false

method activateMnemonic*(t: TabBase, ch: Rune): bool =
  ## Alt+letter selects the tab whose caption has that mnemonic.
  if t.fHideTabs: return false
  for i in 0 ..< t.tabCount:
    if t.selectable(i) and mnemonicOf(t.tabText(i)) == ch:
      t.tabIndex = i
      return true

method doKeyDown*(t: TabBase, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(t), key, shift)
  if key == Key(0): return
  if t.handleTabKey(key, shift): return
  if t.fHideTabs: return
  if shift * {ssCtrl, ssAlt, ssSuper} != {}: return
  var handled = true
  template go(i: int) =
    let target = i
    if target >= 0: t.tabIndex = target
  if key == keyLeft: go t.nextSelectable(t.fIndex, -1)
  elif key == keyRight: go t.nextSelectable(t.fIndex, 1)
  elif key == keyHome: go t.nextSelectable(-1, 1)
  elif key == keyEnd: go t.nextSelectable(t.tabCount, -1)
  else: handled = false
  if handled: key = Key(0)

method doMouseWheel*(t: TabBase, shift: ShiftState, dx, dy: float32,
                     handled: var bool) =
  ## Over the strip, the wheel scrolls tabs that do not fit.
  procCall doMouseWheel(Control(t), shift, dx, dy, handled)
  if handled or t.fHotTab == -1 or t.fHideTabs: return
  t.refreshMetrics()
  t.normalizeFirst()
  if not t.isOverflowing: return
  let d = if dy != 0: dy else: dx
  if d > 0 and t.fFirst > 0: dec t.fFirst
  elif d < 0 and t.tabsRight > t.stripRight: inc t.fFirst
  else: return
  t.invalidate()
  handled = true

method inheritedColor*(t: TabBase): Color =
  if t.fFillBody: t.theme.surface else: procCall inheritedColor(Control(t))

proc drawTabClose(t: TabBase, c: Canvas, i: int, bg, ink: Color) =
  let r = t.closeRect(i)
  if r.w <= 0: return
  let th = t.theme
  if t.fHotClose == i and t.isEnabled:
    c.fillRoundRect(r, th.radius, t.rowHover(th, bg))
  let cx = r.x + r.w / 2
  let cy = r.y + r.h / 2
  let col = if t.isEnabled: ink else: th.textDisabled
  c.line(cx - 3, cy - 3, cx + 3, cy + 3, col, 1.3)
  c.line(cx - 3, cy + 3, cx + 3, cy - 3, col, 1.3)

method paint*(t: TabBase, c: Canvas) =
  let th = t.theme
  let en = t.isEnabled
  let h = t.stripHeight
  let w = t.width
  t.refreshMetrics(force = true)
  t.normalizeFirst()
  if t.fEnsure:
    t.fEnsure = false
    t.ensureVisible(t.fIndex)
  # body
  let bodyH = max(t.height - max(h - 1, 0), 0)
  let body = rectF(0, if t.fPos == tpTop: max(h - 1, 0) else: 0, w, bodyH)
  let own = t.ownColor
  let bodyBg = if own: t.color elif t.fFillBody: th.surface else: th.window
  let tabBg = if own: t.headerFill(th, bodyBg) else: th.surfaceAlt
  if own or t.fFillBody: c.fillRoundRect(body, th.radius, bodyBg)
  c.strokeRoundRect(body, th.radius, th.border, th.borderWidth)
  if t.fHideTabs:
    procCall paint(Control(t), c)
    return
  let right = t.stripRight
  c.pushClip(t.place(rectF(0, 0, right + 2, h)))
  var selR = rectF(0, 0, 0, 0)
  for i in t.fFirst ..< t.stripTabs:
    let r = t.rectOf(i)
    if r.x > right: break
    if r.w <= 0: continue
    if i == t.fIndex:
      selR = r
      continue
    c.pushClip(t.place(rectF(r.x - 1, 0, r.w + 2, h)))
    let fill = if t.fHotTab == i and en: t.rowHover(th, tabBg) else: tabBg
    c.fillRoundRect(t.place(rectF(r.x, r.y, r.w, r.h + 6)), th.radius, fill)
    c.strokeRoundRect(t.place(rectF(r.x, r.y, r.w, r.h + 6)), th.radius, th.border, 1)
    c.popClip()
    let ink = if t.hasFontColor: t.ink(th, fill, en)
              elif en: legible(th.textMuted, fill) else: th.textDisabled
    let tw = if t.fCloseBtn: CloseBox else: 0'f32
    c.drawMnemonic(t.fMetrics.texts[i], t.font, t.place(rectF(r.x + 4, r.y, r.w - 8 - tw, r.h - 1)),
                   ink, t.altHeld, taCenter, vaCenter)
    c.pushClip(t.place(rectF(r.x - 1, 0, r.w + 2, h)))
    t.drawTabClose(c, i, fill, ink)
    c.popClip()
  if selR.w > 0:
    c.pushClip(t.place(rectF(selR.x - 1, 0, selR.w + 2, h)))
    let full = t.place(rectF(selR.x, selR.y, selR.w, selR.h + 6))
    c.fillRoundRect(full, th.radius, bodyBg)
    c.strokeRoundRect(full, th.radius, th.borderStrong, 1)
    c.popClip()
    c.drawMnemonic(t.fMetrics.texts[t.fIndex], t.font,
                   t.place(rectF(selR.x + 4, selR.y, selR.w - 8 -
                                 (if t.fCloseBtn: CloseBox else: 0'f32), selR.h)),
                   t.ink(th, bodyBg, en), t.altHeld, taCenter, vaCenter)
    t.drawTabClose(c, t.fIndex, bodyBg, t.ink(th, bodyBg, en))
    if t.focused:
      drawFocusRing(c, t.place(rectF(selR.x, selR.y, selR.w, selR.h)), th)
  c.popClip()
  if t.isOverflowing:
    for left in [true, false]:
      let r = t.place(t.arrowRect(left))
      let canGo =
        if left: t.fFirst > 0
        else: t.tabsRight > right
      let hot = t.fHotTab == (if left: -2 else: -3) and canGo and en
      c.fillRoundRect(r, th.radius, if hot: t.rowHover(th, bodyBg) else: (if own: bodyBg else: th.surface))
      c.strokeRoundRect(r, th.radius, th.border, 1)
      c.drawArrow(pointF(r.x + r.w / 2, r.y + r.h / 2), 3.5,
                  if left: adLeft else: adRight,
                  if canGo and en: t.ink(th, bodyBg) else: th.textDisabled)
  procCall paint(Control(t), c)

method padding*(t: TabBase): Spacing =
  if t.fPos == tpTop: spacing(1, max(t.stripHeight, 1), 1, 1)
  else: spacing(1, 1, 1, max(t.stripHeight, 1))

proc initTabBase(t: TabBase, owner: Component) =
  t.initContainer(owner)
  t.fIndex = -1
  t.fHotTab = -1
  t.fHotClose = -1
  t.tabStop = true
  t.setBounds(0, 0, 289, 193)

# -------------------------------------------------------------- TabControl

method tabCount*(t: TabControl): int = t.fTabs.len
method tabText*(t: TabControl, i: int): string = t.fTabs[i]

func tabs*(t: TabControl): seq[string] = t.fTabs
proc `tabs=`*(t: TabControl, v: seq[string]) =
  t.fTabs = v
  t.fMetricsDirty = true
  if t.fIndex >= v.len: t.fIndex = v.high
  if t.fIndex < 0 and v.len > 0: t.fIndex = 0
  t.fFirst = 0
  t.invalidate()

method removeTab*(t: TabControl, i: int) =
  if i < 0 or i >= t.fTabs.len: return
  t.fTabs.delete i
  t.fMetricsDirty = true
  let old = t.fIndex
  if i < t.fIndex: dec t.fIndex
  if t.fIndex >= t.fTabs.len: t.fIndex = t.fTabs.high
  t.fFirst = min(t.fFirst, max(t.fTabs.high, 0))
  t.invalidate()
  if i == old and t.fIndex >= 0 and t.onChange != nil: t.onChange(t)

proc addTab*(t: TabControl, caption: string): int {.discardable.} =
  t.fTabs.add caption
  t.fMetricsDirty = true
  if t.fIndex < 0: t.fIndex = 0
  t.invalidate()
  t.fTabs.high

proc initTabControl*(t: TabControl, owner: Component = nil) =
  t.initTabBase(owner)

proc newTabControl*(parent: Container = nil, tabs: seq[string] = @[],
                    left = 0'f32, top = 0'f32, width = -1'f32,
                    height = -1'f32): TabControl {.discardable.} =
  new result
  result.initTabControl(parent)
  result.tabs = tabs
  result.placeControl(parent, left, top, width, height)

# ---------------------------------------------------------------- TabSheet

method inheritedColor*(s: TabSheet): Color =
  if s.parent != nil: s.parent.color else: s.theme.surface

method paint*(s: TabSheet, c: Canvas) =
  if s.ownColor: c.fillRect(s.clientRect, s.color)
  procCall paint(Control(s), c)

proc `caption=`*(s: TabSheet, v: string) =
  ## Sets the tab text (and repaints the strip of the owning PageControl).
  `caption=`(Control(s), v)
  if s.parent != nil:
    if s.parent of PageControl: PageControl(s.parent).fMetricsDirty = true
    s.parent.invalidate()

func caption*(s: TabSheet): string = Control(s).caption

func tabVisible*(s: TabSheet): bool = not s.fTabHidden

proc initTabSheet*(s: TabSheet, owner: Component = nil) =
  s.initContainer(owner)
  s.setBounds(0, 0, 200, 100)
  s.designSet = false      # sized by the page control: its first layout is the design
  s.align = alClient

# -------------------------------------------------------------- PageControl

proc sheets*(p: PageControl): seq[TabSheet] =
  for c in p.children:
    if c of TabSheet: result.add TabSheet(c)

method tabCount*(p: PageControl): int =
  for c in p.children:
    if c of TabSheet: inc result

proc sheetAt(p: PageControl, i: int): TabSheet =
  ## The `i`-th sheet (no allocation); nil when out of range.
  if i < 0: return nil
  var k = 0
  for c in p.children:
    if c of TabSheet:
      if k == i: return TabSheet(c)
      inc k

proc sheetIndex(p: PageControl, s: TabSheet): int =
  result = -1
  if s == nil: return
  var k = 0
  for c in p.children:
    if c of TabSheet:
      if c == Control(s): return k
      inc k

method sheetTabText*(p: PageControl, s: TabSheet): string {.base.} =
  ## The text shown on the tab of `s`: its caption. Override this, not
  ## `tabText`, to change what a PageControl's tabs show: the strip measures
  ## and draws every tab through it. An override builds on `s.caption`
  ## (`procCall` of a base method re-dispatches).
  s.caption

method tabText*(p: PageControl, i: int): string =
  let s = p.sheetAt(i)
  if s == nil: "" else: p.sheetTabText(s)

method removeTab*(p: PageControl, i: int) =
  let s = p.sheetAt(i)
  if s != nil: s.free()

method tabEnabled*(p: PageControl, i: int): bool =
  let s = p.sheetAt(i)
  s != nil and s.enabled

method tabVisible*(p: PageControl, i: int): bool =
  let s = p.sheetAt(i)
  s != nil and s.tabVisible

method collectTabs*(p: PageControl, texts: var seq[string], shown: var seq[bool]) =
  for c in p.children:
    if c of TabSheet:
      texts.add p.sheetTabText(TabSheet(c))
      shown.add TabSheet(c).tabVisible

proc showActive(p: PageControl) =
  var k = 0
  for c in p.children:
    if c of TabSheet:
      let want = k == p.fIndex
      if c.visible != want: c.visible = want
      inc k

proc syncPages(p: PageControl) =
  ## Keeps the index on the active sheet (tracked by identity) and shows only
  ## that sheet. When the active sheet itself is gone its neighbour becomes
  ## active and `onChange` fires.
  if p.fSyncing: return
  p.fSyncing = true
  var lost = false
  try:
    let n = p.tabCount
    if n == 0:
      lost = p.fActive != nil
      p.fIndex = -1
      p.fActive = nil
    else:
      let at = p.sheetIndex(p.fActive)
      if at >= 0: p.fIndex = at
      else:
        lost = p.fActive != nil
        p.fIndex = clamp(p.fIndex, 0, n - 1)
        p.fActive = p.sheetAt(p.fIndex)
    p.showActive()
  finally:
    p.fSyncing = false
  if lost:
    p.fEnsure = true
    p.invalidate()
    p.tabChanged(-1, p.fIndex)
    if p.onChange != nil: p.onChange(p)

func activePageIndex*(p: PageControl): int = p.fIndex
proc `activePageIndex=`*(p: PageControl, v: int) = p.tabIndex = v

proc activePage*(p: PageControl): TabSheet =
  p.sheetAt(p.fIndex)
proc `activePage=`*(p: PageControl, s: TabSheet) =
  let i = p.sheetIndex(s)
  if i >= 0: p.tabIndex = i

proc pageCount*(p: PageControl): int = p.tabCount

method tabChanged*(p: PageControl, oldIndex, newIndex: int) =
  var hadFocus = false
  let h = p.host
  var ui: UiRoot
  if h of UiRoot:
    ui = UiRoot(h)
    let f = ui.focusedControl
    let os = p.sheetAt(oldIndex)
    hadFocus = f != nil and os != nil and
               (f == Control(os) or os.isAncestorOf(f))
  p.fActive = p.sheetAt(newIndex)
  p.syncPages()
  if hadFocus:
    let ns = p.sheetAt(newIndex)
    if ns != nil:
      let stops = tabStops(ns)
      if stops.len > 0: ui.focusControl(stops[0])
      else: ui.focusControl(p)

proc `tabVisible=`*(s: TabSheet, v: bool) =
  ## Shows / hides the sheet's tab (the sheet itself stays a page; hiding the
  ## active sheet's tab selects the next selectable sheet).
  if v == not s.fTabHidden: return
  s.fTabHidden = not v
  if s.parent != nil:
    s.parent.invalidate()
    if s.parent of PageControl:
      let p = PageControl(s.parent)
      p.fMetricsDirty = true
      if not v and p.fActive == s:
        var n = p.nextSelectable(p.fIndex, 1)
        if n < 0: n = p.nextSelectable(p.fIndex, -1)
        if n >= 0: p.tabIndex = n

proc pageKey(ui: UiRoot, key: var Key, shift: ShiftState) =
  var c = ui.focusedControl
  while c != nil and not (c of PageControl): c = Control(c.parent)
  if c != nil: discard PageControl(c).handleTabKey(key, shift)

proc ensureHook(p: PageControl) =
  ## Registers the shared "pages" handler in the key-handler chain of the
  ## form/host the page control is in (once per UiRoot).
  let h = p.host
  if not (h of UiRoot): return
  let ui = UiRoot(h)
  if ui.hasKeyHandler("pages"): return
  ui.addKeyHandler("pages", proc(key: var Key, shift: ShiftState) =
    pageKey(ui, key, shift))

method childBoundsChanged*(p: PageControl, child: Control) =
  procCall childBoundsChanged(Container(p), child)
  if child of TabSheet:
    p.fMetricsDirty = true
    p.syncPages()   # a sheet was added / removed
    p.fEnsure = true    # the strip scroll may now be past the last tab
    p.invalidate()

method visibilityChanged*(p: PageControl) =
  p.ensureHook()                    # fires when inserted into a form/host tree

method paint*(p: PageControl, c: Canvas) =
  p.ensureHook()
  procCall paint(TabBase(p), c)

proc initPageControl*(p: PageControl, owner: Component = nil) =
  p.initTabBase(owner)
  p.fFillBody = true

proc newPageControl*(parent: Container = nil, left = 0'f32, top = 0'f32,
                     width = -1'f32, height = -1'f32): PageControl {.discardable.} =
  new result
  result.initPageControl(parent)
  result.placeControl(parent, left, top, width, height)

proc newTabSheet*(pc: PageControl, caption = ""): TabSheet {.discardable.} =
  ## Adds a page. The first one becomes active; the others start hidden.
  new result
  result.initTabSheet(pc)
  result.caption = caption
  if pc != nil:
    pc.insertControl result
    if pc.fIndex < 0: pc.fIndex = 0
    pc.syncPages()
    pc.invalidate()

proc newTabSheet*(parent: Container, caption = ""): TabSheet {.discardable.} =
  ## Container-typed overload (the `form` macro creates children through it):
  ## a PageControl parent gets a page like above, any other parent a plain sheet.
  if parent of PageControl:
    result = newTabSheet(PageControl(parent), caption)
  else:
    new result
    result.initTabSheet(parent)
    result.caption = caption
    if parent != nil: parent.insertControl result
