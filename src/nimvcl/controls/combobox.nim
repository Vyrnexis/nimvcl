## `ComboBox` (VCL TComboBox): an edit or a display box plus a drop-down list.
##
## Style
## -----
## * `csDropDown` (default): editable text. It is a real `Edit` child (all of
##   Edit's editing, selection, undo, IME and clipboard behaviour); the face
##   around it and the arrow button are the combo's. `text` is the edit text;
##   it is matched against the items (`itemIndex` is the item equal to the text,
##   else -1). `autoComplete` (default true): typing completes to the first item
##   that starts with the typed text, the completed part selected; Backspace and
##   Delete never re-complete.
## * `csDropDownList`: not editable, shows the selected item; the whole face
##   is the button. Typing letters selects by prefix (the ListBox type-ahead).
##
## Items
## -----
## Same shape as `ListBox`: `cb.items.add "x"`, `insert`, `delete`, `clear`,
## `cb.items[i]`, `cb.items.len` (a `ComboItems`, not the ListBox's list), `cb.add`, `cb.insert`, `cb.delete`, `cb.clear`,
## `cb[i]`, `cb.count`, `cb.items = @[...]`, `sorted` (case-insensitive).
## `itemIndex` selects (and shows) an item; -1 clears the selection (and the
## text of a csDropDown).
##
## Events
## ------
## * `onChange`: the text (csDropDown) or the selected item (csDropDownList)
##   changed, whoever did it: typing, a pick, `text=`, `itemIndex=`.
## * `onSelect`: the USER picked an item: a click or Enter in the list, Up/Down
##   or type-ahead while closed. Fired after `onChange`; a pick of the item
##   that is already selected fires `onSelect` only.
## * `onDropDown` just before the list opens (items may be added here),
##   `onCloseUp` after it closed (picked or not).
##
## Drop-down
## ---------
## A popup (core/popup) anchored under the combo (above when it does not fit),
## holding a `ListBox` (a view made for each opening, filled from the combo's
## items and freed on close; `dropList` is nil while closed) of `dropDownCount` rows (default 8; fewer for fewer
## items) and the width of the combo (`dropDownWidth` overrides). The
## popup system swallows the press that closes it (click outside), and routes
## keys to it.
##
## Keys
## ----
## Closed: Up/Down/Home/End (list style) change the selection; Alt+Down, F4
## (and Space in list style) open. Open: Up/Down/PgUp/PgDn/Home/End/letters move
## the highlight (the text stays), Enter or a click picks it and closes, Esc,
## or a click outside, closes without change, Alt+Up/Alt+Down/F4 pick and close.
## Enter and Esc stay unused while closed, so a default/cancel button gets them.

import std/[strutils, algorithm]
import ../graphics/context
import ../core/[form, popup]
import ./common, ./listbox, ./edit, ./rowview

type
  ComboStyle* = enum csDropDown, csDropDownList

  ComboEdit = ref object of Edit
    combo: ComboBox
  DropPanel = ref object of Container
    combo: ComboBox

  ComboBox* = ref object of Container
    ## The combo owns its items and the committed index (the model). The
    ## drop-down `ListBox` is only a view: made when the list opens, filled
    ## from the model and dropped when it closes.
    fItems: seq[string]
    fSorted: bool
    fIndex: int                  # committed item, -1 none
    fLastIndex: int              # the index `onChange` last reported (list style)
    fLastText: string            # the text `onChange` last reported (csDropDown)
    fList: ListBox               # the open popup's list, nil when closed
    fEdit: ComboEdit
    fStyle: ComboStyle
    fDropCount: int
    fDropWidth: float32
    fAutoComplete: bool
    fPopup: PopupWindow
    fPick: int                   # row picked in the list, -1 none
    fQuiet: int                  # > 0: the edit text is being set by the combo
    fInKey, fDirty, fHot: bool   # edit change during a key press / seen
    fType: TypeAhead             # list style, closed: letters select by prefix
    fDropStyle: ListBoxStyle
    onChange*, onSelect*, onDropDown*, onCloseUp*: NotifyEvent
    onDrawItem*: DrawItemEvent   ## owner-drawn rows of the drop-down (`dropStyle = lbOwnerDraw`)

  ComboItems* = object
    ## `cb.items`: add/insert/delete/clear/[]/[]=/len/indexOf on the combo's strings.
    cb: ComboBox

