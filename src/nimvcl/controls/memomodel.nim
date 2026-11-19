## `MemoModel`: the multi-line text model behind `Memo`. Pure Nim, no SDL, no
## drawing.
##
## * The text is a `seq[string]` of lines (always at least one, possibly
##   empty), UTF-8, without line terminators. `text` joins them with "\n";
##   input with "\r\n" / "\r" is normalised to "\n". Control characters other
##   than TAB and newline and invalid UTF-8 are dropped on input.
## * A position is `MemoPos = (line, col)`; `col` is a BYTE index in the line,
##   always snapped to a codepoint boundary. The selection is
##   `anchor` .. `caret` (the caret is the moving end).
## * `offsetOf` / `posAtOffset` convert to byte offsets in the joined `text`
##   (a newline counts as one byte); they are O(lines), meant for the public
##   `selStart`/`selLength` API, not for per-keystroke work. Everything the
##   editing hot path does is O(size of the edit) plus the memmove of the line
##   table when lines are inserted or removed.
## * `maxLength` counts runes of the whole text (a newline is one rune), 0 =
##   unlimited. `readOnly` blocks user edits (insert, delete, undo, redo); the
##   programmatic `setText` and the line API still work.
## * Undo/redo is operation based (position + removed/inserted text), so its
##   cost does not depend on the document size. Typing coalesces within a word,
##   runs of Backspace and of Delete coalesce, everything else (paste, newline,
##   replacing a selection, word delete) is one step. Any caret move or
##   selection change breaks coalescing. `setText` and the line API clear the
##   history.
## * `onChanged(firstLine, oldCount, newCount)` fires after every change of the
##   lines: the lines `firstLine ..< firstLine+oldCount` were replaced by
##   `newCount` lines. Caches (layout, width) are invalidated from this.
## * `desiredCol` (rune column) is kept by `moveUp`/`moveDown` so a run of
##   vertical moves returns to the original column across short lines; any
##   other caret change forgets it. A view that moves by visual lines (wrap)
##   keeps its own pixel column instead.

import std/[unicode, strutils]
import ./textutil
export textutil.snapIndex, textutil.prevBoundary, textutil.nextBoundary,
       textutil.runeCount, textutil.runeColOf, textutil.byteOfRuneCol,
       textutil.wordLeftIn, textutil.wordRightIn, textutil.wordRangeIn

type
  MemoPos* = tuple[line, col: int]

  OpKind = enum opNone, opType, opDelBack, opDelFwd

  Op = object
    start: MemoPos
    removed, inserted: string
    anchorBefore, caretBefore, anchorAfter, caretAfter: MemoPos
    kind: OpKind

  MemoModel* = ref object
    lines: seq[string]
    fAnchor, fCaret: MemoPos
    fRunes: int                       ## runes in the whole text
    fMaxLength: int
    fReadOnly: bool
    fDesiredCol: int
    undoStack, redoStack: seq[Op]
    lastKind: OpKind
    lastWasWord: bool
    pend: tuple[first, oldN, newN: int]   # change recorded by spliceLines
    hasPend: bool
    onChanged*: proc(firstLine, oldCount, newCount: int)
    onSelection*: proc()

const MaxUndoSteps = 1000

# ------------------------------------------------------------------ helpers

func `<`*(a, b: MemoPos): bool = a.line < b.line or (a.line == b.line and a.col < b.col)
func `<=`*(a, b: MemoPos): bool = not (b < a)

func sanitize*(s: string): string =
  ## Newlines normalised to "\n"; control characters except TAB, DEL, C1 and
  ## invalid UTF-8 removed.
  let t = cleanUtf8(s)
  result = newStringOfCap(t.len)
  var i = 0
  while i < t.len:
    let c = t[i]
    if c == '\r':
      if i + 1 < t.len and t[i + 1] == '\n': inc i
      result.add '\n'
    elif c == '\n' or c == '\t': result.add c
    elif ord(c) < 0x20 or ord(c) == 0x7F: discard
    elif ord(c) == 0xC2 and i + 1 < t.len and ord(t[i + 1]) in 0x80 .. 0x9F:
      inc i                                   # C1 control
    else: result.add c
    inc i

