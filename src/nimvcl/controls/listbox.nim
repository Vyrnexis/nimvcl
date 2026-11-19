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
## `add`/`insert`/`delete`/`clear`/`items` and `sorted` do nothing in virtual mode
## (`count` may be set before or after `onData`);
## selection works as usual (selected rows are kept as runs, so selecting a huge range is cheap).
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
## Assigning `itemIndex` selects exactly that row (dropping any other
## selection) and scrolls it into view. `setSelection(indices, focus = -1)`
## replaces the whole selection in one step with one `onChange`.
## Deleting the focused row sets `itemIndex` to -1. Turning `multiSelect` off
## keeps only the focused row selected (the first selected one if none is focused).
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

import std/[monotimes, algorithm, strutils]
import ../graphics/context
import ../core/timer
import ./common, ./scrolling, ./indexset, ./rowview
export scrolling, rowview.nowMs, rowview.prefixIC, rowview.typeAheadChar

type
  ListBoxStyle* = enum lbStandard, lbOwnerDraw

  ItemState* = enum isSelected, isFocused, isHot, isDisabled
  ItemStates* = set[ItemState]

  DrawItemEvent* = proc(sender: Control, canvas: Canvas, index: int,
                        rect: RectF, state: ItemStates)
  DataEvent* = proc(sender: Control, index: int): string

  ListBox* = ref object of ScrollingControl
    fBorder: BorderStyle
    fItems: seq[string]
    fCount: int                  # virtual item count
    fSel: IndexSet
    fIndex, fAnchor, fHot: int
    fVer: int                    # bumped on every selection/focus change
    fMulti, fExtended, fSorted, fDragging, fMouseIn, fShowFocusRect: bool
    fStyle: ListBoxStyle
    fItemHeight, fExtent, fLastIh: float32
    fMouseY: float32
    fType: TypeAhead
    fDragTimer: Timer
    onChange*: NotifyEvent
    fOnData: DataEvent
    onDrawItem*: DrawItemEvent

  ItemList* = object
    ## `lb.items`: add/insert/delete/clear/[]/len on a ListBox's strings.
    lb: ListBox

const
  ItemPadding = 8'f32
  DragScrollMs = 45

# ----------------------------------------------------------------- basics

func onData*(lb: ListBox): DataEvent = lb.fOnData
func isVirtual*(lb: ListBox): bool = lb.fOnData != nil

func count*(lb: ListBox): int =
  if lb.fOnData != nil: lb.fCount else: lb.fItems.len

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
  if lb.fOnData != nil: lb.fOnData(lb, i) else: lb.fItems[i]

proc itemHeight*(lb: ListBox): float32 =
  ## Row height in logical pixels (the automatic one when not set).
  if lb.fItemHeight > 0: return lb.fItemHeight
  if lb.canMeasure:
    max(ceil(lb.renderCtx.fontMetrics(lb.font).lineHeight) + 8, 16)
  else: 22

method scrollLineSize*(lb: ListBox): SizeF = sizeF(24, lb.itemHeight)

proc refresh(lb: ListBox) =
  let ih = lb.itemHeight
  let csW = float64(lb.fExtent)
  let csH = float64(lb.count) * float64(ih)   # float64: exact for millions of rows
  if lb.fLastIh > 0 and ih != lb.fLastIh:
    # row height changed (font, first measurement): keep the same rows in view
    let old = lb.fLastIh
    let y = lb.scrollPosY / float64(old) * float64(ih)
    lb.fLastIh = ih
    if ih < old: lb.scrollTo(lb.scrollPosX, y)
    lb.setContentSize(csW, csH)
    if ih >= old: lb.scrollTo(lb.scrollPosX, y)
  else:
    lb.fLastIh = ih
    lb.setContentSize(csW, csH)
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
  if lb.fSel.selectOnly(i): lb.touch()

proc selectRange(lb: ListBox, a, b: int) =
  if lb.fSel.selectRange(a, b): lb.touch()

proc setFocusRow(lb: ListBox, i: int) =
  if i != lb.fIndex:
    lb.fIndex = i
    lb.touch()

# ------------------------------------------------------------------ geometry

func rowTop(lb: ListBox, i: int, ih: float32): float32 =
  ## Client y of row `i`.
  lb.viewport.y + float32(float64(i) * float64(ih) - lb.scrollPosY)

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
  let i = int(floor((float64(p.y - vp.y) + lb.scrollPosY) / ih))
  if i < 0 or i >= lb.count: -1 else: i

