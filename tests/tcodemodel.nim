## CodeModel: pure logic, no SDL.

import std/[unittest, strutils, random, os, unicode]
import nimvcl/controls/codemodel

proc mk(s: string): CodeModel = newCodeModel(s)

suite "codemodel load":
  test "lines, endings and trailing newline":
    let m = mk("a\nb\nc")
    check m.lineCount == 3 and m.text == "a\nb\nc"
    check not m.trailingNewline and m.lineEnding == leLF
    let t = mk("a\r\nb\r\n")
    check t.lineCount == 3 and t.line(0) == "a" and t.line(2) == ""
    check t.lineEnding == leCRLF and t.trailingNewline and not t.mixedEndings
    check t.toText == "a\r\nb\r\n"
    check t.text == "a\nb\n"
    check mk("").lineCount == 1

  test "mixed endings are reported and normalised to the dominant one":
    let m = newCodeModel()
    let r = m.loadText("a\r\nb\r\nc\nd")
    check r.mixedEndings and r.lineEnding == leCRLF and r.lines == 4
    check m.toText == "a\r\nb\r\nc\r\nd"

  test "a lone CR is a line break":
    let m = newCodeModel()
    let r = m.loadText("a\rb\nc\r\nd\r")
    check m.lineCount == 5 and m.line(0) == "a" and m.line(1) == "b" and m.line(3) == "d"
    check r.loneCr == 2 and m.trailingNewline and r.bytes == 9
    check mk("a\rb").lineCount == 2 and mk("a\r\nb").lineCount == 2
    let mac = mk("x\ry\rz")
    check mac.lineCount == 3 and mac.lineEnding == leLF and not mac.mixedEndings

  test "invalid UTF-8 becomes U+FFFD and is counted":
    let m = newCodeModel()
    let r = m.loadText("ok\n\xFF\xFEab\n\xC3(\nfine é")
    check r.invalidBytes == 3
    check m.line(1) == "\u{FFFD}\u{FFFD}ab"
    check m.line(2) == "\u{FFFD}("
    check m.line(3) == "fine é"
    check r.bytes == 18
    # truncated sequence at the end and an overlong one
    let r2 = m.loadText("a\xE2\x82")
    check r2.invalidBytes == 2 and m.line(0) == "a\u{FFFD}\u{FFFD}"
    check m.loadText("\xC0\x80").invalidBytes == 2

  test "tabs and control characters are stored as-is":
    let m = mk("\tx\x01y")
    check m.line(0) == "\tx\x01y"

  test "file round trip keeps bytes, BOM is stripped":
    let dir = getTempDir() / "tcodemodel_rt"
    createDir dir
    let p = dir / "a.txt"
    for content in ["x\r\ny\r\n", "one\ntwo", "", "\n\n"]:
      writeFile(p, content)
      let m = newCodeModel()
      discard m.loadFile(p)
      m.saveFile(p)
      check readFile(p) == content
    writeFile(p, "\xEF\xBB\xBFhi")
    let m = newCodeModel()
    discard m.loadFile(p)
    check m.text == "hi"
    check m.hasBom
    m.saveFile(p, ensureTrailingNewline = true)
    check readFile(p) == "\xEF\xBB\xBFhi\n"       # the BOM is kept
    m.hasBom = false
    m.saveFile(p)
    check readFile(p) == "hi"
    check not m.loadText("hi").bom and not m.hasBom
    check m.loadText("\xEF\xBB\xBFa\r\nb").bom and m.toText == "a\r\nb"
    removeDir dir

