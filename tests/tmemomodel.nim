## MemoModel: pure logic, no SDL.

import std/[unittest, strutils]
import nimvcl/controls/memomodel

proc mk(s: string): MemoModel = newMemoModel(s)

suite "memomodel text":
  test "lines, joins and normalisation":
    let m = mk("a\r\nb\rc\nd")
    check m.lineCount == 4
    check m.text == "a\nb\nc\nd"
    check mk("").lineCount == 1
    check mk("x\n").lineCount == 2 and mk("x\n").line(1) == ""
    check mk("a\x01b\tc").text == "ab\tc"

  test "offsets and positions":
    let m = mk("héllo\nwörld\n!")
    check m.offsetOf((0, 0)) == 0
    check m.offsetOf((1, 0)) == "héllo".len + 1
    check m.posAtOffset(m.offsetOf((1, 3))) == (1, 3)
    check m.posAtOffset(10_000) == (2, 1)
    # snapped inside a multi-byte rune
    check m.snapPos((0, 2)) == (0, 1)

  test "setText resets caret and history":
    let m = mk("abc")
    discard m.insert("x")
    m.setText("q\nr")
    check m.caret == (0, 0) and not m.canUndo
    check m.runeLen == 3

suite "memomodel caret":
  test "left/right cross lines and are multi-byte safe":
    let m = mk("aé\nb")
    m.setCaret((0, 3))
    m.moveRight()
    check m.caret == (1, 0)
    m.moveLeft()
    check m.caret == (0, 3)
    m.moveLeft()
    check m.caret == (0, 1)            # over the two-byte é
    m.moveDocStart()
    m.moveLeft()
    check m.caret == (0, 0)
    m.moveDocEnd()
    m.moveRight()
    check m.caret == (1, 1)

  test "up/down keep the desired column":
    let m = mk("abcdef\nab\nabcdef")
    m.setCaret((0, 5))
    m.moveDown()
    check m.caret == (1, 2)
    m.moveDown()
    check m.caret == (2, 5)
    m.moveUp()
    m.moveUp()
    check m.caret == (0, 5)
    m.moveUp()
    check m.caret == (0, 0)
    m.moveDown(); m.moveDown(); m.moveDown()
    check m.caret == m.docEnd
    # a horizontal move forgets the column
    m.setCaret((0, 5))
    m.moveDown()
    m.moveLeft()
    m.moveDown()
    check m.caret == (2, 1)

  test "desired column counts runes":
    let m = mk("ééé\nabcd")
    m.setCaret((0, 4))                 # after two é
    m.moveDown()
    check m.caret == (1, 2)

  test "home/end and word moves":
    let m = mk("foo bar\n  baz")
    m.setCaret((0, 4))
    m.moveEnd()
    check m.caret == (0, 7)
    m.moveHome()
    check m.caret == (0, 0)
    m.moveWordRight()
    check m.caret == (0, 4)
    m.moveWordRight()
    check m.caret == (0, 7)
    m.moveWordRight()
    check m.caret == (1, 0)            # over the line break
    m.moveWordRight()
    check m.caret == (1, 2) or m.caret == (1, 5)
    m.moveDocEnd()
    m.moveWordLeft()
    check m.caret == (1, 2)
    m.moveWordLeft()
    check m.caret == (1, 0)
    m.moveWordLeft()
    check m.caret == (0, 7)

  test "selection across lines":
    let m = mk("one\ntwo\nthree")
    m.setCaret((0, 1))
    m.moveDown(extend = true)
    m.moveDown(extend = true)
    check m.selectedText == "ne\ntwo\nt"
    check m.selStart == 1 and m.selLength == 8
    m.moveLeft()
    check m.caret == (0, 1) and not m.hasSelection
    m.selectAll()
    check m.selectedText == m.text
    m.selectWord((1, 1))
    check m.selectedText == "two"
    m.selectLine(0)
    check m.selectedText == "one\n"
    m.selectLine(2)
    check m.selectedText == "three"