const
  ArrowW = 22'f32
  EditInset = 2'f32

# ------------------------------------------------------------------- basics

func style*(c: ComboBox): ComboStyle = c.fStyle
func dropDownCount*(c: ComboBox): int = c.fDropCount
func dropDownWidth*(c: ComboBox): float32 = c.fDropWidth
func autoComplete*(c: ComboBox): bool = c.fAutoComplete
func droppedDown*(c: ComboBox): bool = c.fList != nil
func popupWindow*(c: ComboBox): PopupWindow = c.fPopup
func count*(c: ComboBox): int = c.fItems.len
func itemIndex*(c: ComboBox): int =
  ## The selected item; while the list is open this is still the committed
  ## one (the list's highlight is `dropList.itemIndex`).
  c.fIndex
func sorted*(c: ComboBox): bool = c.fSorted
func items*(c: ComboBox): ComboItems = ComboItems(cb: c)
func edit*(c: ComboBox): Edit = c.fEdit
  ## The embedded edit (csDropDown); hidden in list style.
func dropList*(c: ComboBox): ListBox = c.fList
  ## The list shown in the popup; nil while the combo is closed.
func dropStyle*(c: ComboBox): ListBoxStyle = c.fDropStyle
  ## `lbOwnerDraw`: the drop-down rows are drawn by `onDrawItem`.
proc `dropStyle=`*(c: ComboBox, v: ListBoxStyle) = c.fDropStyle = v
func typeAheadTimeout*(c: ComboBox): int = c.fType.timeout
proc `typeAheadTimeout=`*(c: ComboBox, ms: int) = c.fType.timeout = ms

proc `dropDownCount=`*(c: ComboBox, v: int) = c.fDropCount = max(v, 1)
proc `dropDownWidth=`*(c: ComboBox, v: float32) = c.fDropWidth = max(v, 0)
proc `autoComplete=`*(c: ComboBox, v: bool) = c.fAutoComplete = v

proc itemText(c: ComboBox, i: int): string =
  if i >= 0 and i < c.fItems.len: c.fItems[i] else: ""

proc findItem(c: ComboBox, s: string): int =
  ## First item equal to `s`, -1 for none.
  for i, it in c.fItems:
    if it == s: return i
  -1

proc text*(c: ComboBox): string =
  case c.fStyle
  of csDropDown: c.fEdit.text
  of csDropDownList: c.itemText(c.fIndex)

proc arrowRect(c: ComboBox): RectF =
  rectF(c.width - ArrowW, 0, ArrowW, c.height)

proc layoutEdit(c: ComboBox) =
  c.fEdit.visible = c.fStyle == csDropDown
  c.fEdit.setBounds(EditInset, EditInset,
                    max(c.width - EditInset - ArrowW, 0), max(c.height - 2 * EditInset, 0))

# --------------------------------------------------------------- selection

proc setEditText(c: ComboBox, v: string) =
  ## Sets the edit text without telling `onChange` handlers of the edit.
  if c.fEdit.text == v: return
  inc c.fQuiet
  c.fEdit.text = v
  dec c.fQuiet

proc showHighlight(c: ComboBox) =
  ## The open list follows the committed item.
  if c.fList != nil: c.fList.itemIndex = c.fIndex

proc commit(c: ComboBox, idx: int, clearText, user, force: bool) =
  ## Makes `idx` the committed item: shows it, fires onChange / onSelect.
  ## `clearText`: with no item the free text of a csDropDown is cleared;
  ## `user` / `force`: the change comes from the user (onSelect), `force`
  ## fires onSelect even when nothing changed.
  c.fIndex = idx
  var newText: string
  if c.fStyle == csDropDown:
    newText = c.fEdit.text
    if idx >= 0: newText = c.fItems[idx]
    elif clearText: newText = ""
    c.setEditText newText
    if idx >= 0 and (user or force):
      inc c.fQuiet
      c.fEdit.selectAll()
      dec c.fQuiet
  else:
    newText = c.itemText(idx)
  let changed =
    if c.fStyle == csDropDownList: idx != c.fLastIndex else: newText != c.fLastText
  c.fLastIndex = idx
  c.fLastText = newText
  c.showHighlight()
  c.invalidate()
  if changed and c.onChange != nil: c.onChange(c)
  if (user or force) and (changed or force) and c.onSelect != nil: c.onSelect(c)

