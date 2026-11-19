## Fold regions (indent, brackets, markers), collapsing, row mapping and
## incremental update; plus bracket matching.

import std/[unittest, strutils, random]
import nimvcl/controls/[codemodel, highlight, nimlexer, folding, brackets]

proc regs(f: FoldMap): seq[(int, int)] =
  for r in f.regions: result.add (r.startLine, r.endLine)

suite "folding: indentation":
  test "nim style blocks":
    let m = newCodeModel("""proc a() =
  echo 1
  if x:
    echo 2

  echo 3
proc b() =
  discard
""")
    let f = newFoldMap(m)
    check f.regs == @[(0, 5), (2, 3), (6, 7)]
    check f.canFold(0) and not f.canFold(1) and f.foldEnd(2) == 3 and f.foldEnd(1) == -1

  test "blank lines, tabs and a final dedent":
    let m = newCodeModel("a:\n\tb\n\n\n\tc\nd\n  e\n    f")
    let f = newFoldMap(m)
    check f.regs == @[(0, 4), (5, 7), (6, 7)]

  test "single-line and flat text have no regions":
    check newFoldMap(newCodeModel("a\nb\nc")).regions.len == 0
    check newFoldMap(newCodeModel("")).regions.len == 0

  test "collapse, hidden lines and row mapping":
    let m = newCodeModel("a:\n b\n c:\n  d\n e\nf:\n g\nh")
    let f = newFoldMap(m)
    check f.regs == @[(0, 4), (2, 3), (5, 6)]
    check f.visibleLineCount == 8
    check f.collapse(2)
    check f.isHidden(3) and not f.isHidden(2) and not f.isHidden(4)
    check f.visibleLineCount == 7
    check f.collapse(0)
    check f.isHidden(1) and f.isHidden(4) and f.visibleLineCount == 4
    check f.hiddenRanges == @[(a: 1, b: 4)]          # nested ranges merge
    check f.lineToRow(5) == 1 and f.lineToRow(3) == 0 and f.lineToRow(7) == 3
    check f.rowToLine(0) == 0 and f.rowToLine(1) == 5 and f.rowToLine(3) == 7
    check f.nextVisibleLine(0) == 5 and f.nextVisibleLine(7) == -1
    check f.prevVisibleLine(5) == 0 and f.prevVisibleLine(0) == -1
    f.expandTo(3)
    check not f.isCollapsed(0) and not f.isCollapsed(2)
    check not f.isHidden(3)
    f.collapseAll()
    check f.collapsedLines == @[0, 2, 5]
    f.expandAll()
    check f.visibleLineCount == 8
    check not f.collapse(1)                          # not a header
    var notified = 0
    f.onChanged = proc() = inc notified
    f.toggle(5)
    f.toggle(5)
    check notified == 2

  test "edits shift collapsed headers and the regions follow incrementally":
    let m = newCodeModel("x\na:\n b\n c\nd:\n e\nf")
    let f = newFoldMap(m)
    check f.regs == @[(1, 3), (4, 5)]
    check f.collapse(4)
    discard m.insert((0, 1), "\nnew")       # a line above
    check f.regs == @[(2, 4), (5, 6)]
    check f.isCollapsed(5) and f.isHidden(6)
    discard m.replace((6, 0), (6, 2), "")   # remove the body of d: header no longer folds
    check f.regs == @[(2, 4)]
    check not f.isCollapsed(5) and not f.isHidden(6)
    discard m.undo()
    check f.regs == @[(2, 4), (5, 6)]
    discard m.insert((3, 1), "z")
    check f.regs == @[(2, 4), (5, 6)]

