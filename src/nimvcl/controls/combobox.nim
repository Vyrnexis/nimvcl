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
## `cb.items[i]`, `cb.items.len`, `cb.add`, `cb.insert`, `cb.delete`, `cb.clear`,
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
## holding a `ListBox` of `dropDownCount` rows (default 8; fewer for fewer
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

import std/strutils
import ../graphics/context
import ../core/[form, popup]
import ./common, ./listbox, ./edit
export listbox.ItemList

type
  ComboStyle* = enum csDropDown, csDropDownList

  DropList = ref object of ListBox
  ComboEdit = ref object of Edit
    combo: ComboBox
  DropPanel = ref object of Container
    combo: ComboBox

  ComboBox* = ref object of Container
    fList: DropList
    fEdit: ComboEdit
    fStyle: ComboStyle
    fDropCount: int
    fDropWidth: float32
    fAutoComplete: bool
    fPopup: PopupWindow
    fOpen, fSyncing, fSuppress, fDirty, fUser, fCommit, fExplicit, fHot: bool
    fOpenIndex, fLastIndex: int
    fLastText: string
    onChange*, onSelect*, onDropDown*, onCloseUp*: NotifyEvent

const
  ArrowW = 22'f32
  EditInset = 2'f32

# ------------------------------------------------------------------- basics

func style*(c: ComboBox): ComboStyle = c.fStyle
func dropDownCount*(c: ComboBox): int = c.fDropCount
func dropDownWidth*(c: ComboBox): float32 = c.fDropWidth
func autoComplete*(c: ComboBox): bool = c.fAutoComplete
func droppedDown*(c: ComboBox): bool = c.fOpen
func popupWindow*(c: ComboBox): PopupWindow = c.fPopup
func count*(c: ComboBox): int = c.fList.count
func itemIndex*(c: ComboBox): int =
  ## The selected item; while the list is open this is still the committed one.
  if c.fOpen: c.fOpenIndex else: c.fList.itemIndex
func sorted*(c: ComboBox): bool = c.fList.sorted
func items*(c: ComboBox): ItemList = c.fList.items
func edit*(c: ComboBox): Edit = c.fEdit
  ## The embedded edit (csDropDown); hidden in list style.
func dropList*(c: ComboBox): ListBox = c.fList
  ## The list (the one shown in the popup).

proc `dropDownCount=`*(c: ComboBox, v: int) = c.fDropCount = max(v, 1)
proc `dropDownWidth=`*(c: ComboBox, v: float32) = c.fDropWidth = max(v, 0)
proc `autoComplete=`*(c: ComboBox, v: bool) = c.fAutoComplete = v

proc text*(c: ComboBox): string =
  case c.fStyle
  of csDropDown: c.fEdit.text
  of csDropDownList: c.fList.itemText(c.itemIndex)

proc arrowRect(c: ComboBox): RectF =
  rectF(c.width - ArrowW, 0, ArrowW, c.height)

proc layoutEdit(c: ComboBox) =
  c.fEdit.visible = c.fStyle == csDropDown
  c.fEdit.setBounds(EditInset, EditInset,
                    max(c.width - EditInset - ArrowW, 0), max(c.height - 2 * EditInset, 0))

# --------------------------------------------------------------- selection

proc applySelection(c: ComboBox, user, force: bool) =
  ## The list's selection is the truth: show it, fire onChange/onSelect.
  let i = c.fList.itemIndex
  var newText: string
  if c.fStyle == csDropDown:
    newText = c.fEdit.text
    if i >= 0: newText = c.fList.itemText(i)
    elif c.fExplicit: newText = ""
    if newText != c.fEdit.text:
      c.fSyncing = true
      c.fEdit.text = newText
      c.fSyncing = false
    if i >= 0 and (user or force):
      c.fSyncing = true
      c.fEdit.selectAll()
      c.fSyncing = false
  else:
    newText = c.fList.itemText(i)
  let changed =
    if c.fStyle == csDropDownList: i != c.fLastIndex else: newText != c.fLastText
  c.fLastIndex = i
  c.fLastText = newText
  c.invalidate()
  if changed and c.onChange != nil: c.onChange(c)
  if (user or force) and (changed or force) and c.onSelect != nil: c.onSelect(c)

proc listChanged(c: ComboBox) =
  if c.fSyncing: return
  if c.fOpen:
    c.invalidate()
    return
  let u = c.fUser
  c.fUser = false
  c.applySelection(u, false)

proc `itemIndex=`*(c: ComboBox, v: int) =
  ## Selects item `v` (-1: none, which also clears the free text of a
  ## csDropDown). While the list is open the change is the committed value
  ## right away (closing without a pick keeps it).
  c.fExplicit = v < 0
  if c.fOpen:
    c.fSyncing = true
    c.fList.itemIndex = v
    c.fSyncing = false
    c.fOpenIndex = c.fList.itemIndex
  else:
    c.fList.itemIndex = v
  c.applySelection(false, false)      # idempotent after the list's own onChange
  c.fExplicit = false

