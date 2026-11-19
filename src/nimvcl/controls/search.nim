## Find and replace over a `CodeModel`. Pure Nim, no SDL.
##
## * One match never spans lines: the model is scanned line by line without
##   copying (`line(i)` is a `lent string`), so a search over 2M lines is just
##   a tight loop (see `tests/tcodeperf.nim`). A pattern containing "\n" never
##   matches; regexes run per line (`^` and `$` are line anchors).
## * Options: `ignoreCase` (ASCII folding), `wholeWord` (the match must not be
##   glued to identifier characters; the check is skipped on a side where the
##   pattern itself does not start/end with an identifier character) and
##   `regex` (the engine of `minire`, no external PCRE; a bad pattern raises
##   `RegexError` from `newSearcher`).
## * `findNext` / `findPrev` search forward / backward from a position, with
##   optional wrap-around; `findAll` lists matches; `replaceAll` replaces
##   everything (or a range) as ONE undo step; `replaceText` computes the
##   replacement of one match (regex groups `$1` / `\1` expanded) for a find
##   bar's "Replace" button.
## * Positions are `CodePos` with byte columns, always on codepoint
##   boundaries.

import std/strutils
import ./[codemodel, minire, textutil]
export minire.RegexError

type
  SearchOptions* = object
    ignoreCase*, wholeWord*, regex*: bool

  Match* = tuple[a, b: CodePos]

  Searcher* = ref object
    pattern: string
    opts: SearchOptions
    lowered: string
    re: Regex
    checkLeft, checkRight: bool

  LineMatch = object
    a, b: int
    rm: RegexMatch

proc memchr(s: pointer, c: cint, n: csize_t): pointer {.importc, header: "<string.h>".}

func isWordCharAt(s: string, i: int, before: bool): bool =
  if before:
    if i <= 0: return false
    charClass(runeBefore(s, i)) == ccWord
  else:
    if i >= s.len: return false
    charClass(runeAt(s, i)) == ccWord

proc newSearcher*(pattern: string, opts = SearchOptions()): Searcher =
  ## Compiles `pattern`. Raises `RegexError` when `opts.regex` and the
  ## pattern is malformed.
  result = Searcher(pattern: pattern, opts: opts)
  if opts.regex:
    result.re = compileRegex(pattern, opts.ignoreCase, opts.wholeWord)
  else:
    result.lowered = if opts.ignoreCase: pattern.toLowerAscii else: pattern
    if pattern.len > 0:
      result.checkLeft = charClass(runeAt(pattern, 0)) == ccWord
      result.checkRight = charClass(runeBefore(pattern, pattern.len)) == ccWord

func pattern*(s: Searcher): string = s.pattern
func options*(s: Searcher): SearchOptions = s.opts

func isEmpty*(s: Searcher): bool = s.pattern.len == 0

proc plainFind(s: Searcher, line: string, start: int): int =
  let pat = s.lowered
  let plen = pat.len
  if plen == 0 or line.len - start < plen: return -1
  let last = line.len - plen
  var i = start
  if not s.opts.ignoreCase:
    let p0 = cint(ord(pat[0]))
    while i <= last:
      let r = memchr(unsafeAddr line[i], p0, csize_t(last - i + 1))
      if r == nil: return -1
      i = cast[int](r) - cast[int](unsafeAddr line[0])
      if plen == 1 or equalMem(unsafeAddr line[i + 1], unsafeAddr pat[1], plen - 1): return i
      inc i
  else:
    let p0 = pat[0]
    while i <= last:
      var c = line[i]
      if c in {'A'..'Z'}: c = char(ord(c) + 32)
      if c == p0:
        var k = 1
        while k < plen:
          var d = line[i + k]
          if d in {'A'..'Z'}: d = char(ord(d) + 32)
          if d != pat[k]: break
          inc k
        if k == plen: return i
      inc i
  -1

proc matchInLine(s: Searcher, line: string, start: int, lm: var LineMatch): bool =
  ## First match with start >= `start` (a codepoint boundary).
  if s.pattern.len == 0: return false
  var i = start
  if s.opts.regex:
    var rm: RegexMatch
    if s.re.findAt(line, i, rm):
      lm.a = rm.a
      lm.b = rm.b
      lm.rm = rm
      return true
    return false
  while true:
    let p = s.plainFind(line, i)
    if p < 0: return false
    let e = p + s.pattern.len
    if s.opts.wholeWord and
       ((s.checkLeft and isWordCharAt(line, p, true)) or
        (s.checkRight and isWordCharAt(line, e, false))):
      i = nextBoundary(line, p)
      continue
    lm.a = p
    lm.b = e
    return true

proc lastInLine(s: Searcher, line: string, startLimit: int, lm: var LineMatch): bool =
  ## The last match whose start is < `startLimit`.
  var cur: LineMatch
  var from0 = 0
  while from0 <= line.len and s.matchInLine(line, from0, cur):
    if cur.a >= startLimit: break
    lm = cur
    result = true
    from0 = if cur.b > cur.a: cur.b else: nextBoundary(line, cur.a)
    if cur.b == cur.a and cur.a >= line.len: break

