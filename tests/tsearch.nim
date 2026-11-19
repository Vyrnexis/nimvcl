## Find / replace over a CodeModel, and the regex engine behind it.

import std/[unittest, strutils, random, times]
import nimvcl/controls/[codemodel, search, minire]

proc rx(pat: string, ci = false): Regex = compileRegex(pat, ci)

proc rmatch(pat, s: string, ci = false): string =
  ## The text of the first match, or "<none>".
  var m: RegexMatch
  if rx(pat, ci).findAt(s, 0, m): s[m.a ..< m.b] else: "<none>"

suite "minire":
  test "literals, classes, anchors":
    check rmatch("abc", "xxabcxx") == "abc"
    check rmatch("a.c", "a\nc abc") == "abc"
    check rmatch("[a-c]+", "xxabcabd") == "abcab"
    check rmatch("[^a-c ]+", "ab xyz") == "xyz"
    check rmatch("[\\d_]+", "ab12_3c") == "12_3"
    check rmatch("^ab", "abab") == "ab" and rmatch("^b", "ab") == "<none>"
    check rmatch("b$", "abab") == "b" and rmatch("a$", "ab") == "<none>"
    check rmatch("\\bfoo\\b", "afoo foo") == "foo"
    check rmatch("\\Boo", "foo oo") == "oo"
    check rmatch("\\w+@\\w+\\.com", "mail bob@site.com now") == "bob@site.com"
    check rmatch("[]a]+", "x]a]") == "]a]"
    check rmatch("\\.\\*\\(", "a.*(") == ".*("

  test "quantifiers, greedy and lazy":
    check rmatch("a*", "aaa") == "aaa"
    check rmatch("a+?", "aaa") == "a"
    check rmatch("<.+>", "<a><b>") == "<a><b>"
    check rmatch("<.+?>", "<a><b>") == "<a>"
    check rmatch("ab?c", "ac abc") == "ac"
    check rmatch("a{2}", "aaaa") == "aa"
    check rmatch("a{2,3}", "aaaa") == "aaa"
    check rmatch("a{2,}", "aaaa") == "aaaa"
    check rmatch("a{2,3}?", "aaaa") == "aa"
    check rmatch("x{", "x{") == "x{"             # a literal brace
    check rmatch("(ab)+", "ababab") == "ababab"
    check rmatch("(?:ab){2}", "ababab") == "abab"
    check rmatch("(a|b)*c", "abbac") == "abbac"

  test "alternation, groups and captures":
    check rmatch("cat|dog", "hotdog") == "dog"
    check rmatch("gr(a|e)y", "grey") == "grey"
    var m: RegexMatch
    check rx("(\\w+)=(\\d+)").findAt("x a=12 b", 0, m)
    check m.groups.len == 3 and m.groups[1] == (2, 3) and m.groups[2] == (4, 6)
    check rx("(a)|(b)").findAt("b", 0, m) and m.groups[1] == (-1, -1) and m.groups[2] == (0, 1)
    check expandReplacement(m, "b", "[$0|$2|\\2|$1|$$|\\\\]") == "[b|b|b||$|\\]"

  test "UTF-8 aware":
    check rmatch(".", "é") == "é"
    check rmatch("h.llo", "héllo") == "héllo"
    check rmatch("[é世]+", "ab世é") == "世é"
    check rmatch("é+", "ééé") == "ééé"
    check rmatch("\\w+", "naïve_x y") == "naïve_x"
    check rmatch("[^a]+", "世界a") == "世界"
    var m: RegexMatch
    check rx(".*").findAt("世界", 0, m) and m.b == 6

  test "case insensitive folds ASCII":
    check rmatch("hello", "Say HeLLo", ci = true) == "HeLLo"
    check rmatch("[a-c]+", "xABCx", ci = true) == "ABC"
    check rmatch("hello", "Say HeLLo") == "<none>"

  test "escapes":
    check rmatch("a\\tb", "a\tb") == "a\tb"
    check rmatch("\\x41\\u00e9", "Aé") == "Aé"

  test "bad patterns raise RegexError":
    for p in ["(", ")", "[a", "*a", "a**" & "(", "\\", "(?=a)", "a{3,2}", "[z-a]", "\\q"]:
      expect RegexError: discard compileRegex(p)

  test "runaway patterns give up instead of hanging":
    var m: RegexMatch
    let hay = "a".repeat(40) & "b"
    check not rx("(a+)+$").findAt(hay, 0, m)               # must return
    check not rx("(a*)*c").findAt(hay, 0, m)

  test "findAt start offset and empty matches":
    var m: RegexMatch
    check rx("a").findAt("aXa", 1, m) and m.a == 2
    check rx("x*").findAt("abc", 1, m) and m.a == 1 and m.b == 1
    check not rx("a").findAt("a", 2, m)

