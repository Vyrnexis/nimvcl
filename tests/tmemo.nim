## Memo tests, headless (offscreen SDL): events go through Application.dispatch
## like the loop does.

import std/[unittest, strutils, monotimes, times]
import nimvcl/core/[types, control, form, application, input]
import nimvcl/platform/[events, window]
import nimvcl/graphics/[context, geometry]
import nimvcl/controls/[edit, memo, button]

var
  clip = ""
  changes = 0

editClipboardGet = proc(): string = clip
editClipboardSet = proc(s: string) = clip = s

proc newShown(): Form =
  result = newForm(nil, 400, 300)
  result.show()

proc mkMemo(f: Form, text = "", x = 10'f32, y = 10'f32, w = 240'f32, h = 120'f32): Memo =
  result = newMemo(f, text, x, y, w, h)
  result.setBounds(x, y, w, h)

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
           shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: mbLeft, clicks: clicks, shift: shift))
proc settle(f: Form) = discard f.paintIfDirty()

proc widthOf(f: Form, m: Memo, s: string): float32 =
  f.ctx.measureDevice(s, m.font).w / f.ctx.scale

proc pt(f: Form, m: Memo, line, col: int): (float32, float32) =
  ## Form coordinates of the caret slot (line, col) of a non-wrapped, unscrolled
  ## memo.
  let rh = m.rowHeight
  (m.left + 7 + f.widthOf(m, m.lineAt(line)[0 ..< col]),
   m.top + 5 + float32(line) * rh + rh / 2)

proc clickAt(f: Form, x, y: float32, clicks = 1, shift: ShiftState = {}) =
  f.mouse(ekMouseDown, x, y, clicks, shift)
  f.mouse(ekMouseUp, x, y, 1, shift)

