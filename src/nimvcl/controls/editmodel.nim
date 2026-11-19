## `EditModel`: the single-line text editing model behind `Edit`. Pure Nim, no
## SDL, no drawing.
##
## * `text` is UTF-8. Every index is a BYTE index and is always snapped to a
##   codepoint boundary (the caret can never split a rune).
##   TODO: grapheme clusters (combining marks, ZWJ emoji sequences, flags) are
##   still several carets; a later pass should move by grapheme.
## * The selection is `anchor` .. `caret` (the caret is the moving end).
##   `selStart` / `selLength` are the VCL-style view of it.
## * `maxLength` counts runes (0 = unlimited). `readOnly` blocks every edit
##   (insert, delete, undo, redo) but not caret moves or selection.
##   `setText` is programmatic and works even when read-only.
## * Undo/redo: snapshots of (text, selection). Typing coalesces within a word
##   (a letter typed after a space/punctuation starts a new step), runs of
##   Backspace and runs of Delete coalesce; word-deletes, replacing a
##   selection, multi-rune inserts (paste, IME commit) are single steps. Any
##   caret move or selection change breaks coalescing.
## * `onChange` fires once per text change (insert, delete, undo, redo,
##   setText, clear).

import std/unicode
import ./textutil
export textutil.snapIndex, textutil.prevBoundary, textutil.nextBoundary,
       textutil.runeCount

type
  EditCharCase* = enum ecNormal, ecUpperCase, ecLowerCase

  OpKind = enum opNone, opType, opDelBack, opDelFwd, opOther

  Snapshot = object
    text: string
    anchor, caret: int

  EditModel* = ref object
    fText: string
    fAnchor, fCaret: int
    fMaxLength: int
    fReadOnly: bool
    fCharCase: EditCharCase
    fNumbersOnly: bool
    undoStack, redoStack: seq[Snapshot]
    lastKind: OpKind
    lastWasWord: bool
    onChange*: proc()

const MaxUndoSteps = 500

# ------------------------------------------------------------------ helpers

func sanitize(s: string): string =
  ## Removes control characters (newlines, tabs, DEL, C1) and invalid UTF-8.
  for r in cleanUtf8(s).runes:
    let v = int(r)
    if v < 0x20 or (v >= 0x7F and v < 0xA0): continue
    result.add r.toUTF8

func applyCase(s: string, cc: EditCharCase): string =
  case cc
  of ecNormal: s
  of ecUpperCase: s.toUpper
  of ecLowerCase: s.toLower

# ------------------------------------------------------------ construction

proc newEditModel*(text = ""): EditModel =
  result = EditModel()
  result.fText = sanitize(text)
  result.fCaret = result.fText.len
  result.fAnchor = result.fCaret

# ----------------------------------------------------------------- queries

func text*(m: EditModel): string = m.fText
func caret*(m: EditModel): int = m.fCaret
func anchor*(m: EditModel): int = m.fAnchor
func selStart*(m: EditModel): int = min(m.fAnchor, m.fCaret)
func selLength*(m: EditModel): int = abs(m.fAnchor - m.fCaret)
func selEnd*(m: EditModel): int = max(m.fAnchor, m.fCaret)
func hasSelection*(m: EditModel): bool = m.fAnchor != m.fCaret
func selectedText*(m: EditModel): string = m.fText[m.selStart ..< m.selEnd]
func len*(m: EditModel): int = m.fText.len
func runeLen*(m: EditModel): int = runeCount(m.fText)
func maxLength*(m: EditModel): int = m.fMaxLength
func readOnly*(m: EditModel): bool = m.fReadOnly
func charCase*(m: EditModel): EditCharCase = m.fCharCase
func numbersOnly*(m: EditModel): bool = m.fNumbersOnly
func canUndo*(m: EditModel): bool = m.undoStack.len > 0
func canRedo*(m: EditModel): bool = m.redoStack.len > 0

proc `maxLength=`*(m: EditModel, v: int) = m.fMaxLength = max(v, 0)
proc `readOnly=`*(m: EditModel, v: bool) = m.fReadOnly = v
proc `charCase=`*(m: EditModel, v: EditCharCase) = m.fCharCase = v
proc `numbersOnly=`*(m: EditModel, v: bool) = m.fNumbersOnly = v

# ------------------------------------------------------------- boundaries

func prevRune*(m: EditModel, i: int): int = prevBoundary(m.fText, snapIndex(m.fText, i))
func nextRune*(m: EditModel, i: int): int = nextBoundary(m.fText, snapIndex(m.fText, i))