proc topIndex*(lb: ListBox): int =
  ## First (possibly partially) visible row.
  int(floor(lb.scrollPosY / float64(lb.itemHeight)))
proc `topIndex=`*(lb: ListBox, v: int) =
  lb.scrollTo(lb.scrollPosX, float64(max(v, 0)) * float64(lb.itemHeight))

proc firstFullRow(lb: ListBox): int =
  firstFullRowAt(lb.scrollPosY, lb.itemHeight)
proc lastFullRow(lb: ListBox): int =
  lastFullRowAt(lb.scrollPosY, lb.viewport.h, lb.itemHeight, lb.count)

proc makeVisible*(lb: ListBox, i: int) =
  ## Scrolls vertically the minimum distance that shows row `i` completely.
  if i < 0 or i >= lb.count: return
  let ih = lb.itemHeight
  lb.scrollIntoView(lb.scrollPosX, float64(i) * float64(ih), 1, float64(ih))

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

proc `itemIndex=`*(lb: ListBox, i: int) =
  let v = lb.fVer
  let n = if i < 0 or i >= lb.count: -1 else: i
  lb.selectOnly(n)
  lb.setFocusRow(n)
  lb.fAnchor = n
  lb.makeVisible(n)
  lb.notify(v)

proc setSelection*(lb: ListBox, indices: openArray[int], focus = -1) =
  ## Replaces the selection with `indices` (out-of-range entries are ignored)
  ## in one step and one `onChange`. `focus` becomes the focused item and
  ## anchor (-1: the first index given, or none); it is scrolled into view when
  ## given. Single mode keeps only the first index.
  let v = lb.fVer
  var s = initIndexSet()
  var first = -1
  for i in indices:
    if i >= 0 and i < lb.count:
      if first < 0: first = i
      if not lb.fMulti and s.len == 1: break
      s.incl i
  if s != lb.fSel:
    lb.fSel = s
    lb.touch()
  var f = focus
  if f < 0 or f >= lb.count: f = first
  lb.setFocusRow(f)
  lb.fAnchor = f
  if f >= 0 and focus >= 0: lb.makeVisible(f)
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
  let ver = lb.fVer
  lb.fMulti = v
  if not v:
    # single mode: the focused row is the selection (else the first selected)
    if lb.fIndex < 0 and lb.fSel.len > 0:
      lb.setFocusRow(lb.selectedIndices[0])
      lb.fAnchor = lb.fIndex
    if lb.fIndex >= 0: lb.selectOnly(lb.fIndex) else: lb.selectOnly(-1)
  lb.invalidate()
  lb.notify(ver)

proc `extendedSelect=`*(lb: ListBox, v: bool) = lb.fExtended = v

proc `style=`*(lb: ListBox, v: ListBoxStyle) =
  lb.fStyle = v
  lb.invalidate()

# ------------------------------------------------------------------- items

proc shiftIndices(lb: ListBox, at, delta: int) =
  ## Indices >= `at` move by `delta` (selection, focus, anchor).
  lb.fSel.shift(at, delta)
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
  lb.updateHot()                         # the row under a still pointer changed

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
  let wasFocus = lb.fIndex == i
  lb.fSel.excl i
  if wasFocus: lb.fIndex = -1
  if lb.fAnchor == i: lb.fAnchor = -1
  lb.shiftIndices(i + 1, -1)
  lb.fItems.delete(i)
  if wasSel or wasFocus: lb.touch()
  lb.refresh()
  lb.scrollBy(0, 0)         # re-clamp
  lb.updateHot()
  lb.notify(v)

proc clear*(lb: ListBox) =
  ## Removes all items. Does nothing in virtual mode (the count belongs to
  ## the data source: set `count`).
  if lb.isVirtual: return
  let v = lb.fVer
  let had = lb.fSel.len > 0 or lb.fIndex >= 0
  lb.fItems.setLen(0)
  lb.fSel.clear()
  lb.fIndex = -1
  lb.fAnchor = -1
  lb.fHot = -1
  if had: lb.touch()
  lb.refresh()
  lb.scrollTo(0, 0)
  lb.notify(v)