# ------------------------------------------------------------------ queries

func lineCount*(m: MemoModel): int = m.lines.len
func line*(m: MemoModel, i: int): lent string = m.lines[i]
func lineLen*(m: MemoModel, i: int): int = m.lines[i].len
func caret*(m: MemoModel): MemoPos = m.fCaret
func anchor*(m: MemoModel): MemoPos = m.fAnchor
func selStartPos*(m: MemoModel): MemoPos = (if m.fAnchor < m.fCaret: m.fAnchor else: m.fCaret)
func selEndPos*(m: MemoModel): MemoPos = (if m.fAnchor < m.fCaret: m.fCaret else: m.fAnchor)
func hasSelection*(m: MemoModel): bool = m.fAnchor != m.fCaret
func maxLength*(m: MemoModel): int = m.fMaxLength
func readOnly*(m: MemoModel): bool = m.fReadOnly
func canUndo*(m: MemoModel): bool = m.undoStack.len > 0
func canRedo*(m: MemoModel): bool = m.redoStack.len > 0
func desiredCol*(m: MemoModel): int = m.fDesiredCol
func runeLen*(m: MemoModel): int = m.fRunes
proc `maxLength=`*(m: MemoModel, v: int) = m.fMaxLength = max(v, 0)
proc `readOnly=`*(m: MemoModel, v: bool) = m.fReadOnly = v

func snapPos*(m: MemoModel, p: MemoPos): MemoPos =
  let l = clamp(p.line, 0, m.lines.high)
  (l, snapIndex(m.lines[l], p.col))

func textBetween*(m: MemoModel, a, b: MemoPos): string =
  ## The text from `a` to `b` (a <= b), lines joined with "\n".
  if a.line == b.line: return m.lines[a.line][a.col ..< b.col]
  result = m.lines[a.line][a.col .. ^1]
  for i in a.line + 1 ..< b.line:
    result.add '\n'
    result.add m.lines[i]
  result.add '\n'
  result.add m.lines[b.line][0 ..< b.col]

func selectedText*(m: MemoModel): string = m.textBetween(m.selStartPos, m.selEndPos)

func text*(m: MemoModel): string =
  var total = m.lines.len - 1
  for l in m.lines: total += l.len
  result = newStringOfCap(total)
  for i, l in m.lines:
    if i > 0: result.add '\n'
    result.add l

func offsetOf*(m: MemoModel, p: MemoPos): int =
  let q = m.snapPos(p)
  for i in 0 ..< q.line: result += m.lines[i].len + 1
  result += q.col

func posAtOffset*(m: MemoModel, off: int): MemoPos =
  var rest = max(off, 0)
  for i, l in m.lines:
    if rest <= l.len: return m.snapPos((i, rest))
    rest -= l.len + 1
  (m.lines.high, m.lines[^1].len)

func selStart*(m: MemoModel): int = m.offsetOf(m.selStartPos)
func selLength*(m: MemoModel): int = m.offsetOf(m.selEndPos) - m.offsetOf(m.selStartPos)
func docEnd*(m: MemoModel): MemoPos = (m.lines.high, m.lines[^1].len)

# -------------------------------------------------------------- construction

proc fireChanged(m: MemoModel, first, oldN, newN: int) =
  if m.onChanged != nil: m.onChanged(first, oldN, newN)

proc flushChanged(m: MemoModel) =
  ## Fires the change recorded by `spliceLines` (after caret / anchor are
  ## final, so handlers see a consistent model).
  if m.hasPend:
    m.hasPend = false
    m.fireChanged(m.pend.first, m.pend.oldN, m.pend.newN)

proc fireSel(m: MemoModel) =
  if m.onSelection != nil: m.onSelection()

proc newMemoModel*(text = ""): MemoModel =
  result = MemoModel(fDesiredCol: -1)
  result.lines = splitAtNewlines(sanitize(text))
  for l in result.lines: result.fRunes += runeCount(l)
  result.fRunes += result.lines.len - 1