func wordLeftOf*(m: EditModel, i: int): int =
  ## Start of the word before `i` (skips spaces, then one run of letters/digits
  ## or one run of punctuation).
  wordLeftIn(m.fText, i)

func wordRightOf*(m: EditModel, i: int): int =
  ## Start of the next word after `i` (skips one run of letters/digits or
  ## punctuation, then spaces).
  wordRightIn(m.fText, i)

func wordRangeAt*(m: EditModel, i: int): (int, int) =
  ## Byte range of the run (letters/digits, spaces, or punctuation) at `i`.
  ## At the end of the text the run before it is used. (0, 0) when empty.
  wordRangeIn(m.fText, i)

# ------------------------------------------------------- caret / selection

proc breakCoalesce(m: EditModel) {.inline.} = m.lastKind = opNone

proc setCaret*(m: EditModel, pos: int, extend = false) =
  ## Moves the caret to `pos` (snapped); without `extend` the selection collapses.
  m.fCaret = snapIndex(m.fText, pos)
  if not extend: m.fAnchor = m.fCaret
  m.breakCoalesce()

proc select*(m: EditModel, start, length: int) =
  ## Selects `length` bytes from `start` (both snapped; caret at the end).
  let a = snapIndex(m.fText, start)
  let b = snapIndex(m.fText, a + max(length, 0))
  m.fAnchor = a
  m.fCaret = b
  m.breakCoalesce()

proc `selStart=`*(m: EditModel, v: int) = m.setCaret(v)
proc `selLength=`*(m: EditModel, v: int) = m.select(m.selStart, v)

proc selectAll*(m: EditModel) = m.select(0, m.fText.len)

proc selectWord*(m: EditModel, at: int) =
  let (a, b) = m.wordRangeAt(at)
  m.fAnchor = a
  m.fCaret = b
  m.breakCoalesce()

proc moveLeft*(m: EditModel, extend = false) =
  if not extend and m.hasSelection: m.setCaret(m.selStart)
  else: m.setCaret(prevBoundary(m.fText, m.fCaret), extend)

proc moveRight*(m: EditModel, extend = false) =
  if not extend and m.hasSelection: m.setCaret(m.selEnd)
  else: m.setCaret(nextBoundary(m.fText, m.fCaret), extend)

proc moveHome*(m: EditModel, extend = false) = m.setCaret(0, extend)
proc moveEnd*(m: EditModel, extend = false) = m.setCaret(m.fText.len, extend)
proc moveWordLeft*(m: EditModel, extend = false) =
  m.setCaret(m.wordLeftOf(m.fCaret), extend)
proc moveWordRight*(m: EditModel, extend = false) =
  m.setCaret(m.wordRightOf(m.fCaret), extend)

# ----------------------------------------------------------------- editing

proc snapshot(m: EditModel): Snapshot =
  Snapshot(text: m.fText, anchor: m.fAnchor, caret: m.fCaret)

proc pushUndo(m: EditModel) =
  m.undoStack.add m.snapshot
  if m.undoStack.len > MaxUndoSteps: m.undoStack.delete(0)
  m.redoStack.setLen 0

proc changed(m: EditModel) =
  if m.onChange != nil: m.onChange()

proc replaceRange(m: EditModel, a, b: int, repl: string) =
  m.fText = m.fText[0 ..< a] & repl & m.fText[b .. ^1]
  m.fCaret = a + repl.len
  m.fAnchor = m.fCaret

proc filterInput(m: EditModel, s: string): string =
  result = sanitize(s)
  if m.fNumbersOnly:
    var d = ""
    for ch in result:
      if ch in {'0'..'9'}: d.add ch
    result = d
  result = applyCase(result, m.fCharCase)

proc insert*(m: EditModel, s: string): bool =
  ## Replaces the selection with `s` (filtered: control characters dropped,
  ## `numbersOnly`, `charCase`, `maxLength` applied). Returns true when the
  ## text changed.
  if m.fReadOnly: return false
  var ins = m.filterInput(s)
  if m.fMaxLength > 0:
    let selRunes = runeCount(m.selectedText)
    ins = truncateRunes(ins, max(m.fMaxLength - (m.runeLen - selRunes), 0))
  if ins.len == 0: return false
  let hadSel = m.hasSelection
  let single = runeCount(ins) == 1
  let isWord = single and charClass(runeAt(ins, 0)) == ccWord
  let coalesce = not hadSel and single and m.lastKind == opType and
                 not (isWord and not m.lastWasWord)
  if not coalesce: m.pushUndo()
  m.redoStack.setLen 0
  m.replaceRange(m.selStart, m.selEnd, ins)
  m.lastKind = if single: opType else: opNone
  m.lastWasWord = isWord
  m.changed()
  true

