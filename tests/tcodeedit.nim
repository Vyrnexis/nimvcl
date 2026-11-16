## CodeEdit tests, headless (offscreen SDL): events go through
## Application.dispatch like the loop does.

import std/[unittest, strutils, monotimes, times, os, importutils]
import nimvcl
import nimvcl/controls/codeedit
privateAccess(CodeEdit)

const Sample = """proc foo(a: int): int =
  let x = a + 1
  if x > 2:
    result = x
  else:
    result = 0

type
  Point = object
    x, y: int

echo foo(3)
"""

var
  clip = ""
  changes = 0
  moves: seq[CodePos]
  modEvents = 0

editClipboardGet = proc(): string = clip
editClipboardSet = proc(s: string) = clip = s

proc newShown(): Form =
  result = newForm(nil, 640, 480)
  result.show()

proc mk(f: Form, text = "", lang = "", w = 600'f32, h = 400'f32): CodeEdit =
  result = newCodeEdit(f, "", 10, 10, w, h)
  result.setBounds(10, 10, w, h)
  if lang.len > 0: result.language = lang
  if text.len > 0: result.text = text
  result.setFocus()

proc key(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id,
                                     key: k, shift: shift))
proc ctrl(f: Form, c: char, extra: ShiftState = {}) = f.key(c.key, {ssCtrl} + extra)
proc typeText(f: Form, s: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id, text: s))
proc compose(f: Form, s: string, start = -1, length = 0) =
  Application.dispatch(PlatformEvent(kind: ekTextEditing, windowId: f.win.id,
                                     text: s, editStart: start, editLength: length))
proc mouse(f: Form, kind: EventKind, x, y: float32, clicks = 1,
           shift: ShiftState = {}, button = mbLeft) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))
proc settle(f: Form) = discard f.paintIfDirty()

proc pt(f: Form, e: CodeEdit, line, col: int): (float32, float32) =
  ## Form coordinates of the middle of the character at (line, col).
  let p = e.pointOfPos((line, col))
  (e.left + p.x + 2, e.top + p.y + e.rowHeight / 2)

proc clickAt(f: Form, x, y: float32, clicks = 1, shift: ShiftState = {}) =
  f.mouse(ekMouseDown, x, y, clicks, shift)
  f.mouse(ekMouseUp, x, y, 1, shift)

proc clickPos(f: Form, e: CodeEdit, line, col: int, shift: ShiftState = {}) =
  let (x, y) = f.pt(e, line, col)
  f.clickAt(x, y, 1, shift)

proc doubleClick(f: Form, x, y: float32) =
  f.mouse(ekMouseDown, x, y, 2, {ssDouble})
  f.mouse(ekMouseUp, x, y)

proc gutterX(e: CodeEdit, area: int): float32 =
  ## Form x inside the marker (0), number (1) or fold (2) column.
  let vp = e.viewport
  case area
  of 0: e.left + vp.x + e.markerWidth / 2
  of 1: e.left + vp.x + e.markerWidth + e.numbersWidth / 2
  else: e.left + vp.x + e.markerWidth + e.numbersWidth + e.foldWidth / 2

proc rowY(f: Form, e: CodeEdit, line: int): float32 =
  e.top + e.pointOfPos((line, 0)).y + e.rowHeight / 2

proc lines(e: CodeEdit): seq[string] =
  for i in 0 ..< e.lineCount: result.add e.lineAt(i)

