## Bracket matching for `CodeEdit`: finds the partner of `( ) [ ] { }` next to
## the caret, skipping brackets inside strings, characters and comments by
## asking the highlighter's tokens (without a highlighter every bracket
## counts). Pure Nim, no SDL.

import ./[codemodel, highlight]

type
  BracketMatch* = object
    found*: bool          ## a partner was found
    isBracket*: bool      ## there is a bracket at the position at all
    a*, b*: CodePos       ## the bracket at the caret and its partner

const Skipped = {tkString, tkChar, tkComment, tkDocComment}

func pairOf(c: char): tuple[other: char, forward: bool] =
  case c
  of '(': (')', true)
  of '[': (']', true)
  of '{': ('}', true)
  of ')': ('(', false)
  of ']': ('[', false)
  of '}': ('{', false)
  else: ('\0', true)

proc counts(hl: Highlighter, line, col: int): bool =
  hl == nil or hl.kindAt(line, col) notin Skipped

proc findMatchingBracket*(m: CodeModel, hl: Highlighter, pos: CodePos,
                          maxLines = 20_000): BracketMatch =
  ## The bracket at `pos` (the character right after it) or, failing that,
  ## the one right before it, and its partner. Scans at most `maxLines`
  ## lines away. A bracket inside a string or comment never matches.
  let p = m.snapPos(pos)
  var at: CodePos = (-1, -1)
  for cand in [p, (p.line, p.col - 1)]:
    if cand.col < 0 or cand.col >= m.lineLen(cand.line): continue
    let c = m.line(cand.line)[cand.col]
    if pairOf(c).other != '\0' and counts(hl, cand.line, cand.col):
      at = cand
      break
  if at.line < 0: return
  result.isBracket = true
  result.a = at
  let open = m.line(at.line)[at.col]
  let (other, fwd) = pairOf(open)
  var depth = 0
  if fwd:
    var l = at.line
    while l < m.lineCount and l <= at.line + maxLines:
      let s = m.line(l)
      var c = if l == at.line: at.col else: 0
      while c < s.len:
        let ch = s[c]
        if ch == open or ch == other:
          if counts(hl, l, c):
            if ch == open: inc depth
            else:
              dec depth
              if depth == 0:
                result.found = true
                result.b = (l, c)
                return
        inc c
      inc l
  else:
    var l = at.line
    while l >= 0 and l >= at.line - maxLines:
      let s = m.line(l)
      var c = if l == at.line: at.col else: s.len - 1
      while c >= 0:
        let ch = s[c]
        if ch == open or ch == other:
          if counts(hl, l, c):
            if ch == open: inc depth
            else:
              dec depth
              if depth == 0:
                result.found = true
                result.b = (l, c)
                return
        dec c
      dec l