# ------------------------------------------------------------- model search

proc findNext*(s: Searcher, m: CodeModel, from0: CodePos, found: var Match,
               wrap = true): bool =
  ## The first match starting at or after `from0`; with `wrap`, a search that
  ## runs off the end continues from the top and may return a match before
  ## `from0` (never the same one twice).
  if s.pattern.len == 0: return false
  let p = m.snapPos(from0)
  var lm: LineMatch
  for l in p.line ..< m.lineCount:
    let startCol = if l == p.line: p.col else: 0
    if s.matchInLine(m.line(l), startCol, lm):
      found = ((l, lm.a), (l, lm.b))
      return true
  if wrap:
    for l in 0 .. p.line:
      if s.matchInLine(m.line(l), 0, lm):
        if l == p.line and lm.a >= p.col: break
        found = ((l, lm.a), (l, lm.b))
        return true
  false

proc findPrev*(s: Searcher, m: CodeModel, before: CodePos, found: var Match,
               wrap = true): bool =
  ## The last match starting before `before`; with `wrap` it continues from
  ## the bottom.
  if s.pattern.len == 0: return false
  let p = m.snapPos(before)
  var lm: LineMatch
  for l in countdown(p.line, 0):
    let limit = if l == p.line: p.col else: high(int)
    if s.lastInLine(m.line(l), limit, lm):
      found = ((l, lm.a), (l, lm.b))
      return true
  if wrap:
    for l in countdown(m.lineCount - 1, p.line):
      let limit = high(int)
      if s.lastInLine(m.line(l), limit, lm):
        if l == p.line and lm.a < p.col: break
        found = ((l, lm.a), (l, lm.b))
        return true
  false

iterator matches*(s: Searcher, m: CodeModel, a: CodePos = (0, 0),
                  b: CodePos = (-1, -1)): Match =
  ## Every match inside [a, b] (default: the whole document), in order.
  ## Zero-length regex matches are included (and never loop).
  let e = if b.line < 0: m.docEnd else: m.snapPos(b)
  let st = m.snapPos(a)
  if s.pattern.len > 0:
    var lm: LineMatch
    for l in st.line .. e.line:
      let ln = m.line(l)
      var c = if l == st.line: st.col else: 0
      while c <= ln.len and s.matchInLine(ln, c, lm):
        if l == e.line and lm.b > e.col: break
        yield ((l, lm.a), (l, lm.b))
        if lm.b > lm.a: c = lm.b
        else: c = if lm.a >= ln.len: ln.len + 1 else: nextBoundary(ln, lm.a)

proc findAll*(s: Searcher, m: CodeModel, limit = 0): seq[Match] =
  ## All matches, at most `limit` (0 = unlimited).
  for mt in s.matches(m):
    result.add mt
    if limit > 0 and result.len >= limit: break

proc countAll*(s: Searcher, m: CodeModel): int =
  for _ in s.matches(m): inc result

proc replacementFor*(s: Searcher, m: CodeModel, mt: Match, replacement: string): string =
  ## The text that replaces `mt`: `replacement` as is for plain search; for
  ## regex search `$1`, `\1`, `$&`, `$$`, `\\`, `\n`, `\t` are expanded.
  if not s.opts.regex: return replacement
  let ln = m.line(mt.a.line)
  var rm: RegexMatch
  if s.re.findAt(ln, mt.a.col, rm) and rm.a == mt.a.col:
    return expandReplacement(rm, ln, replacement)
  replacement

proc replaceMatch*(s: Searcher, m: CodeModel, mt: Match, replacement: string): bool =
  ## Replaces one match (one undo step) and selects the inserted text.
  let r = s.replacementFor(m, mt, replacement)
  m.replace(mt.a, mt.b, r)

proc replaceAll*(s: Searcher, m: CodeModel, replacement: string,
                 a: CodePos = (0, 0), b: CodePos = (-1, -1)): int =
  ## Replaces every match inside [a, b] (default: everything) as ONE edit (one
  ## undo step, one change notification) and returns how many matches were
  ## replaced. Nothing happens when the model is read-only. The selection is
  ## left where it was.
  if s.pattern.len == 0 or m.readOnly: return 0
  let e = if b.line < 0: m.docEnd else: m.snapPos(b)
  let st = m.snapPos(a)
  var spanStart, lastEnd: CodePos       # from the first match to the end of the last
  var outText = ""
  var lm: LineMatch
  for l in st.line .. e.line:
    let ln = m.line(l)
    var c = if l == st.line: st.col else: 0
    while c <= ln.len and s.matchInLine(ln, c, lm):
      if l == e.line and lm.b > e.col: break
      if result == 0: spanStart = (l, lm.a)
      else: outText.add m.textBetween(lastEnd, (l, lm.a))
      outText.add(if s.opts.regex: expandReplacement(lm.rm, ln, replacement)
                  else: replacement)
      lastEnd = (l, lm.b)
      inc result
      if lm.b > lm.a: c = lm.b
      else: c = if lm.a >= ln.len: ln.len + 1 else: nextBoundary(ln, lm.a)
  if result > 0: discard m.replaceInGroup(spanStart, lastEnd, outText)