proc breakCoalesce(m: MemoModel) {.inline.} = m.lastKind = opNone

# ------------------------------------------------------- caret / selection

proc setCaret*(m: MemoModel, pos: MemoPos, extend = false) =
  ## Moves the caret (snapped); without `extend` the selection collapses.
  let old = (m.fAnchor, m.fCaret)
  m.fCaret = m.snapPos(pos)
  if not extend: m.fAnchor = m.fCaret
  m.fDesiredCol = -1
  m.breakCoalesce()
  if (m.fAnchor, m.fCaret) != old: m.fireSel()

proc select*(m: MemoModel, a, b: MemoPos) =
  ## Selects from `a` (anchor) to `b` (caret).
  let old = (m.fAnchor, m.fCaret)
  m.fAnchor = m.snapPos(a)
  m.fCaret = m.snapPos(b)
  m.fDesiredCol = -1
  m.breakCoalesce()
  if (m.fAnchor, m.fCaret) != old: m.fireSel()

proc selectAll*(m: MemoModel) = m.select((0, 0), m.docEnd)

proc selectWord*(m: MemoModel, at: MemoPos) =
  let p = m.snapPos(at)
  let (a, b) = wordRangeIn(m.lines[p.line], p.col)
  m.select((p.line, a), (p.line, b))

proc selectLine*(m: MemoModel, line: int) =
  ## Selects the whole line including its line break (not on the last line).
  let l = clamp(line, 0, m.lines.high)
  if l < m.lines.high: m.select((l, 0), (l + 1, 0))
  else: m.select((l, 0), (l, m.lines[l].len))

proc moveLeft*(m: MemoModel, extend = false) =
  if m.hasSelection and not extend: m.setCaret(m.selStartPos)
  else:
    let c = m.fCaret
    if c.col > 0: m.setCaret((c.line, prevBoundary(m.lines[c.line], c.col)), extend)
    elif c.line > 0: m.setCaret((c.line - 1, m.lines[c.line - 1].len), extend)
    else: m.setCaret(c, extend)

proc moveRight*(m: MemoModel, extend = false) =
  if m.hasSelection and not extend: m.setCaret(m.selEndPos)
  else:
    let c = m.fCaret
    if c.col < m.lines[c.line].len:
      m.setCaret((c.line, nextBoundary(m.lines[c.line], c.col)), extend)
    elif c.line < m.lines.high: m.setCaret((c.line + 1, 0), extend)
    else: m.setCaret(c, extend)

proc moveVertical(m: MemoModel, delta: int, extend: bool) =
  let c = m.fCaret
  let target = c.line + delta
  if target < 0:
    m.setCaret((0, 0), extend)
    return
  if target > m.lines.high:
    m.setCaret(m.docEnd, extend)
    return
  let want = if m.fDesiredCol >= 0: m.fDesiredCol else: runeColOf(m.lines[c.line], c.col)
  m.setCaret((target, byteOfRuneCol(m.lines[target], want)), extend)
  m.fDesiredCol = want

proc moveUp*(m: MemoModel, extend = false) = m.moveVertical(-1, extend)
proc moveDown*(m: MemoModel, extend = false) = m.moveVertical(1, extend)
proc moveLines*(m: MemoModel, delta: int, extend = false) = m.moveVertical(delta, extend)
proc moveHome*(m: MemoModel, extend = false) = m.setCaret((m.fCaret.line, 0), extend)
proc moveEnd*(m: MemoModel, extend = false) =
  m.setCaret((m.fCaret.line, m.lines[m.fCaret.line].len), extend)
proc moveDocStart*(m: MemoModel, extend = false) = m.setCaret((0, 0), extend)
proc moveDocEnd*(m: MemoModel, extend = false) = m.setCaret(m.docEnd, extend)

