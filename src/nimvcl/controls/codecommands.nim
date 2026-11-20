## Line-oriented editing commands for `CodeEdit`: indent / outdent, toggle line
## comment, duplicate, delete and move lines, smart Home and the text Enter
## inserts. Pure Nim over `CodeModel`, no SDL; the control only decides which
## lines to pass.
##
## Every command that changes several places is ONE undo step (a model group)
## and leaves the selection where a user expects it (the selection follows the
## text it covered). Commands return whether they changed anything.

import std/strutils
import ./[codemodel, highlight]

func indentUnit*(insertSpaces: bool, tabWidth: int): string =
  ## What one indent level inserts: `tabWidth` spaces or a TAB.
  if insertSpaces: ' '.repeat(max(tabWidth, 1)) else: "\t"

func firstNonBlank*(line: string): int =
  ## Byte index of the first character that is not a space or TAB
  ## (`line.len` for a blank line).
  while result < line.len and line[result] in {' ', '\t'}: inc result

func smartHomeCol*(line: string, col: int): int =
  ## Home: the first non-blank character, or column 0 when the caret is
  ## already there.
  let f = firstNonBlank(line)
  if col == f: 0 else: f

func selectedLines*(m: CodeModel): (int, int) =
  ## The lines a line command acts on: those touched by the primary selection;
  ## a selection that ends at column 0 of a later line does not include it.
  let s = m.selection
  let a = s.startPos
  var b = s.endPos
  if not s.isEmpty and b.col == 0 and b.line > a.line: dec b.line
  (a.line, b.line)

# ------------------------------------------------------------------ helpers

func shifted(p: CodePos, line, atCol, delta: int): CodePos =
  ## `p` after `delta` bytes were inserted (or removed, delta < 0) at `atCol`
  ## of `line`.
  result = p
  if p.line == line:
    if delta >= 0:
      if p.col >= atCol and p.col > 0: result.col = p.col + delta
    else:
      let cut = -delta
      if p.col > atCol: result.col = max(atCol, p.col - cut)

# ------------------------------------------------------------ indent / outdent

proc indentLines*(m: CodeModel, first, last: int, unit: string): bool =
  ## Adds `unit` at the start of every non-empty line in `first .. last`.
  if m.readOnly or unit.len == 0: return false
  var s = m.selection
  m.withGroup:
    for l in first .. min(last, m.lineCount - 1):
      if m.lineLen(l) == 0: continue
      if m.replaceInGroup((l, 0), (l, 0), unit):
        result = true
        s.anchor = shifted(s.anchor, l, 0, unit.len)
        s.caret = shifted(s.caret, l, 0, unit.len)
    if result: m.setSelection(s)

proc outdentLines*(m: CodeModel, first, last: int, tabWidth: int): bool =
  ## Removes one indent level (a TAB, or up to `tabWidth` spaces) from every
  ## line in `first .. last`.
  if m.readOnly: return false
  var s = m.selection
  m.withGroup:
    for l in first .. min(last, m.lineCount - 1):
      let ln = m.line(l)
      var n = 0
      if ln.len > 0 and ln[0] == '\t': n = 1
      else:
        while n < ln.len and n < max(tabWidth, 1) and ln[n] == ' ': inc n
      if n == 0: continue
      if m.replaceInGroup((l, 0), (l, n), ""):
        result = true
        s.anchor = shifted(s.anchor, l, 0, -n)
        s.caret = shifted(s.caret, l, 0, -n)
    if result: m.setSelection(s)

# ------------------------------------------------------------------ comments

type CommentMode* = enum
  cmToggle      ## uncomment when every non-blank line is commented, else comment
  cmAdd         ## comment unless every non-blank line is already commented
  cmRemove      ## uncomment, only when every non-blank line is commented

proc commentLines*(m: CodeModel, first, last: int, token: string,
                   mode = cmToggle): bool =
  ## Comments the lines (the token goes at the smallest indentation of the
  ## non-blank lines) or removes the token and one following space, as `mode`
  ## says; "every line commented" ignores blank lines.
  if m.readOnly or token.len == 0: return false
  let hi = min(last, m.lineCount - 1)
  var allCommented = true
  var anyText = false
  var minIndent = high(int)
  for l in first .. hi:
    let ln = m.line(l)
    let f = firstNonBlank(ln)
    if f >= ln.len: continue
    anyText = true
    minIndent = min(minIndent, f)
    if not ln.continuesWith(token, f): allCommented = false
  if not anyText or (mode == cmAdd and allCommented) or
     (mode == cmRemove and not allCommented): return false
  var s = m.selection
  m.withGroup:
    for l in first .. hi:
      let ln = m.line(l)
      let f = firstNonBlank(ln)
      if f >= ln.len: continue
      if allCommented:
        var n = token.len
        if f + n < ln.len and ln[f + n] == ' ': inc n
        if m.replaceInGroup((l, f), (l, f + n), ""):
          result = true
          s.anchor = shifted(s.anchor, l, f, -n)
          s.caret = shifted(s.caret, l, f, -n)
      else:
        let ins = token & " "
        if m.replaceInGroup((l, minIndent), (l, minIndent), ins):
          result = true
          s.anchor = shifted(s.anchor, l, minIndent, ins.len)
          s.caret = shifted(s.caret, l, minIndent, ins.len)
    if result: m.setSelection(s)

proc toggleLineComment*(m: CodeModel, first, last: int, token: string): bool =
  ## `commentLines` in toggle mode.
  m.commentLines(first, last, token, cmToggle)

# ----------------------------------------------------------- whole lines

