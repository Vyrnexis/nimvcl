## Machinery shared by the row views (`ListBox`, `ListView`, `TreeView`,
## `DrawGrid`): incremental search by typed prefix (`TypeAhead`), the
## Up/Down/Home/End/PageUp/PageDown target math (`rowNavTarget`) with the
## selection updates of clicks and keyboard moves on an `IndexSet`
## (`selectOnly`, `selectRange`, `clickSelect`, `keySelect`), and the in-place
## `Edit` with its slow-click timer (`InPlaceEditor`, `SlowClick`).
##
## Everything here is state-light: the controls own their index fields and ask
## these helpers what to do, so each control keeps its own events and layout.

import std/[monotimes, strutils, math]
import ../core/timer
import ./common, ./edit, ./indexset

proc nowMs*(): int64 = getMonoTime().ticks div 1_000_000

func prefixIC*(s, lowerPrefix: string): bool =
  ## `s` starts with `lowerPrefix` (ASCII case-insensitive; the prefix is already lower case).
  if s.len < lowerPrefix.len: return false
  for j in 0 ..< lowerPrefix.len:
    if toLowerAscii(s[j]) != lowerPrefix[j]: return false
  true

# --------------------------------------------------------------- type-ahead

type
  TypeAhead* = object
    ## Typed characters accumulate into a prefix until `timeout` ms pass
    ## without a key.
    buf: string
    time: int64
    timeout*: int              ## ms; 1000 by default

func initTypeAhead*(timeout = 1000): TypeAhead = TypeAhead(timeout: timeout)

proc typeAheadChar*(key: Key, shift: ShiftState): char =
  ## The printable ASCII character of `key` for type-ahead, '\0' otherwise.
  ## With Shift only letters count (shifted digits / symbols arrive as text and
  ## are not type-ahead).
  if shift * {ssCtrl, ssSuper, ssAlt} != {}: return '\0'
  let v = uint32(key)
  if v >= 0x20 and v < 0x7f:
    if ssShift in shift and not (v >= 0x61 and v <= 0x7a): return '\0'
    char(v)
  else: '\0'

proc running*(t: TypeAhead): bool =
  ## A prefix is being typed (the last key is younger than the timeout).
  t.buf.len > 0 and nowMs() - t.time <= t.timeout

proc keyChar*(t: TypeAhead, key: Key, shift: ShiftState): char =
  ## The character `key` contributes to the search, '\0' when it is no
  ## type-ahead key. A leading space is not one (it belongs to the control).
  result = typeAheadChar(key, shift)
  if result == ' ' and not t.running: result = '\0'

proc reset*(t: var TypeAhead) = t.buf.setLen(0)

proc feed*(t: var TypeAhead, ch: char) =
  ## Adds `ch` to the prefix (restarting it after the timeout).
  let now = nowMs()
  if now - t.time > t.timeout: t.buf.setLen(0)
  t.time = now
  t.buf.add toLowerAscii(ch)

proc find*(t: TypeAhead, cur, n: int, text: proc(i: int): string): int =
  ## Index of the item to jump to for the current prefix, -1 for none. A new
  ## prefix starts after `cur`, a longer one may stay on it. `text(i)` is the
  ## item text.
  if n <= 0 or t.buf.len == 0: return -1
  let start = if t.buf.len == 1: cur + 1 else: max(cur, 0)
  for k in 0 ..< n:
    let i = (start + k) mod n
    if prefixIC(text(i), t.buf): return i
  -1

proc search*(t: var TypeAhead, ch: char, cur, n: int,
             text: proc(i: int): string): int =
  ## `feed` then `find`.
  t.feed ch
  t.find(cur, n, text)

# ----------------------------------------------------------- row navigation

const NotNav* = low(int)       ## `rowNavTarget`: not a navigation key

proc rowNavTarget*(key: Key, cur, n, firstFull, lastFull: int): int =
  ## Target row of Up/Down/Home/End/PageUp/PageDown for a one-column list:
  ## `cur` is the focused row (-1 none), `n` the row count, `firstFull` /
  ## `lastFull` the first and last completely visible rows. PageDown goes to
  ## the last full row, and when already there by a page minus one row.
  ## `NotNav` for any other key; the result is not clamped (it may be -1 or
  ## `n`): use `clampRow`.
  let span = max(lastFull - firstFull, 1)
  if key == keyUp: result = if cur < 0: 0 else: cur - 1
  elif key == keyDown: result = cur + 1
  elif key == keyHome: result = 0
  elif key == keyEnd: result = n - 1
  elif key == keyPageDown: result = if cur < lastFull: lastFull else: cur + span
  elif key == keyPageUp: result = if cur > firstFull: firstFull else: cur - span
  else: result = NotNav

func clampRow*(target, n: int): int = min(max(target, 0), n - 1)

proc firstFullRowAt*(scrollY: float64, rowH: float32): int =
  int(ceil(scrollY / float64(rowH)))