proc clampToCount(lb: ListBox) =
  ## Drops selection / focus / anchor beyond the item count.
  let v = lb.fVer
  var changed = false
  if lb.fSel.truncate(lb.count): changed = true
  if lb.fIndex >= lb.count:
    lb.fIndex = -1
    changed = true
  if lb.fAnchor >= lb.count: lb.fAnchor = -1
  if lb.fHot >= lb.count: lb.fHot = -1
  if changed: lb.touch()
  lb.refresh()
  lb.scrollBy(0, 0)
  lb.notify(v)

proc `count=`*(lb: ListBox, n: int) =
  ## Virtual mode: the number of items. May be set before or after `onData`.
  lb.fCount = max(n, 0)
  if lb.fOnData != nil: lb.clampToCount()

proc `onData=`*(lb: ListBox, v: DataEvent) =
  ## Switches to virtual mode (non-nil; `count` is the item count) or back to
  ## the stored items (nil).
  lb.fOnData = v
  lb.clampToCount()

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
  lb.fSel = lb.fSel.remapped(pos)
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
  ## Replaces all items (does nothing in virtual mode).
  if lb.isVirtual: return
  lb.clear()
  if lb.fSorted:
    for s in v: lb.add s
  else:
    for s in v: lb.fItems.add s
    lb.refresh()

proc `[]`*(lb: ListBox, i: int): string = lb.itemText(i)
proc `[]=`*(lb: ListBox, i: int, s: string) = lb.items[i] = s

# ---------------------------------------------------------------- user input

proc applyClick(lb: ListBox, i: int, shift: ShiftState) =
  if lb.fSel.clickSelect(lb.fAnchor, i, lb.fMulti, lb.fExtended, shift):
    lb.touch()
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
      lb.fDragging = (not lb.fMulti or lb.fExtended) and ssCtrl notin shift
      lb.makeVisible(i)
      lb.notify(v)
  procCall doMouseDown(Control(lb), button, shift, x, y)

proc dragSelect(lb: ListBox) =
  ## Extends the drag selection to the row under (or nearest to) the pointer.
  if lb.count == 0: return
  let vp = lb.viewport
  let cy = min(max(lb.fMouseY, vp.y), vp.bottom - 1)
  var i = int(floor((float64(cy - vp.y) + lb.scrollPosY) /
                    float64(lb.itemHeight)))
  i = min(max(i, 0), lb.count - 1)
  if i != lb.fIndex:
    let v = lb.fVer
    if lb.fMulti: lb.selectRange(max(lb.fAnchor, 0), i)
    else: lb.selectOnly(i)
    lb.setFocusRow(i)
    lb.makeVisible(i)
    lb.notify(v)

proc stopDrag(lb: ListBox) =
  lb.fDragging = false
  if lb.fDragTimer != nil: lb.fDragTimer.enabled = false

method doMouseMove*(lb: ListBox, shift: ShiftState, x, y: float32) =
  lb.fMouseIn = true
  lb.fMouseY = y
  if lb.fDragging and ssLeft in shift and lb.count > 0:
    let vp = lb.viewport
    lb.dragSelect()
    if y < vp.y or y >= vp.bottom:
      if lb.fDragTimer == nil:
        lb.fDragTimer = newTimer(nil, DragScrollMs)
        lb.fDragTimer.onTimer = proc(t: Timer) =
          if not lb.fDragging:
            t.enabled = false
            return
          let vp = lb.viewport
          if lb.fMouseY < vp.y: lb.scrollBy(0, -lb.itemHeight)
          elif lb.fMouseY >= vp.bottom: lb.scrollBy(0, lb.itemHeight)
          lb.dragSelect()
      lb.fDragTimer.enabled = true
    elif lb.fDragTimer != nil:
      lb.fDragTimer.enabled = false
  elif lb.fDragging and ssLeft notin shift:
    lb.stopDrag()
  lb.updateHot()
  procCall doMouseMove(Control(lb), shift, x, y)

