## `ListBox` (VCL TListBox): a scrolling list of one-line items.
##
## Items
## -----
## `items` is a view onto the list: `lb.items.add "x"`, `insert`, `delete`,
## `clear`, `lb.items[i]`, `lb.items.len`, `for s in lb.items`, `lb.items = @[...]`;
## `lb.add`, `lb.insert`, `lb.delete`, `lb.clear`, `lb[i]`, `lb.count` are
## shortcuts. `sorted` keeps the list ordered (case-insensitive; `add` and
## `insert` then place the item by value, `insert`'s index is ignored).
##
## Virtual mode: assign `onData(sender, index): string` and set `count`. Items
## are then never stored; the text of an item is fetched only when it is painted
## or searched, so only the visible rows are touched (1,000,000 rows are fine).
## `add`/`insert`/`delete`/`items` and `sorted` do nothing in virtual mode;
## selection works as usual (a selection of N rows costs N set entries).
## Pixel positions are float32: beyond ~700,000 rows the scroll position is
## quantised to 2 px, which is invisible for row navigation.
##
## Selection
## ---------
## `itemIndex` is the focused row (-1 = none). Single mode (default): the focused
## row is the selection. `multiSelect`: with `extendedSelect` (default) a click
## selects one row, Ctrl+click toggles, Shift+click (and Shift+Up/Down/PgUp/
## PgDn/Home/End) selects the range from the anchor, Ctrl+arrows move the focus
## only, Space toggles the focused row, Ctrl+A selects all; without
## `extendedSelect` a click or Space toggles and arrows only move the focus.
## `selected(i)`, `setSelected`, `selCount`, `selectedIndices`, `selectAll`,
## `clearSelection`. Dragging with the left button selects like arrows do.
## Assigning `itemIndex` selects exactly that row and scrolls it into view.
## Deleting the focused row sets `itemIndex` to -1.
## `onChange` fires when `itemIndex` or the selection changes (user or code);
## `onClick`, `onDblClick` are the usual mouse events.
##
## Display
## -------
## `itemHeight` 0 = automatic (font line height + 8). Variable row heights
## (`onMeasureItem`) are NOT supported; all rows have one height. Scrolling is
## smooth (pixels); `topIndex` is the first (possibly partial) row. The vertical
## bar is automatic; `horizontalExtent` (pixels, 0 = none) is the content width
## for a horizontal bar. `style = lbOwnerDraw` calls
## `onDrawItem(sender, canvas, index, rect, state)` per visible row after the
## row background (selection / hover) is drawn; `rect` is in the list's client
## coordinates; `lb.itemTextColor(state)` and `lb.drawItemText` help with
## text. Selection uses `selection` when focused and `selectionInactive`
## otherwise; the hovered row is highlighted; disabled lists use disabled text.
##
## Keys: Up/Down/Home/End/PgUp/PgDn (PgDn moves to the last fully visible row,
## and when already there by a page minus one row), type-ahead (typed letters
## jump to the next item starting with the typed prefix, reset after
## `typeAheadTimeout` ms, 1000 by default).

import std/[sets, monotimes, algorithm, sequtils, strutils]
import ../graphics/context
import ./common, ./scrolling
export scrolling

type
  ListBoxStyle* = enum lbStandard, lbOwnerDraw

  ItemState* = enum isSelected, isFocused, isHot, isDisabled
  ItemStates* = set[ItemState]

  DrawItemEvent* = proc(sender: Control, canvas: Canvas, index: int,
                        rect: RectF, state: ItemStates)
  DataEvent* = proc(sender: Control, index: int): string

  ListBox* = ref object of ScrollingControl
    fItems: seq[string]
    fCount: int                  # virtual item count
    fSel: HashSet[int]
    fIndex, fAnchor, fHot: int
    fVer: int                    # bumped on every selection/focus change
    fMulti, fExtended, fSorted, fDragging, fMouseIn, fShowFocusRect: bool
    fStyle: ListBoxStyle
    fItemHeight, fExtent, fLastIh: float32
    fMouseY: float32
    fTypeBuf: string
    fTypeTime: int64
    typeAheadTimeout*: int       ## ms
    onChange*: NotifyEvent
    onData*: DataEvent
    onDrawItem*: DrawItemEvent

  ItemList* = object
    ## `lb.items`: add/insert/delete/clear/[]/len on a ListBox's strings.
    lb: ListBox