func wordLeftPos*(m: MemoModel, p: MemoPos): MemoPos =
  if p.col == 0:
    if p.line > 0: (p.line - 1, m.lines[p.line - 1].len) else: p
  else: (p.line, wordLeftIn(m.lines[p.line], p.col))

func wordRightPos*(m: MemoModel, p: MemoPos): MemoPos =
  if p.col >= m.lines[p.line].len:
    if p.line < m.lines.high: (p.line + 1, 0) else: p
  else: (p.line, wordRightIn(m.lines[p.line], p.col))

proc moveWordLeft*(m: MemoModel, extend = false) =
  m.setCaret(m.wordLeftPos(m.fCaret), extend)
proc moveWordRight*(m: MemoModel, extend = false) =
  m.setCaret(m.wordRightPos(m.fCaret), extend)

# ------------------------------------------------------------------ editing

proc spliceLines(m: MemoModel, a, b: MemoPos, repl: string): MemoPos =
  ## Raw replacement of [a, b) by `repl`; returns the end of the inserted text.
  ## Updates the rune count and records the change (`flushChanged` fires
  ## `onChanged` once the caller has set caret and anchor).
  let removedRunes = block:
    var n = 0
    if a.line == b.line: n = runeCount(m.lines[a.line][a.col ..< b.col])
    else:
      n = runeCount(m.lines[a.line][a.col .. ^1]) + 1 + runeCount(m.lines[b.line][0 ..< b.col])
      for i in a.line + 1 ..< b.line: n += runeCount(m.lines[i]) + 1
    n
  let head = m.lines[a.line][0 ..< a.col]
  let tail = m.lines[b.line][b.col .. ^1]
  let oldN = b.line - a.line + 1
  let insRunes = runeCount(repl) # newlines are one rune each
  m.fRunes += insRunes - removedRunes
  if oldN == 1 and repl.find('\n') < 0:          # the common keystroke
    m.lines[a.line] = head & repl & tail
    m.pend = (a.line, 1, 1)
    m.hasPend = true
    return (a.line, a.col + repl.len)
  var parts = splitAtNewlines(repl)
  parts[0] = head & parts[0]
  result = (a.line + parts.high, parts[^1].len)
  parts[^1].add tail
  m.lines.replaceRange(a.line, oldN, parts)
  m.pend = (a.line, oldN, parts.len)
  m.hasPend = true

proc pushOp(m: MemoModel, op: Op) =
  m.undoStack.add op
  if m.undoStack.len > MaxUndoSteps: m.undoStack.delete(0)
  m.redoStack.setLen 0

proc edit(m: MemoModel, a, b: MemoPos, repl: string, kind: OpKind,
          isWord = false, newCaret: MemoPos = (-1, -1)) =
  ## The one editing primitive for user edits (undo recorded, coalesced by `kind`).
  let before = (m.fAnchor, m.fCaret)
  let removed = m.textBetween(a, b)
  var coalesced = false
  if kind != opNone and m.lastKind == kind and m.undoStack.len > 0 and
     m.redoStack.len == 0:
    template last: untyped = m.undoStack[^1]
    case kind
    of opType:
      if removed.len == 0 and a == endOfInsert(last.start, last.inserted):
        let ep = m.spliceLines(a, b, repl)
        last.inserted.add repl
        last.anchorAfter = ep
        last.caretAfter = ep
        m.fAnchor = ep
        m.fCaret = ep
        coalesced = true
    of opDelBack:
      if b == last.start:
        discard m.spliceLines(a, b, repl)
        last.start = a
        last.removed = removed & last.removed
        last.anchorAfter = a
        last.caretAfter = a
        m.fAnchor = a
        m.fCaret = a
        coalesced = true
    of opDelFwd:
      if a == last.start:
        discard m.spliceLines(a, b, repl)
        last.removed.add removed
        last.anchorAfter = a
        last.caretAfter = a
        m.fAnchor = a
        m.fCaret = a
        coalesced = true
    else: discard
  if not coalesced:
    let ep = m.spliceLines(a, b, repl)
    let c = if newCaret.line >= 0: newCaret else: ep
    m.fAnchor = c
    m.fCaret = c
    m.pushOp Op(start: a, removed: removed, inserted: repl,
                anchorBefore: before[0], caretBefore: before[1],
                anchorAfter: c, caretAfter: c, kind: kind)
  m.redoStack.setLen 0
  m.fDesiredCol = -1
  m.lastKind = kind
  m.lastWasWord = isWord
  m.flushChanged()
  m.fireSel()