proc `itemIndex=`*(c: ComboBox, v: int) =
  ## Selects item `v` (-1: none, which also clears the free text of a
  ## csDropDown). While the list is open the change is the committed value
  ## right away (closing without a pick keeps it).
  let i = if v < 0 or v >= c.fItems.len: -1 else: v
  c.commit(i, clearText = v < 0, user = false, force = false)

proc `text=`*(c: ComboBox, v: string) =
  ## csDropDown: sets the edit text (the matching item is selected). List
  ## style: selects the item equal to `v` (none: no selection).
  let idx = c.findItem(v)
  if c.fStyle == csDropDown:
    c.setEditText v
    c.fIndex = idx
    c.showHighlight()
    let changed = v != c.fLastText
    c.fLastText = v
    c.fLastIndex = idx
    c.invalidate()
    if changed and c.onChange != nil: c.onChange(c)
  else:
    c.itemIndex = idx

proc textEdited(c: ComboBox) =
  ## The user changed the edit text (typing, deleting, pasting, undo).
  let t = c.fEdit.text
  let idx = c.findItem(t)
  c.fIndex = idx
  c.showHighlight()
  c.fLastIndex = idx
  c.fLastText = t
  c.invalidate()
  if c.onChange != nil: c.onChange(c)

proc userSelect(c: ComboBox, i: int) =
  let n = c.fItems.len
  if n == 0: return
  let t = clamp(i, 0, n - 1)
  if t == c.fIndex: return
  c.commit(t, false, user = true, force = false)

proc autoCompleteText(c: ComboBox) =
  ## After typing: complete to the first item starting with the text.
  let e = c.fEdit
  let t = e.text
  if t.len == 0 or e.caretPos != t.len or e.selLength != 0: return
  let low = t.toLowerAscii
  for s in c.fItems:
    if s.len > t.len and prefixIC(s, low):
      e.replaceRange(0, t.len, s)        # the item's own spelling replaces the typed text
      e.select(t.len, s.len - t.len)
      return

# -------------------------------------------------------------- drop-down

proc closeUp*(c: ComboBox) =
  ## Closes the list without picking (a pick goes through the list's Enter/click).
  if c.fPopup != nil: closePopup(c.fPopup)

proc pickAndClose(c: ComboBox) =
  if c.fPopup == nil or c.fList == nil: return
  c.fPick = c.fList.itemIndex
  closePopup(c.fPopup)

method doKeyDown*(p: DropPanel, key: var Key, shift: ShiftState) =
  let c = p.combo
  if c.fList == nil: return
  if key == keyEnter and shift * {ssCtrl, ssAlt} == {}:
    key = Key(0)
    if c.fList.itemIndex >= 0: c.pickAndClose() else: c.closeUp()
    return
  if key == keyF4 or (key in [keyUp, keyDown] and ssAlt in shift):
    key = Key(0)
    if c.fList.itemIndex >= 0: c.pickAndClose() else: c.closeUp()
    return
  if key == keyEscape: return           # the popup system closes it
  if ssAlt in shift: return
  c.fList.doKeyDown(key, shift)
  if key != Key(0) and key != keyEscape:
    procCall doKeyDown(Container(p), key, shift)

proc itemRowHeight(c: ComboBox): float32 =
  if c.canMeasure: max(ceil(c.renderCtx.fontMetrics(c.font).lineHeight) + 8, 16)
  else: 22