suite "folding: brackets and markers":
  test "brackets across lines, closing line stays visible":
    let m = newCodeModel("let t = {\n  a: 1,\n  b: 2\n}\nf(\n  x)\ng(1,\n2\n)")
    let f = newFoldMap(m, nil, {fkBrackets})
    check f.regs == @[(0, 2), (6, 7)]          # f( ... x) closes one line later: nothing to hide
    let h = newNimHighlighter(m)
    let g = newFoldMap(m, h, {fkBrackets})
    check g.regs == f.regs

  test "brackets in strings and comments are ignored with a highlighter":
    let m = newCodeModel("a = \"{\"\nb = 1\n# }\nc = {\n1\n}")
    let h = newNimHighlighter(m)
    check newFoldMap(m, h, {fkBrackets}).regs == @[(3, 4)]
    check newFoldMap(m, nil, {fkBrackets}).regs != @[(3, 4)]

  test "bracket facts follow the lexer state (a comment opened above)":
    let m = newCodeModel("x\ny = {\n1\n}")
    let h = newNimHighlighter(m)
    let f = newFoldMap(m, h, {fkBrackets})
    check f.regs == @[(1, 2)]
    discard m.insert((0, 1), " #[")            # the rest of the file is now a comment
    check f.regs.len == 0
    discard m.undo()
    check f.regs == @[(1, 2)]

  test "region markers nest and the end line is hidden":
    let m = newCodeModel("#region A\nx\n  // region B\ny\n  // endregion\n#endregion\nz")
    let f = newFoldMap(m, nil, {fkMarkers})
    check f.regs == @[(0, 5), (2, 4)]

  test "combined sources keep one region per header; custom hook":
    let m = newCodeModel("if x: {\n  a\n}\nb")
    let f = newFoldMap(m, nil, {fkIndent, fkBrackets})
    check f.regs == @[(0, 1)]
    f.setHook(proc(m: CodeModel, hl: Highlighter): seq[FoldRegion] =
      @[FoldRegion(startLine: 2, endLine: 3), FoldRegion(startLine: 0, endLine: 3)])
    check f.regs == @[(0, 3), (2, 3)]

suite "folding: fuzz":
  test "incremental regions equal a fresh map after random edits":
    let alphabet = ["a", " ", "  ", "\n", "\n", "{", "}", "(", ")", "#region", "#endregion",
                    "\t", "\"", "#[", "]#"]
    for seed in 1 .. 300:
      var rng = initRand(seed)
      var src = ""
      for _ in 0 ..< rng.rand(0 .. 40): src.add alphabet[rng.rand(alphabet.high)]
      let m = newCodeModel(src)
      let h = newNimHighlighter(m)
      let f = newFoldMap(m, h, {fkIndent, fkBrackets, fkMarkers})
      for _ in 0 ..< 10:
        let a = m.snapPos((rng.rand(m.lineCount - 1), rng.rand(0 .. 12)))
        let b = m.snapPos((rng.rand(m.lineCount - 1), rng.rand(0 .. 12)))
        var ins = ""
        for _ in 0 ..< rng.rand(0 .. 3): ins.add alphabet[rng.rand(alphabet.high)]
        if rng.rand(6) == 0: discard m.undo()
        else: discard m.replace(a, b, ins)
        if rng.rand(1) == 0:
          let h2 = newNimHighlighter(m)
          let fresh = newFoldMap(m, h2, {fkIndent, fkBrackets, fkMarkers})
          check f.regs == fresh.regs
          h2.detach()
          fresh.detach()

suite "bracket matching":
  test "pairs, nesting and both directions":
    let m = newCodeModel("f(a[1], {b})\n(x\n)")
    check findMatchingBracket(m, nil, (0, 1)) == BracketMatch(found: true, isBracket: true, a: (0, 1), b: (0, 11))
    let r = findMatchingBracket(m, nil, (0, 12))      # after the closing paren
    check r.found and r.a == (0, 11) and r.b == (0, 1)
    let s = findMatchingBracket(m, nil, (0, 3))
    check s.found and s.b == (0, 5)
    let t = findMatchingBracket(m, nil, (1, 0))
    check t.found and t.b == (2, 0)
    check not findMatchingBracket(m, nil, (0, 0)).isBracket

  test "unmatched brackets":
    let m = newCodeModel("(a[b)")
    let r = findMatchingBracket(m, nil, (0, 0))
    check r.isBracket and r.found and r.b == (0, 4)   # '[' in between is not the partner kind
    let u = newCodeModel("(((")
    check findMatchingBracket(u, nil, (0, 0)).isBracket
    check not findMatchingBracket(u, nil, (0, 0)).found

  test "strings and comments are skipped via the highlighter tokens":
    let m = newCodeModel("f(\")\", ')', 1) # )\n#[ ) ]# (x)\n\"\"\"\n)\n\"\"\"")
    let h = newNimHighlighter(m)
    let r = findMatchingBracket(m, h, (0, 1))
    check r.found and r.b == (0, 13)
    check findMatchingBracket(m, nil, (0, 1)).b == (0, 3)
    # a bracket inside a string never matches
    check not findMatchingBracket(m, h, (0, 3)).isBracket
    # (x) after a block comment on line 1
    let q = findMatchingBracket(m, h, (1, 8))
    check q.found and q.b == (1, 10)
    check not findMatchingBracket(m, h, (3, 0)).isBracket   # inside the triple string

  test "scan limit":
    var s = "(\n"
    for _ in 0 ..< 50: s.add "x\n"
    s.add ")"
    let m = newCodeModel(s)
    check findMatchingBracket(m, nil, (0, 0)).found
    check not findMatchingBracket(m, nil, (0, 0), maxLines = 10).found

