## Highlighter API and the Nim lexer: token streams for tricky input,
## per-line state across lines, and incremental re-lexing against a full lex.

import std/[unittest, strutils, random]
import nimvcl/controls/[codemodel, highlight, nimlexer]
import nimvcl/core/theme
import nimvcl/graphics/font

type Tk = tuple[text: string, kind: TokenKind]

proc lexOne(line: string, state: LexState = 0): (seq[Tk], LexState) =
  let h = NimHighlighter()
  var toks: seq[Token]
  let st = h.lexLine(line, state, toks)
  var pos = 0
  for t in toks:
    doAssert t.start == pos and t.len > 0, "tokens must be contiguous: " & line
    pos = t.stop
    result[0].add (line[t.start ..< t.stop], t.kind)
  doAssert pos == line.len, "tokens must cover the line: " & line
  result[1] = st

proc kinds(line: string): seq[Tk] =
  ## Non-space tokens only.
  for t in lexOne(line)[0]:
    if t.text.strip.len > 0: result.add t

suite "nim lexer: single lines":
  test "keywords, types, identifiers":
    check kinds("proc foo(x: int): string") == @[
      ("proc", tkKeyword), ("foo", tkIdent), ("(", tkPunct), ("x", tkIdent),
      (":", tkPunct), ("int", tkType), ("):", tkPunct),       # punctuation merges
      ("string", tkType)]
    check kinds("if a and not b: nil")[0] == ("if", tkKeyword)
    check kinds("x.isNil")[1] == (".", tkPunct)
    check kinds("héllo_wörld")[0] == ("héllo_wörld", tkIdent)

  test "numbers":
    for src in ["0", "42", "1_000_000", "0x1F", "0XfF_aa", "0b1010", "0o777",
                "1.5", "1e10", "1.5e-3", "2E+4", "0x1F'u8", "1'i32", "3.14'f64",
                "0b11'u16", "100'big"]:
      check kinds(src) == @[(src, tkNumber)]
    check kinds("1..2") == @[("1", tkNumber), ("..", tkOperator), ("2", tkNumber)]
    check kinds("5.toStr") == @[("5", tkNumber), (".", tkPunct), ("toStr", tkIdent)]
    check kinds("0x1e5") == @[("0x1e5", tkNumber)]
    check kinds("1.0e") == @[("1.0", tkNumber), ("e", tkIdent)]

  test "strings":
    check kinds("\"a\\\"b\" x") == @[("\"a\\\"b\"", tkString), ("x", tkIdent)]
    check kinds("r\"a\\\"") == @[("r\"a\\\"", tkString)]          # raw: no escapes
    check kinds("r\"a\"\"b\" y") == @[("r\"a\"\"b\"", tkString), ("y", tkIdent)]
    check kinds("fmt\"x{y}\" z") == @[("fmt\"x{y}\"", tkString), ("z", tkIdent)]
    check kinds("\"\"") == @[("\"\"", tkString)]
    check kinds("\"open") == @[("\"open", tkString)]              # to end of line
    check lexOne("\"open")[1] == 0
    check kinds("\"\"\"a\"\"\" b") == @[("\"\"\"a\"\"\"", tkString), ("b", tkIdent)]
    check kinds("\"\"\"\"a\"\"\"\" b")[0] == ("\"\"\"\"a\"\"\"\"", tkString)
    check kinds("not\"x\"")[0] == ("not", tkKeyword)              # keyword, not a prefix

  test "characters":
    check kinds("'a'") == @[("'a'", tkChar)]
    check kinds("'\\n'") == @[("'\\n'", tkChar)]
    check kinds("'\\''") == @[("'\\''", tkChar)]
    check kinds("'\\x41'") == @[("'\\x41'", tkChar)]
    check kinds("'é'") == @[("'é'", tkChar)]
    check kinds("'''")[0].kind == tkError
    check kinds("'ab")[0] == ("'", tkError)

  test "comments":
    check kinds("x # hi") == @[("x", tkIdent), ("# hi", tkComment)]
    check kinds("## doc") == @[("## doc", tkDocComment)]
    check kinds("#[ a ]# b") == @[("#[ a ]#", tkComment), ("b", tkIdent)]
    check kinds("##[ a ]## b") == @[("##[ a ]##", tkDocComment), ("b", tkIdent)]
    check kinds("#[ #[ n ]# ]# c") == @[("#[ #[ n ]# ]#", tkComment), ("c", tkIdent)]
    check lexOne("#[ open")[1] == (stBlockComment or (1 shl 3))
    check lexOne("#[ #[ open")[1] == (stBlockComment or (2 shl 3))
    check lexOne("##[ open")[1] == (stDocBlock or (1 shl 3))
    check kinds("#?x")[0].kind == tkComment

  test "pragmas":
    check kinds("{.push raises: [].}") == @[("{.push raises: [].}", tkPragma)]
    check kinds("proc f() {.inline.} = 1")[3] == ("{.inline.}", tkPragma)
    check kinds("{.emit: \".}\".} x") == @[("{.emit: \".}\".}", tkPragma), ("x", tkIdent)]
    check lexOne("{.push a,")[1] == stPragma
    check kinds("{1, 2}") == @[("{", tkPunct), ("1", tkNumber), (",", tkPunct),
                               ("2", tkNumber), ("}", tkPunct)]

  test "operators, punctuation and backticks":
    check kinds("a == b")[1] == ("==", tkOperator)
    check kinds("a..<b")[1] == ("..<", tkOperator)
    check kinds("x[1]")[1] == ("[", tkPunct)
    check kinds("`+`(1)")[0] == ("`+`", tkIdent)
    check kinds("proc `$`*(x: T)")[1] == ("`$`", tkIdent)
    check kinds("x*")[1] == ("*", tkOperator)
    check kinds("a=-1")[1] == ("=-", tkOperator)
    check kinds("`open")[0] == ("`", tkOperator)
    check kinds("a;b")[1] == (";", tkPunct)