proc lastFullRowAt*(scrollY: float64, viewH, rowH: float32, count: int): int =
  min(int(floor((scrollY + float64(viewH)) / float64(rowH))) - 1, count - 1)

# ------------------------------------------------------ selection updates

proc selectOnly*(sel: var IndexSet, i: int): bool =
  ## Makes `i` the only selected row (`i < 0`: none). True when it changed.
  if sel.len == 1 and i in sel: return false
  if i < 0 and sel.len == 0: return false
  sel.clear()
  if i >= 0: sel.incl i
  true

proc selectRange*(sel: var IndexSet, a, b: int): bool =
  ## Selects exactly the rows between `a` and `b`. True when it changed.
  var s = initIndexSet()
  s.inclRange(a, b)
  if s == sel: return false
  sel = s
  true

proc clickSelect*(sel: var IndexSet, anchor: var int, i: int,
                  multi, extended: bool, shift: ShiftState): bool =
  ## Selection after a click on row `i`: plain replaces, Ctrl toggles and
  ## Shift extends from the anchor (extended multi-select); a simple
  ## multi-select list toggles. True when the selection changed.
  if multi:
    if extended:
      if ssShift in shift and anchor >= 0:
        result = sel.selectRange(anchor, i)
      elif ssCtrl in shift:
        sel.toggle i
        anchor = i
        result = true
      else:
        result = sel.selectOnly(i)
        anchor = i
    else:
      sel.toggle i
      anchor = i
      result = true
  else:
    result = sel.selectOnly(i)
    anchor = i

proc keySelect*(sel: var IndexSet, anchor: var int, cur, target: int,
                multi, extended: bool, shift: ShiftState): bool =
  ## Selection after a keyboard move from `cur` to `target`: Shift extends
  ## from the anchor, Ctrl moves the focus only (extended multi-select), a
  ## simple multi-select list only moves the focus. True when it changed.
  if multi:
    if extended and ssShift in shift:
      if anchor < 0: anchor = max(cur, 0)
      result = sel.selectRange(anchor, target)
    elif extended and ssCtrl notin shift:
      result = sel.selectOnly(target)
      anchor = target
  else:
    result = sel.selectOnly(target)
    anchor = target

# ------------------------------------------------------------ in-place edit

type
  EditFinish* = proc(cancel: bool) {.closure.}
  EditKeyHook* = proc(key: var Key, shift: ShiftState) {.closure.}

  InPlaceEditor* = object
    ## The `Edit` a view shows over a row/cell. Created on first use as a
    ## hidden, non-tab-stop child of the view. Enter commits and Escape
    ## cancels through `finish`; losing the focus commits.
    edit*: Edit

proc ensure*(ed: var InPlaceEditor, owner: Container, finish: EditFinish,
             keyHook: EditKeyHook = nil, exitHook: proc() {.closure.} = nil) =
  ## Creates the edit control. `keyHook` replaces the Enter/Escape handling
  ## and `exitHook` the commit-on-focus-loss (the grid needs its own).
  if ed.edit != nil: return
  let e = newEdit(owner)
  e.visible = false
  e.tabStop = false
  if keyHook != nil:
    e.onKeyDown = proc(s: Control, key: var Key, shift: ShiftState) =
      keyHook(key, shift)
  else:
    e.onKeyDown = proc(s: Control, key: var Key, shift: ShiftState) =
      if key == keyEnter: key = Key(0); finish(false)
      elif key == keyEscape: key = Key(0); finish(true)
  if exitHook != nil:
    e.onExit = proc(s: Control) = exitHook()
  else:
    e.onExit = proc(s: Control) = finish(false)
  ed.edit = e

proc show*(ed: InPlaceEditor, text: string, selectAll = true) =
  ## Fills, shows and focuses the editor (position it with `setBounds`).
  ed.edit.text = text
  ed.edit.visible = true
  ed.edit.setFocus()
  if selectAll: ed.edit.selectAll()

proc text*(ed: InPlaceEditor): string =
  if ed.edit != nil: ed.edit.text else: ""

proc hide*(ed: InPlaceEditor, owner: Control, refocus = true) =
  ## Hides the editor; the view takes the focus back when the editor had it.
  if ed.edit == nil: return
  let had = ed.edit.focused
  ed.edit.visible = false
  if refocus and had: owner.setFocus()

# --------------------------------------------------------------- slow click

type
  SlowClick* = object
    ## The "click the selected item again" timer that starts an edit.
    timer: Timer

proc cancel*(s: SlowClick) =
  if s.timer != nil: s.timer.enabled = false

proc arm*(s: var SlowClick, delay: int, fire: proc() {.closure.}) =
  ## Calls `fire` once after `delay` ms unless cancelled or re-armed.
  if s.timer == nil: s.timer = newTimer(nil, max(delay, 1))
  let t = s.timer
  t.enabled = false
  t.interval = max(delay, 1)
  t.onTimer = proc(x: Timer) =
    x.enabled = false
    fire()
  t.enabled = true
