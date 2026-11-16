## Syntax highlighting API for `CodeEdit`. Pure Nim, no SDL.
##
## * A `Highlighter` is a method-based base class. A language overrides
##   `lexLine(line, state, tokens)`: it lexes ONE line given the lexer state
##   at the start of the line (0 = normal; the language encodes "inside a
##   block comment, depth 2", "inside a triple-quoted string", ... in an int)
##   and returns the state at the end of the line.
## * Token contract: for a non-empty line the tokens cover `0 ..< line.len`
##   contiguously (no gaps, no empty tokens, no overlap); an empty line has no
##   tokens. `emit` merges neighbours of the same kind. Everything between
##   (spaces) is `tkText`.
## * Incremental (the SynEdit approach): the highlighter caches, per line, the
##   tokens, the start state they were lexed with and the end state. A model
##   change splices the caches and marks the changed lines dirty; lines are
##   re-lexed lazily, in order, when `tokens(line)` is asked for. A dirty line
##   is lexed from the previous line's end state; a line whose text is
##   unchanged AND whose start state equals the cached one keeps its tokens,
##   so re-lexing stops paying as soon as the end state of the edited line
##   matches the one it had before (typing in a line costs one line, opening
##   a `"""` string costs the lines until it closes).
## * `TokenStyle` / `SyntaxStyles` map kinds to a colour and font style;
##   `syntaxStylesFor(theme)` picks the light or the dark palette from the
##   theme and takes the text, muted and danger colours from the theme itself.

import std/[algorithm]
import ../graphics/[color, font]
import ../core/theme
import ./codemodel

type
  TokenKind* = enum
    tkText, tkKeyword, tkIdent, tkType, tkNumber, tkString, tkChar, tkComment,
    tkDocComment, tkPragma, tkOperator, tkPunct, tkPreproc, tkError,
    tkUser0, tkUser1, tkUser2, tkUser3, tkUser4, tkUser5, tkUser6, tkUser7
      ## `tkUser0 .. tkUser7` are free for custom languages.

  Token* = object
    start*, len*: int         ## byte range in the line
    kind*: TokenKind

  LexState* = int

  Highlighter* = ref object of RootObj
    model: CodeModel
    listenerId: int
    toks: seq[seq[Token]]
    endState, startUsed: seq[int32]
    lexed: seq[bool]
    clean: int                ## lines < clean are lexed with correct states
    relexed*: int             ## lines lexed so far (for tests and tuning)

const NoListener = -1
let noTokens: seq[Token] = @[]

func stop*(t: Token): int = t.start + t.len

# --------------------------------------------------------------- base class

proc emit*(h: Highlighter, tokens: var seq[Token], start, stop: int, kind: TokenKind) =
  ## Appends a token, merging it into the previous one of the same kind.
  if stop <= start: return
  if tokens.len > 0 and tokens[^1].kind == kind and tokens[^1].stop == start:
    tokens[^1].len += stop - start
  else:
    tokens.add Token(start: start, len: stop - start, kind: kind)


method lexLine*(h: Highlighter, line: string, state: LexState,
                tokens: var seq[Token]): LexState {.base.} =
  ## Lexes `line` starting in `state`; appends the tokens and returns the end
  ## state. The base class makes the whole line `tkText`.
  h.emit(tokens, 0, line.len, tkText)
  state

method languageName*(h: Highlighter): string {.base.} = "text"

# ------------------------------------------------------------------- cache

proc spliceSeq[T](s: var seq[T], first, oldN, newN: int) =
  ## Replaces s[first ..< first+oldN] by `newN` default entries.
  let tail = s.len - (first + oldN)
  if newN > oldN:
    s.setLen s.len + (newN - oldN)
    for i in countdown(tail - 1, 0): s[first + newN + i] = move s[first + oldN + i]
  elif newN < oldN:
    for i in 0 ..< tail: s[first + newN + i] = move s[first + oldN + i]
    s.setLen s.len - (oldN - newN)
  for i in first ..< first + newN: reset s[i]

proc modelChanged(h: Highlighter, first, oldN, newN: int) =
  h.toks.spliceSeq(first, oldN, newN)
  h.endState.spliceSeq(first, oldN, newN)
  h.startUsed.spliceSeq(first, oldN, newN)
  h.lexed.spliceSeq(first, oldN, newN)
  h.clean = min(h.clean, first)

proc resetCache(h: Highlighter) =
  let n = if h.model == nil: 0 else: h.model.lineCount
  h.toks = newSeq[seq[Token]](n)
  h.endState = newSeq[int32](n)
  h.startUsed = newSeq[int32](n)
  h.lexed = newSeq[bool](n)
  h.clean = 0

proc detach*(h: Highlighter) =
  if h.model != nil and h.listenerId != NoListener:
    h.model.removeChangeListener(h.listenerId)
  h.listenerId = NoListener
  h.model = nil
  h.resetCache()

proc attach*(h: Highlighter, m: CodeModel) =
  ## Subscribes to `m` (detaching from any previous model).
  h.detach()
  h.model = m
  h.resetCache()
  if m != nil:
    h.listenerId = m.addChangeListener(proc(first, oldN, newN: int) =
      h.modelChanged(first, oldN, newN))

func model*(h: Highlighter): CodeModel = h.model

proc invalidateAll*(h: Highlighter) =
  ## Forgets every cached line (after a language option changed).
  h.resetCache()

proc invalidateFrom*(h: Highlighter, line: int) =
  ## Forces re-lexing from `line` on (e.g. after an external state changed).
  let l = max(line, 0)
  for i in l ..< h.lexed.len: h.lexed[i] = false
  h.clean = min(h.clean, l)