suite "nim lexer: multi-line state":
  test "triple-quoted strings span lines":
    let (t1, s1) = lexOne("let s = \"\"\"abc")
    check s1 == stTriple and t1[^1] == ("\"\"\"abc", tkString)
    let (t2, s2) = lexOne("still \" inside # not a comment", s1)
    check s2 == stTriple and t2 == @[("still \" inside # not a comment", tkString)]
    let (t3, s3) = lexOne("end\"\"\" & x", s2)
    check s3 == 0 and t3[0] == ("end\"\"\"", tkString) and t3[^1] == ("x", tkIdent)
    let (_, s4) = lexOne("sql\"\"\"select", 0)
    check s4 == stTriple

  test "nested block comments keep their depth":
    let (_, s1) = lexOne("code #[ a #[ b")
    check s1 == (stBlockComment or (2 shl 3))
    let (t2, s2) = lexOne("]# still", s1)
    check s2 == (stBlockComment or (1 shl 3)) and t2 == @[("]# still", tkComment)]
    let (t3, s3) = lexOne("]# done x", s2)
    check s3 == 0 and t3[0] == ("]#", tkComment) and t3[^1] == ("x", tkIdent)
    let (t4, s4) = lexOne("x ]# y")          # a stray close outside a comment is code
    check s4 == 0 and t4[2].kind == tkPunct and t4[3].kind == tkComment

  test "doc block comments":
    let (_, s1) = lexOne("##[ doc")
    let (t2, s2) = lexOne("more ]##", s1)
    check s2 == 0 and t2 == @[("more ]##", tkDocComment)]

  test "multi-line pragma":
    let (_, s1) = lexOne("{.push a,")
    let (t2, s2) = lexOne("  b.} z", s1)
    check s2 == 0 and t2[0].kind == tkPragma and t2[^1] == ("z", tkIdent)

proc dumpAll(h: Highlighter, m: CodeModel): seq[string] =
  for i in 0 ..< m.lineCount:
    var row = $h.stateAtLineStart(i) & "|"
    for t in h.tokens(i): row.add $t.start & ":" & $t.len & ":" & $t.kind & " "
    result.add row