const ItemPadding = 8'f32

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

# ----------------------------------------------------------------- basics

func isVirtual*(lb: ListBox): bool = lb.onData != nil

func count*(lb: ListBox): int =
  if lb.onData != nil: lb.fCount else: lb.fItems.len

func itemIndex*(lb: ListBox): int = lb.fIndex
func multiSelect*(lb: ListBox): bool = lb.fMulti
func extendedSelect*(lb: ListBox): bool = lb.fExtended
func sorted*(lb: ListBox): bool = lb.fSorted
func style*(lb: ListBox): ListBoxStyle = lb.fStyle
func horizontalExtent*(lb: ListBox): float32 = lb.fExtent
func showFocusRect*(lb: ListBox): bool = lb.fShowFocusRect
  ## Whether a focused list draws the accent focus ring (default true). Lists
  ## embedded in other controls (a combo's drop-down) turn it off.
proc `showFocusRect=`*(lb: ListBox, v: bool) =
  if v != lb.fShowFocusRect:
    lb.fShowFocusRect = v
    lb.invalidate()

proc itemText*(lb: ListBox, i: int): string =
  ## Text of item `i` ("" when out of range).
  if i < 0 or i >= lb.count: return ""
  if lb.onData != nil: lb.onData(lb, i) else: lb.fItems[i]

proc itemHeight*(lb: ListBox): float32 =
  ## Row height in logical pixels (the automatic one when not set).
  if lb.fItemHeight > 0: return lb.fItemHeight
  if lb.canMeasure:
    max(ceil(lb.renderCtx.fontMetrics(lb.font).lineHeight) + 8, 16)
  else: 22

method scrollLineSize*(lb: ListBox): SizeF = sizeF(24, lb.itemHeight)

proc refresh(lb: ListBox) =
  let ih = lb.itemHeight
  let cs = sizeF(lb.fExtent, float32(lb.count) * ih)
  if lb.fLastIh > 0 and ih != lb.fLastIh:
    # row height changed (font, first measurement): keep the same rows in view
    let old = lb.fLastIh
    let y = float32(float64(lb.scrollPos.y) / float64(old) * float64(ih))
    lb.fLastIh = ih
    if ih < old: lb.scrollTo(lb.scrollPos.x, y)
    lb.setContentSize(cs.w, cs.h)
    if ih >= old: lb.scrollTo(lb.scrollPos.x, y)
  else:
    lb.fLastIh = ih
    lb.setContentSize(cs.w, cs.h)
  lb.invalidate()

method beforeLayout*(lb: ListBox) =
  lb.refresh()
  procCall beforeLayout(ScrollingControl(lb))

proc `itemHeight=`*(lb: ListBox, v: float32) =
  lb.fItemHeight = max(v, 0)
  lb.refresh()

proc `horizontalExtent=`*(lb: ListBox, v: float32) =
  lb.fExtent = max(v, 0)
  lb.refresh()

proc notify(lb: ListBox, ver: int) =
  ## Fires `onChange` once when the selection state changed since `ver`.
  if lb.fVer != ver:
    lb.invalidate()
    if lb.onChange != nil: lb.onChange(lb)

proc touch(lb: ListBox) = inc lb.fVer

proc selectOnly(lb: ListBox, i: int) =
  if lb.fSel.len == 1 and i in lb.fSel: return
  lb.fSel.clear()
  if i >= 0: lb.fSel.incl i
  lb.touch()

proc selectRange(lb: ListBox, a, b: int) =
  var s = initHashSet[int]()
  for j in min(a, b) .. max(a, b): s.incl j
  if s == lb.fSel: return
  lb.fSel = s
  lb.touch()