proc insert*(m: MemoModel, s: string): bool =
  ## Replaces the selection with `s` (sanitised, newlines split lines, cut to
  ## `maxLength`). True when the text changed.
  if m.fReadOnly: return false
  var ins = sanitize(s)
  if m.fMaxLength > 0:
    let selRunes = if m.hasSelection: runeCount(m.selectedText) else: 0
    ins = truncateRunes(ins, max(m.fMaxLength - (m.fRunes - selRunes), 0))
  if ins.len == 0: return false
  let single = runeCount(ins) == 1 and ins != "\n"
  let isWord = single and charClass(runeAt(ins, 0)) == ccWord
  let kind = if single: opType else: opNone
  # a letter after a non-letter starts a new step: break coalescing first
  if single and isWord and not m.lastWasWord: m.lastKind = opNone
  m.edit(m.selStartPos, m.selEndPos, ins, kind, isWord)
  true

proc deleteSelection*(m: MemoModel): bool =
  if m.fReadOnly or not m.hasSelection: return false
  m.edit(m.selStartPos, m.selEndPos, "", opNone)
  true

proc deleteBackward*(m: MemoModel, word = false): bool =
  ## Backspace: the selection, else the rune (or word) before the caret; at
  ## the start of a line it joins with the previous one.
  if m.fReadOnly: return false
  if m.hasSelection: return m.deleteSelection()
  let c = m.fCaret
  if c.line == 0 and c.col == 0: return false
  var a: MemoPos
  if c.col == 0: a = (c.line - 1, m.lines[c.line - 1].len)
  elif word: a = (c.line, wordLeftIn(m.lines[c.line], c.col))
  else: a = (c.line, prevBoundary(m.lines[c.line], c.col))
  m.edit(a, c, "", (if word: opNone else: opDelBack))
  true

proc deleteForward*(m: MemoModel, word = false): bool =
  if m.fReadOnly: return false
  if m.hasSelection: return m.deleteSelection()
  let c = m.fCaret
  var b: MemoPos
  if c.col >= m.lines[c.line].len:
    if c.line >= m.lines.high: return false
    b = (c.line + 1, 0)
  elif word: b = (c.line, wordRightIn(m.lines[c.line], c.col))
  else: b = (c.line, nextBoundary(m.lines[c.line], c.col))
  m.edit(c, b, "", (if word: opNone else: opDelFwd))
  true

proc deleteLine*(m: MemoModel): bool =
  ## Deletes the caret's line including its break (Ctrl+Shift+K style).
  if m.fReadOnly: return false
  let l = m.fCaret.line
  if m.lines.len == 1:
    if m.lines[0].len == 0: return false
    m.edit((0, 0), (0, m.lines[0].len), "", opNone)
  elif l < m.lines.high: m.edit((l, 0), (l + 1, 0), "", opNone)
  else: m.edit((l - 1, m.lines[l - 1].len), (l, m.lines[l].len), "", opNone)
  true

proc setText*(m: MemoModel, s: string): bool {.discardable.} =
  ## Programmatic assignment: sanitised, cut to `maxLength`; the caret goes
  ## to the start; the undo history is cleared. Works when read-only. True
  ## when the text differs from the old one.
  var t = sanitize(s)
  if m.fMaxLength > 0: t = truncateRunes(t, m.fMaxLength)
  let oldN = m.lines.len
  let newLines = splitAtNewlines(t)
  result = newLines != m.lines
  m.lines = newLines
  m.fRunes = m.lines.len - 1
  for l in m.lines: m.fRunes += runeCount(l)
  m.fAnchor = (0, 0)
  m.fCaret = (0, 0)
  m.fDesiredCol = -1
  m.undoStack.setLen 0
  m.redoStack.setLen 0
  m.lastKind = opNone
  m.fireChanged(0, oldN, m.lines.len)
  m.fireSel()