proc `text=`*(c: ComboBox, v: string) =
  ## csDropDown: sets the edit text (the matching item is selected). List
  ## style: selects the item equal to `v` (none: no selection).
  if c.fStyle == csDropDown:
    c.fSyncing = true
    c.fEdit.text = v
    var idx = -1
    for i in 0 ..< c.fList.count:
      if c.fList.itemText(i) == v:
        idx = i
        break
    c.fList.itemIndex = idx
    c.fSyncing = false
    if c.fOpen: c.fOpenIndex = c.fList.itemIndex
    let changed = v != c.fLastText
    c.fLastText = v
    c.fLastIndex = idx
    c.invalidate()
    if changed and c.onChange != nil: c.onChange(c)
  else:
    var idx = -1
    for i in 0 ..< c.fList.count:
      if c.fList.itemText(i) == v:
        idx = i
        break
    c.itemIndex = idx

proc textEdited(c: ComboBox) =
  ## The user changed the edit text (typing, deleting, pasting, undo).
  let t = c.fEdit.text
  var idx = -1
  for i in 0 ..< c.fList.count:
    if c.fList.itemText(i) == t:
      idx = i
      break
  c.fSyncing = true
  c.fList.itemIndex = idx
  c.fSyncing = false
  c.fLastIndex = idx
  c.fLastText = t
  c.invalidate()
  if c.onChange != nil: c.onChange(c)

proc userSelect(c: ComboBox, i: int) =
  let n = c.fList.count
  if n == 0: return
  let t = clamp(i, 0, n - 1)
  if t == c.fList.itemIndex: return
  c.fUser = true
  c.fList.itemIndex = t
  c.fUser = false

proc autoCompleteText(c: ComboBox) =
  ## After typing: complete to the first item starting with the text.
  let e = c.fEdit
  let t = e.text
  if t.len == 0 or e.caretPos != t.len or e.selLength != 0: return
  let low = t.toLowerAscii
  for i in 0 ..< c.fList.count:
    let s = c.fList.itemText(i)
    if s.len > t.len and s.toLowerAscii.startsWith(low):
      e.replaceRange(0, t.len, s)        # the item's own spelling replaces the typed text
      e.select(t.len, s.len - t.len)
      return

# -------------------------------------------------------------- drop-down

proc closeUp*(c: ComboBox) =
  ## Closes the list without picking (a pick goes through the list's Enter/click).
  if c.fPopup != nil: closePopup(c.fPopup)

proc pickAndClose(c: ComboBox) =
  if c.fPopup == nil: return
  c.fCommit = true
  closePopup(c.fPopup)

method doKeyDown*(p: DropPanel, key: var Key, shift: ShiftState) =
  let c = p.combo
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
  if c.fOpen or not c.isEnabled: return
  let r = c.root
  if not (r of Form): return
  let f = Form(r)
  if not f.hasWindow or not f.visible: return
  if c.onDropDown != nil: c.onDropDown(c)
  let n = c.fList.count
  if n == 0: return
  let ih = c.itemRowHeight
  let rows = min(n, c.fDropCount)
  let w = if c.fDropWidth > 0: c.fDropWidth else: c.width
  let h = float32(rows) * ih + 2
  c.fList.font = c.font
  c.fList.itemHeight = ih
  c.fList.align = alClient
  c.fList.setBounds(0, 0, w, h)
  let panel = DropPanel(combo: c)
  panel.initContainer()
  panel.setBounds(0, 0, w, h)
  panel.insertControl c.fList
  c.fOpenIndex = c.fList.itemIndex
  let anchor = c.clientToForm(c.clientRect)
  c.fOpen = true
  c.fCommit = false
  let p = showPopup(f, panel, anchor, plBelow, pkMenu)
  c.fPopup = p
  p.onClosed = proc(q: PopupWindow) =
    c.fOpen = false
    c.fPopup = nil
    panel.removeControl c.fList
    if c.fCommit:
      c.fCommit = false
      c.applySelection(true, true)
    else:
      c.fSyncing = true
      c.fList.itemIndex = c.fOpenIndex
      c.fSyncing = false
    c.invalidate()
    if c.onCloseUp != nil: c.onCloseUp(c)
  p.ui.focusControl(c.fList)
  if c.fList.itemIndex >= 0: c.fList.makeVisible(c.fList.itemIndex)
  c.invalidate()

proc toggleDrop(c: ComboBox) =
  if c.fOpen: c.closeUp() else: c.dropDown()

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
  let idx = c.fList.itemIndex
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
    c.userSelect(c.fList.count - 1)
  elif list and key == keyPageDown:
    key = Key(0)
    c.userSelect(idx + c.fDropCount)
  elif list and key == keyPageUp:
    key = Key(0)
    c.userSelect(idx - c.fDropCount)
  elif list:
    # type-ahead by the list's own logic
    c.fUser = true
    c.fList.doKeyDown(key, shift)
    c.fUser = false