suite "codeedit":
  setup:
    Application.init()
    Application.forceScale = 0
    clip = ""
    changes = 0
    modEvents = 0
    moves.setLen 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "typing, events and the modified flag":
    let f = newShown()
    let e = f.mk()
    e.onChange = proc(s: Control) = inc changes
    e.onCaretMove = proc(s: Control, l, c: int) = moves.add (l, c)
    e.onModifiedChanged = proc(s: Control) = inc modEvents
    f.typeText("hello")
    check e.text == "hello" and e.caretPos == (0, 5) and changes == 1
    check e.modified and modEvents == 1
    check moves[^1] == (0, 5)
    f.typeText("é世")
    check e.text == "helloé世" and e.caretPos == (0, 5 + 2 + 3)
    f.ctrl('z')
    check e.text == "hello"
    e.markSaved()
    check not e.modified and modEvents >= 2
    check e.lineCount == 1 and e.encoding == "UTF-8"

  test "read-only blocks editing but not navigation":
    let f = newShown()
    let e = f.mk("abc\ndef")
    e.readOnly = true
    f.typeText("x")
    f.key(keyBackspace)
    f.key(keyEnter)
    f.key(keyTab)
    check e.text == "abc\ndef"
    f.key(keyEnd, {ssCtrl})
    check e.caretPos == (1, 3)

  test "IME composition is inline and does not touch the text":
    let f = newShown()
    let e = f.mk("ab")
    e.caretPos = (0, 2)
    settle(f)
    let x0 = e.caretRect.x
    f.compose("にほ", 1, 0)
    check e.isComposing and e.compositionText == "にほ" and e.text == "ab"
    settle(f)
    check e.caretRect.x > x0
    f.compose("")
    check not e.isComposing and e.caretRect.x == x0
    f.compose("x")
    f.typeText("日本")
    check not e.isComposing and e.text == "ab日本"
    f.compose("k")
    e.setFocus()
    f.typeText("z")
    check e.text == "ab日本z"

  test "arrow keys, word moves, Home smart, End, Ctrl+Home/End":
    let f = newShown()
    let e = f.mk("  one two\nthree\n    four five")
    f.key(keyHome, {ssCtrl})
    check e.caretPos == (0, 0)
    f.key(keyHome)                                  # first non-blank
    check e.caretPos == (0, 2)
    f.key(keyHome)                                  # back to column 0
    check e.caretPos == (0, 0)
    f.key(keyEnd)
    check e.caretPos == (0, 9)
    f.key(keyLeft, {ssCtrl})
    check e.caretPos == (0, 6)
    f.key(keyRight, {ssCtrl})
    check e.caretPos == (0, 9)
    f.key(keyRight)
    check e.caretPos == (1, 0)
    f.key(keyLeft)
    check e.caretPos == (0, 9)
    f.key(keyDown)
    f.key(keyDown)
    check e.caretPos.line == 2
    f.key(keyUp)
    check e.caretPos.line == 1
    f.key(keyEnd, {ssCtrl})
    check e.caretPos == (2, 13)
    f.key(keyHome)
    check e.caretPos == (2, 4)

  test "Up and Down keep the visual column across short lines and tabs":
    let f = newShown()
    let e = f.mk("abcdefgh\nab\n\tabcdefgh")
    e.caretPos = (0, 6)
    f.key(keyDown)
    check e.caretPos == (1, 2)
    f.key(keyDown)
    check e.caretPos == (2, 3)                      # tab = 4 cells, column 6 -> 2 chars after it
    f.key(keyUp)
    f.key(keyUp)
    check e.caretPos == (0, 6)

  test "PageUp/PageDown move the caret and the view":
    let f = newShown()
    var s = ""
    for i in 0 ..< 300: s.add "line " & $i & "\n"
    let e = f.mk(s)
    settle(f)
    f.key(keyPageDown)
    check e.caretPos.line > 10
    let r = e.caretRect
    check r.y >= e.viewport.y - 0.5 and r.bottom <= e.viewport.bottom + 0.5
    let l1 = e.caretPos.line
    f.key(keyPageDown)
    check e.caretPos.line > l1 and e.scrollPos.y > 0
    f.key(keyPageUp)
    check e.caretPos.line == l1
    f.key(keyEnd, {ssCtrl})
    check e.caretPos.line == 300
    check e.topLine > 250

  test "Shift extends, Ctrl+A, selection collapse":
    let f = newShown()
    let e = f.mk("one two\nthree")
    f.key(keyRight, {ssShift})
    f.key(keyRight, {ssShift})
    check e.selectedText == "on"
    f.key(keyRight, {ssCtrl, ssShift})
    check e.selectedText == "one "
    f.key(keyDown, {ssShift})
    check e.selectedText == "one two\nthre"
    f.key(keyLeft)                                  # collapses to the start
    check e.caretPos == (0, 0) and not e.hasSelection
    f.ctrl('a')
    check e.selectedText == e.text
    f.key(keyRight)
    check e.caretPos == (1, 5)
    f.key(keyHome, {ssShift, ssCtrl})
    check e.selectedText == e.text

  test "undo, redo, Ctrl+Shift+Z":
    let f = newShown()
    let e = f.mk()
    f.typeText("abc")
    f.key(keyEnter)
    f.typeText("def")
    check e.text == "abc\ndef"
    f.ctrl('z')
    check e.text == "abc\n"
    f.ctrl('z')
    f.ctrl('z')
    check e.text == "" and not e.canUndo
    f.ctrl('y')
    check e.text == "abc"
    f.ctrl('z', {ssShift})
    check e.text == "abc\n"
    f.ctrl('z', {ssShift})
    check e.text == "abc\ndef"

  test "clipboard: copy, cut, paste, line copy and cut without selection":
    let f = newShown()
    let e = f.mk("one\ntwo\nthree")
    e.select((0, 0), (0, 3))
    f.ctrl('c')
    check clip == "one"
    f.ctrl('x')
    check e.text == "\ntwo\nthree"
    f.key(keyDown)
    f.ctrl('v')
    check e.text == "\nonetwo\nthree"
    e.caretPos = (2, 2)
    f.ctrl('c')                                     # whole line
    check clip == "three\n"
    f.ctrl('x')                                     # cut line
    check e.text == "\nonetwo"
    f.ctrl('v')                                     # pastes the line above the caret
    check e.lines == @["", "three", "onetwo"] and e.caretPos == (2, 2)
    f.key(keyInsert, {ssCtrl})
    f.key(keyInsert, {ssShift})
    check e.canUndo

  test "Ctrl+D duplicates, Ctrl+Shift+K deletes lines":
    let f = newShown()
    let e = f.mk("a\nb\nc")
    e.caretPos = (1, 1)
    f.ctrl('d')
    check e.lines == @["a", "b", "b", "c"] and e.caretPos == (2, 1)
    f.ctrl('z')
    check e.lines == @["a", "b", "c"]
    e.select((0, 0), (1, 1))
    f.ctrl('d')
    check e.lines == @["a", "b", "a", "b", "c"]
    f.ctrl('k', {ssShift})
    check e.lines == @["a", "b", "c"]
    e.caretPos = (2, 1)
    f.ctrl('k', {ssShift})                          # last line
    check e.lines == @["a", "b"] and e.caretPos.line == 1
    f.ctrl('k', {ssShift})
    f.ctrl('k', {ssShift})
    check e.lines == @[""]
    f.ctrl('z')
    check e.lines == @["a"]

  test "Alt+Up/Down move lines; one undo step":
    let f = newShown()
    let e = f.mk("one\ntwo\nthree\nfour")
    e.caretPos = (1, 2)
    f.key(keyUp, {ssAlt})
    check e.lines == @["two", "one", "three", "four"] and e.caretPos == (0, 2)
    f.key(keyUp, {ssAlt})                           # at the top: nothing
    check e.lines[0] == "two"
    e.select((1, 1), (2, 2))
    f.key(keyDown, {ssAlt})
    check e.lines == @["two", "four", "one", "three"]
    check e.selection == sel((2, 1), (3, 2))
    f.key(keyDown, {ssAlt})
    check e.lines == @["two", "four", "one", "three"]
    f.ctrl('z')
    check e.lines == @["two", "one", "three", "four"]
    check e.selection == sel((1, 1), (2, 2))
    f.ctrl('z')
    check e.lines == @["one", "two", "three", "four"]
    f.ctrl('y')
    check e.lines[0] == "two"

  test "Tab and Shift+Tab: caret, selection, TAB mode":
    let f = newShown()
    let e = f.mk("a\nb\n\nc")
    f.key(keyTab)
    check e.text.startsWith("    a")                 # spaces up to the next stop
    f.key(keyTab, {ssShift})
    check e.text.startsWith("a\n") and e.caretPos == (0, 0)
    e.caretPos = (0, 1)
    f.key(keyTab)
    check e.lineAt(0) == "a   "
    f.ctrl('z')
    e.selectAll()
    f.key(keyTab)
    check e.lines == @["    a", "    b", "", "    c"]
    check e.selection.startPos.line == 0 and e.selection.endPos.line == 3
    f.key(keyTab, {ssShift})
    check e.lines == @["a", "b", "", "c"]
    f.ctrl('z')
    check e.lines[0] == "    a"
    e.insertSpaces = false
    e.selectAll()
    f.key(keyTab, {ssShift})
    e.caretPos = (0, 0)
    e.select((0, 0), (0, 0))
    f.key(keyTab)
    check e.lineAt(0).startsWith("\t")

  test "Backspace in the indentation removes back to the tab stop":
    let f = newShown()
    let e = f.mk("          x")
    e.caretPos = (0, 10)
    f.key(keyBackspace)
    check e.caretPos == (0, 8)
    f.key(keyBackspace)
    check e.caretPos == (0, 4)
    f.typeText("a")
    f.key(keyBackspace)
    f.key(keyBackspace)
    check e.caretPos == (0, 0)
    check e.text == "x"

  test "Enter: auto-indent rules":
    let f = newShown()
    let e = f.mk("", "nim")
    f.typeText("proc f() =")
    f.key(keyEnter)
    check e.lines == @["proc f() =", "    "] and e.caretPos == (1, 4)
    f.typeText("if a == b:")
    f.key(keyEnter)
    check e.caretPos == (2, 8)
    f.typeText("x")
    f.key(keyEnter)                                 # keeps the indentation
    check e.caretPos == (3, 8)
    f.key(keyBackspace)                             # back to the previous tab stop
    check e.caretPos == (3, 4)
    f.typeText("let y = [")
    f.key(keyEnter)
    check e.caretPos == (4, 8)
    # == and += do not start a block; comments do not count
    e.text = ""
    f.typeText("a +=")
    f.key(keyEnter)
    check e.caretPos == (1, 0)
    f.typeText("x == ")
    f.key(keyEnter)
    check e.caretPos == (2, 0)
    f.typeText("y = 1 # note:")
    f.key(keyEnter)
    check e.caretPos == (3, 0)
    f.typeText("s = \"a:")
    f.key(keyEnter)
    check e.caretPos == (4, 0)
    # between a bracket pair: three lines, caret in the middle
    e.text = "  call()"
    e.caretPos = (0, 7)
    f.key(keyEnter)
    check e.lines == @["  call(", "      ", "  )"] and e.caretPos == (1, 6)
    f.ctrl('z')
    check e.text == "  call()"
    # plain text: only brackets, `:` does nothing
    e.language = "text"
    e.text = "key:"
    e.caretPos = (0, 4)
    f.key(keyEnter)
    check e.caretPos == (1, 0)
    # a selection is replaced
    e.text = "ab cd"
    e.select((0, 2), (0, 3))
    f.key(keyEnter)
    check e.lines == @["ab", "cd"]
    # TAB indentation keeps TABs
    e.insertSpaces = false
    e.language = "nim"
    e.text = "if x:"
    e.caretPos = (0, 5)
    f.key(keyEnter)
    check e.lineAt(1) == "\t"

  test "Ctrl+/ toggles the line comment":
    let f = newShown()
    let e = f.mk("  a\n    b\n\n  c", "nim")
    e.selectAll()
    f.key('/'.key, {ssCtrl})
    check e.lines == @["  # a", "  #   b", "", "  # c"]
    f.key('/'.key, {ssCtrl})
    check e.lines == @["  a", "    b", "", "  c"]
    f.ctrl('z')
    check e.lines[0] == "  # a"
    f.ctrl('z')
    e.caretPos = (1, 5)
    f.key('/'.key, {ssCtrl})
    check e.lineAt(1) == "    # b" and e.caretPos == (1, 7)
    e.language = "text"
    f.key('/'.key, {ssCtrl})                        # no comment token: nothing
    check e.lineAt(1) == "    # b"
    e.lineComment = "//"
    f.key('/'.key, {ssCtrl})
    check e.lineAt(1) == "    // # b"

  test "Insert toggles overwrite mode (block caret)":
    let f = newShown()
    let e = f.mk("abcd")
    var ow = 0
    e.onOverwriteChange = proc(s: Control) = inc ow
    f.key(keyInsert)
    check e.overwrite and ow == 1
    check e.caretRect.w >= e.charWidth - 0.01
    f.typeText("XY")
    check e.text == "XYcd" and e.caretPos == (0, 2)
    e.caretPos = (0, 4)
    f.typeText("Z")
    check e.text == "XYcdZ"
    f.key(keyInsert)
    check not e.overwrite and ow == 2
    f.typeText("!")
    check e.text == "XYcdZ!"

  test "tabs and wide characters: caret x and click positions":
    let f = newShown()
    let e = f.mk("\tab\nxé世y")
    settle(f)
    let a = e.charWidth
    let o = e.pointOfPos((0, 0)).x
    check abs(e.pointOfPos((0, 1)).x - o - 4 * a) < 0.01
    check abs(e.pointOfPos((0, 3)).x - o - 6 * a) < 0.01
    check e.pointOfPos((1, 3)).x - e.pointOfPos((1, 1)).x > 0
    for col in [0, 1, 2, 3]:
      let p = e.pointOfPos((0, col))
      check e.posAtPoint(p.x + 1, p.y + 3) == (0, col)
    for col in [0, 1, 3, 6, 7]:                     # codepoint boundaries of "xé世y"
      let p = e.pointOfPos((1, col))
      check e.posAtPoint(p.x + 1, p.y + 3) == (1, col)
    e.tabWidth = 8
    check abs(e.pointOfPos((0, 1)).x - o - 8 * a) < 0.01

  test "mouse: click, shift+click, drag, double and triple click":
    let f = newShown()
    let e = f.mk("hello world\nsecond line\nthird")
    settle(f)
    f.clickPos(e, 0, 5)
    check e.caretPos == (0, 5)
    f.clickPos(e, 1, 3, {ssShift})
    check e.selectedText == " world\nsec"
    let (x3, y3) = f.pt(e, 0, 2)
    let (x4, y4) = f.pt(e, 2, 3)
    f.mouse(ekMouseDown, x3 - 2, y3)
    f.mouse(ekMouseMove, x4 - 2, y4, shift = {ssLeft})
    f.mouse(ekMouseUp, x4 - 2, y4)
    check e.selectedText == "llo world\nsecond line\nthi"
    let (x5, y5) = f.pt(e, 1, 9)
    f.doubleClick(x5, y5)
    check e.selectedText == "line"
    f.mouse(ekMouseDown, x5, y5)                    # third click: the line
    f.mouse(ekMouseUp, x5, y5)
    check e.selectedText == "second line\n"
    # double click, then drag extends by words
    let (x6, y6) = f.pt(e, 0, 1)
    sleep 650
    f.mouse(ekMouseDown, x6, y6, 2, {ssDouble})
    let (x7, y7) = f.pt(e, 1, 2)
    f.mouse(ekMouseMove, x7, y7, shift = {ssLeft})
    f.mouse(ekMouseUp, x7, y7)
    check e.selectedText == "hello world\nsecond"
    # below the text: the end of the last line
    f.clickAt(e.left + e.gutterWidth + 60, e.top + e.height - 6)
    check e.caretPos == (2, 5)
    # a middle click does nothing
    f.mouse(ekMouseDown, x5, y5, button = mbMiddle)
    f.mouse(ekMouseUp, x5, y5, button = mbMiddle)
    check e.caretPos == (2, 5)

  test "mouse: right click moves the caret unless inside the selection":
    let f = newShown()
    let e = f.mk("hello world\nsecond line")
    e.select((0, 0), (0, 5))
    let (x1, y1) = f.pt(e, 0, 2)
    f.mouse(ekMouseDown, x1, y1, button = mbRight)
    f.mouse(ekMouseUp, x1, y1, button = mbRight)
    check e.selectedText == "hello"
    let (x2, y2) = f.pt(e, 1, 3)
    f.mouse(ekMouseDown, x2, y2, button = mbRight)
    f.mouse(ekMouseUp, x2, y2, button = mbRight)
    check e.caretPos == (1, 3) and not e.hasSelection

  test "gutter: click selects the line, drag selects lines, onGutterClick":
    let f = newShown()
    let e = f.mk("aa\nbb\ncc\ndd")
    settle(f)
    f.clickAt(e.gutterX(1), f.rowY(e, 1))
    check e.selection == sel((1, 0), (2, 0))
    f.clickAt(e.gutterX(1), f.rowY(e, 3), 1, {ssShift})
    check e.selection.startPos == (1, 0) and e.selection.endPos == (3, 2)
    f.mouse(ekMouseDown, e.gutterX(1), f.rowY(e, 0))
    f.mouse(ekMouseMove, e.gutterX(1), f.rowY(e, 2), shift = {ssLeft})
    f.mouse(ekMouseUp, e.gutterX(1), f.rowY(e, 2))
    check e.selection.startPos == (0, 0) and e.selection.endPos == (3, 0)
    var got = (-1, gaNumbers)
    e.onGutterClick = proc(s: Control, line: int, area: GutterArea, b: MouseButton,
                           handled: var bool) =
      got = (line, area)
      handled = true
    e.caretPos = (0, 0)
    f.clickAt(e.gutterX(1), f.rowY(e, 2))
    check got == (2, gaNumbers) and e.caretPos == (0, 0)
    e.addMarker(1, mkBreakpoint)
    settle(f)
    f.clickAt(e.gutterX(0), f.rowY(e, 1))
    check got == (1, gaMarkers)

  test "wheel scrolls without moving the caret; line numbers follow the line count":
    let f = newShown()
    var s = ""
    for i in 0 ..< 500: s.add "line " & $i & "\n"
    let e = f.mk(s)
    settle(f)
    let w1 = e.gutterWidth
    e.text = s & s & s & s & s & s & s & s & s & s & s & s & s & s & s & s & s & s & s & s
    settle(f)
    check e.gutterWidth > w1                        # 5 digits
    let c0 = e.caretPos
    Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: f.win.id,
                                       x: e.left + 100, y: e.top + 40, dy: -1))
    check e.caretPos == c0 and e.scrollPos.y > 0

  test "folding: gutter click, hidden rows, caret skips hidden lines":
    let f = newShown()
    let e = f.mk(Sample, "nim")
    settle(f)
    check e.canFold(0) and e.canFold(2) and e.canFold(7)
    f.clickAt(e.gutterX(2), f.rowY(e, 2))           # fold `if x > 2:` (hides line 3)
    check e.isFolded(2) and e.isLineVisible(2) and not e.isLineVisible(3)
    check e.isLineVisible(4)
    e.caretPos = (2, 3)
    f.key(keyDown)                                  # lands after the region
    check e.caretPos.line == 4
    f.key(keyUp)
    check e.caretPos.line == 2
    f.key(keyEnd)
    f.key(keyRight)                                 # skips the hidden lines
    check e.caretPos == (4, 0)
    f.key(keyLeft)
    check e.caretPos == (2, e.lineAt(2).len) and e.isFolded(2)
    # Home/Ctrl+End etc. never put the caret inside
    f.key(keyEnd, {ssCtrl})
    f.key(keyHome, {ssCtrl})
    check e.isFolded(2)
    # the pill expands
    let pr = e.pointOfPos((2, e.lineAt(2).len))
    f.clickAt(e.left + pr.x + e.charWidth * 2.4, e.top + pr.y + e.rowHeight / 2)
    check not e.isFolded(2)
    # clicking the chevron again folds, a second time unfolds
    f.clickAt(e.gutterX(2), f.rowY(e, 2))
    check e.isFolded(2)
    f.clickAt(e.gutterX(2), f.rowY(e, 2))
    check not e.isFolded(2)

  test "folding: keys, fold all, caret moves to the header, search hit expands":
    let f = newShown()
    let e = f.mk(Sample, "nim")
    settle(f)
    e.caretPos = (3, 4)
    f.key('['.key, {ssCtrl, ssShift})
    check e.isFolded(2) and e.caretPos.line == 2
    f.key(']'.key, {ssCtrl, ssShift})
    check not e.isFolded(2)
    f.ctrl('k')
    f.ctrl('0')
    check e.isFolded(0) and e.isFolded(7)
    check e.isLineVisible(0) and not e.isLineVisible(1)
    check e.caretPos.line == 0
    f.ctrl('k')
    f.ctrl('j')
    check not e.isFolded(0) and not e.isFolded(2)
    # a search hit inside a fold expands it
    e.foldAll()
    check not e.isLineVisible(3)
    check e.find("result = x")
    check e.caretPos.line == 3 and e.isLineVisible(3) and not e.isFolded(2)
    # goto line expands too
    e.foldAll()
    e.gotoLine(5)
    check e.isLineVisible(5) and e.caretPos == (5, 0)
    # editing a header keeps the fold bookkeeping sane
    e.foldAll()
    e.caretPos = (0, 0)
    f.typeText("x")
    check e.lineAt(0).startsWith("xproc")
    e.unfoldAll()
    check not e.isFolded(0)

  test "folding: Delete at the end of a folded header unfolds first":
    let f = newShown()
    let e = f.mk(Sample, "nim")
    e.toggleFold(2)
    e.caretPos = (2, e.lineAt(2).len)
    check e.isFolded(2)
    f.key(keyDelete)
    check not e.isFolded(2)
    check e.lineAt(2) == "  if x > 2:    result = x"

  test "folding: bracket kind for plain text and foldKinds":
    let f = newShown()
    let e = f.mk("{\n  a\n}\nx", "text")
    check e.canFold(0) and not e.canFold(1)
    e.foldKinds = {fkIndent}
    check e.canFold(0)
    e.folding = false
    check not e.canFold(0) and e.foldMap == nil
    e.foldAll()                                     # no-op
    check e.isLineVisible(1)

  test "markers follow their lines":
    let f = newShown()
    let e = f.mk("a\nb\nc\nd\ne")
    e.addMarker(1, mkBookmark)
    e.addMarker(3, mkBreakpoint)
    e.addMarker(3, mkError)
    e.addMarker(3, mkError)
    check e.markers.len == 3 and e.hasMarker(3, mkError)
    check e.markerLines(mkBreakpoint) == @[3]
    e.caretPos = (0, 1)
    f.key(keyEnter)                                 # a line above: markers shift
    check e.markerLines(mkBookmark) == @[2] and e.markerLines(mkError) == @[4]
    e.select((3, 0), (4, 0))                        # join lines 3 and 4: one line fewer
    f.key(keyDelete)
    check e.markerLines(mkBreakpoint) == @[3] and e.markerLines(mkError) == @[3]
    e.caretPos = (2, 0)
    f.ctrl('k', {ssShift})                          # deleting the line drops its markers
    check e.markerLines(mkBookmark) == @[] and e.markerLines(mkBreakpoint) == @[2]
    check e.toggleMarker(0, mkInfo) and not e.toggleMarker(0, mkInfo)
    e.removeMarker(2, mkError)
    check e.nextMarker(mkBreakpoint, 0) == 2 and e.nextMarker(mkBreakpoint, 2) == 2
    check e.nextMarker(mkBookmark, 0) == -1
    e.clearMarkers(mkBreakpoint)
    check e.markers.len == 0
    e.addMarker(0, mkWarning)
    e.clearMarkers()
    check e.markers.len == 0
    # the marker column appears with the first marker and settles
    settle(f)
    let w0 = e.gutterWidth
    e.addMarker(0)
    check e.gutterWidth > w0
    e.text = "new text"
    check e.markers.len == 0

  test "find bar: Ctrl+F, typing, Enter, Shift+Enter, options, Esc":
    let f = newShown()
    let e = f.mk(Sample, "nim")
    settle(f)
    f.ctrl('f')
    check e.findBarVisible and e.findBar.findEdit.focused
    f.typeText("result")
    check e.selectedText == "result" and e.caretPos.line == 3
    check e.findBar.status == "1 of 2"
    f.key(keyEnter)
    check e.caretPos.line == 5
    f.key(keyEnter, {ssShift})
    check e.caretPos.line == 3
    f.key(keyF3)                                    # F3 from the bar
    check e.caretPos.line == 5
    f.typeText("x")
    check e.findBar.status == "No results" and e.findBar.statusBad
    f.key(keyBackspace)
    check e.findBar.status == "2 of 2"
    # options
    e.findBar.findEdit.text = "Result"
    check e.findBar.status.endsWith("of 2")
    f.key('c'.key, {ssAlt})                         # match case
    check e.findBar.status == "No results" and e.searchOptions.ignoreCase == false
    f.key('c'.key, {ssAlt})
    f.key('w'.key, {ssAlt})                         # whole word
    check e.searchOptions.wholeWord
    f.key('w'.key, {ssAlt})
    f.key('r'.key, {ssAlt})
    check e.searchOptions.regex
    e.findBar.findEdit.text = "re[s]ult"
    check e.findBar.status.endsWith("of 2")
    e.findBar.findEdit.text = "re(s"
    check e.findBar.status == "Invalid pattern"
    f.key('r'.key, {ssAlt})
    f.key(keyEscape)
    check not e.findBarVisible and e.focused
    # F3 / Shift+F3 in the editor
    e.setSearch("result")
    e.caretPos = (0, 0)
    f.key(keyF3)
    check e.caretPos.line == 3
    f.key(keyF3)
    check e.caretPos.line == 5
    f.key(keyF3, {ssShift})
    check e.caretPos.line == 3
    # a selection seeds the field
    e.select((1, 6), (1, 7))
    f.ctrl('f')
    check e.findBar.findText == "x"
    f.key(keyEscape)

  test "find bar: highlights matches, replace and replace all":
    let f = newShown()
    let e = f.mk("foo bar foo\nfoo baz\nbar", "text")
    f.ctrl('h')
    check e.findBar.replaceMode
    f.typeText("foo")
    check e.selection == sel((0, 0), (0, 3))
    e.findBar.replaceEdit.text = "qux"
    settle(f)
    check e.findBar.status == "1 of 3"
    e.findBar.onReplace(e.findBar)
    check e.lineAt(0) == "qux bar foo" and e.selectedText == "foo"
    e.findBar.onReplaceAll(e.findBar)
    check e.lines == @["qux bar qux", "qux baz", "bar"]
    check e.findBar.status == "2 replaced"
    e.undo()
    check e.lines == @["qux bar foo", "foo baz", "bar"]
    # programmatic API
    check e.replaceAll("ba", "BA", SearchOptions()) == 3
    check e.lines == @["qux BAr foo", "foo BAz", "BAr"]
    check not e.find("zzz")
    e.caretPos = e.model.docEnd
    check e.find("BA", SearchOptions(), forward = false) and e.caretPos.line == 2
    check e.replaceAll("(o+)", "<$1>", SearchOptions(regex: true)) == 2
    check e.lineAt(1) == "f<oo> BAz"
    e.readOnly = true
    check e.replaceAll("BA", "x") == 0

  test "find: no matches never changes the selection; wraps around":
    let f = newShown()
    let e = f.mk("a1\nb\na2")
    e.caretPos = (2, 2)
    check e.find("a")
    check e.caretPos == (0, 1)                      # wrapped to the top
    check e.find("a")
    check e.caretPos == (2, 1)
    let s0 = e.selection
    check not e.find("nothere")
    check e.selection == s0

  test "Ctrl+G uses gotoLineDialog; gotoLine clamps and centres":
    let f = newShown()
    var s = ""
    for i in 0 ..< 400: s.add "line " & $i & "\n"
    let e = f.mk(s)
    settle(f)
    var asked = 0
    e.gotoLineDialog = proc(c: CodeEdit) =
      inc asked
      c.gotoLine(250, 3)
    f.ctrl('g')
    check asked == 1 and e.caretPos == (250, 3)
    let r = e.caretRect
    check r.y >= e.viewport.y and r.bottom <= e.viewport.bottom + 1
    check abs(r.y - (e.viewport.y + e.viewport.h / 2)) < 2 * e.rowHeight   # centred
    e.gotoLine(100000)
    check e.caretPos.line == 400
    e.gotoLine(-5)
    check e.caretPos == (0, 0) and e.topLine == 0

  test "files: load, save, line endings, highlighter by extension":
    let f = newShown()
    let e = f.mk()
    let dir = getTempDir() / "nimvcl_codeedit_test"
    createDir dir
    let p = dir / "a.nim"
    writeFile(p, "let a = 1\r\nlet b = 2\r\n")
    let rep = e.loadFromFile(p)
    check rep.lineEnding == leCRLF and e.lineEnding == leCRLF and rep.lines == 3
    check e.fileName == p and e.language == "nim" and not e.modified
    check e.lineAt(0) == "let a = 1"
    e.caretPos = (1, 9)
    f.typeText("0")
    check e.modified
    e.saveToFile()
    check not e.modified
    check readFile(p) == "let a = 1\r\nlet b = 20\r\n"
    e.lineEnding = leLF
    check e.modified
    e.saveToFile(dir / "b.txt")
    check readFile(dir / "b.txt") == "let a = 1\nlet b = 20\n"
    check e.fileName == dir / "b.txt"
    e.fileName = dir / "c.nim"
    check e.language == "nim"
    e.fileName = dir / "c.txt"
    check e.language == "text"
    check e.loadFromFile(p).lines == 3 and e.language == "nim"
    removeDir dir
    expect IOError: e.saveToFile("")

  test "theme switch repaints with the matching palette":
    let f = newShown()
    let e = f.mk("proc a() = discard # c", "nim")
    settle(f)
    check e.fStyles[tkKeyword].color == syntaxStylesFor(themeLight())[tkKeyword].color
    f.theme = themeDark()
    check f.ui.needsPaint
    settle(f)
    check e.fStyles[tkKeyword].color == syntaxStylesFor(themeDark())[tkKeyword].color
    check e.fStyles[tkText].color == themeDark().text
    f.theme = nil
    settle(f)
    check e.fStyles[tkKeyword].color == syntaxStylesFor(themeLight())[tkKeyword].color

  test "caret blink repaints only the caret area":
    let f = newShown()
    let e = f.mk(Sample, "nim")
    e.setFocus()
    settle(f)
    check e.focused and e.blink != nil
    f.invalidate()
    settle(f)
    let on0 = e.caretOn
    e.blink.onTimer(e.blink)
    check e.caretOn != on0
    check f.ui.dirtyRects.len == 1 and not f.ui.dirty
    let r = f.ui.dirtyRects[0]
    check r.w <= 8 and r.h <= e.rowHeight + 4
    settle(f)
    check not f.ui.lastPaintFull and f.ui.lastPaintRects.len == 1
    # the partial repaint equals a full one
    let path = getTempDir() / "nimvcl_codeedit_blink.bmp"
    check f.screenshot(path, false)
    let partial = readFile(path)
    check f.screenshot(path, true)
    check partial == readFile(path)
    removeFile path

  test "scrolling to the end of a long file keeps the caret row visible":
    let f = newShown()
    var s = ""
    for i in 0 ..< 3000: s.add "let v" & $i & " = " & $i & "\n"
    let e = f.mk(s, "nim")
    settle(f)
    f.key(keyEnd, {ssCtrl})
    settle(f)
    check e.caretPos.line == 3000
    let r = e.caretRect
    check r.y >= e.viewport.y and r.bottom <= e.viewport.bottom + 1
    check e.scrollPos.y > 3000 * e.rowHeight - e.viewport.h - 20
    f.key(keyHome, {ssCtrl})
    settle(f)
    check e.scrollPos.y == 0

  test "long lines scroll horizontally and the caret stays in view":
    let f = newShown()
    let e = f.mk("x".repeat(400))
    settle(f)
    check e.hScrollBar.visible
    f.key(keyEnd)
    settle(f)
    check e.scrollPos.x > 0
    let r = e.caretRect
    check r.x >= e.viewport.x + e.gutterWidth - 1 and r.x <= e.viewport.right
    f.key(keyHome)
    check e.scrollPos.x == 0

  test "highlighting: exact near the top, approximate after a far jump":
    let f = newShown()
    var s = ""
    for i in 0 ..< 60_000: s.add "let v" & $i & " = \"s\" # c\n"
    let e = f.mk(s, "nim")
    settle(f)
    check not e.approximateHighlight
    e.gotoLine(50_000)
    settle(f)
    check e.approximateHighlight
    e.gotoLine(10)
    settle(f)
    check not e.approximateHighlight

  test "large file: scroll to the end and paint time":
    let f = newShown()
    let n = when defined(release): 2_000_000 else: 200_000
    var parts = newSeq[string](n)
    for i in 0 ..< n: parts[i] = "  let value" & $i & " = foo(" & $i & ", \"text\") # comment"
    let big = parts.join("\n")
    let e = f.mk()
    var t0 = getMonoTime()
    e.text = big
    settle(f)
    let openMs = (getMonoTime() - t0).inMicroseconds.float / 1000
    e.language = "nim"
    settle(f)
    check e.lineCount == n
    check (e.foldMap == nil) == (n > FoldMaxLines)
    f.key(keyEnd, {ssCtrl})
    t0 = getMonoTime()
    settle(f)
    let endMs = (getMonoTime() - t0).inMicroseconds.float / 1000
    check e.caretPos.line == n - 1
    check e.scrollPos.y > float(n - 100) * e.rowHeight - e.viewport.h
    # paint cost while scrolling in the middle
    e.gotoLine(n div 2)
    settle(f)
    var worst = 0.0
    for i in 0 ..< 30:
      Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: f.win.id,
                                         x: e.left + 100, y: e.top + 40, dy: -1))
      t0 = getMonoTime()
      settle(f)
      worst = max(worst, (getMonoTime() - t0).inMicroseconds.float / 1000)
    # typing in the middle
    e.gotoLine(n div 2, 5)
    var tw = 0.0
    for i in 0 ..< 10:
      t0 = getMonoTime()
      f.typeText("x")
      settle(f)
      tw = max(tw, (getMonoTime() - t0).inMicroseconds.float / 1000)
    check e.lineAt(n div 2).contains("xxxxxxxxxx")
    echo "  ", n, " lines: set text+paint ", openMs.formatFloat(ffDecimal, 0), " ms; paint after jump to the end ",
         endMs.formatFloat(ffDecimal, 1), " ms; wheel paint worst ", worst.formatFloat(ffDecimal, 2),
         " ms; keystroke+paint worst ", tw.formatFloat(ffDecimal, 1), " ms"
    when defined(release):
      check worst < 40 and endMs < 200
    else:
      check worst < 400 and endMs < 2000