proc dropDown*(c: ComboBox) =
  ## Opens the list (no-op when open, empty, disabled or not shown).
  if c.fList != nil or not c.isEnabled: return
  let r = c.root
  if not (r of Form): return
  let f = Form(r)
  if not f.hasWindow or not f.visible: return
  if c.onDropDown != nil: c.onDropDown(c)
  let n = c.fItems.len
  if n == 0: return
  let ih = c.itemRowHeight
  let rows = min(n, c.fDropCount)
  let w = if c.fDropWidth > 0: c.fDropWidth else: c.width
  let h = float32(rows) * ih + 2
  let list = newListBox()
  list.showFocusRect = false
  list.tabStop = false
  list.items = c.fItems
  list.style = c.fDropStyle
  list.onDrawItem = c.onDrawItem
  list.font = c.font
  if c.ownColor: list.color = c.colorOwner.color else: list.parentColor = true
  list.itemHeight = ih
  list.align = alClient
  list.setBounds(0, 0, w, h)
  list.itemIndex = c.fIndex
  list.onClick = proc(s: Control) =
    if c.fList == list and list.itemIndex >= 0: c.pickAndClose()
  let panel = DropPanel(combo: c)
  panel.initContainer()
  panel.setBounds(0, 0, w, h)
  panel.insertControl list
  let anchor = c.clientToForm(c.clientRect)
  c.fList = list
  c.fPick = -1
  let p = showPopup(f, panel, anchor, plBelow, pkMenu)
  c.fPopup = p
  p.onClosed = proc(q: PopupWindow) =
    c.fList = nil
    c.fPopup = nil
    panel.removeControl list
    list.free()
    let pick = c.fPick
    c.fPick = -1
    if pick >= 0 and pick < c.fItems.len: c.commit(pick, false, true, true)
    c.invalidate()
    if c.onCloseUp != nil: c.onCloseUp(c)
  p.ui.focusControl(list)
  if list.itemIndex >= 0: list.makeVisible(list.itemIndex)
  c.invalidate()

proc toggleDrop(c: ComboBox) =
  if c.fList != nil: c.closeUp() else: c.dropDown()

# ------------------------------------------------------------------ keys

proc handleKey(c: ComboBox, key: var Key, shift: ShiftState) =
  ## Keys of the closed combo (from the edit or the combo itself).
  let list = c.fStyle == csDropDownList
  if key == keyF4 or (key == keyDown and ssAlt in shift) or
     (list and key == keySpace and shift * {ssCtrl, ssAlt} == {}):
    key = Key(0)
    c.dropDown()
    return
  if shift * {ssAlt, ssCtrl, ssSuper} != {}: return
  let idx = c.fIndex
  if key == keyDown:
    key = Key(0)
    c.userSelect(if idx < 0: 0 else: idx + 1)
  elif key == keyUp:
    key = Key(0)
    c.userSelect(if idx < 0: 0 else: idx - 1)
  elif list and key == keyHome:
    key = Key(0)
    c.userSelect(0)
  elif list and key == keyEnd:
    key = Key(0)
    c.userSelect(c.fItems.len - 1)
  elif list and key == keyPageDown:
    key = Key(0)
    c.userSelect(idx + c.fDropCount)
  elif list and key == keyPageUp:
    key = Key(0)
    c.userSelect(idx - c.fDropCount)
  elif list:
    let ch = c.fType.keyChar(key, shift)
    if ch != '\0':
      key = Key(0)
      let i = c.fType.search(ch, idx, c.fItems.len,
                             proc(i: int): string = c.fItems[i])
      if i >= 0: c.userSelect(i)

method doKeyDown*(e: ComboEdit, key: var Key, shift: ShiftState) =
  e.combo.handleKey(key, shift)
  if key != Key(0): procCall doKeyDown(Edit(e), key, shift)

method doKeyPress*(e: ComboEdit, text: var string) =
  let c = e.combo
  c.fInKey = true
  c.fDirty = false
  try:
    procCall doKeyPress(Edit(e), text)
    if c.fDirty and c.fAutoComplete: c.autoCompleteText()
  finally:
    c.fInKey = false
  if c.fDirty:
    c.fDirty = false
    c.textEdited()

method doEnter*(e: ComboEdit) =
  procCall doEnter(Edit(e))
  e.combo.invalidate()

method doExit*(e: ComboEdit) =
  procCall doExit(Edit(e))
  e.combo.invalidate()

method focusTarget*(c: ComboBox): Control =
  if c.fStyle == csDropDown: c.fEdit else: c

method canFocus*(c: ComboBox): bool =
  c.fStyle == csDropDownList and c.isVisible and c.isEnabled