suite "memo":
  setup:
    Application.init()
    Application.forceScale = 0
    clip = ""
    changes = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "typing and Enter make lines, onChange once per change":
    let f = newShown()
    let m = f.mkMemo()
    m.onChange = proc(s: Control) = inc changes
    m.setFocus()
    f.typeText("hello")
    check m.text == "hello" and m.caretPos == (0, 5) and changes == 1
    f.key(keyEnter)
    check m.text == "hello\n" and m.caretPos == (1, 0) and changes == 2
    f.typeText("wörld")
    check m.text == "hello\nwörld" and m.lines.count == 2
    check m.lines[1] == "wörld"
    check m.selStart == 12 and m.selLength == 0

  test "Enter does not reach the default button while wantReturns":
    let f = newShown()
    let m = f.mkMemo()
    let b = newButton(f, "OK", 10, 150)
    b.isDefault = true
    var clicks = 0
    b.onClick = proc(s: Control) = inc clicks
    m.setFocus()
    f.key(keyEnter)
    check clicks == 0 and m.lines.count == 2
    m.wantReturns = false
    f.key(keyEnter)
    check clicks == 1 and m.lines.count == 2
    f.typeText("a\nb")                  # line breaks in text input become spaces
    check m.text == "\na b"

  test "Tab: moves focus unless wantTabs":
    let f = newShown()
    let m = f.mkMemo()
    let b = newButton(f, "OK", 10, 150)
    m.setFocus()
    f.key(keyTab)
    check m.text == "" and f.activeControl == Control(b)
    m.setFocus()
    m.wantTabs = true
    f.key(keyTab)
    check m.text == "\t" and f.activeControl == Control(m)
    f.typeText("x")
    check m.text == "\tx"

  test "navigation and selection keys":
    let f = newShown()
    let m = f.mkMemo("one two\nthree\nfour five six")
    m.setFocus()
    f.key(keyHome, {ssCtrl})
    check m.caretPos == (0, 0)
    f.key(keyRight, {ssCtrl})
    check m.caretPos == (0, 4)
    f.key(keyDown)
    check m.caretPos == (1, 4)
    f.key(keyDown)
    f.key(keyUp)
    check m.caretPos.line == 1
    f.key(keyEnd)
    check m.caretPos == (1, 5)
    f.key(keyDown, {ssShift})
    check m.selText.startsWith("\nfour") or m.selText.len > 0
    f.key(keyLeft)
    check m.selLength == 0
    f.key(keyEnd, {ssCtrl})
    check m.caretPos == (2, 13)
    f.key(keyHome, {ssShift})
    check m.selText == "four five six"
    f.ctrl('a')
    check m.selText == m.text
    f.key(keyRight)
    check m.caretPos == (2, 13)

  test "up and down keep the pixel column across short lines":
    let f = newShown()
    let m = f.mkMemo("abcdefgh\nab\nabcdefgh")
    m.setFocus()
    m.caretPos = (0, 6)
    f.key(keyDown)
    check m.caretPos == (1, 2)
    f.key(keyDown)
    check m.caretPos == (2, 6)
    f.key(keyUp); f.key(keyUp)
    check m.caretPos == (0, 6)
    f.key(keyUp)
    check m.caretPos == (0, 0)
    f.key(keyDown, {ssCtrl, ssShift})
    f.key(keyDown); f.key(keyDown); f.key(keyDown)
    check m.caretPos == (2, 8)

  test "Shift+Backspace deletes like Backspace":
    let f = newShown()
    let m = f.mkMemo("abc")
    m.setFocus()
    m.caretPos = (0, 3)
    f.key(keyBackspace, {ssShift})
    check m.text == "ab"

  test "backspace joins lines, delete pulls the next line up":
    let f = newShown()
    let m = f.mkMemo("ab\ncd")
    m.setFocus()
    m.caretPos = (1, 0)
    f.key(keyBackspace)
    check m.text == "abcd" and m.caretPos == (0, 2)
    f.key(keyEnter)
    check m.text == "ab\ncd"
    f.key(keyLeft)
    f.key(keyDelete)
    check m.text == "abcd"

  test "undo and redo keys across line edits":
    let f = newShown()
    let m = f.mkMemo()
    m.setFocus()
    f.typeText("ab")
    f.key(keyEnter)
    f.typeText("cd")
    check m.text == "ab\ncd"
    f.ctrl('z')
    check m.text == "ab\n"
    f.ctrl('z')
    check m.text == "ab"
    f.ctrl('z')
    check m.text == ""
    f.ctrl('y')
    check m.text == "ab"
    f.ctrl('z', {ssShift})              # Ctrl+Shift+Z redoes
    check m.text == "ab\n"
    f.ctrl('y')
    check m.text == "ab\ncd"

  test "clipboard: copy, cut and paste multi-line text":
    let f = newShown()
    let m = f.mkMemo("one\ntwo\nthree")
    m.setFocus()
    m.select(2, 5)
    f.ctrl('c')
    check clip == "e\ntwo"
    f.ctrl('x')
    check m.text == "on\nthree"
    m.caretPos = (1, 5)
    clip = "x\r\ny\rz"
    f.ctrl('v')
    check m.text == "on\nthreex\ny\nz" and m.lines.count == 4
    f.key(keyInsert, {ssShift})
    check m.lines.count == 6
    m.readOnly = true
    f.ctrl('v')
    check m.lines.count == 6
    f.typeText("q")
    check m.lines.count == 6

  test "readOnly keeps navigation, maxLength limits":
    let f = newShown()
    let m = f.mkMemo("abc\ndef")
    m.setFocus()
    m.readOnly = true
    f.key(keyEnd, {ssCtrl})
    f.key(keyBackspace)
    f.typeText("x")
    f.key(keyEnter)
    check m.text == "abc\ndef" and m.caretPos == (1, 3)
    m.readOnly = false
    m.maxLength = 8
    f.typeText("ghi")
    check m.text == "abc\ndefg"
    m.text = "waytoolongtext"
    check m.text == "waytoolo"            # text= is cut to maxLength too
    m.maxLength = 0

  test "placeholder, selStart/selLength in byte offsets":
    let f = newShown()
    let m = f.mkMemo()
    m.placeholder = "type here"
    check m.showsPlaceholder
    m.text = "héllo\nwörld"
    check not m.showsPlaceholder
    m.select(0, "héllo\nwö".len)
    check m.selText == "héllo\nwö"
    check m.selStart == 0 and m.selLength == "héllo\nwö".len
    m.selStart = 3
    check m.caretPos == (0, 3) and m.selLength == 0
    m.selLength = 4
    check m.selText == "llo\n" or m.selText.len == 4
    settle(f)

  test "lines API":
    let f = newShown()
    let m = f.mkMemo()
    m.lines.add "a"
    check m.text == "a" and m.lines.count == 1
    m.lines.add "b"
    m.lines.insert(1, "x")
    check m.text == "a\nx\nb"
    m.lines[0] = "A"
    m.lines.delete(1)
    check m.text == "A\nb"
    var all: seq[string]
    for s in m.lines: all.add s
    check all == @["A", "b"]
    m.lines.clear()
    check m.text == "" and m.lines.count == 1

  test "mouse: click, shift+click, drag across lines, double and triple click":
    let f = newShown()
    let m = f.mkMemo("hello world\nsecond line\nthird")
    settle(f)
    let (x1, y1) = f.pt(m, 0, 5)
    f.clickAt(x1, y1)
    check m.caretPos == (0, 5)
    let (x2, y2) = f.pt(m, 1, 3)
    f.clickAt(x2, y2, shift = {ssShift})
    check m.selText == " world\nsec"
    # drag
    let (x3, y3) = f.pt(m, 0, 2)
    let (x4, y4) = f.pt(m, 2, 3)
    f.mouse(ekMouseDown, x3, y3)
    f.mouse(ekMouseMove, x4, y4, shift = {ssLeft})
    f.mouse(ekMouseUp, x4, y4)
    check m.selText == "llo world\nsecond line\nthi"
    # double click selects the word, triple the line
    let (x5, y5) = f.pt(m, 1, 9)
    f.mouse(ekMouseDown, x5, y5, 2, {ssDouble})
    f.mouse(ekMouseUp, x5, y5)
    check m.selText == "line"
    f.mouse(ekMouseDown, x5, y5)
    f.mouse(ekMouseUp, x5, y5)
    check m.selText == "second line\n"
    # click below the text goes to the end
    f.clickAt(m.left + 50, m.top + m.height - 3)
    check m.caretPos == (2, 5)

  test "word wrap: visual rows, Up/Down/Home/End by visual line":
    let f = newShown()
    let m = f.mkMemo("", w = 120, h = 140)
    m.text = "alpha beta gamma delta epsilon zeta eta theta\nshort"
    m.wordWrap = true
    settle(f)
    check m.visualRowCount > 2
    let rows = m.visualRowCount
    check m.hScrollBar.visible == false and m.contentSize.w == 0
    m.setFocus()
    f.key(keyHome, {ssCtrl})
    f.key(keyDown)
    check m.caretPos.line == 0 and m.caretPos.col > 0 and m.visualRowOfCaret == 1
    f.key(keyHome)
    let startOfRow1 = m.caretPos.col
    check startOfRow1 > 0
    f.key(keyEnd)
    check m.caretPos.line == 0 and m.visualRowOfCaret == 1 and m.caretPos.col > startOfRow1
    f.key(keyEnd, {ssCtrl})
    check m.caretPos == (1, 5) and m.visualRowOfCaret == rows - 1
    f.key(keyUp)
    check m.caretPos.line == 0
    # wrap off: one row per line and a horizontal bar for long lines
    m.wordWrap = false
    settle(f)
    check m.visualRowCount == 2
    check m.contentSize.w > m.width
    check m.hScrollBar.visible
    m.wordWrap = true
    check m.visualRowCount == rows

  test "wrapped caret and click hit the same slot":
    let f = newShown()
    let m = f.mkMemo("", w = 120, h = 140)
    m.wordWrap = true
    m.text = "alpha beta gamma delta epsilon zeta"
    settle(f)
    m.caretPos = (0, 14)               # inside "gamma"/"delta"
    let r = m.caretRect
    let p = m.posAtPoint(r.x, r.y + r.h / 2)
    check p == (0, 14)

  test "scrolling keeps the caret visible":
    let f = newShown()
    var s = ""
    for i in 0 ..< 200: s.add "line " & $i & "\n"
    let m = f.mkMemo(s)
    m.setFocus()
    settle(f)
    check m.vScrollBar.visible and m.scrollPos.y == 0
    f.key(keyEnd, {ssCtrl})
    var r = m.caretRect
    check m.scrollPos.y > 0
    check r.y >= m.viewport.y and r.bottom <= m.viewport.bottom + 0.5
    f.key(keyHome, {ssCtrl})
    check m.scrollPos.y == 0
    for _ in 0 ..< 30: f.key(keyDown)
    r = m.caretRect
    check r.y >= m.viewport.y and r.bottom <= m.viewport.bottom + 0.5
    f.key(keyPageDown)
    check m.caretPos.line > 30
    r = m.caretRect
    check r.y >= m.viewport.y and r.bottom <= m.viewport.bottom + 0.5
    f.key(keyPageUp)
    f.key(keyPageUp)
    check m.caretPos.line < 40
    # the wheel scrolls without moving the caret
    let c0 = m.caretPos
    Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: f.win.id,
                                       x: m.left + 20, y: m.top + 20, dy: -1))
    check m.caretPos == c0 and m.scrollPos.y > 0

  test "scrollBars msNone: no bars; msVertical only":
    let f = newShown()
    var s = ""
    for i in 0 ..< 100: s.add "line " & $i & " " & "x".repeat(100) & "\n"
    let m = f.mkMemo(s)
    settle(f)
    check m.vScrollBar.visible and m.hScrollBar.visible
    m.scrollBars = msVertical
    settle(f)
    check m.vScrollBar.visible and not m.hScrollBar.visible
    m.scrollBars = msNone
    settle(f)
    check not m.vScrollBar.visible and not m.hScrollBar.visible

  test "IME composition is inline and does not touch the text":
    let f = newShown()
    let m = f.mkMemo("ab\ncd")
    m.setFocus()
    m.caretPos = (1, 1)
    let before = m.caretRect.x
    f.compose("にほ", 1, 0)
    check m.isComposing and m.compositionText == "にほ" and m.text == "ab\ncd"
    check m.caretRect.x > before
    check m.textInputRect.y == m.caretRect.y
    settle(f)
    f.typeText("日本")                  # commit
    check not m.isComposing and m.text == "ab\nc日本d"
    f.compose("x")
    f.compose("")
    check not m.isComposing
    m.readOnly = true
    f.compose("y")
    check not m.isComposing

  test "focus lost drops composition; unfocused memo draws without caret":
    let f = newShown()
    let m = f.mkMemo("ab")
    let o = newButton(f, "x", 10, 150)
    m.setFocus()
    f.compose("z")
    o.setFocus()
    check not m.isComposing and not m.caretVisible
    settle(f)

  test "cut and paste fire onChange, repaint and follow the caret (review 5)":
    let f = newShown()
    let m = f.mkMemo(h = 60)
    var ch = 0
    m.onChange = proc(s: Control) = inc ch
    clip = "1\n2\n3\n4\n5\n6\n7\n8\n9"
    m.pasteFromClipboard()
    check ch == 1 and m.lineCount == 9
    settle f
    check m.scrollPos.y > 0                  # the caret line (last) is visible
    m.selectAll()
    ch = 0
    m.cutToClipboard()
    check ch == 1 and m.text == "" and clip.len > 0
    check m.scrollPos.y == 0

  test "lines.add fills only a pristine empty memo (review 20)":
    let f = newShown()
    let m = f.mkMemo()
    m.lines.add ""                           # first add into the pristine memo
    m.lines.add "b"
    check m.text == "\nb" and m.lines.count == 2
    let m2 = f.mkMemo()
    m2.text = "x"
    m2.lines[0] = ""
    m2.lines.add "y"                         # edited: appends
    check m2.text == "\ny"
    let m3 = f.mkMemo()
    m3.text = ""
    m3.lines.add "first"
    check m3.text == "first"
    m3.lines.clear()
    m3.lines.add "again"
    check m3.text == "again"

  test "text= compares the sanitised value (review 21)":
    let f = newShown()
    let m = f.mkMemo("ab")
    var ch = 0
    m.onChange = proc(s: Control) = inc ch
    m.text = "a\x01b"                        # sanitises to "ab"
    check ch == 0
    m.text = "a\r\nb"
    check ch == 1 and m.text == "a\nb"
    m.text = "a\rb"
    check ch == 1
    m.maxLength = 2
    m.text = "ab"
    check ch == 2 and m.text == "ab"
    m.text = "abcdef"                         # cut to "ab": same
    check ch == 2

  test "wantReturns = false: pasted, typed and IME breaks become spaces (review 25)":
    let f = newShown()
    let m = f.mkMemo()
    m.wantReturns = false
    m.setFocus()
    f.typeText("a\nb")
    check m.text == "a b"
    clip = "c\r\nd\ne"
    m.pasteFromClipboard()
    check m.text == "a bc d e" and m.lineCount == 1