proc setFocusRow(lb: ListBox, i: int) =
  if i != lb.fIndex:
    lb.fIndex = i
    lb.touch()

# ------------------------------------------------------------------ geometry

func rowTop(lb: ListBox, i: int, ih: float32): float32 =
  ## Client y of row `i`.
  lb.viewport.y + float32(float64(i) * float64(ih) - float64(lb.scrollPos.y))

proc itemRect*(lb: ListBox, i: int): RectF =
  ## Row `i` in client coordinates, as currently scrolled.
  let ih = lb.itemHeight
  let vp = lb.viewport
  rectF(vp.x - lb.scrollPos.x, lb.rowTop(i, ih), max(vp.w, lb.contentSize.w), ih)

proc indexAt*(lb: ListBox, p: PointF): int =
  ## Row under `p` (client coordinates); -1 outside the rows.
  let vp = lb.viewport
  if not vp.contains(p): return -1
  let ih = float64(lb.itemHeight)
  let i = int(floor((float64(p.y - vp.y) + float64(lb.scrollPos.y)) / ih))
  if i < 0 or i >= lb.count: -1 else: i

proc topIndex*(lb: ListBox): int =
  ## First (possibly partially) visible row.
  int(floor(float64(lb.scrollPos.y) / float64(lb.itemHeight)))
proc `topIndex=`*(lb: ListBox, v: int) =
  lb.scrollTo(lb.scrollPos.x, float32(max(v, 0)) * lb.itemHeight)

proc firstFullRow(lb: ListBox): int =
  int(ceil(float64(lb.scrollPos.y) / float64(lb.itemHeight)))
proc lastFullRow(lb: ListBox): int =
  min(int(floor((float64(lb.scrollPos.y) + float64(lb.viewport.h)) /
                float64(lb.itemHeight))) - 1, lb.count - 1)

proc makeVisible*(lb: ListBox, i: int) =
  ## Scrolls vertically the minimum distance that shows row `i` completely.
  if i < 0 or i >= lb.count: return
  let ih = lb.itemHeight
  lb.scrollIntoView(rectF(lb.scrollPos.x, float32(i) * ih, 1, ih))

proc updateHot(lb: ListBox) =
  let h = if lb.fMouseIn and lb.isEnabled:
            lb.indexAt(pointF(lb.viewport.x + 1, lb.fMouseY))
          else: -1
  if h != lb.fHot:
    lb.fHot = h
    lb.invalidate()

method contentScrolled*(lb: ListBox) =
  procCall contentScrolled(ScrollingControl(lb))
  lb.updateHot()

# --------------------------------------------------------------- selection

func selected*(lb: ListBox, i: int): bool = i in lb.fSel
func selCount*(lb: ListBox): int = lb.fSel.len

proc selectedIndices*(lb: ListBox): seq[int] =
  for i in lb.fSel: result.add i
  result.sort()

proc `itemIndex=`*(lb: ListBox, i: int) =
  let v = lb.fVer
  let n = if i < 0 or i >= lb.count: -1 else: i
  lb.selectOnly(n)
  lb.setFocusRow(n)
  lb.fAnchor = n
  lb.makeVisible(n)
  lb.notify(v)

proc setSelected*(lb: ListBox, i: int, v: bool) =
  ## Single mode: selecting moves `itemIndex`; clearing clears it.
  if i < 0 or i >= lb.count: return
  let ver = lb.fVer
  if not lb.fMulti:
    if v: lb.itemIndex = i
    elif i == lb.fIndex: lb.itemIndex = -1
    return
  if v == (i in lb.fSel): return
  if v: lb.fSel.incl i else: lb.fSel.excl i
  lb.touch()
  lb.notify(ver)

proc clearSelection*(lb: ListBox) =
  if lb.fSel.len == 0: return
  let v = lb.fVer
  lb.fSel.clear()
  lb.touch()
  lb.notify(v)