suite "highlighter cache":
  test "tokens(line) over a model, lazily, with correct states":
    let m = newCodeModel("let a = \"\"\"x\ny\"\"\"\nvar b = 1 #[ c\nd ]# e")
    let h = newNimHighlighter(m)
    check h.relexed == 0
    check h.tokens(0)[^1].kind == tkString
    check h.relexed == 1
    check h.tokens(1).len == 1 and h.tokens(1)[0].kind == tkString
    check h.stateAtLineStart(1) == stTriple
    check h.stateAtLineStart(2) == 0
    check h.stateAtLineStart(3) == (stBlockComment or (1 shl 3))
    check h.tokens(3)[^1].kind == tkIdent
    check h.tokens(99).len == 0
    check h.kindAt(0, 9) == tkString and h.kindAt(2, 0) == tkKeyword
    check h.tokenAt(2, 4).kind == tkIdent and h.tokenAt(2, 99).len == 0

  test "an edit re-lexes the edited line and stops when the state matches":
    var src = ""
    for i in 0 ..< 500: src.add "let v" & $i & " = " & $i & " # c\n"
    let m = newCodeModel(src)
    let h = newNimHighlighter(m)
    h.lexAll()
    check h.relexed == 501
    discard m.insert((250, 5), "x")
    h.lexAll()
    check h.relexed == 502                 # just the edited line
    discard m.insert((100, 0), "\n")       # a new line shifts the rest, no re-lex
    h.lexAll()
    check h.relexed == 504                 # two changed lines (the split one)
    discard m.insert((10, 0), "\"\"\"")    # opens a triple string: states change below
    h.lexAll()
    check h.relexed > 504 + 100
    discard m.undo()
    h.lexAll()
    check h.dumpAll(m) == (let f = newNimHighlighter(m); f.attach(m); f.dumpAll(m))

  test "re-attach and invalidateAll":
    let m = newCodeModel("a\nb")
    let h = newNimHighlighter(m)
    h.lexAll()
    h.invalidateAll()
    check h.relexed == 2
    h.lexAll()
    check h.relexed == 4
    h.detach()
    check h.tokens(0).len == 0

suite "highlighter styles":
  test "palettes follow the theme":
    let lt = syntaxStylesFor(themeLight())
    let dk = syntaxStylesFor(themeDark())
    check lt[tkText].color == themeLight().text
    check dk[tkText].color == themeDark().text
    check lt[tkKeyword].color != dk[tkKeyword].color
    check fsItalic in lt[tkComment].style and fsBold in dk[tkKeyword].style
    check lt[tkComment].color == themeLight().textMuted
    check dk[tkError].color == themeDark().danger
    var s = lt
    s[tkUser3] = TokenStyle(color: dk[tkString].color)
    check s[tkUser3].color == dk[tkString].color

# ------------------------------------------------------------ incremental fuzz

const Vocab = ["let", "proc", "x", "y_1", "\"", "\"\"\"", "r\"", "'", "'a'", "#", "##",
               "#[", "]#", "##[", "]##", "{.", ".}", "`", "(", ")", "[", "]", "{",
               "}", "0x1F", "1.5", "'i32", ".", "..", "=", "+", " ", "  ", "\n",
               "\n", "\n", "\\", "é", "\"\"", ":"]

proc randomText(rng: var Rand, n: int): string =
  for _ in 0 ..< n: result.add Vocab[rng.rand(Vocab.high)]

suite "incremental re-lex fuzz":
  test "1000 seeds: cached highlighter equals a fresh full lex after random edits":
    for seed in 1 .. 1000:
      var rng = initRand(seed)
      let m = newCodeModel(rng.randomText(rng.rand(0 .. 60)))
      let h = newNimHighlighter(m)
      for step in 0 ..< 12:
        # sometimes look at a few lines before editing, like a painter would
        if rng.rand(2) == 0:
          for _ in 0 .. 3: discard h.tokens(rng.rand(m.lineCount - 1))
        let a = m.snapPos((rng.rand(m.lineCount - 1), rng.rand(0 .. 30)))
        let b = m.snapPos((rng.rand(m.lineCount - 1), rng.rand(0 .. 30)))
        case rng.rand(9)
        of 0: discard m.undo()
        of 1: discard m.redo()
        else: discard m.replace(a, b, rng.randomText(rng.rand(0 .. 4)))
        if rng.rand(1) == 0 or step == 11:
          let fresh = newNimHighlighter(m)
          let got = h.dumpAll(m)
          let want = fresh.dumpAll(m)
          if got != want:
            checkpoint "seed " & $seed & " step " & $step
          check got == want
          if got != want: break
