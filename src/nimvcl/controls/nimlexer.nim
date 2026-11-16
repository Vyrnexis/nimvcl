## Nim highlighter for `CodeEdit`: a line lexer with per-line state (see
## `highlight`). Pure Nim, no SDL.
##
## Lexer state (the `LexState` carried from line to line) is
## `kind or (depth shl 3)`:
## * `stBlockComment` / `stDocBlock`: inside `#[ ... ]#` / `##[ ... ]##`,
##   nested to `depth`;
## * `stTriple`: inside a `"""` string (also the generalized `r"""..."""`);
## * `stPragma`: inside `{. ... .}` (a pragma split over several lines).
## Every other construct (normal and raw strings, characters, line comments)
## ends with its line. Unterminated strings are coloured to the end of the
## line only.

import std/strutils
import ./[codemodel, highlight]
export highlight

const
  stNone* = 0
  stBlockComment* = 1
  stDocBlock* = 2
  stTriple* = 3
  stPragma* = 4

type
  NimHighlighter* = ref object of Highlighter

func isKeyword*(s: string): bool =
  case s
  of "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
     "concept", "const", "continue", "converter", "defer", "discard",
     "distinct", "div", "do", "elif", "else", "end", "enum", "except",
     "export", "finally", "for", "from", "func", "if", "import", "in",
     "include", "interface", "is", "isnot", "iterator", "let", "macro",
     "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or",
     "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
     "template", "try", "tuple", "type", "using", "var", "when", "while",
     "xor", "yield", "true", "false": true
  else: false

func isBuiltinType*(s: string): bool =
  case s
  of "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
     "uint32", "uint64", "float", "float32", "float64", "bool", "char",
     "string", "cstring", "pointer", "seq", "array", "set", "openArray",
     "varargs", "typedesc", "untyped", "typed", "void", "auto", "any", "range",
     "byte", "Natural", "Positive", "SomeInteger", "SomeFloat", "SomeNumber",
     "SomeOrdinal", "SomeSignedInt", "SomeUnsignedInt", "Ordinal", "Slice",
     "Table", "TableRef", "HashSet", "Option", "Rune", "Exception",
     "CatchableError", "Defect", "ValueError", "IOError", "OSError",
     "KeyError", "IndexDefect": true
  else: false

func isIdentStart(c: char): bool {.inline.} =
  c in {'a'..'z', 'A'..'Z', '_'} or ord(c) >= 0x80

func isIdentChar(c: char): bool {.inline.} =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'} or ord(c) >= 0x80

const OpChars = {'+', '-', '*', '/', '<', '>', '=', '@', '$', '~', '&', '%', '|',
                 '!', '?', '^', '.', ':', '\\'}

func utf8Len(c: char): int {.inline.} =
  let b = ord(c)
  if b < 0x80: 1 elif b >= 0xF0: 4 elif b >= 0xE0: 3 elif b >= 0xC0: 2 else: 1

func skipBlock(line: string, i: int, depth: var int, doc: bool): int =
  ## From `i` inside a nested block comment: the index after the text that
  ## closes it, or `line.len`; `depth` is updated. Doc comments nest with
  ## `##[` and close with `]##`, plain ones with `#[` and `]#`.
  result = i
  let n = line.len
  let openLen = if doc: 3 else: 2
  let closeLen = openLen
  while result < n and depth > 0:
    if line[result] == '#' and result + openLen <= n and
       (if doc: line[result + 1] == '#' and line[result + 2] == '['
        else: line[result + 1] == '['):
      inc depth
      result += openLen
    elif line[result] == ']' and result + closeLen <= n and
         (if doc: line[result + 1] == '#' and line[result + 2] == '#'
          else: line[result + 1] == '#'):
      dec depth
      result += closeLen
    else: inc result

func skipPragma(line: string, i: int, closed: var bool): int =
  ## From `i` inside `{. ... .}`: the index after `.}` (closed = true) or the
  ## end of the line. Strings inside may contain `.}`.
  result = i
  let n = line.len
  closed = false
  while result < n:
    let c = line[result]
    if c == '"':
      inc result
      while result < n and line[result] != '"':
        if line[result] == '\\': inc result
        inc result
      inc result
    elif c == '.' and result + 1 < n and line[result + 1] == '}':
      result += 2
      closed = true
      return
    else: inc result
  result = min(result, n)

func stringEnd(line: string, i: int, raw: bool): int =
  ## `i` is the index of the opening quote; returns the index after the
  ## closing quote (or the end of the line).
  let n = line.len
  var j = i + 1
  while j < n:
    let c = line[j]
    if c == '"':
      if raw and j + 1 < n and line[j + 1] == '"': j += 2
      else: return j + 1
    elif c == '\\' and not raw: j += 2
    else: inc j
  n

func numberEnd(line: string, i: int): int =
  let n = line.len
  var j = i
  template digits(set: untyped) =
    while j < n and (line[j] in set or line[j] == '_'): inc j
  if line[j] == '0' and j + 1 < n and line[j + 1] in {'x', 'X'}:
    j += 2
    digits({'0'..'9', 'a'..'f', 'A'..'F'})
  elif line[j] == '0' and j + 1 < n and line[j + 1] in {'b', 'B'}:
    j += 2
    digits({'0'..'1'})
  elif line[j] == '0' and j + 1 < n and line[j + 1] in {'o', 'O'}:
    j += 2
    digits({'0'..'7'})
  else:
    digits({'0'..'9'})
    if j + 1 < n and line[j] == '.' and line[j + 1] in {'0'..'9'}:
      inc j
      digits({'0'..'9'})
    if j < n and line[j] in {'e', 'E'}:
      var k = j + 1
      if k < n and line[k] in {'+', '-'}: inc k
      if k < n and line[k] in {'0'..'9'}:
        j = k
        digits({'0'..'9'})
  if j + 1 < n and line[j] == '\'' and isIdentStart(line[j + 1]):
    j += 2
    while j < n and isIdentChar(line[j]): inc j
  j