proc selectAll*(lb: ListBox) =
  ## Multi-select only.
  if not lb.fMulti or lb.count == 0: return
  let v = lb.fVer
  lb.selectRange(0, lb.count - 1)
  lb.notify(v)

proc `multiSelect=`*(lb: ListBox, v: bool) =
  if v == lb.fMulti: return
  lb.fMulti = v
  if not v and lb.fSel.len > 1: lb.selectOnly(lb.fIndex)
  lb.invalidate()

proc `extendedSelect=`*(lb: ListBox, v: bool) = lb.fExtended = v

proc `style=`*(lb: ListBox, v: ListBoxStyle) =
  lb.fStyle = v
  lb.invalidate()

# ------------------------------------------------------------------- items

proc shiftIndices(lb: ListBox, at, delta: int) =
  ## Indices >= `at` move by `delta` (selection, focus, anchor).
  var s = initHashSet[int]()
  for j in lb.fSel: s.incl(if j >= at: j + delta else: j)
  lb.fSel = s
  if lb.fIndex >= at: lb.fIndex += delta
  if lb.fAnchor >= at: lb.fAnchor += delta
  if lb.fHot >= at: lb.fHot = -1

proc upperBound(lb: ListBox, s: string): int =
  var lo = 0
  var hi = lb.fItems.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if cmpIgnoreCase(lb.fItems[mid], s) <= 0: lo = mid + 1 else: hi = mid
  lo

proc insert*(lb: ListBox, index: int, s: string) =
  ## Inserts at `index` (clamped); on a `sorted` list the index is ignored.
  if lb.isVirtual: return
  let i = if lb.fSorted: lb.upperBound(s)
          else: min(max(index, 0), lb.fItems.len)
  lb.shiftIndices(i, 1)
  lb.fItems.insert(s, i)
  lb.refresh()

proc add*(lb: ListBox, s: string) =
  if lb.isVirtual: return
  if lb.fSorted: lb.insert(0, s)
  else:
    lb.fItems.add s
    lb.refresh()

proc delete*(lb: ListBox, i: int) =
  if lb.isVirtual or i < 0 or i >= lb.fItems.len: return
  let v = lb.fVer
  let wasSel = i in lb.fSel
  lb.fSel.excl i
  lb.shiftIndices(i + 1, -1)
  if lb.fIndex == i: lb.fIndex = -1
  if lb.fAnchor == i: lb.fAnchor = -1
  lb.fItems.delete(i)
  if wasSel or lb.fIndex == -1: lb.touch()
  lb.refresh()
  lb.scrollBy(0, 0)         # re-clamp
  lb.notify(v)

proc clear*(lb: ListBox) =
  let v = lb.fVer
  let had = lb.fSel.len > 0 or lb.fIndex >= 0
  lb.fItems.setLen(0)
  lb.fCount = 0
  lb.fSel.clear()
  lb.fIndex = -1
  lb.fAnchor = -1
  lb.fHot = -1
  if had: lb.touch()
  lb.refresh()
  lb.scrollTo(0, 0)
  lb.notify(v)

proc `count=`*(lb: ListBox, n: int) =
  ## Virtual mode: the number of items (set `onData` too).
  lb.fCount = max(n, 0)
  if lb.onData != nil:
    let v = lb.fVer
    var changed = false
    for j in toSeq(lb.fSel):
      if j >= lb.fCount:
        lb.fSel.excl j
        changed = true
    if lb.fIndex >= lb.fCount:
      lb.fIndex = -1
      changed = true
    if lb.fAnchor >= lb.fCount: lb.fAnchor = -1
    if changed: lb.touch()
    lb.refresh()
    lb.scrollBy(0, 0)
    lb.notify(v)

