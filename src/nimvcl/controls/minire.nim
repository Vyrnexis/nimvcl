## A small backtracking regular expression engine, UTF-8 aware, no external
## library (std/re and std/nre need a PCRE shared library at run time, which
## is not guaranteed on every machine that runs a nimvcl program).
##
## Syntax: literals, `.` (any codepoint but "\n"), classes `[a-z_]` /
## `[^...]` (with `\d \w \s` inside), `\d \D \w \W \s \S`, `\b \B`, `^ $`
## (line start/end: the search engine matches one line at a time),
## groups `( )` and `(?: )`, alternation `|`, greedy and lazy quantifiers
## `* + ? {n} {n,} {n,m}` (`*?`, `+?`, `??`, `{n,m}?`), escapes `\t \n \r \xHH
## \uHHHH` and `\` + punctuation. Not supported: backreferences, lookaround,
## possessive quantifiers. Matching is linear in (pattern size x line length):
## the VM remembers which (instruction, position) states it has already
## explored, so alternation and nested quantifiers cannot backtrack
## exponentially, and a loop whose body matched the empty string stops there.
## A generous step budget remains as a last-resort guard.
##
## `\w` and `\b` use code word characters (letters, digits, `_`); the
## `caseInsensitive` option folds ASCII letters only. With `wholeWord` a match
## must not start or end inside a word (both neighbours of the edge being word
## characters), which, unlike wrapping the pattern in `\b`, leaves a pattern
## that begins or ends with punctuation alone and still lets the engine
## backtrack to another match at the same start.

import std/[unicode, strutils]
import ./codemodel

type
  BtKind = enum btBranch, btCap, btRepGreedy, btRepLazy

  Bt = object
    kind: BtKind
    pc, i, x: int

type
  RegexError* = object of ValueError

  InstrKind = enum
    ikChar, ikAny, ikClass, ikSplit, ikJmp, ikSave, ikBol, ikEol, ikWordB,
    ikNotWordB, ikRep, ikMatch

  ClassItem = tuple[lo, hi: int]   # lo < 0: -1 \d, -2 \w, -3 \s, -4 \D, -5 \W, -6 \S

  Instr = object
    kind: InstrKind
    c: char
    x, y: int                 # split/jmp offsets, save slot, rep min/max
    cls: int
    lazy: bool

  Regex* = ref object
    prog: seq[Instr]
    classes: seq[tuple[items: seq[ClassItem], negate: bool]]
    groups*: int              ## number of capture groups
    ci, wholeWord: bool
    lead: int                 ## byte every match starts with, or -1
    required: string          ## literal every match contains ("" = none)
    scratchCaps: seq[int]
    scratchStack: seq[Bt]

  RegexMatch* = object
    a*, b*: int
    groups*: seq[tuple[a, b: int]]   ## [0] is the whole match; (-1, -1) unset

const
  StepBudget = 3_000_000
  MaxStack = 2_000_000
  MemoMaxBits = 32 * 1024 * 1024     # largest visited-state table (4 MiB)
  Inf = high(int)

# ------------------------------------------------------------------- parser

type
  Parser = object
    s: string
    i: int
    re: Regex
    ngroups: int

func peekc(p: Parser): char = (if p.i < p.s.len: p.s[p.i] else: '\0')

proc fail(msg: string) {.noinline.} = raise newException(RegexError, msg)

proc ins(k: InstrKind, c = '\0', x = 0, y = 0, cls = 0, lazy = false): Instr =
  Instr(kind: k, c: c, x: x, y: y, cls: cls, lazy: lazy)

proc utf8Instrs(r: int): seq[Instr] =
  for ch in Rune(r).toUTF8: result.add ins(ikChar, ch)

proc parseAlt(p: var Parser): seq[Instr]