proc mk(s: string): CodeModel = newCodeModel(s)

proc ms(s: Searcher, m: CodeModel): seq[string] =
  for mt in s.matches(m): result.add $mt.a.line & ":" & $mt.a.col & "-" & $mt.b.col

suite "search: plain":
  let doc = "foo Foo FOO\nfoobar barfoo foo_x\n  foo\nél é Él"

  test "case sensitive, ignore case, whole word":
    let m = mk(doc)
    check newSearcher("foo").ms(m) == @["0:0-3", "1:0-3", "1:10-13", "1:14-17", "2:2-5"]
    check newSearcher("foo", SearchOptions(ignoreCase: true)).countAll(m) == 7
    check newSearcher("foo", SearchOptions(wholeWord: true)).ms(m) == @["0:0-3", "2:2-5"]
    check newSearcher("FOO", SearchOptions(wholeWord: true, ignoreCase: true)).ms(m) ==
      @["0:0-3", "0:4-7", "0:8-11", "2:2-5"]
    # the check is skipped on a side where the pattern is not an identifier char
    check newSearcher("foo(", SearchOptions(wholeWord: true)).countAll(mk("xfoo( foo(")) == 1
    check newSearcher("é", SearchOptions(wholeWord: true)).ms(m) == @["3:4-6"]
    check newSearcher("").countAll(m) == 0

  test "findNext / findPrev with wrap":
    let m = mk(doc)
    let s = newSearcher("foo")
    var f: Match
    check s.findNext(m, (0, 0), f) and f == ((0, 0), (0, 3))
    check s.findNext(m, (0, 1), f) and f == ((1, 0), (1, 3))
    check s.findNext(m, (2, 3), f) and f == ((0, 0), (0, 3))          # wrapped
    check not s.findNext(m, (2, 3), f, wrap = false)
    check s.findPrev(m, (1, 0), f) and f == ((0, 0), (0, 3))
    check s.findPrev(m, (0, 0), f) and f == ((2, 2), (2, 5))           # wrapped
    check not s.findPrev(m, (0, 0), f, wrap = false)
    check s.findPrev(m, (1, 16), f) and f == ((1, 14), (1, 17))
    let t = newSearcher("zzz")
    check not t.findNext(m, (0, 0), f) and not t.findPrev(m, (0, 0), f)

  test "only match of a document wraps onto itself":
    let m = mk("abc")
    var f: Match
    check newSearcher("b").findNext(m, (0, 2), f) and f == ((0, 1), (0, 2))
    check newSearcher("b").findPrev(m, (0, 1), f) and f == ((0, 1), (0, 2))

  test "ranges and findAll limit":
    let m = mk("a a a\na a")
    check newSearcher("a").ms(m).len == 5
    var inRange: seq[string]
    for mt in newSearcher("a").matches(m, (0, 2), (1, 0)): inRange.add $mt.a
    check inRange.len == 2
    check newSearcher("a").findAll(m, 3).len == 3

  test "replace one and replace all in one undo step":
    let m = mk("foo bar foo\nfoo")
    let s = newSearcher("foo")
    var f: Match
    check s.findNext(m, (0, 0), f)
    check s.replaceMatch(m, f, "quux")
    check m.text == "quux bar foo\nfoo"
    check s.replaceAll(m, "X") == 2
    check m.text == "quux bar X\nX"
    discard m.undo()
    check m.text == "quux bar foo\nfoo"
    discard m.undo()
    check m.text == "foo bar foo\nfoo"
    check s.replaceAll(m, "foofoo") == 3                     # no re-scan of the output
    check m.text == "foofoo bar foofoo\nfoofoo"
    check s.replaceAll(m, "a\nb") == 6
    check m.text == "a\nba\nb bar a\nba\nb\na\nba\nb"
    discard m.undo()
    check m.text == "foofoo bar foofoo\nfoofoo"

  test "replace all inside a range, read-only":
    let m = mk("a a\na a\na a")
    check newSearcher("a").replaceAll(m, "b", (1, 0), (1, 3)) == 2
    check m.text == "a a\nb b\na a"
    m.readOnly = true
    check newSearcher("a").replaceAll(m, "c") == 0

  test "multi-line replacement text shifts later lines":
    let m = mk("x\nx\nx")
    check newSearcher("x").replaceAll(m, "1\n2") == 3
    check m.text == "1\n2\n1\n2\n1\n2"
    discard m.undo()
    check m.text == "x\nx\nx"

