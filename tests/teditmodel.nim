## EditModel tests: pure Nim, no SDL.
import std/[unittest, unicode]
import nimvcl/controls/editmodel

proc mk(s: string, caret = -1): EditModel =
  result = newEditModel(s)
  if caret >= 0: result.setCaret(caret)

func isBoundary(s: string, i: int): bool =
  i == 0 or i == s.len or (ord(s[i]) and 0xC0) != 0x80

suite "editmodel: basics":
  test "insert and caret":
    let m = newEditModel()
    check m.insert("abc")
    check m.text == "abc" and m.caret == 3 and not m.hasSelection
    m.setCaret(1)
    check m.insert("X")
    check m.text == "aXbc" and m.caret == 2

  test "insert strips newlines and control chars":
    let m = newEditModel()
    check m.insert("a\nb\r\tc\x01d\x7f")
    check m.text == "abcd"
    check not m.insert("\n\r")
    check m.text == "abcd"

  test "invalid utf-8 is dropped":
    let m = newEditModel()
    check m.insert("a\xFFb\xC3")
    check m.text == "ab"

  test "onChange fires once per change":
    let m = newEditModel()
    var n = 0
    m.onChange = proc() = inc n
    discard m.insert("hello")
    check n == 1
    m.selectAll()
    discard m.insert("x")          # replacing a selection: one change
    check n == 2
    discard m.deleteBackward()
    check n == 3
    discard m.deleteBackward()     # nothing to delete
    check n == 3
    discard m.undo()
    check n == 4
    m.setText("same")
    check n == 5
    m.setText("same")
    check n == 5

  test "selStart / selLength":
    let m = mk("hello world")
    m.selStart = 2
    m.selLength = 3
    check m.selStart == 2 and m.selLength == 3 and m.selectedText == "llo"
    check m.anchor == 2 and m.caret == 5
    m.select(6, 100)
    check m.selectedText == "world"

  test "clear":
    let m = mk("abc")
    m.clear()
    check m.text == "" and m.caret == 0
    check m.undo()
    check m.text == "abc"

suite "editmodel: multibyte":
  const s = "aé漢\u{1F600}z"        # a é 漢 😀 z (1+2+3+4+1 bytes)

  test "caret moves never split runes":
    let m = newEditModel(s)
    m.moveHome()
    var seen = @[0]
    while m.caret < m.len:
      m.moveRight()
      check isBoundary(s, m.caret)
      seen.add m.caret
    check seen == @[0, 1, 3, 6, 10, 11]
    while m.caret > 0:
      m.moveLeft()
      check isBoundary(s, m.caret)
    check m.caret == 0

  test "setCaret / select snap to boundaries":
    let m = newEditModel(s)
    m.setCaret(2)                 # inside é
    check m.caret == 1
    m.setCaret(8)                 # inside the emoji
    check m.caret == 6
    m.select(4, 3)                # inside 漢 .. inside emoji
    check isBoundary(s, m.selStart) and isBoundary(s, m.selEnd)

  test "delete removes whole runes":
    let m = newEditModel(s)
    check m.deleteBackward() and m.text == "aé漢\u{1F600}"
    check m.deleteBackward() and m.text == "aé漢"
    check m.deleteBackward() and m.text == "aé"
    m.moveHome()
    check m.deleteForward() and m.text == "é"
    check m.deleteForward() and m.text == ""
    check not m.deleteForward()

  test "maxLength counts runes":
    let m = newEditModel()
    m.maxLength = 3
    check m.insert("漢\u{1F600}éx")
    check m.text == "漢\u{1F600}é" and m.runeLen == 3
    check not m.insert("z")
    check m.len == 9