proc parseEscapeCodepoint(p: var Parser): int =
  ## After `\`: x/u/t/n/r or punctuation, returns a codepoint, or -1 if the
  ## escape is a class shorthand (the caller handles those).
  let c = p.s[p.i]
  inc p.i
  case c
  of 't': result = 9
  of 'n': result = 10
  of 'r': result = 13
  of 'f': result = 12
  of 'v': result = 11
  of '0': result = 0
  of 'x', 'u':
    let n = if c == 'x': 2 else: 4
    if p.i + n > p.s.len: fail("bad \\" & c & " escape")
    try: result = parseHexInt(p.s[p.i ..< p.i + n])
    except ValueError: fail("bad \\" & c & " escape")
    p.i += n
  of 'd', 'D', 'w', 'W', 's', 'S', 'b', 'B': result = -1
  else:
    if c.isAlphaNumeric: fail("unknown escape \\" & c)
    result = ord(c)

func shorthand(c: char): int =
  case c
  of 'd': -1
  of 'w': -2
  of 's': -3
  of 'D': -4
  of 'W': -5
  else: -6

proc addClass(p: var Parser, items: seq[ClassItem], negate: bool): int =
  p.re.classes.add (items, negate)
  p.re.classes.high

proc parseClass(p: var Parser): seq[Instr] =
  # after '['
  var negate = false
  if p.peekc == '^':
    negate = true
    inc p.i
  var items: seq[ClassItem]
  var first = true
  while true:
    if p.i >= p.s.len: fail("unterminated [")
    var c = p.s[p.i]
    if c == ']' and not first:
      inc p.i
      break
    first = false
    var lo: int
    if c == '\\':
      inc p.i
      if p.i >= p.s.len: fail("trailing backslash")
      let e = p.s[p.i]
      if e in {'d', 'D', 'w', 'W', 's', 'S'}:
        inc p.i
        items.add (shorthand(e), shorthand(e))
        continue
      lo = p.parseEscapeCodepoint()
      if lo < 0: fail("bad escape in class")
    else:
      var r: Rune
      fastRuneAt(p.s, p.i, r, true)
      lo = int(r)
    var hi = lo
    if p.i + 1 < p.s.len and p.s[p.i] == '-' and p.s[p.i + 1] != ']':
      inc p.i
      if p.s[p.i] == '\\':
        inc p.i
        if p.i >= p.s.len: fail("trailing backslash")
        hi = p.parseEscapeCodepoint()
        if hi < 0: fail("bad range in class")
      else:
        var r: Rune
        fastRuneAt(p.s, p.i, r, true)
        hi = int(r)
      if hi < lo: fail("reversed range in class")
    items.add (lo, hi)
  @[ins(ikClass, cls = p.addClass(items, negate))]

proc splitFrag(prefX, prefY: int, lazy: bool): Instr =
  if lazy: ins(ikSplit, x = prefY, y = prefX) else: ins(ikSplit, x = prefX, y = prefY)

proc repeatFrag(a: seq[Instr], lo, hi: int, lazy: bool): seq[Instr] =
  if a.len == 1 and a[0].kind in {ikChar, ikAny, ikClass}:
    return @[ins(ikRep, x = lo, y = hi, lazy = lazy), a[0]]
  for _ in 1 .. lo: result.add a
  if hi == Inf:
    # L: split(1, len+2); a; jmp L
    var loop = @[splitFrag(1, a.len + 2, lazy)]
    loop.add a
    loop.add ins(ikJmp, x = -(a.len + 1))
    result.add loop
  elif hi > lo:
    # nested optionals: (a(a(a)?)?)?
    var tail: seq[Instr]
    for _ in 1 .. hi - lo:
      var body = a
      body.add tail
      tail = @[splitFrag(1, body.len + 1, lazy)]
      tail.add body
    result.add tail