method doMouseUp*(lb: ListBox, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft: lb.stopDrag()
  procCall doMouseUp(Control(lb), button, shift, x, y)

proc moveFocus(lb: ListBox, target: int, shift: ShiftState) =
  ## Keyboard navigation to row `target` (already clamped).
  let v = lb.fVer
  if lb.fSel.keySelect(lb.fAnchor, lb.fIndex, target, lb.fMulti, lb.fExtended,
                       shift):
    lb.touch()
  lb.setFocusRow(target)
  lb.makeVisible(target)
  lb.notify(v)

proc typeAheadTimeout*(lb: ListBox): int = lb.fType.timeout
proc `typeAheadTimeout=`*(lb: ListBox, ms: int) = lb.fType.timeout = ms

proc typeAhead(lb: ListBox, ch: char) =
  let i = lb.fType.search(ch, lb.fIndex, lb.count,
                          proc(i: int): string = lb.itemText(i))
  if i < 0: return
  let v = lb.fVer
  if lb.fMulti and not lb.fExtended: lb.setFocusRow(i)
  else:
    lb.selectOnly(i)
    lb.fAnchor = i
    lb.setFocusRow(i)
  lb.makeVisible(i)
  lb.notify(v)

method doKeyDown*(lb: ListBox, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(lb), key, shift)
  if key == Key(0) or not lb.isEnabled: return
  let n = lb.count
  if shift * {ssAlt} != {}: return
  let target = rowNavTarget(key, lb.fIndex, n, lb.firstFullRow, lb.lastFullRow)
  if target != NotNav:
    key = Key(0)
    if n > 0: lb.moveFocus(clampRow(target, n), shift)
    return
  if lb.fMulti and key == keySpace:
    key = Key(0)
    if lb.fIndex >= 0:
      let v = lb.fVer
      lb.applyClick(lb.fIndex, if lb.fExtended: {ssCtrl} else: {})
      lb.notify(v)
  elif lb.fMulti and lb.fExtended and ssCtrl in shift and key == 'a'.key:
    key = Key(0)
    lb.selectAll()
  else:
    let ch = lb.fType.keyChar(key, shift)
    if ch != '\0':
      key = Key(0)
      lb.typeAhead(ch)

method doExit*(lb: ListBox) =
  lb.stopDrag()
  lb.invalidate()
  procCall doExit(Control(lb))

# -------------------------------------------------------------------- paint

proc itemTextColor*(lb: ListBox, state: ItemStates): Color =
  let t = lb.theme
  if isDisabled in state: t.textDisabled
  elif isSelected in state and lb.focused: t.selectionText
  elif isSelected in state and not lb.ownColor: lb.ink(t, t.selectionInactive)
  else: lb.ink(t, lb.fieldFill(t, true))

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
  let bg = lb.fieldFill(t, enabled)
  c.fillFrame(r, t, lb.fBorder, bg)
  let vp = lb.viewport
  let ih = lb.itemHeight
  let n = lb.count
  let focused = lb.focused
  c.pushClip(vp)
  let first = max(int(floor(lb.scrollPosY / float64(ih))), 0)
  let last = min(int(ceil((lb.scrollPosY + float64(vp.h)) / float64(ih))), n)
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
      c.fillRoundRect(box, rad, lb.rowHover(t, bg))
    if isFocused in st and lb.fMulti:
      c.strokeRoundRect(box, rad, t.focusRing, 1)
    if ownerDraw:
      lb.onDrawItem(lb, c, i, row, st)
    else:
      lb.drawItemText(c, row, lb.itemText(i), st)
  c.popClip()
  let ring = focused and lb.fShowFocusRect
  c.strokeFrame(r, t, lb.fBorder, if ring: t.focusRing else: t.borderStrong,
                    if ring: t.focusRingWidth else: t.borderWidth)
  procCall paint(Control(lb), c)

func borderStyle*(x: ListBox): BorderStyle = x.fBorder
proc `borderStyle=`*(x: ListBox, v: BorderStyle) =
  ## `bsSingle` (default): the usual border and focus ring; `bsNone`: none,
  ## so the control can sit flush in a panel.
  if v == x.fBorder: return
  x.fBorder = v
  x.invalidate()

proc initListBox*(lb: ListBox, owner: Component = nil) =
  lb.initScrollingControl(owner)
  lb.fBorder = bsSingle
  lb.setBounds(0, 0, 160, 140)
  lb.tabStop = true
  lb.fIndex = -1
  lb.fAnchor = -1
  lb.fHot = -1
  lb.fExtended = true
  lb.fType = initTypeAhead()
  lb.fSel = initIndexSet()
  lb.fShowFocusRect = true
  lb.padding = spacing(1)

proc newListBox*(parent: Container = nil, left = 0'f32, top = 0'f32,
                 width = -1'f32, height = -1'f32): ListBox =
  new result
  result.initListBox(parent)
  result.placeControl(parent, left, top, width, height)