suite "codemodel positions":
  test "snapping and offsets":
    let m = mk("héllo\nwörld\n!")
    check m.snapPos((0, 2)) == (0, 1)
    check m.snapPos((9, 0)) == m.docEnd
    check m.snapPos((-1, 5)) == (0, 0)
    check m.offsetOf((1, 0)) == "héllo".len + 1
    check m.posAtOffset(m.offsetOf((1, 3))) == (1, 3)
    check m.posAtOffset(10_000) == (2, 1)
    check m.textBetween((0, 1), (1, 3)) == "éllo\nwö"

  test "visual columns with tabs":
    check visualCol("\tab", 1, 4) == 4
    check visualCol("a\tb", 2, 4) == 4
    check visualCol("abc\td", 4, 4) == 4
    check visualCol("héllo", 3, 4) == 2
    check colAtVisual("\tab", 4, 4) == 1
    check colAtVisual("\tab", 2, 4) == 0
    check colAtVisual("\tab", 2, 4, roundNearest = true) == 1
    check colAtVisual("ab", 99, 4) == 2
    check colAtVisual("héllo", 2, 4) == 3
    check indentWidth("\t  x", 4) == 6 and indentWidth("   ", 4) == -1
    check indentWidth("", 4) == -1
    let m = mk("\tx")
    m.tabWidth = 8
    check visualCol(m.line(0), 1, m.tabWidth) == 8

  test "word boundaries use code identifiers":
    check wordLeftIn("foo_bar baz", 7) == 0
    check wordLeftIn("foo_bar baz", 11) == 8
    check wordRightIn("foo_bar  baz", 0) == 9
    check wordRightIn("a+=b", 0) == 1
    check wordRangeIn("foo_bar(x)", 2) == (0, 7)
    check wordRangeIn("foo_bar(x)", 7) == (7, 8)
    check identRangeIn("foo_bar(x)", 7) == (0, 7)       # caret just after the identifier
    check identRangeIn("a + b", 2) == (2, 2)
    check identRangeIn("héllo wörld", 3) == (0, 6)
    let m = mk("ab\n  cd")
    check m.wordLeftPos((1, 2)) == (1, 0)
    check m.wordLeftPos((1, 0)) == (0, 2)
    check m.wordRightPos((0, 2)) == (1, 0)

suite "codemodel editing":
  test "insert, delete, replace across lines":
    let m = mk("hello world")
    check m.insert((0, 5), ",\nnew")
    check m.text == "hello,\nnew world"
    check m.caret == (1, 3)
    check m.delete((0, 5), (1, 3))
    check m.text == "hello world"
    check m.replace((0, 0), (0, 5), "HI\r\nthere")
    check m.text == "HI\nthere world"
    check not m.insert((0, 0), "")         # nothing changes
    check m.lineCount == 2

  test "positions are snapped, ranges reordered":
    let m = mk("é")
    check m.replace((0, 1), (0, 0), "x")
    check m.text == "xé"                       # (0,1) snaps to 0
    let n = mk("héllo")
    check n.delete((0, 5), (0, 2))
    check n.text == "ho"                       # (0,2) snaps to 1
    check validateUtf8(n.text) < 0

  test "invalid and CR input is repaired":
    let m = mk("")
    check m.typeText("a\r\nb\rc\xFF")
    check m.text == "a\nb\nc\u{FFFD}"

  test "read-only blocks edits and undo":
    let m = mk("abc")
    check m.insert((0, 0), "x")
    m.readOnly = true
    check not m.insert((0, 0), "y") and not m.undo()
    check m.text == "xabc"
    m.readOnly = false
    check m.undo() and m.text == "abc"

  test "change notifications carry the affected line range":
    let m = mk("a\nb\nc")
    var ev: seq[(int, int, int)]
    let id = m.addChangeListener(proc(f, o, n: int) = ev.add (f, o, n))
    discard m.insert((1, 1), "x")
    check ev == @[(1, 1, 1)]
    ev.setLen 0
    discard m.insert((1, 0), "p\nq\n")
    check ev == @[(1, 1, 3)]
    ev.setLen 0
    discard m.delete((0, 0), (3, 0))
    check ev == @[(0, 4, 1)]
    ev.setLen 0
    discard m.undo()
    check ev == @[(0, 1, 4)]
    m.removeChangeListener(id)
    ev.setLen 0
    discard m.insert((0, 0), "z")
    check ev.len == 0

  test "version and modified":
    let m = mk("a")
    let v = m.version
    check not m.modified
    discard m.insert((0, 1), "b")
    check m.version > v and m.modified
    m.markSaved()
    check not m.modified
    discard m.insert((0, 2), "c")
    check m.modified
    discard m.undo()
    check not m.modified
    discard m.undo()
    check m.modified