proc parseAtom(p: var Parser): seq[Instr] =
  let c = p.s[p.i]
  case c
  of '(':
    inc p.i
    var capture = true
    if p.i + 1 < p.s.len and p.s[p.i] == '?' and p.s[p.i + 1] == ':':
      capture = false
      p.i += 2
    elif p.peekc == '?': fail("unsupported group syntax (?")
    var slot = 0
    if capture:
      inc p.ngroups
      slot = p.ngroups
    let inner = p.parseAlt()
    if p.peekc != ')': fail("missing )")
    inc p.i
    if capture:
      result.add ins(ikSave, x = 2 * slot)
      result.add inner
      result.add ins(ikSave, x = 2 * slot + 1)
    else: result = inner
  of '[':
    inc p.i
    result = p.parseClass()
  of '.':
    inc p.i
    result = @[ins(ikAny)]
  of '^':
    inc p.i
    result = @[ins(ikBol)]
  of '$':
    inc p.i
    result = @[ins(ikEol)]
  of '\\':
    inc p.i
    if p.i >= p.s.len: fail("trailing backslash")
    let e = p.s[p.i]
    case e
    of 'd', 'D', 'w', 'W', 's', 'S':
      inc p.i
      result = @[ins(ikClass, cls = p.addClass(@[(shorthand(e), shorthand(e))], false))]
    of 'b':
      inc p.i
      result = @[ins(ikWordB)]
    of 'B':
      inc p.i
      result = @[ins(ikNotWordB)]
    else:
      let cp = p.parseEscapeCodepoint()
      result = utf8Instrs(cp)
  of '*', '+', '?': fail("nothing to repeat")
  of ')', '|': fail("unexpected " & c)
  else:
    var r: Rune
    fastRuneAt(p.s, p.i, r, true)
    result = utf8Instrs(int(r))

proc parseSeq(p: var Parser): seq[Instr] =
  while p.i < p.s.len and p.s[p.i] notin {'|', ')'}:
    var a = p.parseAtom()
    # quantifier
    while p.i < p.s.len:
      var lo, hi: int
      case p.s[p.i]
      of '*': (lo, hi) = (0, Inf); inc p.i
      of '+': (lo, hi) = (1, Inf); inc p.i
      of '?': (lo, hi) = (0, 1); inc p.i
      of '{':
        let close = p.s.find('}', p.i)
        if close < 0: break
        let body = p.s[p.i + 1 ..< close]
        let parts = body.split(',')
        try:
          if parts.len == 1 and parts[0].len > 0:
            lo = parseInt(parts[0]); hi = lo
          elif parts.len == 2 and parts[0].len > 0:
            lo = parseInt(parts[0])
            hi = if parts[1].len == 0: Inf else: parseInt(parts[1])
          else: break                       # a literal brace
        except ValueError: break
        if hi < lo: fail("bad {n,m}")
        if lo > 1000 or (hi != Inf and hi > 1000): fail("repeat count too large")
        p.i = close + 1
      else: break
      var lazy = false
      if p.peekc == '?':
        lazy = true
        inc p.i
      # check the size before building the copies
      if (a.len + 1) * max(1, (if hi == Inf: lo else: hi)) > 20000:
        fail("pattern too large")
      a = repeatFrag(a, lo, hi, lazy)
    result.add a

proc parseAlt(p: var Parser): seq[Instr] =
  result = p.parseSeq()
  while p.peekc == '|':
    inc p.i
    let b = p.parseSeq()
    var r = @[ins(ikSplit, x = 1, y = result.len + 2)]
    r.add result
    r.add ins(ikJmp, x = b.len + 1)
    r.add b
    result = r

proc requiredLiteral(prog: seq[Instr]): string =
  ## The longest run of literal characters that every match must pass
  ## through (no jump skips it), used to reject lines quickly.
  var i = 0
  while i < prog.len:
    if prog[i].kind == ikRep:
      i += 2                         # the repeated atom is not a fixed literal
      continue
    if prog[i].kind != ikChar:
      inc i
      continue
    var j = i
    var lit = ""
    while j < prog.len and prog[j].kind == ikChar:
      lit.add prog[j].c
      inc j
    var ok = true
    for k in 0 ..< prog.len:
      case prog[k].kind
      of ikSplit:
        for t in [k + prog[k].x, k + prog[k].y]:
          if k < i and t > i: ok = false
      of ikJmp:
        if k < i and k + prog[k].x > i: ok = false
      else: discard
    if ok and lit.len > result.len: result = lit
    i = j