proc `sorted=`*(lb: ListBox, v: bool) =
  if v == lb.fSorted: return
  lb.fSorted = v
  if not v or lb.isVirtual or lb.fItems.len == 0: return
  # stable sort, keeping selection / focus / anchor attached to their items
  var order = newSeq[int](lb.fItems.len)
  for i in 0 ..< order.len: order[i] = i
  let items = lb.fItems
  order.sort(proc(a, b: int): int =
    result = cmpIgnoreCase(items[a], items[b])
    if result == 0: result = cmp(a, b))
  var pos = newSeq[int](order.len)            # old index -> new index
  for n, o in order:
    pos[o] = n
    lb.fItems[n] = items[o]
  var s = initHashSet[int]()
  for j in lb.fSel: s.incl pos[j]
  lb.fSel = s
  if lb.fIndex >= 0: lb.fIndex = pos[lb.fIndex]
  if lb.fAnchor >= 0: lb.fAnchor = pos[lb.fAnchor]
  lb.invalidate()

func items*(lb: ListBox): ItemList = ItemList(lb: lb)
proc len*(l: ItemList): int = l.lb.count
proc count*(l: ItemList): int = l.lb.count
proc add*(l: ItemList, s: string) = l.lb.add s
proc insert*(l: ItemList, i: int, s: string) = l.lb.insert(i, s)
proc delete*(l: ItemList, i: int) = l.lb.delete i
proc clear*(l: ItemList) = l.lb.clear()
proc `[]`*(l: ItemList, i: int): string = l.lb.itemText(i)
proc `[]=`*(l: ItemList, i: int, s: string) =
  if l.lb.isVirtual or i < 0 or i >= l.lb.fItems.len: return
  l.lb.fItems[i] = s
  l.lb.invalidate()
proc indexOf*(l: ItemList, s: string): int =
  for i in 0 ..< l.lb.count:
    if l.lb.itemText(i) == s: return i
  -1
iterator items*(l: ItemList): string =
  for i in 0 ..< l.lb.count: yield l.lb.itemText(i)

proc `items=`*(lb: ListBox, v: openArray[string]) =
  ## Replaces all items.
  lb.clear()
  if lb.isVirtual: return
  if lb.fSorted:
    for s in v: lb.add s
  else:
    for s in v: lb.fItems.add s
    lb.refresh()

proc `[]`*(lb: ListBox, i: int): string = lb.itemText(i)
proc `[]=`*(lb: ListBox, i: int, s: string) = lb.items[i] = s

# ---------------------------------------------------------------- user input

proc applyClick(lb: ListBox, i: int, shift: ShiftState) =
  if lb.fMulti:
    if lb.fExtended:
      if ssShift in shift and lb.fAnchor >= 0:
        lb.selectRange(lb.fAnchor, i)
      elif ssCtrl in shift:
        if i in lb.fSel: lb.fSel.excl i else: lb.fSel.incl i
        lb.touch()
        lb.fAnchor = i
      else:
        lb.selectOnly(i)
        lb.fAnchor = i
    else:
      if i in lb.fSel: lb.fSel.excl i else: lb.fSel.incl i
      lb.touch()
      lb.fAnchor = i
  else:
    lb.selectOnly(i)
    lb.fAnchor = i
  lb.setFocusRow(i)

method canFocus*(lb: ListBox): bool = lb.isVisible and lb.isEnabled

method doMouseEnter*(lb: ListBox) =
  lb.fMouseIn = true
  procCall doMouseEnter(Control(lb))

method doMouseLeave*(lb: ListBox) =
  lb.fMouseIn = false
  lb.updateHot()
  procCall doMouseLeave(Control(lb))

