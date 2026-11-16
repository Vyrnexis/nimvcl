## Performance of the code editor's non-visual layer on big inputs: opening a
## 100 MB / 2M-line file, re-highlighting after one edit in a 200k-line file,
## folding and searching 2M lines. The targets are asserted in release builds
## only (debug builds run a 20x smaller document and just print the numbers).

import std/[unittest, monotimes, times, os, strutils]
import nimvcl/controls/[codemodel, highlight, nimlexer, folding, search]

const Release = defined(release) or defined(danger)
const Scale = if Release: 1 else: 20

proc ms(t0: MonoTime): float = float((getMonoTime() - t0).inNanoseconds) / 1e6

const Block = [
  "proc compute(a, b: int): int =",
  "  # sum with a comment, with a few more words in it",
  "  result = a + b * 3",
  "  let name = \"some string value\" & $a",
  "  if result > 100 and name.len > 3:",
  "    echo \"big: \", result, ' ', 0x1F'u8",
  "  for i in 0 ..< 10:",
  "    result += i # accumulate",
  "",
  "type Point = object",
  "  x, y: float   ## coordinates",
  "const greeting = \"héllo wörld, ünïcode 世界\"",
  "{.push raises: [].}",
  "template twice(body: untyped) = body; body",
  "  discard needle_not_here_really",
  "var table: seq[(string, int)] = @[(\"a\", 1), (\"b\", 2)]",
]

proc bigText(lines: int): string =
  result = newStringOfCap(lines * 48)
  for i in 0 ..< lines:
    result.add Block[i mod Block.len]
    if Block[i mod Block.len].len > 0: result.add " # padding padding"
    result.add '\n'

suite "code editor performance":
  test "open a 100 MB file":
    let n = 2_000_000 div Scale
    let path = getTempDir() / "nimvcl_perf_big.txt"
    writeFile(path, bigText(n))
    defer: removeFile path
    let m = newCodeModel()
    var t = 1e9
    var rep: LoadReport
    for _ in 0 ..< 3:                  # best of three: the box may be busy
      let t0 = getMonoTime()
      rep = m.loadFile(path)
      t = min(t, t0.ms)
    echo "  load ", rep.bytes div 1_000_000, " MB, ", rep.lines, " lines: ", $int(t), " ms"
    check m.lineCount == n + 1 and rep.invalidBytes == 0
    if Release: check t < 1000
    # an edit in the middle of the huge buffer
    let t1 = getMonoTime()
    discard m.insert((n div 2, 3), "x\ny")
    discard m.undo()
    let te = t1.ms
    echo "  insert+undo of a newline mid-file: ", te.formatFloat(ffDecimal, 2), " ms"
    if Release: check te < 100

  test "re-highlight after one edit in 200k lines":
    let n = 200_000 div max(Scale div 4, 1)
    let m = newCodeModel(bigText(n))
    let h = newNimHighlighter(m)
    let t0 = getMonoTime()
    h.lexAll()
    echo "  full lex of ", n, " lines: ", $int(t0.ms), " ms"
    let mid = n div 2
    # typing in a visible window: edit, then repaint 60 lines around it
    var worst = 0.0
    for k in 0 ..< 20:
      let t1 = getMonoTime()
      discard m.insert((mid + k, 4), "q")
      for l in mid - 30 ..< mid + 30: discard h.tokens(l)
      worst = max(worst, t1.ms)
    echo "  edit + re-highlight visible window: worst ", worst.formatFloat(ffDecimal, 3), " ms"
    if Release: check worst < 5
    # the viewport is far below the edit: only the walk over cached lines
    discard m.insert((10, 4), "z")
    let t2 = getMonoTime()
    discard h.tokens(n - 1)
    echo "  edit at the top, ask for the last line: ", t2.ms.formatFloat(ffDecimal, 3), " ms"
    if Release: check t2.ms < 5
    # a newline insert shifts the caches without re-lexing
    let before = h.relexed
    discard m.insert((mid, 0), "\n")
    discard h.tokens(n - 1)
    check h.relexed - before <= 3
    # opening a triple-quoted string re-lexes everything below it, once
    discard m.insert((100, 0), "\"\"\"")
    let t3 = getMonoTime()
    discard h.tokens(n - 1)
    echo "  worst case, state change at line 100: ", $int(t3.ms), " ms"

  test "folding 200k lines":
    let n = 200_000 div max(Scale div 4, 1)
    let m = newCodeModel(bigText(n))
    let f = newFoldMap(m)
    let t0 = getMonoTime()
    let c = f.regions.len
    echo "  indent regions (", c, ") first build: ", t0.ms.formatFloat(ffDecimal, 1), " ms"
    var worst = 0.0
    for k in 0 ..< 10:
      let t1 = getMonoTime()
      discard m.insert((n div 2 + k, 2), "z")
      discard f.regions
      worst = max(worst, t1.ms)
    echo "  edit + regions: worst ", worst.formatFloat(ffDecimal, 2), " ms"
    if Release: check worst < 25

  test "find across 2M lines":
    let n = 2_000_000 div Scale
    let m = newCodeModel(bigText(n))
    var f: Match
    for (label, pat, opts) in [
        ("plain, absent", "zzzqqq", SearchOptions()),
        ("ignore case, absent", "ZZZQQQ", SearchOptions(ignoreCase: true)),
        ("whole word, absent", "zzzqqq", SearchOptions(wholeWord: true)),
        ("regex literal-first, absent", "zzz\\w+", SearchOptions(regex: true))]:
      let s = newSearcher(pat, opts)
      let t0 = getMonoTime()
      check not s.findNext(m, (0, 0), f, wrap = false)
      let t = t0.ms
      echo "  ", label, ": ", $int(t), " ms"
      if Release and not opts.regex: check t < 1500
    let s = newSearcher("needle_not_here_really")
    let t1 = getMonoTime()
    let c = s.countAll(m)
    echo "  count ", c, " plain matches: ", $int(t1.ms), " ms"
    check c == n div Block.len
    let r = newSearcher("[a-z]+_not_here", SearchOptions(regex: true))
    let t2 = getMonoTime()
    let rc = r.countAll(m)
    echo "  count ", rc, " regex matches: ", $int(t2.ms), " ms"
    check rc == c
    # replace all in one undo step
    let small = newCodeModel(bigText(n div 10))
    let t3 = getMonoTime()
    let k = newSearcher("needle_not_here_really").replaceAll(small, "N")
    echo "  replace ", k, " matches (", small.lineCount, " lines) as one step: ", $int(t3.ms), " ms"
    check k > 0
    let t4 = getMonoTime()
    discard small.undo()
    echo "  undo of that step: ", $int(t4.ms), " ms"
    check not small.canUndo