method doKeyDown*(c: ComboBox, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(c), key, shift)
  if key == Key(0) or c.fStyle != csDropDownList: return
  c.handleKey(key, shift)

method doMouseEnter*(c: ComboBox) =
  c.fHot = true
  procCall doMouseEnter(Control(c))
  c.invalidate()

method doMouseLeave*(c: ComboBox) =
  c.fHot = false
  procCall doMouseLeave(Control(c))
  c.invalidate()

method doMouseDown*(c: ComboBox, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  procCall doMouseDown(Control(c), button, shift, x, y)
  if button != mbLeft or not c.isEnabled: return
  if c.fStyle == csDropDown:
    if x >= c.width - ArrowW:
      c.fEdit.setFocus()
      c.toggleDrop()
  else:
    c.toggleDrop()

method visibilityChanged*(c: ComboBox) =
  procCall visibilityChanged(Container(c))
  if not c.isShowing: c.closeUp()

method enabledChanged*(c: ComboBox) =
  procCall enabledChanged(Container(c))
  if not c.enabled: c.closeUp()

method doExit*(c: ComboBox) =
  procCall doExit(Container(c))
  c.invalidate()

method doResize*(c: ComboBox) =
  procCall doResize(Container(c))
  c.layoutEdit()

method colorOwner*(e: ComboEdit): Control = e.combo

method doEnter*(c: ComboBox) =
  procCall doEnter(Container(c))
  c.invalidate()

# --------------------------------------------------------------------- paint

method paint*(c: ComboBox, cv: Canvas) =
  let t = c.theme
  let enabled = c.isEnabled
  let foc = c.focused or (c.fStyle == csDropDown and c.fEdit.focused)
  let r = c.clientRect
  let bg = c.fieldFill(t, enabled)
  let bc =
    if not enabled: t.border
    elif foc or c.droppedDown: t.accent
    elif c.fHot: t.borderStrong
    else: t.border
  cv.fillRoundRect(r, t.radius, bg)
  let ar = c.arrowRect
  let btnRect = rectF(ar.x, ar.y + 1, ar.w - 1, ar.h - 2)
  if enabled and (c.fHot or c.droppedDown):
    let hotArea = if c.fStyle == csDropDownList: rectF(1, 1, c.width - 2, c.height - 2)
                  else: btnRect
    cv.fillRoundRect(hotArea, max(t.radius - 1, 1), if c.droppedDown: (if c.ownColor: shade(bg, 0.18'f32) else: t.pressed)
                                              else: c.rowHover(t, bg))
  if c.fStyle == csDropDownList:
    let ta = rectF(8, 0, max(c.width - ArrowW - 8, 0), c.height)
    cv.textRect(c.text, c.font, ta, c.ink(t, bg, enabled),
                taLeft, vaCenter)
  cv.drawArrow(pointF(ar.x + ar.w / 2 - 0.5, ar.y + ar.h / 2), 4, adDown,
               if enabled: legible(t.textMuted, bg) else: t.textDisabled)
  cv.strokeRoundRect(r, t.radius, bc, t.borderWidth)
  if foc and enabled: drawFocusRing(cv, r, t)
  procCall paint(Control(c), cv)

# ------------------------------------------------------------------- items

proc upperBound(c: ComboBox, s: string): int =
  var lo = 0
  var hi = c.fItems.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if cmpIgnoreCase(c.fItems[mid], s) <= 0: lo = mid + 1 else: hi = mid
  lo

proc refindIndex(c: ComboBox) =
  ## csDropDown: the selected item is the one equal to the text; after the
  ## items changed it may be another one (or none).
  if c.fStyle != csDropDown: return
  c.fIndex = c.findItem(c.fEdit.text)
  c.fLastIndex = c.fIndex
  c.showHighlight()

proc itemsChanged(c: ComboBox) =
  ## The items changed: an open list shows the new ones and the committed item.
  if c.fList != nil:
    c.fList.items = c.fItems
    c.fList.itemIndex = c.fIndex
  c.invalidate()

proc resort(c: ComboBox) =
  ## Stable case-insensitive sort; the committed item stays attached to its text.
  var order = newSeq[int](c.fItems.len)
  for i in 0 ..< order.len: order[i] = i
  let old = c.fItems
  order.sort(proc(a, b: int): int =
    result = cmpIgnoreCase(old[a], old[b])
    if result == 0: result = cmp(a, b))
  let cur = c.fIndex
  for n, o in order:
    c.fItems[n] = old[o]
    if o == cur: c.fIndex = n
  c.fLastIndex = c.fIndex
  c.itemsChanged()

proc insert*(c: ComboBox, index: int, s: string) =
  ## Inserts at `index` (clamped); on a `sorted` combo the index is ignored.
  let i = if c.fSorted: c.upperBound(s) else: min(max(index, 0), c.fItems.len)
  c.fItems.insert(s, i)
  if c.fIndex >= i:
    inc c.fIndex
    c.fLastIndex = c.fIndex
  c.itemsChanged()
  c.refindIndex()
proc add*(c: ComboBox, s: string) = c.insert(c.fItems.len, s)
proc delete*(c: ComboBox, i: int) =
  if i < 0 or i >= c.fItems.len: return
  c.fItems.delete i
  if i < c.fIndex:
    dec c.fIndex
    c.fLastIndex = c.fIndex
  c.itemsChanged()
  if i == c.fIndex:                       # the committed item is gone
    c.commit(-1, false, false, false)
proc clear*(c: ComboBox) =
  c.fItems.setLen(0)
  c.itemsChanged()
  c.commit(-1, false, false, false)
proc `[]`*(c: ComboBox, i: int): string = c.itemText(i)
proc `items=`*(c: ComboBox, v: openArray[string]) =
  c.fItems = @v
  if c.fSorted: c.fIndex = -1; c.resort()
  c.itemsChanged()
  c.commit(-1, false, false, false)
  c.refindIndex()
proc `sorted=`*(c: ComboBox, v: bool) =
  if v == c.fSorted: return
  c.fSorted = v
  if v: c.resort()

func len*(l: ComboItems): int = l.cb.fItems.len
func count*(l: ComboItems): int = l.cb.fItems.len
proc add*(l: ComboItems, s: string) = l.cb.add s
proc insert*(l: ComboItems, i: int, s: string) = l.cb.insert(i, s)
proc delete*(l: ComboItems, i: int) = l.cb.delete i
proc clear*(l: ComboItems) = l.cb.clear()
proc `[]`*(l: ComboItems, i: int): string = l.cb.itemText(i)
proc `[]=`*(l: ComboItems, i: int, s: string) =
  ## Replaces item `i` (a sorted combo re-sorts).
  if i < 0 or i >= l.cb.fItems.len: return
  l.cb.fItems[i] = s
  if l.cb.fSorted: l.cb.resort() else: l.cb.itemsChanged()
proc indexOf*(l: ComboItems, s: string): int = l.cb.findItem(s)
iterator items*(l: ComboItems): string =
  for s in l.cb.fItems: yield s

proc `style=`*(c: ComboBox, v: ComboStyle) =
  if v == c.fStyle: return
  c.closeUp()
  c.fStyle = v
  c.tabStop = v == csDropDownList
  c.cursor = crDefault
  c.layoutEdit()
  c.invalidate()

proc initComboBox*(c: ComboBox, owner: Component = nil) =
  c.initContainer(owner)
  c.fDropCount = 8
  c.fAutoComplete = true
  c.fStyle = csDropDown
  c.fIndex = -1
  c.fLastIndex = -1
  c.fPick = -1
  c.fType = initTypeAhead()
  c.fEdit = ComboEdit(combo: c)
  c.fEdit.initEdit(c)
  c.fEdit.borderStyle = ebNone
  c.insertControl c.fEdit
  c.setBounds(0, 0, 160, currentTheme().controlHeight)
  c.layoutEdit()
  c.fEdit.onChange = proc(s: Control) =
    if c.fQuiet > 0: return
    if c.fInKey: c.fDirty = true
    else: c.textEdited()

proc newComboBox*(parent: Container = nil, style = csDropDown, left = 0'f32,
                  top = 0'f32, width = -1'f32, height = -1'f32): ComboBox {.discardable.} =
  ## `parent` (also the owner) gets the control appended when non-nil.
  new result
  result.initComboBox(parent)
  result.style = style
  placeControl(result, parent, left, top, width, height)