method doMouseDown*(lb: ListBox, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    let i = lb.indexAt(pointF(x, y))
    if i >= 0:
      let v = lb.fVer
      lb.applyClick(i, shift)
      lb.fDragging = not lb.fMulti or lb.fExtended
      lb.makeVisible(i)
      lb.notify(v)
  procCall doMouseDown(Control(lb), button, shift, x, y)

method doMouseMove*(lb: ListBox, shift: ShiftState, x, y: float32) =
  lb.fMouseIn = true
  lb.fMouseY = y
  if lb.fDragging and ssLeft in shift and lb.count > 0:
    let vp = lb.viewport
    let cy = min(max(y, vp.y), vp.bottom - 1)
    var i = int(floor((float64(cy - vp.y) + float64(lb.scrollPos.y)) /
                      float64(lb.itemHeight)))
    i = min(max(i, 0), lb.count - 1)
    if y < vp.y: i = max(lb.topIndex, 0)
    if i != lb.fIndex:
      let v = lb.fVer
      if lb.fMulti: lb.selectRange(max(lb.fAnchor, 0), i)
      else: lb.selectOnly(i)
      lb.setFocusRow(i)
      lb.makeVisible(i)
      lb.notify(v)
  elif lb.fDragging and ssLeft notin shift:
    lb.fDragging = false
  lb.updateHot()
  procCall doMouseMove(Control(lb), shift, x, y)

method doMouseUp*(lb: ListBox, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft: lb.fDragging = false
  procCall doMouseUp(Control(lb), button, shift, x, y)

proc moveFocus(lb: ListBox, target: int, shift: ShiftState) =
  ## Keyboard navigation to row `target` (already clamped).
  let v = lb.fVer
  if lb.fMulti:
    if lb.fExtended and ssShift in shift:
      if lb.fAnchor < 0: lb.fAnchor = max(lb.fIndex, 0)
      lb.selectRange(lb.fAnchor, target)
    elif lb.fExtended and ssCtrl notin shift:
      lb.selectOnly(target)
      lb.fAnchor = target
    # else: focus only
  else:
    lb.selectOnly(target)
    lb.fAnchor = target
  lb.setFocusRow(target)
  lb.makeVisible(target)
  lb.notify(v)

func prefixIC(s, lowerPrefix: string): bool =
  if s.len < lowerPrefix.len: return false
  for j in 0 ..< lowerPrefix.len:
    if toLowerAscii(s[j]) != lowerPrefix[j]: return false
  true

proc typeAhead(lb: ListBox, ch: char): bool =
  let now = nowMs()
  if now - lb.fTypeTime > lb.typeAheadTimeout: lb.fTypeBuf.setLen(0)
  lb.fTypeTime = now
  lb.fTypeBuf.add toLowerAscii(ch)
  let n = lb.count
  if n == 0: return true
  let start = if lb.fTypeBuf.len == 1: lb.fIndex + 1 else: max(lb.fIndex, 0)
  for k in 0 ..< n:
    let i = (start + k) mod n
    if prefixIC(lb.itemText(i), lb.fTypeBuf):
      let v = lb.fVer
      if lb.fMulti and not lb.fExtended: lb.setFocusRow(i)
      else:
        lb.selectOnly(i)
        lb.fAnchor = i
        lb.setFocusRow(i)
      lb.makeVisible(i)
      lb.notify(v)
      break
  true

method doKeyDown*(lb: ListBox, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(lb), key, shift)
  if key == Key(0) or not lb.isEnabled: return
  let n = lb.count
  if shift * {ssAlt} != {}: return
  var target = -2                       # -2: not a navigation key
  let span = max(lb.lastFullRow - lb.firstFullRow, 1)
  if key == keyUp: target = if lb.fIndex < 0: 0 else: lb.fIndex - 1
  elif key == keyDown: target = lb.fIndex + 1
  elif key == keyHome: target = 0
  elif key == keyEnd: target = n - 1
  elif key == keyPageDown:
    let lf = lb.lastFullRow
    target = if lb.fIndex < lf: lf else: lb.fIndex + span
  elif key == keyPageUp:
    let ff = lb.firstFullRow
    target = if lb.fIndex > ff: ff else: lb.fIndex - span
  if target != -2:
    key = Key(0)
    if n > 0: lb.moveFocus(min(max(target, 0), n - 1), shift)
    return
  if lb.fMulti and key == keySpace and lb.fIndex >= 0 and
     (not lb.fExtended or ssCtrl in shift):
    key = Key(0)
    let v = lb.fVer
    lb.applyClick(lb.fIndex, if lb.fExtended: {ssCtrl} else: {})
    lb.notify(v)
  elif lb.fMulti and lb.fExtended and ssCtrl in shift and key == 'a'.key:
    key = Key(0)
    lb.selectAll()
  elif shift * {ssCtrl, ssSuper} == {}:
    let v = uint32(key)
    if v >= 0x20 and v < 0x7f and (v != 0x20 or lb.fTypeBuf.len > 0 and
        nowMs() - lb.fTypeTime <= lb.typeAheadTimeout):
      if lb.typeAhead(char(v)): key = Key(0)

method doExit*(lb: ListBox) =
  lb.fDragging = false
  lb.invalidate()
  procCall doExit(Control(lb))

# -------------------------------------------------------------------- paint

proc itemTextColor*(lb: ListBox, state: ItemStates): Color =
  let t = lb.theme
  if isDisabled in state: t.textDisabled
  elif isSelected in state and lb.focused: t.selectionText
  else: t.text

proc drawItemText*(lb: ListBox, c: Canvas, rect: RectF, text: string,
                   state: ItemStates) =
  ## Standard item text inside `rect` (left padded, vertically centred).
  var r = rect
  r.x += ItemPadding
  r.w = max(r.w - 2 * ItemPadding, 0)
  c.textRect(text, lb.font, r, lb.itemTextColor(state), taLeft, vaCenter)

method paint*(lb: ListBox, c: Canvas) =
  let t = lb.theme
  let enabled = lb.isEnabled
  let r = lb.clientRect
  c.fillRoundRect(r, t.radius, if enabled: t.surface else: t.surfaceAlt)
  let vp = lb.viewport
  let ih = lb.itemHeight
  let n = lb.count
  let focused = lb.focused
  c.pushClip(vp)
  let first = max(int(floor(float64(lb.scrollPos.y) / float64(ih))), 0)
  let last = min(int(ceil((float64(lb.scrollPos.y) + float64(vp.h)) / float64(ih))), n)
  let rad = max(t.radius - 1, 2)
  let ownerDraw = lb.fStyle == lbOwnerDraw and lb.onDrawItem != nil
  for i in first ..< last:
    var st: ItemStates
    if i in lb.fSel: st.incl isSelected
    if focused and i == lb.fIndex: st.incl isFocused
    if i == lb.fHot: st.incl isHot
    if not enabled: st.incl isDisabled
    let row = lb.itemRect(i)
    let box = rectF(row.x + 2, row.y + 1, row.w - 4, row.h - 2)
    if isSelected in st:
      c.fillRoundRect(box, rad,
                      if focused and enabled: t.selection else: t.selectionInactive)
    elif isHot in st:
      c.fillRoundRect(box, rad, t.hover)
    if isFocused in st and lb.fMulti:
      c.strokeRoundRect(box, rad, t.focusRing, 1)
    if ownerDraw:
      lb.onDrawItem(lb, c, i, row, st)
    else:
      lb.drawItemText(c, row, lb.itemText(i), st)
  c.popClip()
  let ring = focused and lb.fShowFocusRect
  c.strokeRoundRect(r, t.radius, if ring: t.focusRing else: t.borderStrong,
                    if ring: t.focusRingWidth else: t.borderWidth)
  procCall paint(Control(lb), c)

proc initListBox*(lb: ListBox, owner: Component = nil) =
  lb.initScrollingControl(owner)
  lb.setBounds(0, 0, 160, 140)
  lb.tabStop = true
  lb.fIndex = -1
  lb.fAnchor = -1
  lb.fHot = -1
  lb.fExtended = true
  lb.typeAheadTimeout = 1000
  lb.fSel = initHashSet[int]()
  lb.fShowFocusRect = true
  lb.padding = spacing(1)

proc newListBox*(parent: Container = nil, left = 0'f32, top = 0'f32,
                 width = -1'f32, height = -1'f32): ListBox =
  new result
  result.initListBox(parent)
  result.placeControl(parent, left, top, width, height)