proc clear*(m: MemoModel) = m.setText("")

# programmatic line API (clears undo; `lines.add` etc. of the control)
proc afterLineApi(m: MemoModel, first, oldN, newN: int) =
  m.undoStack.setLen 0
  m.redoStack.setLen 0
  m.lastKind = opNone
  m.fAnchor = m.snapPos(m.fAnchor)
  m.fCaret = m.snapPos(m.fCaret)
  m.fDesiredCol = -1
  m.fireChanged(first, oldN, newN)      # after the caret is valid again
  m.fireSel()

proc lineIndexError(what: string, i, hi: int) {.noinline.} =
  raise newException(IndexDefect, what & ": line index " & $i &
                     " out of bounds 0.." & $hi)

proc setLine*(m: MemoModel, i: int, s: string) =
  ## Replaces line `i` (line breaks in `s` become spaces; cut to `maxLength`).
  ## Raises IndexDefect when `i` is out of range.
  if i < 0 or i >= m.lines.len: lineIndexError("setLine", i, m.lines.high)
  var t = sanitize(s).replace("\n", " ")
  let oldRunes = runeCount(m.lines[i])
  if m.fMaxLength > 0:
    t = truncateRunes(t, max(m.fMaxLength - (m.fRunes - oldRunes), 0))
  m.fRunes += runeCount(t) - oldRunes
  m.lines[i] = t
  m.afterLineApi(i, 1, 1)

proc insertLine*(m: MemoModel, i: int, s: string) =
  ## Inserts a line before index `i` (`i == lineCount` appends). A text with
  ## "\n" inserts several lines. Raises IndexDefect when `i` is outside
  ## 0 .. lineCount. With a `maxLength` the text is cut to what still fits
  ## (each line costs one line break); nothing is inserted when not even the
  ## break fits.
  if i < 0 or i > m.lines.len: lineIndexError("insertLine", i, m.lines.len)
  var t = sanitize(s)
  if m.fMaxLength > 0:
    let room = m.fMaxLength - m.fRunes - 1
    if room < 0: return
    t = truncateRunes(t, room)
  let parts = splitAtNewlines(t)
  m.lines.replaceRange(i, 0, parts)
  for p in parts: m.fRunes += runeCount(p) + 1
  m.afterLineApi(i, 0, parts.len)

proc deleteLineAt*(m: MemoModel, i: int) =
  if i < 0 or i >= m.lines.len: return
  if m.lines.len == 1:
    m.fRunes = 0
    m.lines[0] = ""
    m.afterLineApi(0, 1, 1)
  else:
    m.fRunes -= runeCount(m.lines[i]) + 1
    m.lines.delete(i)
    m.afterLineApi(i, 1, 0)

# ------------------------------------------------------------- undo / redo

proc restoreSel(m: MemoModel, a, c: MemoPos) =
  m.fAnchor = m.snapPos(a)
  m.fCaret = m.snapPos(c)
  m.fDesiredCol = -1
  m.lastKind = opNone

proc undo*(m: MemoModel): bool =
  if m.fReadOnly or m.undoStack.len == 0: return false
  let op = m.undoStack.pop()
  discard m.spliceLines(op.start, endOfInsert(op.start, op.inserted), op.removed)
  m.restoreSel(op.anchorBefore, op.caretBefore)
  m.redoStack.add op
  m.flushChanged()
  m.fireSel()
  true

proc redo*(m: MemoModel): bool =
  if m.fReadOnly or m.redoStack.len == 0: return false
  let op = m.redoStack.pop()
  discard m.spliceLines(op.start, endOfInsert(op.start, op.removed), op.inserted)
  m.restoreSel(op.anchorAfter, op.caretAfter)
  m.undoStack.add op
  m.flushChanged()
  m.fireSel()
  true