proc ensure(h: Highlighter, upTo: int) =
  let last = min(upTo, h.model.lineCount - 1)
  while h.clean <= last:
    let k = h.clean
    let start = if k == 0: 0'i32 else: h.endState[k - 1]
    if not (h.lexed[k] and h.startUsed[k] == start):
      h.toks[k].setLen 0
      h.endState[k] = int32(h.lexLine(h.model.line(k), LexState(start), h.toks[k]))
      h.startUsed[k] = start
      h.lexed[k] = true
      inc h.relexed
    inc h.clean

proc tokens*(h: Highlighter, line: int): lent seq[Token] =
  ## The tokens of `line` (valid until the next model change). Lexes the
  ## lines before it first if they are dirty.
  if h.model == nil or line < 0 or line >= h.model.lineCount: return noTokens
  h.ensure(line)
  h.toks[line]

proc stateAtLineStart*(h: Highlighter, line: int): LexState =
  ## Lexer state entering `line` (0 for line 0).
  if h.model == nil or line <= 0: return 0
  h.ensure(min(line, h.model.lineCount) - 1)
  LexState(h.endState[min(line, h.model.lineCount) - 1])

proc stateAtLineEnd*(h: Highlighter, line: int): LexState =
  h.stateAtLineStart(line + 1)

proc lexAll*(h: Highlighter) =
  ## Brings every line up to date (tests, background warm-up).
  if h.model != nil: h.ensure(h.model.lineCount - 1)

func isClean*(h: Highlighter, line: int): bool = line < h.clean

proc tokenAt*(h: Highlighter, line, col: int): Token =
  ## The token covering byte `col` of `line`; a zero-length tkText token if
  ## there is none (end of line).
  let ts = h.tokens(line)
  if ts.len > 0:
    let i = ts.lowerBound(col, proc(t: Token, c: int): int =
      if t.stop <= c: -1 else: 0)
    if i < ts.len and ts[i].start <= col: return ts[i]
  Token(start: col, len: 0, kind: tkText)

proc kindAt*(h: Highlighter, line, col: int): TokenKind = h.tokenAt(line, col).kind

# ------------------------------------------------------------------- styles

type
  TokenStyle* = object
    color*: Color
    style*: set[FontStyle]

  SyntaxStyles* = object
    table*: array[TokenKind, TokenStyle]

func `[]`*(s: SyntaxStyles, k: TokenKind): TokenStyle = s.table[k]
proc `[]=`*(s: var SyntaxStyles, k: TokenKind, v: TokenStyle) = s.table[k] = v

func tstyle(c: Color, st: set[FontStyle] = {}): TokenStyle = TokenStyle(color: c, style: st)

func luminance(c: Color): float =
  0.2126 * float(c.r) + 0.7152 * float(c.g) + 0.0722 * float(c.b)

proc lightSyntaxStyles*(): SyntaxStyles =
  ## For the light theme (`themeLight`): text #1f2328, accent blue keywords.
  let t = tstyle(hex"#1f2328")
  for k in TokenKind: result.table[k] = t
  result[tkKeyword] = tstyle(hex"#1d4ed8", {fsBold})
  result[tkIdent] = t
  result[tkType] = tstyle(hex"#0f766e")
  result[tkNumber] = tstyle(hex"#b45309")
  result[tkString] = tstyle(hex"#15803d")
  result[tkChar] = tstyle(hex"#15803d")
  result[tkComment] = tstyle(hex"#5b6470", {fsItalic})
  result[tkDocComment] = tstyle(hex"#4b7a5a", {fsItalic})
  result[tkPragma] = tstyle(hex"#7e22ce")
  result[tkOperator] = tstyle(hex"#9a3412")
  result[tkPunct] = tstyle(hex"#4b5563")
  result[tkPreproc] = tstyle(hex"#a21caf")
  result[tkError] = tstyle(hex"#dc2626", {fsUnderline})

proc darkSyntaxStyles*(): SyntaxStyles =
  ## For the dark theme (`themeDark`): text #e6e8ec.
  let t = tstyle(hex"#e6e8ec")
  for k in TokenKind: result.table[k] = t
  result[tkKeyword] = tstyle(hex"#7aa7ff", {fsBold})
  result[tkIdent] = t
  result[tkType] = tstyle(hex"#4fd1c5")
  result[tkNumber] = tstyle(hex"#f6ad55")
  result[tkString] = tstyle(hex"#86d19a")
  result[tkChar] = tstyle(hex"#86d19a")
  result[tkComment] = tstyle(hex"#9aa3af", {fsItalic})
  result[tkDocComment] = tstyle(hex"#8fbf9f", {fsItalic})
  result[tkPragma] = tstyle(hex"#c4a1f5")
  result[tkOperator] = tstyle(hex"#f0a078")
  result[tkPunct] = tstyle(hex"#b4bbc6")
  result[tkPreproc] = tstyle(hex"#e08ae6")
  result[tkError] = tstyle(hex"#f0605d", {fsUnderline})

proc syntaxStylesFor*(t: Theme): SyntaxStyles =
  ## The palette that suits `t` (dark when its surface is dark), with the
  ## plain-text, comment and error colours taken from the theme.
  result = if luminance(t.surface) < 128: darkSyntaxStyles() else: lightSyntaxStyles()
  for k in [tkText, tkIdent, tkUser0, tkUser1, tkUser2, tkUser3, tkUser4, tkUser5,
            tkUser6, tkUser7]:
    result.table[k].color = t.text
  result.table[tkComment].color = t.textMuted
  result.table[tkError].color = t.danger
