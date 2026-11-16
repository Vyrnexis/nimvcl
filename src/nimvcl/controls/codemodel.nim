## `CodeModel`: the text buffer behind `CodeEdit`. Pure Nim, no SDL, no
## drawing.
##
## Why not `MemoModel`? Memo normalises its input (control characters and
## invalid bytes are dropped, every line ending becomes "\n"), couples undo to
## one caret and walks the whole text on load. A code buffer must round-trip a
## file byte for byte where it can (line endings, trailing newline, tabs,
## control characters) and report what it had to repair. So `CodeModel` is its
## own type, built on the same proven representation: a `seq[string]` of lines.
## Measured against a lazily split buffer or a piece table, the eager line
## array loads 100 MB / 2M lines well inside one second in release mode (see
## `tests/tcodeperf.nim`), keeps `line(i)` a zero-copy `lent string` for the
## lexers and the painter, and keeps every edit O(size of the edit) plus a
## memmove of the line table when the line count changes.
##
## * Lines are UTF-8 without terminators; there is always at least one line.
##   Only "\n" separates lines. A "\r" directly before a "\n" is the CRLF
##   terminator and is stripped; a lone "\r" stays in the line text.
##   `lineEnding` (dominant style: LF or CRLF), `mixedEndings` and
##   `trailingNewline` are detected on load and used by `toText` / `saveFile`,
##   so an untouched file is written back identically (a file with mixed
##   endings is normalised to the dominant one). A text that ends with a
##   newline simply has an empty last line, which is also what an editor
##   shows.
## * Encoding is UTF-8. Invalid bytes are replaced by U+FFFD on load (and on
##   every insert) and counted in `LoadReport.invalidBytes`; the model never
##   holds an invalid sequence, so a caret can always snap to a boundary.
## * A position is `CodePos = (line, col)`; `col` is a BYTE index, always
##   snapped to a codepoint boundary by every public operation. Tabs are
##   stored as-is; `tabWidth` plus `visualCol` / `colAtVisual` convert between
##   byte columns and screen columns (every codepoint is one cell; wide CJK
##   and combining marks are not special-cased yet).
## * The selection state is a `seq[Selection]` (at least one, the first is
##   the primary). Edits take explicit ranges, so several carets can be
##   edited inside one `beginGroup` .. `endGroup` (one undo step); the
##   convenience editors (`typeText`, `deleteBackward`, ...) work on the
##   primary selection.
## * Undo/redo is operation based (position + removed/inserted text), so its
##   cost does not depend on the document size. Steps restore the selections
##   from before / after. Typing coalesces while the typed character class
##   stays the same (a word, a run of spaces, a run of punctuation), runs of
##   Backspace and of Delete coalesce, everything else (paste, newline,
##   replace) is one step. `beginGroup` / `endGroup` merge any number of edits
##   into one step. Setting the selection or `breakGroup` ends coalescing.
## * Change notification: listeners get `(firstLine, oldCount, newCount)`:
##   the lines `firstLine ..< firstLine + oldCount` were replaced by
##   `newCount` lines. The highlighter cache and the fold map subscribe to it.

import std/[unicode, strutils]
import ./editmodel
export editmodel.snapIndex, editmodel.prevBoundary, editmodel.nextBoundary,
       editmodel.runeCount

type
  CodePos* = tuple[line, col: int]

  Selection* = object
    ## `anchor` is the fixed end, `caret` the moving one.
    anchor*, caret*: CodePos

  LineEnding* = enum leLF, leCRLF

  LoadReport* = object
    bytes*, lines*: int
    invalidBytes*: int        ## bytes replaced by U+FFFD
    lineEnding*: LineEnding   ## the dominant style
    mixedEndings*: bool       ## both LF and CRLF terminators were present
    trailingNewline*: bool

  EditKind* = enum
    ekOther       ## its own undo step
    ekTyping      ## coalesces with an adjacent run of the same character class
    ekDelBack     ## coalesces with Backspace runs
    ekDelFwd      ## coalesces with Delete runs

  ChangeHandler* = proc(firstLine, oldCount, newCount: int) {.closure.}

  CharClass* = enum ccSpace, ccWord, ccOther

  Op = object
    pos: CodePos
    removed, inserted: string

  UndoStep = object
    ops: seq[Op]
    selBefore, selAfter: seq[Selection]

  CodeModel* = ref object
    lines: seq[string]
    sels: seq[Selection]
    fTabWidth: int
    fLineEnding: LineEnding
    fMixed: bool
    fReadOnly: bool
    fVersion: int
    listeners: seq[tuple[id: int, cb: ChangeHandler]]
    nextListenerId: int
    undoStack, redoStack: seq[UndoStep]
    groupDepth: int
    newStepPending: bool
    lastKind: EditKind
    lastClass: CharClass
    lastPos: CodePos
    savedStep: int            ## undoStack.len at the last save; -1 = unreachable
    fModified: bool
    maxUndo: int
    onSelection*: proc()