suite "folding: incremental facts and row mapping":
  proc naiveRow(hidden: seq[(int, int)], line: int): int =
    result = line
    for (a, b) in hidden:
      if a <= line: result -= min(b, line) - a + 1

  test "row mapping agrees with a linear scan over many collapsed regions":
    var src = ""
    for i in 0 ..< 60: src.add "r" & $i & ":\n  a\n  b\n"
    let m = newCodeModel(src)
    let f = newFoldMap(m)
    for i in countup(0, 59, 3): discard f.collapse(i * 3)
    let hidden = block:
      var h: seq[(int, int)]
      for r in f.hiddenRanges: h.add (r.a, r.b)
      h
    check hidden.len == 20
    var rows: seq[int]
    for l in 0 ..< m.lineCount:
      check f.lineToRow(l) == naiveRow(hidden, l)
      if not f.isHidden(l): rows.add l
    check f.visibleLineCount == rows.len
    for r in 0 ..< rows.len: check f.rowToLine(r) == rows[r]
    var l = 0
    var seen = 0
    while l >= 0:
      inc seen
      let n = f.nextVisibleLine(l)
      if n >= 0: check f.prevVisibleLine(n) == l
      l = n
    check seen == rows.len

  test "typing inside a line keeps the regions; an indent change updates them":
    let m = newCodeModel("a:\n  b\n  c\nd")
    let f = newFoldMap(m)
    check f.regs == @[(0, 2)]
    discard m.insert((1, 3), "xyz")
    check f.regs == @[(0, 2)]
    discard m.insert((3, 0), "  ")
    check f.regs == @[(0, 3)]
    discard m.delete((1, 0), (1, 2))
    check f.regs == newFoldMap(m).regs

  test "incremental regions equal a fresh build after random edits":
    for kinds in [{fkIndent}, {fkBrackets}, {fkIndent, fkBrackets, fkMarkers}]:
      for seed in 1 .. 40:
        var rng = initRand(seed)
        let hl = newNimHighlighter()
        let m = newCodeModel("proc a() =\n  if x:\n    f(1,\n      2)\n  # c\nproc b() = discard\n")
        hl.attach(m)
        let f = newFoldMap(m, hl, kinds)
        let frags = ["  ", "(", ")", "\n", "x", "#[", "]#", "\"", "\n  ", "{", "}", "#region", "#endregion"]
        for step in 0 ..< 25:
          let l = rng.rand(m.lineCount - 1)
          let c = min(rng.rand(8), m.lineLen(l))
          let frag = frags[rng.rand(frags.high)]
          if rng.rand(3) == 0 and m.lineLen(l) > c:
            discard m.delete((l, c), (l, m.nextPos((l, c)).col))
          else: discard m.insert((l, c), frag)
          if rng.rand(5) == 0: discard m.undo()
          if rng.rand(2) == 0:
            let fresh = newFoldMap(m, hl, kinds)
            check f.regs == fresh.regs
        let fresh = newFoldMap(m, hl, kinds)
        check f.regs == fresh.regs