suite "codemodel undo":
  test "typing coalesces within a word, spaces and punctuation split":
    let m = mk("")
    for ch in "foo bar":
      discard m.typeText($ch)
    check m.text == "foo bar"
    discard m.undo()
    check m.text == "foo "
    discard m.undo()
    check m.text == "foo"
    discard m.undo()
    check m.text == "" and not m.canUndo
    discard m.redo()
    check m.text == "foo"
    discard m.redo(); discard m.redo()
    check m.text == "foo bar" and not m.canRedo

  test "paste, newline and replace are one step each":
    let m = mk("abc")
    discard m.typeText("x")
    m.setSelection(sel((0, 0), (0, 2)))
    discard m.typeText("PASTE\nED")
    check m.text == "PASTE\nEDbc"
    discard m.undo()
    check m.text == "xabc"
    check m.selection == sel((0, 0), (0, 2))
    discard m.undo()
    check m.text == "abc"

  test "selection moves break coalescing; undo restores selection":
    let m = mk("")
    discard m.typeText("a")
    discard m.typeText("b")
    m.setCaret((0, 0))
    m.setCaret((0, 2))
    discard m.typeText("c")
    check m.text == "abc"
    discard m.undo()
    check m.text == "ab" and m.caret == (0, 2)
    discard m.undo()
    check m.text == "" and m.caret == (0, 0)

  test "backspace and delete runs coalesce":
    let m = mk("abcdef")
    m.setCaret((0, 6))
    for _ in 1 .. 3: discard m.deleteBackward()
    check m.text == "abc"
    discard m.undo()
    check m.text == "abcdef" and m.caret == (0, 6)
    m.setCaret((0, 0))
    for _ in 1 .. 2: discard m.deleteForward()
    check m.text == "cdef"
    discard m.undo()
    check m.text == "abcdef"
    m.setCaret((1 - 1, 3))
    check m.deleteBackward(word = true)
    check m.text == "def"

  test "backspace joins lines and keeps UTF-8 whole":
    let m = mk("é\nb")
    m.setCaret((1, 0))
    check m.deleteBackward()
    check m.text == "éb" and m.caret == (0, 2)
    check m.deleteBackward()
    check m.text == "b"
    m.setCaret(m.docEnd)
    check not m.deleteForward()

  test "groups merge edits into one step":
    let m = mk("a\nb\nc")
    m.beginGroup()
    discard m.replaceInGroup((0, 0), (0, 1), "AA")
    discard m.replaceInGroup((1, 0), (1, 1), "BB")
    m.beginGroup()                      # nested
    discard m.replaceInGroup((2, 0), (2, 1), "CC")
    m.endGroup()
    m.endGroup()
    check m.text == "AA\nBB\nCC"
    discard m.undo()
    check m.text == "a\nb\nc" and not m.canUndo
    discard m.redo()
    check m.text == "AA\nBB\nCC"

  test "a new edit clears redo; history is bounded":
    let m = mk("")
    m.maxUndoSteps = 3
    for i in 1 .. 5: discard m.insert(m.docEnd, $i & "\n")
    var n = 0
    while m.undo(): inc n
    check n == 3
    discard m.redo()
    discard m.insert((0, 0), "z")
    check not m.canRedo

  test "history is bounded by bytes too; trimming keeps undo and the saved state right":
    let m = mk("")
    m.maxUndoBytes = 1000
    for i in 1 .. 5: discard m.insert(m.docEnd, repeat('x', 400) & "\n")
    var n = 0
    while m.undo(): inc n
    check n == 2                                    # 800 bytes fit, a third step would be 1200
    check m.text.len == 3 * 401
    # many small steps: the oldest are dropped without disturbing the newest
    let k = mk("")
    k.maxUndoSteps = 300
    for i in 1 .. 5000:
      discard k.insert(k.docEnd, "a\n")
      if i == 4000: k.markSaved()
    check k.modified
    var c = 0
    while k.undo(): inc c
    check c == 300 and k.modified                   # the saved state was trimmed away
    check k.lineCount == 4701
    let j = mk("")
    j.maxUndoSteps = 3
    for i in 1 .. 600: discard j.insert(j.docEnd, "b\n")
    j.markSaved()
    check not j.modified and j.undo() and j.modified and j.redo() and not j.modified

  test "multiple selections are kept as a type":
    let m = mk("abc\ndef")
    m.setSelections([sel((0, 0), (0, 1)), sel((1, 0), (1, 2))])
    check m.selections.len == 2 and m.selection == sel((0, 0), (0, 1))
    check m.selectedText == "a"
    m.beginGroup()
    discard m.replaceInGroup((1, 0), (1, 2), "X")
    discard m.replaceInGroup((0, 0), (0, 1), "Y")
    m.endGroup()
    check m.text == "Ybc\nXf"
    check m.selections.len == 2
    discard m.undo()
    check m.text == "abc\ndef" and m.selections.len == 2