func charEnd(line: string, i: int): int =
  ## End of a character literal starting at the quote `i`, or -1.
  let n = line.len
  if i + 2 >= n: return -1
  if line[i + 1] == '\\':
    var k = i + 3
    while k < n and k <= i + 16:
      if line[k] == '\'': return k + 1
      inc k
    return -1
  if line[i + 1] == '\'': return -1
  let k = i + 1 + utf8Len(line[i + 1])
  if k < n and line[k] == '\'': k + 1 else: -1

method languageName*(h: NimHighlighter): string = "nim"

method lexLine*(h: NimHighlighter, line: string, state: LexState,
                tokens: var seq[Token]): LexState =
  let n = line.len
  var i = 0
  var st = state and 7
  var depth = state shr 3
  template put(start, stop: int, kind: TokenKind) = h.emit(tokens, start, stop, kind)

  # continue a multi-line construct
  case st
  of stBlockComment, stDocBlock:
    let e = skipBlock(line, 0, depth, st == stDocBlock)
    put(0, e, if st == stBlockComment: tkComment else: tkDocComment)
    i = e
    if depth == 0: st = stNone
  of stTriple:
    let p = line.find("\"\"\"")
    if p < 0:
      put(0, n, tkString)
      return stTriple
    var e = p + 3
    while e < n and line[e] == '"': inc e
    put(0, e, tkString)
    i = e
    st = stNone
  of stPragma:
    var closed: bool
    let e = skipPragma(line, 0, closed)
    put(0, e, tkPragma)
    i = e
    if closed: st = stNone
  else: discard

  while st == stNone and i < n:
    let c = line[i]
    case c
    of ' ', '\t', '\r', '\v', '\f':
      var j = i + 1
      while j < n and line[j] in {' ', '\t', '\r', '\v', '\f'}: inc j
      put(i, j, tkText)
      i = j
    of '#':
      if i + 1 < n and line[i + 1] == '[':
        depth = 1
        let e = skipBlock(line, i + 2, depth, false)
        put(i, e, tkComment)
        i = e
        if depth > 0: st = stBlockComment
      elif i + 1 < n and line[i + 1] == '#':
        if i + 2 < n and line[i + 2] == '[':
          depth = 1
          let e = skipBlock(line, i + 3, depth, true)
          put(i, e, tkDocComment)
          i = e
          if depth > 0: st = stDocBlock
        else:
          put(i, n, tkDocComment)
          i = n
      else:
        put(i, n, tkComment)
        i = n
    of '"':
      if line.len >= i + 3 and line[i + 1] == '"' and line[i + 2] == '"':
        let p = line.find("\"\"\"", i + 3)
        if p < 0:
          put(i, n, tkString)
          i = n
          st = stTriple
        else:
          var e = p + 3
          while e < n and line[e] == '"': inc e
          put(i, e, tkString)
          i = e
      else:
        let e = stringEnd(line, i, false)
        put(i, e, tkString)
        i = e
    of '0'..'9':
      let e = numberEnd(line, i)
      put(i, e, tkNumber)
      i = e
    of '`':
      let p = line.find('`', i + 1)
      if p < 0:
        put(i, i + 1, tkOperator)
        inc i
      else:
        put(i, p + 1, tkIdent)
        i = p + 1
    of '\'':
      let e = charEnd(line, i)
      if e < 0:
        put(i, i + 1, tkError)
        inc i
      else:
        put(i, e, tkChar)
        i = e
    of '{':
      if i + 1 < n and line[i + 1] == '.':
        var closed: bool
        let e = skipPragma(line, i + 2, closed)
        put(i, e, tkPragma)
        i = e
        if not closed: st = stPragma
      else:
        put(i, i + 1, tkPunct)
        inc i
    of '(', ')', '[', ']', '}', ',', ';':
      put(i, i + 1, tkPunct)
      inc i
    elif isIdentStart(c):
      var j = i + 1
      while j < n and isIdentChar(line[j]): inc j
      let word = line[i ..< j]
      if j < n and line[j] == '"' and not isKeyword(word):
        # generalized raw string: r"..", fmt"..", sql"""..."""
        if line.len >= j + 3 and line[j + 1] == '"' and line[j + 2] == '"':
          let p = line.find("\"\"\"", j + 3)
          if p < 0:
            put(i, n, tkString)
            i = n
            st = stTriple
          else:
            var e = p + 3
            while e < n and line[e] == '"': inc e
            put(i, e, tkString)
            i = e
        else:
          let e = stringEnd(line, j, true)
          put(i, e, tkString)
          i = e
      else:
        put(i, j, if isKeyword(word): tkKeyword
                  elif isBuiltinType(word): tkType
                  else: tkIdent)
        i = j
    elif c in OpChars:
      var j = i + 1
      while j < n and line[j] in OpChars: inc j
      put(i, j, if j == i + 1 and c in {'.', ':'}: tkPunct else: tkOperator)
      i = j
    else:
      put(i, i + 1, tkError)
      inc i

  result = st or (if st in {stBlockComment, stDocBlock}: depth shl 3 else: 0)

proc newNimHighlighter*(m: CodeModel = nil): NimHighlighter =
  result = NimHighlighter()
  if m != nil: result.attach(m)