proc linesText(m: CodeModel, first, last: int): string =
  for l in first .. last:
    if l > first: result.add '\n'
    result.add m.line(l)

proc duplicateLines*(m: CodeModel, first, last: int): bool =
  ## Inserts a copy of the lines below them; the selection moves to the copy.
  if m.readOnly: return false
  let hi = min(last, m.lineCount - 1)
  let n = hi - first + 1
  let s = m.selection
  let sa: CodePos = (s.anchor.line + n, s.anchor.col)
  let sc: CodePos = (s.caret.line + n, s.caret.col)
  m.edit((hi, m.lineLen(hi)), (hi, m.lineLen(hi)), "\n" & m.linesText(first, hi),
         ekOther, sel(sa, sc))

proc deleteLines*(m: CodeModel, first, last: int): bool =
  ## Removes the lines including their line breaks; the caret keeps its column
  ## on the line that takes their place.
  if m.readOnly: return false
  var hi = min(last, m.lineCount - 1)
  if hi == m.lineCount - 1 and m.trailingNewline: dec hi    # the empty line after the last break is no line
  if hi < first: return false
  let col = m.caret.col
  var a, b: CodePos
  var target: int
  if hi + 1 < m.lineCount:
    a = (first, 0)
    b = (hi + 1, 0)
    target = first
  elif first > 0:
    a = (first - 1, m.lineLen(first - 1))
    b = (hi, m.lineLen(hi))
    target = first - 1
  else:
    a = (0, 0)
    b = (hi, m.lineLen(hi))
    target = 0
  let remaining = if hi + 1 < m.lineCount: m.line(hi + 1)
                  elif first > 0: m.line(first - 1) else: ""
  m.edit(a, b, "", ekOther, sel((target, snapIndex(remaining, min(col, remaining.len)))))

proc moveLines*(m: CodeModel, first, last: int, up: bool,
                nbFirst = -1, nbLast = -1): bool =
  ## Moves the lines `first .. last` above (`up`) or below the neighbouring
  ## block `nbFirst .. nbLast` (default: the single line next to them). The
  ## selection moves with the text.
  if m.readOnly: return false
  var hi = min(last, m.lineCount - 1)
  let lastReal = if m.trailingNewline: m.lineCount - 2 else: m.lineCount - 1   # not the empty line after the last break
  hi = min(hi, lastReal)
  if hi < first: return false
  var nf = nbFirst
  var nl = nbLast
  if nf < 0:
    if up: (nf, nl) = (first - 1, first - 1)
    else: (nf, nl) = (hi + 1, hi + 1)
  if up and nf < 0: return false
  if not up and nl > lastReal: return false
  let blk = m.linesText(first, hi)
  let nb = m.linesText(nf, nl)
  let s = m.selection
  var a, b: CodePos
  var repl: string
  var dLines: int
  if up:
    a = (nf, 0)
    b = (hi, m.lineLen(hi))
    repl = blk & "\n" & nb
    dLines = -(nl - nf + 1)
  else:
    a = (first, 0)
    b = (nl, m.lineLen(nl))
    repl = nb & "\n" & blk
    dLines = nl - nf + 1
  m.edit(a, b, repl, ekOther,
         sel((s.anchor.line + dLines, s.anchor.col), (s.caret.line + dLines, s.caret.col)))

# ------------------------------------------------------------------- Enter

type
  NewlineInsert* = object
    text*: string             ## "\n" plus the indentation (and, between a bracket pair, a second line)
    caretOffset*: int         ## byte offset of the caret inside `text`

func closerOf(c: char): char =
  case c
  of '(': ')'
  of '[': ']'
  of '{': '}'
  else: '\0'

const OperatorChars = {'=', '<', '>', '!', '+', '-', '*', '/', '&', '|', '%', '^', '~', '@', '$', '?', '.', ':'}

proc newlineInsert*(m: CodeModel, hl: Highlighter, pos: CodePos, unit: string,
                    indentAfter: string): NewlineInsert =
  ## What Enter at `pos` inserts: a line break, the indentation of the current
  ## line, one more `unit` when the text before the caret ends with one of the
  ## characters of `indentAfter` (`:` `=` or an open bracket; a trailing `=`
  ## that belongs to an operator such as `==` or `+=` does not count; nothing
  ## counts inside a comment or string; a comment at the end of the line before
  ## the caret is looked through: `if x:  # why` indents like `if x:`), and, with the caret between `(` `)`,
  ## `[` `]` or `{` `}`, a second line holding the closer.
  let ln = m.line(pos.line)
  let col = min(pos.col, ln.len)
  let ind = ln[0 ..< min(firstNonBlank(ln), col)]
  var extra = false
  var j = col
  while true:                       # trailing blanks, and comments the caret is behind
    while j > 0 and ln[j - 1] in {' ', '\t'}: dec j
    if hl == nil or j == 0: break
    let t = hl.tokenAt(pos.line, j - 1)
    if t.kind notin {tkComment, tkDocComment} or t.stop > col or t.start >= j: break
    j = t.start
  var opener = '\0'
  if j > 0:
    let c = ln[j - 1]
    let skipped = hl != nil and hl.kindAt(pos.line, j - 1) in {tkComment, tkDocComment, tkString, tkChar}
    if not skipped and c in indentAfter:
      if c == '=':
        extra = j < 2 or ln[j - 2] notin OperatorChars
      else:
        extra = true
      if c in {'(', '[', '{'}: opener = c
  let body = "\n" & ind & (if extra: unit else: "")
  result.text = body
  result.caretOffset = body.len
  if opener != '\0' and col < ln.len and ln[col] == closerOf(opener):
    result.text = body & "\n" & ind
