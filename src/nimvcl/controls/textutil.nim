## Text helpers shared by the editing models (`EditModel`, `MemoModel`,
## `CodeModel`), the search engine and the highlighter caches: UTF-8
## boundaries and repair, word classes and word movement, rune columns, line
## splitting and the in-place splice of parallel per-line sequences. Pure Nim.
##
## Every index is a BYTE index into a valid UTF-8 string; the functions that
## take one snap it to a codepoint boundary first.

import std/unicode

type
  CharClass* = enum ccSpace, ccWord, ccOther

const Replacement* = "\xEF\xBF\xBD"        ## U+FFFD

# ---------------------------------------------------------------- boundaries

func isContinuation*(b: char): bool {.inline.} = (ord(b) and 0xC0) == 0x80

func snapIndex*(s: string, i: int): int =
  ## Clamps to 0 .. s.len and moves back to a codepoint boundary.
  result = clamp(i, 0, s.len)
  while result > 0 and result < s.len and isContinuation(s[result]): dec result

func prevBoundary*(s: string, i: int): int =
  result = i - 1
  while result > 0 and isContinuation(s[result]): dec result
  if result < 0: result = 0

func nextBoundary*(s: string, i: int): int =
  if i >= s.len: return s.len
  result = i + 1
  while result < s.len and isContinuation(s[result]): inc result

func runeAt*(s: string, i: int): Rune =
  var r: Rune
  fastRuneAt(s, i, r, false)
  r

func runeBefore*(s: string, i: int): Rune = runeAt(s, prevBoundary(s, i))

func runeCount*(s: string): int = unicode.runeLen(s)

func runeColOf*(line: string, col: int): int =
  ## Rune column of byte index `col`.
  var i = 0
  while i < col and i < line.len:
    i = nextBoundary(line, i)
    inc result

func byteOfRuneCol*(line: string, rc: int): int =
  var n = 0
  while result < line.len and n < rc:
    result = nextBoundary(line, result)
    inc n

func truncateRunes*(s: string, n: int): string =
  ## The first `n` runes of `s`.
  var count = 0
  var i = 0
  while i < s.len and count < n:
    i = nextBoundary(s, i)
    inc count
  s[0 ..< i]

# --------------------------------------------------------------------- UTF-8

func utf8SeqLen*(s: string, i: int): int =
  ## Length of the valid UTF-8 sequence at `i`, 0 if it is invalid.
  let b0 = ord(s[i])
  if b0 < 0x80: return 1
  func cont(s: string, j: int): int {.inline.} =
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

proc firstInvalidUtf8*(s: string, start = 0, stop = -1): int =
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

proc repairUtf8*(s: string, invalid: var int, replacement = Replacement): string =
  ## `s` with each invalid byte replaced by `replacement` ("" drops it);
  ## adds the number of bad bytes to `invalid`. Valid text is returned as is.
  if firstInvalidUtf8(s) < 0: return s
  result = newStringOfCap(s.len + 8)
  var i = 0
  while i < s.len:
    let l = utf8SeqLen(s, i)
    if l == 0:
      result.add replacement
      inc invalid
      inc i
    else:
      result.add s[i ..< i + l]
      i += l

proc cleanUtf8*(s: string): string =
  ## `s` without its invalid UTF-8 bytes.
  var n = 0
  repairUtf8(s, n, "")

# ------------------------------------------------------------- word classes

func charClass*(r: Rune): CharClass =
  ## Word classes: identifier characters (letters, digits, `_`), spaces,
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

# --------------------------------------------------------------------- lines

proc splitAtNewlines*(s: string): seq[string] =
  ## `s` cut at every "\n" (at least one element).
  result = @[]
  var start = 0
  for i in 0 ..< s.len:
    if s[i] == '\n':
      result.add s[start ..< i]
      start = i + 1
  result.add s[start .. ^1]

func endOfInsert*(start: tuple[line, col: int], s: string): tuple[line, col: int] =
  ## Where the caret is after inserting `s` (lines separated by "\n") at `start`.
  var nl = 0
  var lastNl = -1
  for i in 0 ..< s.len:
    if s[i] == '\n':
      inc nl
      lastNl = i
  if nl == 0: (start.line, start.col + s.len)
  else: (start.line + nl, s.len - lastNl - 1)

proc spliceSeq*[T](s: var seq[T], first, oldN, newN: int) =
  ## Makes room for `newN` entries in place of the `oldN` at `first` with one
  ## move of the tail. The entries in the common range keep their values, the
  ## new ones are default.
  if oldN == newN: return
  if newN < oldN:
    let d = oldN - newN
    for i in first + oldN ..< s.len: s[i - d] = move s[i]
    s.setLen(s.len - d)
  else:
    let d = newN - oldN
    let old = s.len
    s.setLen(old + d)
    for i in countdown(old - 1, first + oldN): s[i + d] = move s[i]
    for i in first + oldN ..< first + newN: s[i] = default(T)

proc respliceSeq*[T](s: var seq[T], first, oldN, newN: int) =
  ## `spliceSeq`, then every entry of the `newN` is reset (per-line caches
  ## whose entries for the changed lines are invalid).
  s.spliceSeq(first, oldN, newN)
  for i in first ..< first + newN: reset s[i]

proc replaceRange*[T](s: var seq[T], first, oldN: int, parts: openArray[T]) =
  ## Replaces `s[first ..< first + oldN]` by `parts` (one move of the tail).
  s.spliceSeq(first, oldN, parts.len)
  for i in 0 ..< parts.len: s[first + i] = parts[i]