suite "memomodel editing":
  test "typing, newline split and backspace join":
    let m = mk("")
    check m.insert("ab")
    check m.insert("\n")
    check m.insert("cd")
    check m.text == "ab\ncd" and m.caret == (1, 2)
    m.setCaret((0, 1))
    check m.insert("\n")
    check m.text == "a\nb\ncd" and m.caret == (1, 0)
    check m.deleteBackward()           # joins
    check m.text == "ab\ncd" and m.caret == (0, 1)
    m.setCaret((0, 2))
    check m.deleteForward()            # joins with the next line
    check m.text == "abcd" and m.caret == (0, 2)
    m.moveDocEnd()
    check not m.deleteForward()
    m.moveDocStart()
    check not m.deleteBackward()

  test "multi-line paste and replace selection":
    let m = mk("hello world")
    m.select((0, 6), (0, 11))
    check m.insert("a\nb\nc")
    check m.text == "hello a\nb\nc"
    check m.caret == (2, 1) and m.lineCount == 3
    m.select((0, 3), (2, 0))
    check m.deleteSelection()
    check m.text == "helc" and m.lineCount == 1
    discard m.undo()
    check m.text == "hello a\nb\nc"
    discard m.undo()
    check m.text == "hello world"
    check m.selectedText == "world"
    discard m.redo()
    check m.text == "hello a\nb\nc"
    discard m.redo()
    check m.text == "helc"

  test "multi-byte edits":
    let m = mk("aéb")
    m.setCaret((0, 3))
    check m.deleteBackward()
    check m.text == "ab"
    m.setCaret((0, 1))
    check m.insert("日本")
    check m.text == "a日本b" and m.caret == (0, 7)
    check m.deleteBackward() and m.text == "a日b"

  test "undo coalescing: typing words, backspace and delete runs":
    let m = mk("")
    for ch in "hello": discard m.insert($ch)
    discard m.insert(" ")
    for ch in "world": discard m.insert($ch)
    check m.text == "hello world"
    check m.undo() and m.text == "hello "
    check m.undo() and m.text == ""      # a trailing space joins the word
    check not m.undo()
    check m.redo() and m.text == "hello "
    m.setText("abcdef")
    m.moveDocEnd()
    for _ in 0 ..< 3: discard m.deleteBackward()
    check m.text == "abc"
    check m.undo() and m.text == "abcdef" and m.caret == (0, 6)
    check m.redo() and m.text == "abc"
    m.moveDocStart()
    for _ in 0 ..< 2: discard m.deleteForward()
    check m.text == "c"
    check m.undo() and m.text == "abc" and m.caret == (0, 0)

  test "caret move breaks coalescing; newline is its own step":
    let m = mk("")
    discard m.insert("a"); discard m.insert("b")
    m.moveLeft(); m.moveRight()
    discard m.insert("c")
    check m.undo() and m.text == "ab"
    discard m.insert("\n")
    discard m.insert("x")
    check m.undo() and m.text == "ab\n"
    check m.undo() and m.text == "ab"

  test "undo of line joins restores selection":
    let m = mk("ab\ncd")
    m.setCaret((1, 0))
    check m.deleteBackward()
    check m.text == "abcd"
    check m.undo()
    check m.text == "ab\ncd" and m.caret == (1, 0)

  test "read only and maxLength":
    let m = mk("abc")
    m.readOnly = true
    check not m.insert("x") and not m.deleteBackward() and not m.undo()
    m.setText("zz")                    # programmatic still works
    check m.text == "zz"
    m.readOnly = false
    m.maxLength = 5
    m.setText("ab\ncd")                # 5 runes with the newline
    check m.insert("x") == false
    m.moveDocEnd()
    discard m.deleteBackward()
    check m.insert("xyz")
    check m.text == "ab\ncx"
    m.setText("0123456789")
    check m.text == "01234"

  test "line API":
    let m = mk("a")
    m.insertLine(1, "b")
    m.insertLine(2, "c\nd")
    check m.text == "a\nb\nc\nd"
    m.setLine(1, "B")
    m.deleteLineAt(0)
    check m.text == "B\nc\nd"
    m.deleteLineAt(0); m.deleteLineAt(0); m.deleteLineAt(0)
    check m.text == "" and m.lineCount == 1

  test "onChanged ranges":
    let m = mk("a\nb\nc")
    var log: seq[(int, int, int)]
    m.onChanged = proc(f, o, n: int) = log.add (f, o, n)
    m.setCaret((1, 1))
    discard m.insert("x")
    discard m.insert("\ny")
    m.select((0, 0), (2, 0))
    discard m.deleteSelection()
    check log[0] == (1, 1, 1)
    check log[1] == (1, 1, 2)
    check log[2] == (0, 3, 1)

  test "rune count stays exact through edits and undo":
    let m = mk("héllo\nwörld")
    check m.runeLen == 11
    m.select((0, 2), (1, 3))
    discard m.deleteSelection()
    check m.runeLen == runeCount(m.text)
    discard m.undo()
    check m.runeLen == runeCount(m.text) and m.runeLen == 11
    discard m.insert("日\n本\n")
    check m.runeLen == runeCount(m.text)

  test "deleteLine":
    let m = mk("a\nb\nc")
    m.setCaret((1, 0))
    check m.deleteLine() and m.text == "a\nc"
    m.moveDocEnd()
    check m.deleteLine() and m.text == "a"
    check m.deleteLine() and m.text == ""
    check not m.deleteLine()

  test "large document edits stay cheap":
    var big = newSeq[string](100_000)
    for i in 0 ..< big.len: big[i] = "line number " & $i
    let m = mk(big.join("\n"))
    check m.lineCount == 100_000
    m.setCaret((50_000, 4))
    for ch in "typing": discard m.insert($ch)
    check m.line(50_000).startsWith("linetyping")
    check m.undo()
    check m.line(50_000) == "line number 50000"

  test "onChanged fires after caret and anchor are final (review 18)":
    let m = mk("abc\ndef")
    var seen: seq[(MemoPos, MemoPos)]
    m.onChanged = proc(f, o, n: int) = seen.add (m.anchor, m.caret)
    m.setCaret((1, 3))
    discard m.insert("XY")
    check seen[^1] == ((1, 5), (1, 5))
    discard m.deleteBackward()
    check seen[^1] == ((1, 4), (1, 4))
    discard m.insert("\nQ")                 # multi-line: caret on a new line
    check seen[^1] == (m.anchor, m.caret) and m.caret == (2, 1)
    seen.setLen 0
    check m.undo()
    check seen.len == 1 and seen[0] == ((1, 4), (1, 4))
    seen.setLen 0
    check m.redo()
    check seen.len == 1 and seen[0][1] == (2, 1)
    # line API: handler sees a snapped caret
    m.setCaret((1, 4))
    seen.setLen 0
    m.setLine(1, "z")
    check seen[0][1] == (1, 1)

  test "setLine / insertLine: bounds and maxLength (review 19)":
    let m = mk("ab\ncd")
    expect IndexDefect: m.setLine(2, "x")
    expect IndexDefect: m.setLine(-1, "x")
    expect IndexDefect: m.insertLine(3, "x")
    expect IndexDefect: m.insertLine(-1, "x")
    try:
      m.setLine(7, "x")
    except IndexDefect as e:
      check "7" in e.msg and "setLine" in e.msg
    check m.text == "ab\ncd"
    m.maxLength = 7                         # "ab\ncd" is 5 runes
    m.setLine(0, "abcdefgh")                # room: 7 - (5 - 2) = 4
    check m.line(0) == "abcd" and m.runeLen == 7
    m.setLine(0, "x")
    m.insertLine(2, "123456")               # 7 - 4 runes - 1 break = 2 left
    check m.text == "x\ncd\n12" and m.runeLen == 7
    m.insertLine(0, "no")                   # no room even for the break
    check m.text == "x\ncd\n12"
    m.insertLine(3, "")
    check m.text == "x\ncd\n12"