proc deleteSelection*(m: EditModel): bool =
  if m.fReadOnly or not m.hasSelection: return false
  m.pushUndo()
  m.replaceRange(m.selStart, m.selEnd, "")
  m.lastKind = opNone
  m.changed()
  true

proc deleteRun(m: EditModel, a, b: int, kind: OpKind, newCaret: int): bool =
  ## Deletes [a, b) as one coalescing step of `kind` (opNone: never coalesce).
  if a >= b: return false
  let coalesce = kind != opNone and m.lastKind == kind
  if not coalesce: m.pushUndo()
  m.redoStack.setLen 0
  m.fText = m.fText[0 ..< a] & m.fText[b .. ^1]
  m.fCaret = newCaret
  m.fAnchor = newCaret
  m.lastKind = kind
  m.changed()
  true

proc deleteBackward*(m: EditModel, word = false): bool =
  ## Backspace: the selection, else the rune (or word) before the caret.
  if m.fReadOnly: return false
  if m.hasSelection: return m.deleteSelection()
  if m.fCaret == 0: return false
  let a = if word: m.wordLeftOf(m.fCaret) else: prevBoundary(m.fText, m.fCaret)
  m.deleteRun(a, m.fCaret, (if word: opNone else: opDelBack), a)

proc deleteForward*(m: EditModel, word = false): bool =
  ## Delete: the selection, else the rune (or word) after the caret.
  if m.fReadOnly: return false
  if m.hasSelection: return m.deleteSelection()
  if m.fCaret >= m.fText.len: return false
  let b = if word: m.wordRightOf(m.fCaret) else: nextBoundary(m.fText, m.fCaret)
  m.deleteRun(m.fCaret, b, (if word: opNone else: opDelFwd), m.fCaret)

proc setText*(m: EditModel, s: string) =
  ## Programmatic assignment: sanitised, case-mapped and truncated to
  ## `maxLength`; the caret goes to the end; the undo history is cleared.
  ## Works when read-only. Fires `onChange` only if the text differs.
  var t = applyCase(sanitize(s), m.fCharCase)
  if m.fMaxLength > 0: t = truncateRunes(t, m.fMaxLength)
  m.undoStack.setLen 0
  m.redoStack.setLen 0
  m.lastKind = opNone
  let diff = t != m.fText
  m.fText = t
  m.fCaret = t.len
  m.fAnchor = t.len
  if diff: m.changed()

proc clear*(m: EditModel) =
  ## Removes all text as one undoable step (no-op when read-only or empty).
  if m.fReadOnly or m.fText.len == 0: return
  m.pushUndo()
  m.fText = ""
  m.fCaret = 0
  m.fAnchor = 0
  m.lastKind = opNone
  m.changed()

proc restore(m: EditModel, s: Snapshot) =
  m.fText = s.text
  m.fAnchor = s.anchor
  m.fCaret = s.caret
  m.lastKind = opNone

proc undo*(m: EditModel): bool =
  if m.fReadOnly or m.undoStack.len == 0: return false
  m.redoStack.add m.snapshot
  m.restore m.undoStack.pop()
  m.changed()
  true

proc redo*(m: EditModel): bool =
  if m.fReadOnly or m.redoStack.len == 0: return false
  m.undoStack.add m.snapshot
  m.restore m.redoStack.pop()
  m.changed()
  true

# -------------------------------------------------------- password masking

func displayText*(m: EditModel, passwordChar: Rune): string =
  ## One `passwordChar` per rune of the text.
  let c = passwordChar.toUTF8
  for _ in 0 ..< m.runeLen: result.add c

func toDisplayIndex*(m: EditModel, idx: int, passwordChar: Rune): int =
  ## Byte index in the masked text for byte index `idx` of the real text.
  runeCount(m.fText[0 ..< snapIndex(m.fText, idx)]) * passwordChar.toUTF8.len

func toModelIndex*(m: EditModel, displayIdx: int, passwordChar: Rune): int =
  ## Byte index in the real text for byte index `displayIdx` of the masked text
  ## (rounded down to a mask character).
  let n = max(displayIdx, 0) div passwordChar.toUTF8.len
  var i = 0
  for _ in 0 ..< n:
    if i >= m.fText.len: break
    i = nextBoundary(m.fText, i)
  i