proc compileRegex*(pattern: string, caseInsensitive = false,
                   wholeWord = false): Regex =
  ## Raises `RegexError` for a malformed pattern.
  var p = Parser(s: pattern,
                 re: Regex(ci: caseInsensitive, wholeWord: wholeWord, lead: -1))
  let body = p.parseAlt()
  if p.i < p.s.len: fail("unmatched )")
  p.re.groups = p.ngroups
  p.re.prog = @[ins(ikSave, x = 0)]
  p.re.prog.add body
  p.re.prog.add ins(ikSave, x = 1)
  p.re.prog.add ins(ikMatch)
  if p.re.prog.len > 1 and p.re.prog[1].kind == ikChar and not caseInsensitive:
    p.re.lead = ord(p.re.prog[1].c)
  if not caseInsensitive: p.re.required = requiredLiteral(p.re.prog)
  p.re

# ------------------------------------------------------------------ matcher

type Ctx = object
  re: Regex
  s: ptr UncheckedArray[char]
  n: int
  caps: seq[int]
  steps: int                  # forward steps in this findAt call (all start offsets)
  budget: int                 # steps allowed before giving up
  memoAt: int                 # step count at which the visited table starts
  memo: seq[uint64]           # visited (position, instruction) states; empty = off
  memoOff: bool               # table would be too large: rely on the budget only
  aborted: bool               # the budget or the stack limit was hit

func lowerAscii(c: char): char {.inline.} =
  if c in {'A'..'Z'}: char(ord(c) + 32) else: c

func classHas(re: Regex, ci: int, r: int): bool =
  var hit = false
  for (lo, hi) in re.classes[ci].items:
    if lo >= 0:
      if r >= lo and r <= hi: hit = true
      elif re.ci and r < 128 and r >= 0:
        let c = char(r)
        let alt = if c in {'a'..'z'}: ord(c) - 32 elif c in {'A'..'Z'}: ord(c) + 32 else: r
        if alt >= lo and alt <= hi: hit = true
    else:
      let isWord = charClass(Rune(r)) == ccWord
      let isDigit = r >= ord('0') and r <= ord('9')
      let isSpace = r == 32 or (r >= 9 and r <= 13) or (r > 127 and Rune(r).isWhiteSpace)
      case lo
      of -1: hit = hit or isDigit
      of -2: hit = hit or isWord
      of -3: hit = hit or isSpace
      of -4: hit = hit or not isDigit
      of -5: hit = hit or not isWord
      else: hit = hit or not isSpace
    if hit: break
  hit != re.classes[ci].negate

func decode(c: Ctx, i: int, r: var int): int {.inline.} =
  ## Length of the codepoint at `i` (valid UTF-8 guaranteed) and its value.
  let b = ord(c.s[i])
  if b < 0x80:
    r = b
    return 1
  let l = if b >= 0xF0: 4 elif b >= 0xE0: 3 else: 2
  r = b and (0x7F shr l)                 # payload bits of the lead byte
  for k in 1 ..< l:
    r = (r shl 6) or (if i + k < c.n: ord(c.s[i + k]) and 0x3F else: 0)
  l

func prevBoundary(s: ptr UncheckedArray[char], i, n: int): int =
  result = i - 1
  while result > 0 and (ord(s[result]) and 0xC0) == 0x80: dec result