suite "search: regex":
  test "find, groups in replacement, whole word":
    let m = mk("let a = 12\nlet bb = 345\nx12")
    let s = newSearcher("(\\w+) = (\\d+)", SearchOptions(regex: true))
    check s.countAll(m) == 2
    check s.replaceAll(m, "$2 -> $1") == 2
    check m.text == "let 12 -> a\nlet 345 -> bb\nx12"
    let w = newSearcher("\\d+", SearchOptions(regex: true, wholeWord: true))
    check w.ms(m) == @["0:4-6", "1:4-7"]
    let i = newSearcher("LET", SearchOptions(regex: true, ignoreCase: true))
    check i.countAll(m) == 2

  test "zero-length matches terminate and replace":
    let m = mk("ab\n\ncd")
    let s = newSearcher("^", SearchOptions(regex: true))
    check s.countAll(m) == 3
    check s.replaceAll(m, "// ") == 3
    check m.text == "// ab\n// \n// cd"
    let e = newSearcher("x*", SearchOptions(regex: true))
    check e.countAll(mk("ab")) == 3

  test "bad regex raises at compile time":
    expect RegexError: discard newSearcher("(", SearchOptions(regex: true))

  test "replaceText expands one match; regex find next/prev":
    let m = mk("k1=v1\nk2=v2")
    let s = newSearcher("(\\w)(\\d)=", SearchOptions(regex: true))
    var f: Match
    check s.findNext(m, (0, 1), f) and f.a == (1, 0)
    check s.replacementFor(m, f, "$2$1:") == "2k:"
    check s.findPrev(m, (1, 0), f) and f.a == (0, 0)

suite "search: fuzz":
  test "plain search agrees with a naive scan":
    let alphabet = ["a", "A", "b", "_", " ", "é", "ab"]
    for seed in 1 .. 300:
      var rng = initRand(seed)
      var text = ""
      for _ in 0 ..< rng.rand(0 .. 40):
        text.add (if rng.rand(7) == 0: "\n" else: alphabet[rng.rand(alphabet.high)])
      var pat = ""
      for _ in 0 ..< rng.rand(1 .. 3): pat.add alphabet[rng.rand(alphabet.high)]
      let ci = rng.rand(1) == 0
      let m = mk(text)
      let s = newSearcher(pat, SearchOptions(ignoreCase: ci))
      var naive: seq[string]
      for l in 0 ..< m.lineCount:
        let ln = m.line(l)
        var i = 0
        while i + pat.len <= ln.len:
          let seg = ln[i ..< i + pat.len]
          if (if ci: cmpIgnoreCase(seg, pat) == 0 else: seg == pat):
            naive.add $l & ":" & $i & "-" & $(i + pat.len)
            i += pat.len
          else: inc i
      # the engine skips past a match; so does the naive scan above
      check s.ms(m) == naive