suite "codemodel: save point, notifications, groups":
  test "a save point inside a discarded redo branch is unreachable":
    let m = mk("")
    discard m.insert((0, 0), "a")
    m.markSaved()
    discard m.undo()
    discard m.insert((0, 0), "x")
    discard m.replace((0, 1), (0, 1), "yy")
    check m.text == "xyy" and m.modified
    discard m.undo()
    check m.text == "x" and m.modified          # differs from the saved "a"
    discard m.undo()
    check m.modified
    discard m.redo()
    discard m.redo()
    check m.modified

  test "a save point still reachable through undo and redo":
    let m = mk("")
    discard m.insert((0, 0), "a")
    m.markSaved()
    discard m.insert((0, 1), " b")
    discard m.undo()
    check not m.modified
    discard m.redo()
    check m.modified
    discard m.undo()
    check not m.modified

  test "listeners see the final selection, and a group notifies once per undo":
    let m = mk("abc\ndef\nghi")
    var seen: seq[CodePos]
    var calls = 0
    discard m.addChangeListener(proc(f, o, n: int) =
      inc calls
      seen.add m.caret
      check m.caret.line < m.lineCount and m.caret.col <= m.lineLen(m.caret.line))
    m.setCaret((2, 3))
    discard m.delete((0, 0), (2, 3))             # caret goes to (0, 0)
    check seen == @[(0, 0)]
    discard m.undo()
    check seen[^1] == (2, 3)
    m.beginGroup()
    discard m.replaceInGroup((0, 0), (0, 1), "X")
    discard m.replaceInGroup((2, 0), (2, 1), "Y\nZ")
    m.endGroup()
    calls = 0
    seen.setLen 0
    var ev: seq[(int, int, int)]
    discard m.addChangeListener(proc(f, o, n: int) = ev.add (f, o, n))
    discard m.undo()
    check calls == 1 and m.text == "abc\ndef\nghi"
    check ev == @[(0, 4, 3)]                      # covers both edits
    discard m.redo()
    check calls == 2 and m.text == "Xbc\ndef\nY\nZhi"
    check ev[^1] == (0, 3, 4)

  test "withGroup closes the group when the body raises":
    let m = mk("a")
    try:
      m.withGroup:
        discard m.insert((0, 1), "b")
        raise newException(ValueError, "boom")
    except ValueError: discard
    check not m.inGroup
    discard m.insert((0, 2), "c")
    discard m.undo()
    check m.text == "ab"

  test "overwrite typing is one undo step":
    let m = mk("xyz")
    for i in 0 ..< 3: discard m.replace((0, i), (0, i + 1), "abc"[i .. i], ekTyping)
    check m.text == "abc"
    discard m.undo()
    check m.text == "xyz" and not m.canUndo

  test "insertionEnd matches what edit does with CR and bad bytes":
    let m = mk("")
    check insertionEnd((0, 0), "a\r\nb") == (1, 1)
    check insertionEnd((0, 0), "\xFF") == (0, 3)
    discard m.edit((0, 0), (0, 0), "\xFF", ekOther, sel(insertionEnd((0, 0), "\xFF")))
    check m.caret == (0, 3)

suite "codemodel fuzz":
  test "random edits match a flat string; undo/redo are exact":
    for seed in 1 .. 200:
      var rng = initRand(seed)
      let alphabet = ["a", "b", " ", "\n", "é", "\t", "xy", "\n\n", "世"]
      var model = ""
      for _ in 0 ..< rng.rand(0 .. 20): model.add alphabet[rng.rand(alphabet.high)]
      let m = mk(model)
      let start = m.text
      var steps = 0
      for _ in 0 ..< 60:
        var ins = ""
        for _ in 0 ..< rng.rand(0 .. 4): ins.add alphabet[rng.rand(alphabet.high)]
        let a = (rng.rand(m.lineCount - 1), rng.rand(0 .. 8))
        let b = (rng.rand(m.lineCount - 1), rng.rand(0 .. 8))
        var pa = m.snapPos(a)
        var pb = m.snapPos(b)
        if pb < pa: swap pa, pb
        let oa = m.offsetOf(pa)
        let ob = m.offsetOf(pb)
        let expected = m.text[0 ..< oa] & ins & m.text[ob .. ^1]
        let before = m.text
        let kind = if ins.len > 0 and oa == ob and rng.rand(1) == 0: ekTyping else: ekOther
        let ok = m.replace(a, b, ins, kind)
        check m.text == expected
        check ok == (expected != before)
        check validateUtf8(m.text) < 0
        # model invariants
        check m.lineCount >= 1
        for i in 0 ..< m.lineCount: check '\n' notin m.line(i)
        if ok: inc steps
        if rng.rand(9) == 0: m.breakGroup()
      let final = m.text
      while m.undo(): discard
      check m.text == start
      while m.redo(): discard
      check m.text == final