const
  DefaultMaxUndo = 10_000
  Replacement = "\xEF\xBF\xBD"

# ------------------------------------------------------------------ helpers

func `<`*(a, b: CodePos): bool = a.line < b.line or (a.line == b.line and a.col < b.col)
func `<=`*(a, b: CodePos): bool = not (b < a)

func sel*(anchor, caret: CodePos): Selection = Selection(anchor: anchor, caret: caret)
func sel*(p: CodePos): Selection = Selection(anchor: p, caret: p)
func isEmpty*(s: Selection): bool = s.anchor == s.caret
func startPos*(s: Selection): CodePos = (if s.anchor < s.caret: s.anchor else: s.caret)
func endPos*(s: Selection): CodePos = (if s.anchor < s.caret: s.caret else: s.anchor)

func runeAt(s: string, i: int): Rune =
  var r: Rune
  fastRuneAt(s, i, r, false)
  r

func runeBefore(s: string, i: int): Rune = runeAt(s, prevBoundary(s, i))

func charClass*(r: Rune): CharClass =
  ## Code word classes: identifier characters (letters, digits, `_`), spaces,
  ## everything else.
  let v = int(r)
  if v < 128:
    let c = char(v)
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: ccWord
    elif c in {' ', '\t', '\v', '\f', '\r', '\n'}: ccSpace
    else: ccOther
  elif r.isWhiteSpace: ccSpace
  elif r.isAlpha: ccWord
  else: ccOther

func isIdentRune*(r: Rune): bool = charClass(r) == ccWord

func utf8SeqLen(s: string, i: int): int =
  ## Length of the valid UTF-8 sequence at `i`, 0 if it is invalid.
  let b0 = ord(s[i])
  if b0 < 0x80: return 1
  proc cont(s: string, j: int): int {.inline.} =
    if j < s.len: ord(s[j]) else: 0
  template isC(x: int): bool = (x and 0xC0) == 0x80
  if b0 in 0xC2 .. 0xDF:
    if isC(cont(s, i + 1)): return 2
  elif b0 in 0xE0 .. 0xEF:
    let b1 = cont(s, i + 1)
    let lo = if b0 == 0xE0: 0xA0 else: 0x80
    let hi = if b0 == 0xED: 0x9F else: 0xBF
    if b1 in lo .. hi and isC(cont(s, i + 2)): return 3
  elif b0 in 0xF0 .. 0xF4:
    let b1 = cont(s, i + 1)
    let lo = if b0 == 0xF0: 0x90 else: 0x80
    let hi = if b0 == 0xF4: 0x8F else: 0xBF
    if b1 in lo .. hi and isC(cont(s, i + 2)) and isC(cont(s, i + 3)): return 4
  0