func atomLen(c: var Ctx, a: Instr, i: int): int =
  ## Bytes consumed by the single-width atom `a` at `i`, -1 if no match.
  if i >= c.n: return -1
  case a.kind
  of ikChar:
    if c.s[i] == a.c or (c.re.ci and lowerAscii(c.s[i]) == lowerAscii(a.c)): 1 else: -1
  of ikAny:
    if c.s[i] == '\n': -1
    else:
      var r: int
      c.decode(i, r)
  else:
    var r: int
    let l = c.decode(i, r)
    if c.re.classHas(a.cls, r): l else: -1

func isWordAt(c: Ctx, i: int): bool =
  if i < 0 or i >= c.n: return false
  var j = i
  if ord(c.s[j]) >= 0x80:
    while j > 0 and (ord(c.s[j]) and 0xC0) == 0x80: dec j
    var r: int
    discard c.decode(j, r)
    charClass(Rune(r)) == ccWord
  else: charClass(Rune(ord(c.s[j]))) == ccWord

func insideWord(c: Ctx, i: int): bool {.inline.} =
  ## Both neighbours of position `i` are word characters.
  c.isWordAt(i - 1) and c.isWordAt(i)

proc firstVisit(c: var Ctx, pc, i: int): bool {.inline.} =
  ## Marks the state (pc, i) as explored; false if it already was. Reaching
  ## a state again means its first exploration failed (a match would have
  ## ended the search) or is still in progress, i.e. a loop went round
  ## without consuming input; either way this path cannot succeed.
  if c.memo.len == 0: return true
  let k = i * c.re.prog.len + pc
  let bit = 1'u64 shl (k and 63)
  if (c.memo[k shr 6] and bit) != 0: return false
  c.memo[k shr 6] = c.memo[k shr 6] or bit
  true

proc startMemo(c: var Ctx) =
  let bits = (c.n + 1) * c.re.prog.len
  if bits > MemoMaxBits: c.memoOff = true
  else: c.memo = newSeq[uint64]((bits + 63) shr 6)

proc run(c: var Ctx, stack: var seq[Bt], start: int): bool =
  ## Iterative backtracking VM (an explicit stack: no recursion limit).
  var pc = 0
  var i = start
  stack.setLen 0
  let prog {.cursor.} = c.re.prog
  var failed = false
  while true:
    if failed:
      failed = false
      # backtrack
      var resumed = false
      while stack.len > 0 and not resumed:
        let e = stack.pop
        case e.kind
        of btCap: c.caps[e.pc] = e.i
        of btBranch:
          pc = e.pc
          i = e.i
          resumed = true
        of btRepGreedy:
          # e.pc: continuation, e.i: current end, e.x: minimum end
          if e.i > e.x:
            let ni = prevBoundary(c.s, e.i, c.n)
            if ni > e.x: stack.add Bt(kind: btRepGreedy, pc: e.pc, i: ni, x: e.x)
            pc = e.pc
            i = ni
            resumed = true
        of btRepLazy:
          # e.pc: the rep instruction, e.i: current end, e.x: matches so far
          let ins = prog[e.pc]
          if e.x < ins.y:
            let l = c.atomLen(prog[e.pc + 1], e.i)
            if l >= 0:
              stack.add Bt(kind: btRepLazy, pc: e.pc, i: e.i + l, x: e.x + 1)
              pc = e.pc + 2
              i = e.i + l
              resumed = true
      if not resumed: return false
      continue
    inc c.steps
    if c.steps == c.memoAt and not c.memoOff: c.startMemo()
    if c.steps > c.budget or stack.len > MaxStack:
      c.aborted = true
      return false
    let ins = prog[pc]
    case ins.kind
    of ikChar, ikAny, ikClass:
      let l = c.atomLen(ins, i)
      if l < 0: failed = true
      else:
        i += l
        inc pc
    of ikSplit:
      if not c.firstVisit(pc, i): failed = true; continue
      stack.add Bt(kind: btBranch, pc: pc + ins.y, i: i)
      pc += ins.x
    of ikJmp: pc += ins.x
    of ikSave:
      stack.add Bt(kind: btCap, pc: ins.x, i: c.caps[ins.x])
      c.caps[ins.x] = i
      inc pc
    of ikBol:
      if i != 0: failed = true else: inc pc
    of ikEol:
      if i != c.n: failed = true else: inc pc
    of ikWordB, ikNotWordB:
      let b = c.isWordAt(i - 1) != c.isWordAt(i)
      if b != (ins.kind == ikWordB): failed = true else: inc pc
    of ikRep:
      if not c.firstVisit(pc, i): failed = true; continue
      let atom = prog[pc + 1]
      var count = 0
      var j = i
      while count < ins.x and not failed:
        let l = c.atomLen(atom, j)
        if l < 0: failed = true
        else:
          j += l
          inc count
      if failed: continue
      if ins.lazy:
        if count < ins.y: stack.add Bt(kind: btRepLazy, pc: pc, i: j, x: count)
      else:
        let minEnd = j
        while count < ins.y:
          let l = c.atomLen(atom, j)
          if l < 0: break
          j += l
          inc count
        if j > minEnd: stack.add Bt(kind: btRepGreedy, pc: pc + 2, i: j, x: minEnd)
      i = j
      pc += 2
    of ikMatch:
      if c.re.wholeWord and c.insideWord(i): failed = true
      else: return true