suite "minire: required literal prefilter":
  test "does not reject matches that skip optional or repeated characters":
    for (p, s, want) in [("x*", "ab", ""), ("ab*c", "ac", "ac"), ("a(bc)?d", "ad", "ad"),
                         ("(?:foo)?bar", "bar", "bar"), ("foo|bar", "bar", "bar"),
                         ("a+bc", "aabc", "aabc"), ("(abc)+", "abcabc", "abcabc"),
                         ("(xyz)*q", "q", "q"), ("a{0,2}b", "b", "b")]:
      check rmatch(p, s) == want
    check rmatch("foo\\d+bar", "x foo12bar") == "foo12bar"
    check rmatch("[a-z]+_end", "ab no_end") == "no_end"
    check rmatch("[a-z]+_end", "ab no_en") == "<none>"

suite "minire: runaway patterns and empty loops":
  test "an exponential pattern finishes quickly (one budget per search)":
    let t0 = cpuTime()
    check rmatch("(a|aa)+$", 'a'.repeat(200) & "X") == "<none>"
    check rmatch("(a*)*b", 'a'.repeat(300)) == "<none>"
    check rmatch("(x+x+)+y", 'x'.repeat(200)) == "<none>"
    check cpuTime() - t0 < 5.0
    check rmatch("(a|aa)+$", "aaaaaaaaaaa") == "aaaaaaaaaaa"

  test "a loop whose body matches the empty string still matches":
    check rmatch("(a*)*b", "b") == "b"
    check rmatch("(a*)*b", "aab") == "aab"
    check rmatch("(x?)+y", "y") == "y"
    check rmatch("(a|b*)*c", "abc") == "abc"
    check rmatch("(\\s*\\w*)*;", "ab cd ;") == "ab cd ;"
    check rmatch("(\\d*,?)+x", "1,22,x") == "1,22,x"

  test "captures survive memoisation":
    var m: RegexMatch
    check rx("(a+)(b+)").findAt("xxaabbb", 0, m)
    check m.groups[1] == (2, 4) and m.groups[2] == (4, 7)

  test "oversized repeats are refused before they are built":
    expect RegexError: discard rx("((ab){1000}){1000}")

suite "search: whole word, empty matches, replace all":
  test "regex whole word leaves punctuation edges alone":
    let m = mk("foo(x foo() food")
    let s = newSearcher("foo\\(", SearchOptions(regex: true, wholeWord: true))
    check s.ms(m) == @["0:0-4", "0:6-10"]
    let w = newSearcher("foo|food", SearchOptions(regex: true, wholeWord: true))
    check w.ms(mk("food foo foods")) == @["0:0-4", "0:5-8"]

  test "findPrev visits every empty match":
    let m = mk("foo bar")
    let s = newSearcher("\\b", SearchOptions(regex: true))
    var f: Match
    check s.findPrev(m, (0, 6), f) and f.a == (0, 4)
    check s.findPrev(m, f.a, f) and f.a == (0, 3)

  test "replace all with a newline in the replacement is one edit":
    let m = mk(";a;b;c;\n;")
    let ver = m.version
    var fired = 0
    discard m.addChangeListener(proc(f, o, n: int) = inc fired)
    let s = newSearcher(";")
    check s.replaceAll(m, ";\n") == 5
    check m.text == ";\na;\nb;\nc;\n\n;\n"
    check fired == 1 and m.version == ver + 1
    check m.undo()
    check m.text == ";a;b;c;\n;" and not m.canUndo

  test "replace all counts replacements that change nothing":
    let m = mk("a b a")
    check newSearcher("a").replaceAll(m, "a") == 2

  test "replace all scales linearly with a line-adding replacement":
    var big = newStringOfCap(400_000)
    for i in 0 ..< 40_000: big.add "x;\n"
    let m = mk(big)
    let t0 = cpuTime()
    check newSearcher(";").replaceAll(m, ";\n") == 40_000
    check m.lineCount == 80_001
    check cpuTime() - t0 < 5.0