proc firstInvalidUtf8(s: string, start = 0, stop = -1): int =
  ## Index of the first invalid byte in `s[start ..< stop]`, or -1.
  let n = if stop < 0: s.len else: stop
  var i = start
  while i < n:
    if i + 8 <= n:
      var w: uint64
      copyMem(addr w, unsafeAddr s[i], 8)
      if (w and 0x8080808080808080'u64) == 0:
        i += 8
        continue
    if ord(s[i]) < 0x80: inc i
    else:
      let l = utf8SeqLen(s, i)
      if l == 0 or i + l > n: return i
      i += l
  -1

proc fixUtf8(s: string, invalid: var int): string =
  ## `s` with each invalid byte replaced by U+FFFD; counts them.
  result = newStringOfCap(s.len + 8)
  var i = 0
  while i < s.len:
    if ord(s[i]) < 0x80:
      result.add s[i]
      inc i
    else:
      let l = utf8SeqLen(s, i)
      if l == 0:
        result.add Replacement
        inc invalid
        inc i
      else:
        result.add s[i ..< i + l]
        i += l

proc normalizeInput(s: string): string =
  ## "\r\n" and lone "\r" become "\n"; invalid UTF-8 becomes U+FFFD.
  var t = s
  if firstInvalidUtf8(t) >= 0:
    var n = 0
    t = fixUtf8(t, n)
  if t.find('\r') < 0: return t
  result = newStringOfCap(t.len)
  var i = 0
  while i < t.len:
    if t[i] == '\r':
      if i + 1 < t.len and t[i + 1] == '\n': inc i
      result.add '\n'
    else: result.add t[i]
    inc i

proc splitOn(s: string, c: char): seq[string] =
  result = @[]
  var start = 0
  for i in 0 ..< s.len:
    if s[i] == c:
      result.add s[start ..< i]
      start = i + 1
  result.add s[start .. ^1]

func endOfInsert(start: CodePos, s: string): CodePos =
  var nl = 0
  var lastNl = -1
  for i in 0 ..< s.len:
    if s[i] == '\n':
      inc nl
      lastNl = i
  if nl == 0: (start.line, start.col + s.len)
  else: (start.line + nl, s.len - lastNl - 1)

# ----------------------------------------------------- columns, tabs, words

func visualCol*(line: string, col, tabWidth: int): int =
  ## Screen column of byte index `col` (tabs advance to the next multiple of
  ## `tabWidth`, every other codepoint is one cell).
  let tw = max(tabWidth, 1)
  var i = 0
  let stop = min(col, line.len)
  while i < stop:
    if line[i] == '\t': result = (result div tw + 1) * tw
    else: inc result
    i = nextBoundary(line, i)

func colAtVisual*(line: string, vcol, tabWidth: int, roundNearest = false): int =
  ## Byte index of the character at screen column `vcol`; past the end it is
  ## `line.len`. With `roundNearest` a column in the second half of a cell
  ## (a wide tab) selects the character after it.
  let tw = max(tabWidth, 1)
  var v = 0
  var i = 0
  while i < line.len:
    let w = if line[i] == '\t': (v div tw + 1) * tw - v else: 1
    if vcol < v + w:
      if roundNearest and vcol - v >= (w + 1) div 2: return nextBoundary(line, i)
      return i
    v += w
    i = nextBoundary(line, i)
  line.len

func visualWidth*(line: string, tabWidth: int): int = visualCol(line, line.len, tabWidth)

func runeColOf*(line: string, col: int): int =
  var i = 0
  while i < col and i < line.len:
    i = nextBoundary(line, i)
    inc result

func byteOfRuneCol*(line: string, rc: int): int =
  var n = 0
  while result < line.len and n < rc:
    result = nextBoundary(line, result)
    inc n

func wordLeftIn*(s: string, i: int): int =
  ## Start of the word (identifier or punctuation run) before `i`.
  result = snapIndex(s, i)
  while result > 0 and charClass(runeBefore(s, result)) == ccSpace:
    result = prevBoundary(s, result)
  if result > 0:
    let cls = charClass(runeBefore(s, result))
    while result > 0 and charClass(runeBefore(s, result)) == cls:
      result = prevBoundary(s, result)

func wordRightIn*(s: string, i: int): int =
  ## Start of the next word after `i` (skips the current run and the spaces).
  result = snapIndex(s, i)
  if result < s.len:
    let cls = charClass(runeAt(s, result))
    if cls != ccSpace:
      while result < s.len and charClass(runeAt(s, result)) == cls:
        result = nextBoundary(s, result)
  while result < s.len and charClass(runeAt(s, result)) == ccSpace:
    result = nextBoundary(s, result)

func wordRangeIn*(s: string, i: int): (int, int) =
  ## The run of the same class (identifier, spaces, punctuation) around `i`;
  ## at the end of the line the run before it. (0, 0) for an empty line.
  if s.len == 0: return (0, 0)
  var p = snapIndex(s, i)
  if p >= s.len: p = prevBoundary(s, s.len)
  let cls = charClass(runeAt(s, p))
  var a = p
  while a > 0 and charClass(runeBefore(s, a)) == cls: a = prevBoundary(s, a)
  var b = nextBoundary(s, p)
  while b < s.len and charClass(runeAt(s, b)) == cls: b = nextBoundary(s, b)
  (a, b)

func identRangeIn*(s: string, i: int): (int, int) =
  ## The identifier touching `i` (also when the caret is just after it);
  ## (i, i) when there is none.
  let p = snapIndex(s, i)
  var a = p
  var b = p
  while a > 0 and isIdentRune(runeBefore(s, a)): a = prevBoundary(s, a)
  while b < s.len and isIdentRune(runeAt(s, b)): b = nextBoundary(s, b)
  (a, b)

func indentWidth*(line: string, tabWidth: int): int =
  ## Screen width of the leading whitespace; -1 if the line is blank.
  let tw = max(tabWidth, 1)
  var v = 0
  for c in line:
    case c
    of ' ': inc v
    of '\t': v = (v div tw + 1) * tw
    of '\r', '\v', '\f': discard
    else: return v
  -1

# ------------------------------------------------------------------ queries

func lineCount*(m: CodeModel): int = m.lines.len
func line*(m: CodeModel, i: int): lent string = m.lines[i]
func lineLen*(m: CodeModel, i: int): int = m.lines[i].len
func docEnd*(m: CodeModel): CodePos = (m.lines.high, m.lines[^1].len)
func tabWidth*(m: CodeModel): int = m.fTabWidth
func lineEnding*(m: CodeModel): LineEnding = m.fLineEnding
func mixedEndings*(m: CodeModel): bool = m.fMixed
func readOnly*(m: CodeModel): bool = m.fReadOnly
func version*(m: CodeModel): int = m.fVersion
  ## Bumped by every change of the text.
func modified*(m: CodeModel): bool = m.fModified
func canUndo*(m: CodeModel): bool = m.undoStack.len > 0
func canRedo*(m: CodeModel): bool = m.redoStack.len > 0
func selections*(m: CodeModel): seq[Selection] = m.sels
func selection*(m: CodeModel): Selection = m.sels[0]
func caret*(m: CodeModel): CodePos = m.sels[0].caret
func anchor*(m: CodeModel): CodePos = m.sels[0].anchor
func hasSelection*(m: CodeModel): bool = not m.sels[0].isEmpty
func trailingNewline*(m: CodeModel): bool = m.lines.len > 1 and m.lines[^1].len == 0
proc `readOnly=`*(m: CodeModel, v: bool) = m.fReadOnly = v
proc `maxUndoSteps=`*(m: CodeModel, v: int) = m.maxUndo = max(v, 1)
proc `tabWidth=`*(m: CodeModel, v: int) = m.fTabWidth = clamp(v, 1, 32)

func eolString*(e: LineEnding): string = (if e == leCRLF: "\r\n" else: "\n")

func snapPos*(m: CodeModel, p: CodePos): CodePos =
  ## Clamps to the document and snaps to a codepoint boundary.
  let l = clamp(p.line, 0, m.lines.high)
  if p.line < 0: return (0, 0)
  if p.line > m.lines.high: return m.docEnd
  (l, snapIndex(m.lines[l], p.col))

func textBetween*(m: CodeModel, a, b: CodePos): string =
  ## The text of [a, b) with "\n" separators.
  let a = m.snapPos(a)
  let b = m.snapPos(b)
  if b <= a: return ""
  if a.line == b.line: return m.lines[a.line][a.col ..< b.col]
  result = m.lines[a.line][a.col .. ^1]
  for i in a.line + 1 ..< b.line:
    result.add '\n'
    result.add m.lines[i]
  result.add '\n'
  result.add m.lines[b.line][0 ..< b.col]

func selectedText*(m: CodeModel): string =
  m.textBetween(m.sels[0].startPos, m.sels[0].endPos)

func text*(m: CodeModel): string = m.textBetween((0, 0), m.docEnd)
  ## The whole text with "\n" separators (see `toText` for the file form).

func offsetOf*(m: CodeModel, p: CodePos): int =
  ## Byte offset of `p` in `text` (newline = 1 byte). O(lines).
  let p = m.snapPos(p)
  for i in 0 ..< p.line: result += m.lines[i].len + 1
  result += p.col

func posAtOffset*(m: CodeModel, off: int): CodePos =
  var rest = max(off, 0)
  for i in 0 ..< m.lines.len:
    if rest <= m.lines[i].len: return (i, snapIndex(m.lines[i], rest))
    rest -= m.lines[i].len + 1
  m.docEnd

func charCount*(m: CodeModel): int =
  ## Bytes in `text`.
  for l in m.lines: result += l.len + 1
  result -= 1

proc toText*(m: CodeModel, lineEnding: LineEnding, ensureTrailingNewline = false): string =
  ## The document as file text with the given line ending.
  let eol = eolString(lineEnding)
  var total = 0
  for l in m.lines: total += l.len + eol.len
  result = newStringOfCap(total)
  for i, l in m.lines:
    if i > 0: result.add eol
    result.add l
  if ensureTrailingNewline and not m.trailingNewline and result.len > 0:
    result.add eol

proc toText*(m: CodeModel, ensureTrailingNewline = false): string =
  m.toText(m.fLineEnding, ensureTrailingNewline)

# ------------------------------------------------------------- notification

proc addChangeListener*(m: CodeModel, cb: ChangeHandler): int =
  ## Returns an id for `removeChangeListener`.
  inc m.nextListenerId
  m.listeners.add (m.nextListenerId, cb)
  m.nextListenerId

proc removeChangeListener*(m: CodeModel, id: int) =
  for i in 0 ..< m.listeners.len:
    if m.listeners[i].id == id:
      m.listeners.delete i
      return

proc fireChanged(m: CodeModel, first, oldN, newN: int) =
  inc m.fVersion
  let ls = m.listeners          # a listener may (un)subscribe while running
  for l in ls: l.cb(first, oldN, newN)

proc fireSel(m: CodeModel) =
  if m.onSelection != nil: m.onSelection()

# ---------------------------------------------------------------- selection

proc breakGroup*(m: CodeModel) {.inline.} =
  ## Ends typing/deleting coalescing: the next edit starts a new undo step.
  m.lastKind = ekOther

proc snapSel(m: CodeModel, s: Selection): Selection =
  Selection(anchor: m.snapPos(s.anchor), caret: m.snapPos(s.caret))

proc setSelections*(m: CodeModel, s: openArray[Selection]) =
  ## Replaces all selections (at least one; the first is the primary).
  if s.len == 0: return
  var v = newSeq[Selection](s.len)
  for i in 0 ..< s.len: v[i] = m.snapSel(s[i])
  m.breakGroup()
  if v != m.sels:
    m.sels = v
    m.fireSel()

proc setSelection*(m: CodeModel, s: Selection) = m.setSelections([s])

proc setCaret*(m: CodeModel, pos: CodePos, extend = false) =
  let p = m.snapPos(pos)
  m.setSelection(Selection(anchor: (if extend: m.sels[0].anchor else: p), caret: p))

proc selectAll*(m: CodeModel) = m.setSelection(sel((0, 0), m.docEnd))

# -------------------------------------------------------------- raw editing

proc deleteLines(lines: var seq[string], first, last: int) =
  let n = last - first + 1
  if n <= 0: return
  for i in last + 1 ..< lines.len: lines[i - n] = move lines[i]
  lines.setLen(lines.len - n)

proc insertLines(lines: var seq[string], parts: seq[string], at: int) =
  let n = parts.len
  if n == 0: return
  let old = lines.len
  lines.setLen(old + n)
  for i in countdown(old - 1, at): lines[i + n] = move lines[i]
  for i in 0 ..< n: lines[at + i] = parts[i]

proc spliceRaw(m: CodeModel, a, b: CodePos, repl: string): CodePos =
  ## Replaces [a, b) by `repl` ("\n" separated, valid UTF-8), fires the change
  ## and returns the end of the inserted text. No history, no selection.
  let oldN = b.line - a.line + 1
  if repl.find('\n') < 0:
    if oldN == 1 and a.line == b.line:
      let l = m.lines[a.line]
      m.lines[a.line] = l[0 ..< a.col] & repl & l[b.col .. ^1]
    else:
      m.lines[a.line] = m.lines[a.line][0 ..< a.col] & repl & m.lines[b.line][b.col .. ^1]
      m.lines.deleteLines(a.line + 1, b.line)
    result = (a.line, a.col + repl.len)
    m.fireChanged(a.line, oldN, 1)
    return
  var parts = splitOn(repl, '\n')
  parts[0] = m.lines[a.line][0 ..< a.col] & parts[0]
  result = (a.line + parts.high, parts[^1].len)
  parts[^1].add m.lines[b.line][b.col .. ^1]
  let newN = parts.len
  if newN == oldN:
    for i in 0 ..< newN: m.lines[a.line + i] = move parts[i]
  elif newN < oldN:
    for i in 0 ..< newN: m.lines[a.line + i] = move parts[i]
    m.lines.deleteLines(a.line + newN, b.line)
  else:
    for i in 0 ..< oldN: m.lines[a.line + i] = move parts[i]
    m.lines.insertLines(parts[oldN .. ^1], b.line + 1)
  m.fireChanged(a.line, oldN, newN)

# ------------------------------------------------------------------ history

proc beginGroup*(m: CodeModel) =
  ## Starts (or nests into) a group: every edit until the matching `endGroup`
  ## is one undo step.
  if m.groupDepth == 0:
    m.newStepPending = true
    m.breakGroup()
  inc m.groupDepth

proc endGroup*(m: CodeModel) =
  if m.groupDepth > 0:
    dec m.groupDepth
    if m.groupDepth == 0:
      m.newStepPending = false
      m.breakGroup()

func inGroup*(m: CodeModel): bool = m.groupDepth > 0

proc pushStep(m: CodeModel, op: Op) =
  m.undoStack.add UndoStep(ops: @[op], selBefore: m.sels)
  m.redoStack.setLen 0
  if m.undoStack.len > m.maxUndo:
    m.undoStack.delete 0
    if m.savedStep >= 0: dec m.savedStep

proc charClassOfText(s: string, last: bool): CharClass =
  if s.len == 0: ccOther
  elif last: charClass(runeBefore(s, s.len))
  else: charClass(runeAt(s, 0))

proc recordOp(m: CodeModel, op: Op, kind: EditKind, a: CodePos, cls: CharClass) =
  ## Adds `op` to the history, coalescing with the previous step when allowed.
  var merged = false
  if m.groupDepth > 0:
    if m.newStepPending or m.undoStack.len == 0:
      m.pushStep op
      m.newStepPending = false
    else:
      m.undoStack[^1].ops.add op
      m.redoStack.setLen 0
    merged = true
  elif kind != ekOther and m.lastKind == kind and m.undoStack.len > 0 and
       m.redoStack.len == 0:
    let ok = case kind
      of ekTyping: op.removed.len == 0 and a == m.lastPos and cls == m.lastClass
      of ekDelBack: op.inserted.len == 0 and op.removed.find('\n') < 0 and
                    endOfInsert(a, op.removed) == m.lastPos
      of ekDelFwd: op.inserted.len == 0 and op.removed.find('\n') < 0 and a == m.lastPos
      of ekOther: false
    if ok:
      m.undoStack[^1].ops.add op
      merged = true
  if not merged: m.pushStep op
  if kind != ekOther and m.groupDepth == 0:
    m.lastKind = kind
    m.lastClass = cls
    m.lastPos = (if kind == ekTyping: endOfInsert(a, op.inserted) else: a)
  else:
    m.lastKind = ekOther
  m.fModified = true

proc edit*(m: CodeModel, a, b: CodePos, s: string, kind: EditKind,
           selAfter: Selection): bool =
  ## Replaces [a, b) by `s` as one history entry of `kind` and sets the
  ## selection to `selAfter` (clamped to the new document). Returns false
  ## (and changes nothing) when read-only or when nothing would change.
  if m.fReadOnly: return false
  var a = m.snapPos(a)
  var b = m.snapPos(b)
  if b < a: swap a, b
  let ins = normalizeInput(s)
  let removed = m.textBetween(a, b)
  if removed == ins: return false
  let cls = charClassOfText(ins, true)
  m.recordOp(Op(pos: a, removed: removed, inserted: ins), kind, a, cls)
  discard m.spliceRaw(a, b, ins)
  m.sels = @[m.snapSel(selAfter)]
  m.undoStack[^1].selAfter = m.sels
  m.fireSel()
  true

proc replace*(m: CodeModel, a, b: CodePos, s: string, kind = ekOther): bool =
  ## `edit` with the caret placed after the inserted text.
  var a = m.snapPos(a)
  var b = m.snapPos(b)
  if b < a: swap a, b
  let e = endOfInsert(a, normalizeInput(s))
  m.edit(a, b, s, kind, sel(e))

proc insert*(m: CodeModel, p: CodePos, s: string): bool = m.replace(p, p, s)
proc delete*(m: CodeModel, a, b: CodePos): bool = m.replace(a, b, "")

proc replaceInGroup*(m: CodeModel, a, b: CodePos, s: string): bool =
  ## An edit that leaves the selection alone (for tools that make many edits
  ## inside `beginGroup`; the caller sets the final selection).
  let keep = m.sels
  result = m.edit(a, b, s, ekOther, keep[0])
  if result:
    m.sels = keep
    for i in 0 ..< m.sels.len: m.sels[i] = m.snapSel(m.sels[i])
    m.undoStack[^1].selAfter = m.sels

proc typeText*(m: CodeModel, s: string): bool =
  ## Types `s` over the primary selection. A single typed character
  ## coalesces with the previous typing; a longer text (paste) is a step.
  if s.len == 0: return false
  let sl = m.sels[0]
  let single = runeCount(s) == 1 and s.find({'\n', '\r'}) < 0 and sl.isEmpty
  m.replace(sl.startPos, sl.endPos, s, if single: ekTyping else: ekOther)

proc deleteSelection*(m: CodeModel): bool =
  let sl = m.sels[0]
  if sl.isEmpty: return false
  m.replace(sl.startPos, sl.endPos, "")

proc deleteBackward*(m: CodeModel, word = false): bool =
  if m.hasSelection: return m.deleteSelection()
  let c = m.caret
  var a: CodePos
  if c.col > 0:
    a = (c.line, if word: wordLeftIn(m.lines[c.line], c.col)
                 else: prevBoundary(m.lines[c.line], c.col))
  elif c.line > 0: a = (c.line - 1, m.lines[c.line - 1].len)
  else: return false
  m.replace(a, c, "", if word: ekOther else: ekDelBack)

proc deleteForward*(m: CodeModel, word = false): bool =
  if m.hasSelection: return m.deleteSelection()
  let c = m.caret
  var b: CodePos
  if c.col < m.lines[c.line].len:
    b = (c.line, if word: wordRightIn(m.lines[c.line], c.col)
                 else: nextBoundary(m.lines[c.line], c.col))
  elif c.line < m.lines.high: b = (c.line + 1, 0)
  else: return false
  m.replace(c, b, "", if word: ekOther else: ekDelFwd)

proc applyStep(m: CodeModel, st: UndoStep, undo: bool) =
  if undo:
    for i in countdown(st.ops.high, 0):
      let op = st.ops[i]
      discard m.spliceRaw(op.pos, endOfInsert(op.pos, op.inserted), op.removed)
  else:
    for op in st.ops:
      discard m.spliceRaw(op.pos, endOfInsert(op.pos, op.removed), op.inserted)

proc undo*(m: CodeModel): bool =
  if m.fReadOnly or m.undoStack.len == 0: return false
  let st = m.undoStack.pop
  m.breakGroup()
  m.applyStep(st, true)
  m.sels = st.selBefore
  for i in 0 ..< m.sels.len: m.sels[i] = m.snapSel(m.sels[i])
  m.redoStack.add st
  m.fModified = m.savedStep != m.undoStack.len
  m.fireSel()
  true

proc redo*(m: CodeModel): bool =
  if m.fReadOnly or m.redoStack.len == 0: return false
  let st = m.redoStack.pop
  m.breakGroup()
  m.applyStep(st, false)
  m.sels = st.selAfter
  for i in 0 ..< m.sels.len: m.sels[i] = m.snapSel(m.sels[i])
  m.undoStack.add st
  m.fModified = m.savedStep != m.undoStack.len
  m.fireSel()
  true

proc clearHistory*(m: CodeModel) =
  m.undoStack.setLen 0
  m.redoStack.setLen 0
  m.breakGroup()
  if not m.fModified: m.savedStep = 0 else: m.savedStep = -1

proc markSaved*(m: CodeModel) =
  ## Call after writing the file: `modified` becomes false, and returns to
  ## true as soon as the history moves away from this point.
  m.breakGroup()
  m.savedStep = m.undoStack.len
  m.fModified = false

# --------------------------------------------------------------- load / save

proc newCodeModel*(): CodeModel =
  CodeModel(lines: @[""], sels: @[sel((0, 0))], fTabWidth: 4, maxUndo: DefaultMaxUndo,
            savedStep: 0)

proc memchrNl(p: pointer, n: int): int =
  proc memchr(s: pointer, c: cint, n: csize_t): pointer {.importc, header: "<string.h>".}
  let r = memchr(p, 10, csize_t(n))
  if r == nil: -1 else: cast[int](r) - cast[int](p)

proc loadText*(m: CodeModel, data: string): LoadReport =
  ## Replaces the whole document with `data` (raw file bytes): detects the
  ## line ending style, repairs invalid UTF-8 (U+FFFD) and clears the history.
  let oldN = m.lines.len
  var invalid = 0
  let bad = firstInvalidUtf8(data)
  var fixLines = bad >= 0           # repair line by line below
  var crlf, lf = 0
  var newLines = newSeqOfCap[string](max(16, data.len div 40))
  var start = 0
  let n = data.len
  while true:
    let rel = if start < n: memchrNl(unsafeAddr data[start], n - start) else: -1
    if rel < 0:
      newLines.add data[start ..< n]
      break
    let e = start + rel
    var stop = e
    if e > start and data[e - 1] == '\r':
      dec stop
      inc crlf
    else: inc lf
    newLines.add data[start ..< stop]
    start = e + 1
  if fixLines:
    for i in 0 ..< newLines.len:
      if firstInvalidUtf8(newLines[i]) >= 0:
        newLines[i] = fixUtf8(newLines[i], invalid)
  m.lines = move newLines
  m.fLineEnding = if crlf > lf: leCRLF else: leLF
  m.fMixed = crlf > 0 and lf > 0
  m.sels = @[sel((0, 0))]
  m.undoStack.setLen 0
  m.redoStack.setLen 0
  m.groupDepth = 0
  m.newStepPending = false
  m.breakGroup()
  m.savedStep = 0
  m.fModified = false
  result = LoadReport(bytes: data.len, lines: m.lines.len, invalidBytes: invalid,
                      lineEnding: m.fLineEnding, mixedEndings: m.fMixed,
                      trailingNewline: m.trailingNewline)
  m.fireChanged(0, oldN, m.lines.len)
  m.fireSel()

proc loadFile*(m: CodeModel, path: string): LoadReport =
  ## Reads `path` (raises IOError if it cannot be read). Strips a UTF-8 BOM.
  var data = readFile(path)
  if data.len >= 3 and data[0] == '\xEF' and data[1] == '\xBB' and data[2] == '\xBF':
    data = data[3 .. ^1]
  m.loadText(data)

proc setText*(m: CodeModel, s: string) =
  ## Programmatic replacement (line endings detected like `loadText`).
  discard m.loadText(s)

proc saveFile*(m: CodeModel, path: string, ensureTrailingNewline = false) =
  ## Writes the document with its detected line ending, in chunks (no copy of
  ## the whole text), and calls `markSaved`.
  let eol = eolString(m.fLineEnding)
  let f = open(path, fmWrite)
  try:
    var chunk = newStringOfCap(1 shl 20)
    for i, l in m.lines:
      if i > 0: chunk.add eol
      chunk.add l
      if chunk.len >= (1 shl 20) - 256:
        discard f.writeBuffer(addr chunk[0], chunk.len)
        chunk.setLen 0
    if ensureTrailingNewline and not m.trailingNewline and m.docEnd != (0, 0):
      chunk.add eol
    if chunk.len > 0: discard f.writeBuffer(addr chunk[0], chunk.len)
  finally:
    f.close()
  m.markSaved()

proc newCodeModel*(text: string): CodeModel =
  result = newCodeModel()
  discard result.loadText(text)

# ---------------------------------------------------- cursor movement helpers

func wordLeftPos*(m: CodeModel, p: CodePos): CodePos =
  let p = m.snapPos(p)
  if p.col == 0: (if p.line > 0: (p.line - 1, m.lines[p.line - 1].len) else: p)
  else: (p.line, wordLeftIn(m.lines[p.line], p.col))

func wordRightPos*(m: CodeModel, p: CodePos): CodePos =
  let p = m.snapPos(p)
  if p.col >= m.lines[p.line].len: (if p.line < m.lines.high: (p.line + 1, 0) else: p)
  else: (p.line, wordRightIn(m.lines[p.line], p.col))

func prevPos*(m: CodeModel, p: CodePos): CodePos =
  ## One codepoint left; crosses to the end of the previous line.
  if p.col > 0: (p.line, prevBoundary(m.lines[p.line], p.col))
  elif p.line > 0: (p.line - 1, m.lines[p.line - 1].len)
  else: p

func nextPos*(m: CodeModel, p: CodePos): CodePos =
  if p.col < m.lines[p.line].len: (p.line, nextBoundary(m.lines[p.line], p.col))
  elif p.line < m.lines.high: (p.line + 1, 0)
  else: p
