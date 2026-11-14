## `PageControl` + `TabSheet` and `TabControl` (VCL TPageControl / TTabControl).
##
## Both draw the same tab strip (`TabBase`): tabs across the top, the selected
## one joined to the body below. `tabIndex` is the selected tab; changing it
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
## Mnemonics: `&` in a sheet caption is underlined while Alt is held;
## Alt+letter selects that page (when the sheet is enabled).
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
## the new sheet (or to the strip when it has none). `activePage`,
## `activePageIndex` and `tabIndex` are the same selection.
##
## TabControl: only tabs (`tabs`, `tabIndex`); the body is a plain frame that
## children can be placed in, below the strip.

import ../core/[input, form]
import ./common

type
  TabChangingEvent* = proc(sender: Control, allowChange: var bool)

  TabBase* = ref object of Container
    fIndex: int
    fFirst: int                 # first tab shown (strip scroll position)
    fHotTab: int                # -1 none, tab index, or -2/-3 scroll arrows
    fFillBody: bool
    fEnsure: bool               # scroll the selected tab into view on next paint
    onChange*: NotifyEvent
    onChanging*: TabChangingEvent

  TabControl* = ref object of TabBase
    fTabs: seq[string]

  TabSheet* = ref object of Container

  PageControl* = ref object of TabBase

const
  TabPad = 14'f32
  MinTabW = 44'f32
  ArrowW = 20'f32
  StripLeft = 2'f32

# --------------------------------------------------------------- base API

method tabCount*(t: TabBase): int {.base.} = 0
method tabText*(t: TabBase, i: int): string {.base.} = ""
method tabChanged*(t: TabBase, oldIndex, newIndex: int) {.base.} =
  ## Called after the index changed (before `onChange`).
  discard

func tabIndex*(t: TabBase): int = t.fIndex

proc stripHeight*(t: TabBase): float32 =
  ## Height of the tab strip (derived from the theme, no window needed).
  t.theme.controlHeight

proc tabWidth(t: TabBase, i: int): float32 =
  max(t.textWidth(displayText(t.tabText(i)), t.font) + 2 * TabPad, MinTabW)

proc totalTabsWidth(t: TabBase): float32 =
  for i in 0 ..< t.tabCount: result += t.tabWidth(i)

proc overflowing*(t: TabBase): bool =
  StripLeft + t.totalTabsWidth > t.width - 2