method doKeyDown*(e: ComboEdit, key: var Key, shift: ShiftState) =
  e.combo.handleKey(key, shift)
  if key != Key(0): procCall doKeyDown(Edit(e), key, shift)

method doKeyPress*(e: ComboEdit, text: var string) =
  let c = e.combo
  c.fSuppress = true
  c.fDirty = false
  try:
    procCall doKeyPress(Edit(e), text)
    if c.fDirty and c.fAutoComplete: c.autoCompleteText()
  finally:
    c.fSuppress = false
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

method doExit*(c: ComboBox) =
  procCall doExit(Container(c))
  c.invalidate()

method doResize*(c: ComboBox) =
  procCall doResize(Container(c))
  c.layoutEdit()

method doEnter*(c: ComboBox) =
  procCall doEnter(Container(c))
  c.invalidate()

# --------------------------------------------------------------------- paint

method paint*(c: ComboBox, cv: Canvas) =
  let t = c.theme
  let enabled = c.isEnabled
  let foc = c.focused or (c.fStyle == csDropDown and c.fEdit.focused)
  let r = c.clientRect
  let bg = if enabled: t.surface else: t.surfaceAlt
  let bc =
    if not enabled: t.border
    elif foc or c.fOpen: t.accent
    elif c.fHot: t.borderStrong
    else: t.border
  cv.fillRoundRect(r, t.radius, bg)
  let ar = c.arrowRect
  let btnRect = rectF(ar.x, ar.y + 1, ar.w - 1, ar.h - 2)
  if enabled and (c.fHot or c.fOpen):
    let hotArea = if c.fStyle == csDropDownList: rectF(1, 1, c.width - 2, c.height - 2)
                  else: btnRect
    cv.fillRoundRect(hotArea, max(t.radius - 1, 1), if c.fOpen: t.pressed else: t.hover)
  if c.fStyle == csDropDownList:
    let ta = rectF(8, 0, max(c.width - ArrowW - 8, 0), c.height)
    cv.textRect(c.text, c.font, ta, if enabled: t.text else: t.textDisabled,
                taLeft, vaCenter)
  cv.drawArrow(pointF(ar.x + ar.w / 2 - 0.5, ar.y + ar.h / 2), 4, adDown,
               if enabled: t.textMuted else: t.textDisabled)
  cv.strokeRoundRect(r, t.radius, bc, t.borderWidth)
  if foc and enabled: drawFocusRing(cv, r, t)
  procCall paint(Control(c), cv)

# ------------------------------------------------------------- construction

proc editItems(c: ComboBox, op: proc()) =
  ## Runs a structural change of the list. While the list is open the
  ## committed index follows its item (shifting / dropping with it) and the
  ## result is applied at once.
  if not c.fOpen:
    op()
    return
  c.fSyncing = true
  c.fList.itemIndex = c.fOpenIndex          # the list tracks the committed item
  c.fSyncing = false
  op()
  c.fOpenIndex = c.fList.itemIndex
  c.applySelection(false, false)

proc add*(c: ComboBox, s: string) = c.editItems(proc() = c.fList.add s)
proc insert*(c: ComboBox, index: int, s: string) =
  c.editItems(proc() = c.fList.insert(index, s))
proc delete*(c: ComboBox, i: int) = c.editItems(proc() = c.fList.delete i)
proc clear*(c: ComboBox) =
  c.editItems(proc() = c.fList.clear())
  if c.fStyle == csDropDownList: c.invalidate()
proc `[]`*(c: ComboBox, i: int): string = c.fList.itemText(i)
proc `items=`*(c: ComboBox, v: openArray[string]) =
  let items = @v
  c.editItems(proc() = c.fList.items = items)
proc `sorted=`*(c: ComboBox, v: bool) = c.fList.sorted = v

proc `style=`*(c: ComboBox, v: ComboStyle) =
  if v == c.fStyle: return
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
  c.fLastIndex = -1
  c.fList = DropList()
  c.fList.initListBox()
  c.fList.showFocusRect = false
  c.fList.tabStop = false
  c.fEdit = ComboEdit(combo: c)
  c.fEdit.initEdit(c)
  c.fEdit.borderStyle = ebNone
  c.insertControl c.fEdit
  c.setBounds(0, 0, 160, currentTheme().controlHeight)
  c.layoutEdit()
  c.fEdit.onChange = proc(s: Control) =
    if c.fSyncing: return
    if c.fSuppress: c.fDirty = true
    else: c.textEdited()
  c.fList.onChange = proc(s: Control) = c.listChanged()
  c.fList.onClick = proc(s: Control) =
    if c.fOpen and c.fList.itemIndex >= 0: c.pickAndClose()

proc newComboBox*(parent: Container = nil, style = csDropDown, left = 0'f32,
                  top = 0'f32, width = -1'f32, height = -1'f32): ComboBox =
  ## `parent` (also the owner) gets the control appended when non-nil.
  new result
  result.initComboBox(parent)
  result.style = style
  placeControl(result, parent, left, top, width, height)