suite "memo large":
  setup:
    Application.init()
    Application.forceScale = 0
    clip = ""
  teardown:
    for f in openForms(): f.freeWindow()

  test "100,000 lines: open, edit, scroll, paint":
    let f = newShown()
    let m = f.mkMemo(w = 300, h = 200)
    var parts = newSeq[string](100_000)
    for i in 0 ..< parts.len: parts[i] = "line number " & $i & " with some more text"
    let big = parts.join("\n")
    var t0 = getMonoTime()
    m.text = big
    settle(f)
    let openMs = (getMonoTime() - t0).inMicroseconds.float / 1000
    check m.lines.count == 100_000
    m.setFocus()
    f.key(keyEnd, {ssCtrl})
    settle(f)
    check m.caretPos.line == 99_999
    check m.scrollPos.y > 1_000_000
    # typing in the middle of the document
    m.caretPos = (50_000, 4)
    settle(f)
    var worst = 0.0
    var total = 0.0
    const N = 40
    for i in 0 ..< N:
      t0 = getMonoTime()
      f.typeText("x")
      settle(f)
      let ms = (getMonoTime() - t0).inMicroseconds.float / 1000
      total += ms
      worst = max(worst, ms)
    check m.lines[50_000].startsWith("linexxxxxxxx")
    # Enter splits the line; Backspace joins it again (structural edits)
    var tn = 0.0
    for i in 0 ..< 10:
      t0 = getMonoTime()
      f.key(keyEnter)
      settle(f)
      f.key(keyBackspace)
      settle(f)
      tn = max(tn, (getMonoTime() - t0).inMicroseconds.float / 1000)
    check m.lines.count == 100_000
    # wheel scrolling paints
    t0 = getMonoTime()
    for i in 0 ..< 20:
      Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: f.win.id,
                                         x: m.left + 20, y: m.top + 20, dy: -1))
      settle(f)
    let scrollMs = (getMonoTime() - t0).inMicroseconds.float / 1000 / 20
    echo "  100k lines: open+paint ", openMs.formatFloat(ffDecimal, 1), " ms; keystroke+paint avg ",
         (total / N).formatFloat(ffDecimal, 2), " ms, worst ", worst.formatFloat(ffDecimal, 2),
         " ms; Enter+Backspace pair worst ", tn.formatFloat(ffDecimal, 2),
         " ms; wheel+paint avg ", scrollMs.formatFloat(ffDecimal, 2), " ms"
    when defined(release):
      check worst < 50 and tn < 100
    else:
      check worst < 250 and tn < 400

  test "100,000 wrapped lines stay responsive":
    let f = newShown()
    let m = f.mkMemo(w = 200, h = 200)
    var parts = newSeq[string](100_000)
    for i in 0 ..< parts.len: parts[i] = "wrapped line " & $i & " that is long enough to wrap around"
    m.wordWrap = true
    var t0 = getMonoTime()
    m.text = parts.join("\n")
    settle(f)
    let openMs = (getMonoTime() - t0).inMicroseconds.float / 1000
    m.setFocus()
    m.caretPos = (60_000, 0)
    settle(f)
    var worst = 0.0
    for i in 0 ..< 20:
      t0 = getMonoTime()
      f.typeText("y")
      settle(f)
      worst = max(worst, (getMonoTime() - t0).inMicroseconds.float / 1000)
    check m.lines[60_000].startsWith("yyyyyyyyyyyyyyyyyyyywrapped")
    let r = m.caretRect
    check r.y >= m.viewport.y and r.bottom <= m.viewport.bottom + 0.5
    echo "  100k wrapped lines: open+paint ", openMs.formatFloat(ffDecimal, 1),
         " ms; keystroke+paint worst ", worst.formatFloat(ffDecimal, 2), " ms"
    when defined(release): check worst < 50
    else: check worst < 250