proc findAt*(re: Regex, s: string, start: int, m: var RegexMatch): bool =
  ## The first match starting at byte `start` or later. `s` must be valid
  ## UTF-8 (the model guarantees it).
  if start > s.len: return false
  if re.required.len > 0 and s.find(re.required, start) < 0: return false
  let states = (s.len + 1) * re.prog.len
  var c = Ctx(re: re, n: s.len, caps: move re.scratchCaps,
              budget: max(StepBudget, 4 * states),
              memoAt: 256 + states div 128)   # tiny searches never pay for the table
  if c.caps.len != 2 * (re.groups + 1): c.caps = newSeq[int](2 * (re.groups + 1))
  var stack = move re.scratchStack
  defer:
    re.scratchCaps = move c.caps
    re.scratchStack = move stack
  if s.len > 0: c.s = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
  var i = start
  while i <= s.len:
    if re.lead >= 0:
      let k = if i < s.len: s.find(char(re.lead), i) else: -1
      if k < 0: return false
      i = k
    for k in 0 ..< c.caps.len: c.caps[k] = -1
    if not (re.wholeWord and c.insideWord(i)) and c.run(stack, i):
      m.a = c.caps[0]
      m.b = c.caps[1]
      m.groups.setLen(re.groups + 1)
      for g in 0 .. re.groups: m.groups[g] = (c.caps[2 * g], c.caps[2 * g + 1])
      return true
    if c.aborted or i >= s.len: break
    inc i
    while i < s.len and (ord(s[i]) and 0xC0) == 0x80: inc i
  false

proc expandReplacement*(m: RegexMatch, line, repl: string): string =
  ## `$1`..`$9`, `\1`..`\9` insert groups, `$0` / `$&` the whole match,
  ## `\\` and `$$` a literal backslash / dollar, `\n` `\t` the controls.
  var i = 0
  while i < repl.len:
    let c = repl[i]
    if (c == '$' or c == '\\') and i + 1 < repl.len:
      let d = repl[i + 1]
      if d in {'0'..'9'}:
        let g = ord(d) - ord('0')
        if g < m.groups.len and m.groups[g].a >= 0:
          result.add line[m.groups[g].a ..< m.groups[g].b]
        i += 2
        continue
      elif c == '$' and d == '&':
        result.add line[m.a ..< m.b]
        i += 2
        continue
      elif c == '$' and d == '$':
        result.add '$'
        i += 2
        continue
      elif c == '\\' and d == '\\':
        result.add '\\'
        i += 2
        continue
      elif c == '\\' and d == 'n':
        result.add '\n'
        i += 2
        continue
      elif c == '\\' and d == 't':
        result.add '\t'
        i += 2
        continue
    result.add c
    inc i