suite "editmodel: selection":
  test "extend and collapse":
    let m = mk("hello", 2)
    m.moveRight(extend = true)
    m.moveRight(extend = true)
    check m.selStart == 2 and m.selLength == 2 and m.caret == 4
    m.moveLeft(extend = true)
    check m.selLength == 1
    m.moveLeft()                  # collapse to the start, no extra step
    check not m.hasSelection and m.caret == 2
    m.moveRight(extend = true)
    m.moveRight(extend = true)
    m.moveRight()                 # collapse to the end
    check not m.hasSelection and m.caret == 4

  test "home / end extend":
    let m = mk("hello", 2)
    m.moveHome(extend = true)
    check m.selectedText == "he" and m.caret == 0 and m.anchor == 2
    m.moveEnd(extend = true)
    check m.selectedText == "llo"
    m.moveHome()
    check m.caret == 0 and not m.hasSelection

  test "select all and replace":
    let m = mk("hello")
    m.selectAll()
    check m.selectedText == "hello"
    check m.insert("x")
    check m.text == "x" and m.caret == 1

  test "insert replaces the selection":
    let m = mk("hello world")
    m.select(0, 5)
    check m.insert("bye")
    check m.text == "bye world" and m.caret == 3

  test "delete with selection removes it":
    let m = mk("hello world")
    m.select(5, 6)
    check m.deleteForward()
    check m.text == "hello" and m.caret == 5
    m.select(0, 2)
    check m.deleteBackward()
    check m.text == "llo"

  test "reversed selection":
    let m = mk("hello", 4)
    m.moveLeft(extend = true)
    m.moveLeft(extend = true)
    check m.selStart == 2 and m.selEnd == 4 and m.anchor == 4 and m.caret == 2

suite "editmodel: words":
  test "word left/right":
    let m = mk("foo bar  baz")
    m.moveHome()
    m.moveWordRight(); check m.caret == 4
    m.moveWordRight(); check m.caret == 9
    m.moveWordRight(); check m.caret == 12
    m.moveWordRight(); check m.caret == 12
    m.moveWordLeft(); check m.caret == 9
    m.moveWordLeft(); check m.caret == 4
    m.moveWordLeft(); check m.caret == 0

  test "punctuation is its own word":
    let m = mk("foo.bar, baz")
    m.moveHome()
    m.moveWordRight(); check m.caret == 3      # "foo"
    m.moveWordRight(); check m.caret == 4      # "."
    m.moveWordRight(); check m.caret == 7      # "bar"
    m.moveWordRight(); check m.caret == 9      # ", "
    m.moveWordRight(); check m.caret == 12

  test "unicode letters and digits are word characters":
    let m = mk("café 漢字 x1_y")
    m.moveHome()
    m.moveWordRight(); check m.caret == 6      # after "café "
    m.moveWordRight(); check m.caret == 13     # after "漢字 "
    m.moveWordRight(); check m.caret == m.len

  test "word movement extends selection":
    let m = mk("foo bar baz", 0)
    m.moveWordRight(extend = true)
    check m.selectedText == "foo "
    m.moveWordRight(extend = true)
    check m.selectedText == "foo bar "
    m.moveWordLeft(extend = true)
    check m.selectedText == "foo "

  test "ctrl delete":
    let m = mk("foo bar baz")
    check m.deleteBackward(word = true)
    check m.text == "foo bar "
    check m.deleteBackward(word = true)
    check m.text == "foo "
    m.moveHome()
    check m.deleteForward(word = true)
    check m.text == ""
    check not m.deleteForward(word = true)

  test "selectWord":
    let m = mk("foo bar  baz")
    m.selectWord(5)
    check m.selectedText == "bar"
    m.selectWord(8)                 # inside the double space
    check m.selectedText == "  "
    m.selectWord(m.len)             # end: the last word
    check m.selectedText == "baz"
    m.selectWord(0)
    check m.selectedText == "foo"
    check newEditModel("").selStart == 0
    let e = newEditModel("")
    e.selectWord(0)
    check not e.hasSelection

  test "selectWord multibyte":
    let m = mk("a 漢字 b")
    m.selectWord(3)
    check m.selectedText == "漢字"

suite "editmodel: filters":
  test "numbersOnly":
    let m = newEditModel()
    m.numbersOnly = true
    check m.insert("a1b2-3.")
    check m.text == "123"
    check not m.insert("abc")
    check m.text == "123"

  test "charCase":
    let m = newEditModel()
    m.charCase = ecUpperCase
    discard m.insert("abc é")
    check m.text == "ABC É"
    let l = newEditModel()
    l.charCase = ecLowerCase
    discard l.insert("ABC")
    check l.text == "abc"

  test "maxLength with selection":
    let m = mk("abcde")
    m.maxLength = 5
    check not m.insert("x") or m.text.len == 5
    m.select(1, 2)
    check m.insert("XYZ")           # 2 removed, 2 allowed
    check m.text == "aXYde"

  test "maxLength truncates paste":
    let m = newEditModel()
    m.maxLength = 4
    check m.insert("abcdefgh")
    check m.text == "abcd"

  test "setText applies maxLength, sanitises, moves caret to end":
    let m = newEditModel()
    m.maxLength = 3
    m.setText("ab\ncdef")
    check m.text == "abc" and m.caret == 3

  test "readOnly blocks edits but not selection":
    let m = mk("hello")
    m.readOnly = true
    check not m.insert("x")
    check not m.deleteBackward()
    check not m.deleteForward()
    check not m.undo()
    m.selectAll()
    check m.selectedText == "hello"
    m.moveHome()
    check m.caret == 0
    m.setText("abc")                # programmatic works
    check m.text == "abc"