proc stripRight(t: TabBase): float32 =
  ## Right edge available to tabs.
  t.width - 2 - (if t.overflowing: 2 * ArrowW else: 0'f32)

proc tabRect*(t: TabBase, i: int): RectF =
  ## Tab `i` in client coordinates; empty when scrolled out to the left.
  if i < t.fFirst or i >= t.tabCount: return rectF(0, 0, 0, 0)
  var x = StripLeft
  for k in t.fFirst ..< i: x += t.tabWidth(k)
  let h = t.stripHeight
  if i == t.fIndex: rectF(x, 1, t.tabWidth(i), h - 1)
  else: rectF(x, 3, t.tabWidth(i), h - 3)

proc arrowRect(t: TabBase, left: bool): RectF =
  let h = t.stripHeight
  let x = t.width - 2 * ArrowW - 2 + (if left: 0'f32 else: ArrowW)
  rectF(x, 3, ArrowW, h - 5)

proc tabAt*(t: TabBase, x, y: float32): int =
  ## Tab under the point, -1 none, -2 / -3 the left / right scroll arrow.
  if y < 0 or y >= t.stripHeight: return -1
  if t.overflowing:
    if t.arrowRect(true).contains(pointF(x, y)): return -2
    if t.arrowRect(false).contains(pointF(x, y)): return -3
  if x >= t.stripRight: return -1
  for i in t.fFirst ..< t.tabCount:
    let r = t.tabRect(i)
    if x >= r.x and x < r.right: return i
    if r.x > t.stripRight: break
  -1

proc ensureVisible(t: TabBase, i: int) =
  if i < 0 or i >= t.tabCount: return
  if not t.overflowing:
    t.fFirst = 0
    return
  if i < t.fFirst: t.fFirst = i
  while t.fFirst < i and t.tabRect(i).right > t.stripRight:
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

proc cycle*(t: TabBase, dir: int) =
  ## Next / previous tab, wrapping.
  let n = t.tabCount
  if n > 1: t.tabIndex = (t.fIndex + dir + n) mod n

func firstVisibleTab*(t: TabBase): int = t.fFirst

# ---------------------------------------------------------- base behaviour

method canFocus*(t: TabBase): bool = t.isVisible and t.isEnabled

method doMouseDown*(t: TabBase, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    let i = t.tabAt(x, y)
    if i >= 0: t.tabIndex = i
    elif i == -2 and t.fFirst > 0:
      dec t.fFirst
      t.invalidate()
    elif i == -3 and t.tabRect(t.tabCount - 1).right > t.stripRight:
      inc t.fFirst
      t.invalidate()
  procCall doMouseDown(Control(t), button, shift, x, y)

method doMouseMove*(t: TabBase, shift: ShiftState, x, y: float32) =
  let h = t.tabAt(x, y)
  if h != t.fHotTab:
    t.fHotTab = h
    t.invalidate()
  procCall doMouseMove(Control(t), shift, x, y)

method doMouseLeave*(t: TabBase) =
  t.fHotTab = -1
  t.invalidate()
  procCall doMouseLeave(Control(t))

proc handleTabKey(t: TabBase, key: var Key, shift: ShiftState): bool =
  ## Shortcuts shared by the focused strip and the form-level hook.
  if ssAlt in shift or ssSuper in shift: return false
  if ssCtrl in shift:
    if key == keyTab: t.cycle(if ssShift in shift: -1 else: 1)
    elif key == keyPageDown and ssShift notin shift: t.cycle(1)
    elif key == keyPageUp and ssShift notin shift: t.cycle(-1)
    else: return false
    key = Key(0)
    return true
  false

method tabEnabled*(t: TabBase, i: int): bool {.base.} = true

method activateMnemonic*(t: TabBase, ch: char): bool =
  ## Alt+letter selects the tab whose caption has that mnemonic.
  for i in 0 ..< t.tabCount:
    if t.tabEnabled(i) and mnemonicOf(t.tabText(i)) == ch:
      t.tabIndex = i
      return true

method doKeyDown*(t: TabBase, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(t), key, shift)
  if key == Key(0): return
  if t.handleTabKey(key, shift): return
  if shift * {ssCtrl, ssAlt, ssSuper} != {}: return
  var handled = true
  if key == keyLeft: t.tabIndex = t.fIndex - 1
  elif key == keyRight: t.tabIndex = t.fIndex + 1
  elif key == keyHome: t.tabIndex = 0
  elif key == keyEnd: t.tabIndex = t.tabCount - 1
  else: handled = false
  if handled: key = Key(0)

method inheritedColor*(t: TabBase): Color =
  if t.fFillBody: t.theme.surface else: procCall inheritedColor(Control(t))

method paint*(t: TabBase, c: Canvas) =
  let th = t.theme
  let en = t.isEnabled
  let h = t.stripHeight
  let w = t.width
  if t.fEnsure:
    t.fEnsure = false
    t.ensureVisible(t.fIndex)
  # body
  let body = rectF(0, h - 1, w, max(t.height - h + 1, 0))
  if t.fFillBody: c.fillRoundRect(body, th.radius, th.surface)
  c.strokeRoundRect(body, th.radius, th.border, th.borderWidth)
  let right = t.stripRight
  c.pushClip(rectF(0, 0, right + 2, h))
  var selR = rectF(0, 0, 0, 0)
  for i in t.fFirst ..< t.tabCount:
    let r = t.tabRect(i)
    if r.x > right: break
    if i == t.fIndex:
      selR = r
      continue
    c.pushClip(rectF(r.x - 1, 0, r.w + 2, h))
    let fill = if t.fHotTab == i and en: th.hover else: th.surfaceAlt
    c.fillRoundRect(rectF(r.x, r.y, r.w, r.h + 6), th.radius, fill)
    c.strokeRoundRect(rectF(r.x, r.y, r.w, r.h + 6), th.radius, th.border, 1)
    c.popClip()
    c.drawMnemonic(t.tabText(i), t.font, rectF(r.x + 4, r.y, r.w - 8, r.h - 1),
                   if en: th.textMuted else: th.textDisabled, t.altHeld,
                   taCenter, vaCenter)
  if selR.w > 0:
    c.pushClip(rectF(selR.x - 1, 0, selR.w + 2, h))
    let full = rectF(selR.x, selR.y, selR.w, selR.h + 6)
    c.fillRoundRect(full, th.radius, if t.fFillBody: th.surface else: th.window)
    c.strokeRoundRect(full, th.radius, th.borderStrong, 1)
    c.popClip()
    c.drawMnemonic(t.tabText(t.fIndex), t.font,
                   rectF(selR.x + 4, selR.y, selR.w - 8, selR.h),
                   if en: th.text else: th.textDisabled, t.altHeld, taCenter, vaCenter)
    if t.focused:
      drawFocusRing(c, rectF(selR.x, selR.y, selR.w, selR.h), th)
  c.popClip()
  if t.overflowing:
    for left in [true, false]:
      let r = t.arrowRect(left)
      let canGo =
        if left: t.fFirst > 0
        else: t.tabRect(t.tabCount - 1).right > right
      let hot = t.fHotTab == (if left: -2 else: -3) and canGo and en
      c.fillRoundRect(r, th.radius, if hot: th.hover else: th.surface)
      c.strokeRoundRect(r, th.radius, th.border, 1)
      c.drawArrow(pointF(r.x + r.w / 2, r.y + r.h / 2), 3.5,
                  if left: adLeft else: adRight,
                  if canGo and en: th.text else: th.textDisabled)
  procCall paint(Control(t), c)

method padding*(t: TabBase): Spacing =
  spacing(1, t.stripHeight, 1, 1)

proc initTabBase(t: TabBase, owner: Component) =
  t.initContainer(owner)
  t.fIndex = -1
  t.fHotTab = -1
  t.tabStop = true
  t.setBounds(0, 0, 289, 193)

# -------------------------------------------------------------- TabControl

method tabCount*(t: TabControl): int = t.fTabs.len
method tabText*(t: TabControl, i: int): string = t.fTabs[i]

func tabs*(t: TabControl): seq[string] = t.fTabs
proc `tabs=`*(t: TabControl, v: seq[string]) =
  t.fTabs = v
  if t.fIndex >= v.len: t.fIndex = v.high
  if t.fIndex < 0 and v.len > 0: t.fIndex = 0
  t.fFirst = 0
  t.invalidate()

proc addTab*(t: TabControl, caption: string): int {.discardable.} =
  t.fTabs.add caption
  if t.fIndex < 0: t.fIndex = 0
  t.invalidate()
  t.fTabs.high

proc initTabControl*(t: TabControl, owner: Component = nil) =
  t.initTabBase(owner)

proc newTabControl*(parent: Container = nil, tabs: seq[string] = @[],
                    left = 0'f32, top = 0'f32, width = -1'f32,
                    height = -1'f32): TabControl =
  new result
  result.initTabControl(parent)
  result.tabs = tabs
  result.placeControl(parent, left, top, width, height)

# ---------------------------------------------------------------- TabSheet

method inheritedColor*(s: TabSheet): Color = s.theme.surface

proc `caption=`*(s: TabSheet, v: string) =
  ## Sets the tab text (and repaints the strip of the owning PageControl).
  `caption=`(Control(s), v)
  if s.parent != nil: s.parent.invalidate()

func caption*(s: TabSheet): string = Control(s).caption

proc initTabSheet*(s: TabSheet, owner: Component = nil) =
  s.initContainer(owner)
  s.setBounds(0, 0, 200, 100)
  s.align = alClient

# -------------------------------------------------------------- PageControl

proc sheets*(p: PageControl): seq[TabSheet] =
  for c in p.children:
    if c of TabSheet: result.add TabSheet(c)

method tabCount*(p: PageControl): int =
  for c in p.children:
    if c of TabSheet: inc result

method tabText*(p: PageControl, i: int): string =
  p.sheets[i].caption

method tabEnabled*(p: PageControl, i: int): bool =
  p.sheets[i].enabled

proc syncPages(p: PageControl) =
  ## Keeps the index valid and shows only the active sheet.
  let sh = p.sheets
  if sh.len == 0:
    p.fIndex = -1
    return
  if p.fIndex < 0 or p.fIndex >= sh.len: p.fIndex = clamp(p.fIndex, 0, sh.high)
  for i, s in sh:
    if s.visible != (i == p.fIndex): s.visible = i == p.fIndex

func activePageIndex*(p: PageControl): int = p.fIndex
proc `activePageIndex=`*(p: PageControl, v: int) = p.tabIndex = v

proc activePage*(p: PageControl): TabSheet =
  let sh = p.sheets
  if p.fIndex >= 0 and p.fIndex < sh.len: sh[p.fIndex] else: nil
proc `activePage=`*(p: PageControl, s: TabSheet) =
  let i = p.sheets.find(s)
  if i >= 0: p.tabIndex = i

proc pageCount*(p: PageControl): int = p.tabCount

method tabChanged*(p: PageControl, oldIndex, newIndex: int) =
  let sh = p.sheets
  var hadFocus = false
  let h = p.host
  var ui: UiRoot
  if h of UiRoot:
    ui = UiRoot(h)
    let f = ui.focusedControl
    hadFocus = f != nil and oldIndex >= 0 and oldIndex < sh.len and
               (f == Control(sh[oldIndex]) or sh[oldIndex].isAncestorOf(f))
  p.syncPages()
  if hadFocus and newIndex < sh.len:
    let stops = tabStops(sh[newIndex])
    if stops.len > 0: ui.focusControl(stops[0])
    else: ui.focusControl(p)

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

method visibilityChanged*(p: PageControl) =
  p.ensureHook()                    # fires when inserted into a form/host tree

method padding*(p: PageControl): Spacing =
  p.syncPages()
  procCall padding(TabBase(p))

method paint*(p: PageControl, c: Canvas) =
  p.ensureHook()
  p.syncPages()
  procCall paint(TabBase(p), c)

proc initPageControl*(p: PageControl, owner: Component = nil) =
  p.initTabBase(owner)
  p.fFillBody = true

proc newPageControl*(parent: Container = nil, left = 0'f32, top = 0'f32,
                     width = -1'f32, height = -1'f32): PageControl =
  new result
  result.initPageControl(parent)
  result.placeControl(parent, left, top, width, height)

proc newTabSheet*(pc: PageControl, caption = ""): TabSheet =
  ## Adds a page. The first one becomes active; the others start hidden.
  new result
  result.initTabSheet(pc)
  result.caption = caption
  if pc != nil:
    pc.insertControl result
    if pc.fIndex < 0: pc.fIndex = 0
    pc.syncPages()
    pc.invalidate()