suite "editmodel: undo":
  test "typing in a word coalesces":
    let m = newEditModel()
    for ch in "hello": discard m.insert($ch)
    check m.undo()
    check m.text == ""
    check not m.canUndo
    check m.redo()
    check m.text == "hello" and m.caret == 5

  test "a new word starts a new step":
    let m = newEditModel()
    for ch in "hello world": discard m.insert($ch)
    check m.undo(); check m.text == "hello "
    check m.undo(); check m.text == ""
    check m.redo(); check m.text == "hello "
    check m.redo(); check m.text == "hello world"
    check not m.redo()

  test "caret move breaks coalescing":
    let m = newEditModel()
    discard m.insert("ab")
    m.moveLeft()
    m.moveRight()
    discard m.insert("cd")
    check m.undo(); check m.text == "ab"
    check m.undo(); check m.text == ""

  test "backspace run coalesces":
    let m = newEditModel("hello")
    for _ in 1 .. 3: discard m.deleteBackward()
    check m.text == "he"
    check m.undo()
    check m.text == "hello" and m.caret == 5

  test "delete run coalesces, differs from backspace":
    let m = mk("abcdef", 0)
    discard m.deleteForward(); discard m.deleteForward()
    discard m.deleteBackward()           # no-op at 0, must not corrupt
    check m.text == "cdef"
    m.setCaret(2)
    discard m.deleteBackward()           # new run
    check m.text == "cef"
    check m.undo(); check m.text == "cdef"
    check m.undo(); check m.text == "abcdef"

  test "paste is its own step and ends the typing run":
    let m = newEditModel()
    discard m.insert("a"); discard m.insert("b")
    discard m.insert("PASTE")
    discard m.insert("c")
    check m.undo(); check m.text == "abPASTE"
    check m.undo(); check m.text == "ab"
    check m.undo(); check m.text == ""

  test "undo restores the selection":
    let m = mk("hello")
    m.select(1, 3)
    discard m.insert("X")
    check m.text == "hXo"
    check m.undo()
    check m.text == "hello" and m.selStart == 1 and m.selLength == 3

  test "a new edit clears redo":
    let m = newEditModel()
    discard m.insert("a")
    discard m.undo()
    check m.canRedo
    discard m.insert("b")
    check not m.canRedo

  test "word delete is a step of its own":
    let m = newEditModel("foo bar baz")
    discard m.deleteBackward(word = true)
    discard m.deleteBackward(word = true)
    check m.text == "foo "
    check m.undo(); check m.text == "foo bar "
    check m.undo(); check m.text == "foo bar baz"

  test "undo of typing over selection then typing more is one step":
    let m = mk("hello")
    m.selectAll()
    discard m.insert("a"); discard m.insert("b")
    check m.text == "ab"
    check m.undo()
    check m.text == "hello"

  test "history is bounded":
    let m = newEditModel()
    for i in 0 ..< 700:
      discard m.insert("word ")        # each pair of inserts is a new step
      m.moveEnd()
    var n = 0
    while m.undo(): inc n
    check n <= 500

suite "editmodel: password":
  test "displayText":
    let bullet = Rune(0x2022)
    let m = newEditModel("aé漢\u{1F600}")
    check m.displayText(bullet) == "••••"
    check m.displayText(Rune('*')) == "****"

  test "index mapping":
    let bullet = Rune(0x2022)           # 3 bytes
    let m = newEditModel("aé漢")     # boundaries 0 1 3 6
    check m.toDisplayIndex(0, bullet) == 0
    check m.toDisplayIndex(1, bullet) == 3
    check m.toDisplayIndex(3, bullet) == 6
    check m.toDisplayIndex(6, bullet) == 9
    check m.toModelIndex(0, bullet) == 0
    check m.toModelIndex(3, bullet) == 1
    check m.toModelIndex(6, bullet) == 3
    check m.toModelIndex(9, bullet) == 6
    check m.toModelIndex(100, bullet) == 6
    check m.toModelIndex(4, bullet) == 1     # inside a mask char: rounds down
    let a = Rune('*')
    for i in [0, 1, 3, 6]:
      check m.toModelIndex(m.toDisplayIndex(i, a), a) == i
