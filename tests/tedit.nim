## Edit tests, headless (offscreen SDL): events go through Application.dispatch
## like the loop does.

import std/[unittest, unicode, monotimes, times, importutils, strutils]
import nimvcl/core/[types, control, form, application, input, timer]
import nimvcl/platform/[events, window]
import nimvcl/graphics/context
import nimvcl/controls/[edit, editmodel]
import nimvcl/dsl/[props, props_std, nfm]
privateAccess(Edit)

var
  clip = ""
  changes = 0

editClipboardGet = proc(): string = clip
editClipboardSet = proc(s: string) = clip = s

proc newShown(): Form =
  result = newForm(nil, 400, 240)
  result.show()

proc mkEdit(f: Form, text = "", x = 10'f32, y = 10'f32, w = 200'f32): Edit =
  result = newEdit(f, text, x, y, w)
  result.setBounds(x, y, w, 28)

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

proc widthOf(f: Form, e: Edit, s: string): float32 =
  f.ctx.measureDevice(s, e.font).w / f.ctx.scale

proc xAfter(f: Form, e: Edit, prefix: string): float32 =
  ## Client-space x (form coords) of the caret slot after `prefix`.
  e.left + 7 + f.widthOf(e, prefix)

proc clickAt(f: Form, x: float32, clicks = 1, shift: ShiftState = {}) =
  f.mouse(ekMouseDown, x, 24, clicks, shift)
  f.mouse(ekMouseUp, x, 24, 1, shift)

proc settle(f: Form) = discard f.paintIfDirty()

suite "edit":
  setup:
    Application.init()
    Application.forceScale = 0
    clip = ""
    changes = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "typing through text input events":
    let f = newShown()
    let e = f.mkEdit()
    e.onChange = proc(s: Control) = inc changes
    e.setFocus()
    f.typeText("hello")
    check e.text == "hello" and e.caretPos == 5
    check changes == 1
    f.typeText(" wörld")
    check e.text == "hello wörld"
    check changes == 2
    f.typeText("\n")                     # newlines never get in
    check e.text == "hello wörld" and changes == 2

  test "keyboard navigation and selection":
    let f = newShown()
    let e = f.mkEdit("hello world")
    e.setFocus()
    f.key(keyHome)
    check e.caretPos == 0
    f.key(keyRight, {ssShift})
    f.key(keyRight, {ssShift})
    check e.selText == "he"
    f.key(keyRight, {ssCtrl})            # word right collapses and moves
    check e.caretPos == 6 and e.selLength == 0
    f.key(keyEnd, {ssShift})
    check e.selText == "world"
    f.key(keyLeft, {ssCtrl, ssShift})
    check e.selLength == 0 and e.caretPos == 6
    f.key(keyLeft)
    f.key(keyHome)
    f.key(keyEnd)
    check e.caretPos == e.text.len

  test "ctrl+A then typing replaces; Backspace and Delete":
    let f = newShown()
    let e = f.mkEdit("hello")
    e.setFocus()
    f.ctrl('a')
    check e.selText == "hello"
    f.typeText("x")
    check e.text == "x"
    f.key(keyBackspace)
    check e.text == ""
    e.text = "foo bar"
    f.key(keyBackspace, {ssCtrl})
    check e.text == "foo "
    f.key(keyHome)
    f.key(keyDelete)
    check e.text == "oo "
    f.key(keyDelete, {ssCtrl})
    check e.text == ""

  test "undo and redo keys":
    let f = newShown()
    let e = f.mkEdit()
    e.setFocus()
    f.typeText("a"); f.typeText("b")
    f.key(keyLeft); f.key(keyRight)
    f.typeText("c")
    f.ctrl('z')
    check e.text == "ab"
    f.ctrl('z')
    check e.text == ""
    f.ctrl('y')
    check e.text == "ab"
    f.ctrl('z', {ssShift})               # Ctrl+Shift+Z is redo
    check e.text == "abc"

  test "onChange fires once per edit":
    let f = newShown()
    let e = f.mkEdit("hello")
    e.setFocus()
    e.onChange = proc(s: Control) = inc changes
    f.ctrl('a'); f.typeText("x")
    check changes == 1
    f.ctrl('z')
    check changes == 2 and e.text == "hello"
    f.key(keyHome)
    check changes == 2                   # moving is not a change
    f.key(keyDelete)
    check changes == 3
    clip = "pasted"
    f.ctrl('v')
    check changes == 4 and e.text == "pastedello"
    e.text = "other"
    check changes == 5
    e.text = "other"
    check changes == 5

  test "clipboard round trip":
    let f = newShown()
    let e = f.mkEdit("hello world")
    e.setFocus()
    f.key(keyHome)
    for _ in 0 ..< 5: f.key(keyRight, {ssShift})
    f.ctrl('c')
    check clip == "hello"
    check e.text == "hello world"
    f.ctrl('x')
    check clip == "hello" and e.text == " world"
    f.key(keyEnd)
    f.ctrl('v')
    check e.text == " worldhello"
    clip = "a\r\nb\nc"                   # line breaks become spaces
    f.ctrl('v')
    check e.text == " worldhelloa b c"
    f.key(keyInsert, {ssShift})          # Shift+Insert pastes too
    check e.text == " worldhelloa b ca b c"

  test "real application clipboard (skipped when the driver has none)":
    Application.clipboard = "probe"
    if Application.clipboard == "probe":
      let g = editClipboardGet
      let s = editClipboardSet
      editClipboardGet = proc(): string = Application.clipboard
      editClipboardSet = proc(v: string) = Application.clipboard = v
      let f = newShown()
      let e = f.mkEdit("round trip")
      e.setFocus()
      f.ctrl('a'); f.ctrl('c')
      check Application.clipboard == "round trip"
      f.key(keyEnd); f.ctrl('v')
      check e.text == "round tripround trip"
      editClipboardGet = g
      editClipboardSet = s
    else:
      skip()

  test "click places the caret, multibyte safe":
    let f = newShown()
    let s = "aé漢z"
    let e = f.mkEdit(s)
    f.settle()
    f.clickAt(f.xAfter(e, "a") + 1)
    check e.caretPos == 1
    f.clickAt(f.xAfter(e, "aé漢") - 1)
    check e.caretPos == 6                # after 漢, not inside it
    f.clickAt(f.xAfter(e, "aé") + 2)
    check e.caretPos == 3
    f.clickAt(190)                       # far right: end of text
    check e.caretPos == e.text.len
    f.clickAt(e.left + 2)                # left of the first rune
    check e.caretPos == 0
    check e.focused
    # every caret slot of an emoji text is a boundary
    e.text = "\u{1F600}x\u{1F600}"
    for i in 0 .. 3:
      f.clickAt(e.left + 7 + 6.0'f32 * float32(i))
      check e.caretPos in [0, 4, 5, 9]

  test "drag selects, shift+click extends":
    let f = newShown()
    let e = f.mkEdit("hello world")
    f.settle()
    f.mouse(ekMouseDown, f.xAfter(e, "hel") , 24)
    f.mouse(ekMouseMove, f.xAfter(e, "hello wo"), 24, shift = {ssLeft})
    f.mouse(ekMouseUp, f.xAfter(e, "hello wo"), 24)
    check e.selStart == 3 and e.selText == "lo wo"
    f.mouse(ekMouseDown, f.xAfter(e, "he") + 1, 24, shift = {ssShift})
    f.mouse(ekMouseUp, f.xAfter(e, "he") + 1, 24)
    check e.selStart == 2 and e.caretPos == 2 and e.selText == "l"

  test "drag outside keeps extending and scrolls":
    let f = newShown()
    let e = f.mkEdit("the quick brown fox jumps over the lazy dog again and again")
    f.settle()
    f.mouse(ekMouseDown, e.left + 20, 24)
    f.mouse(ekMouseMove, e.left + e.width + 60, 24, shift = {ssLeft})
    check e.caretPos == e.text.len
    check e.scrollOffset > 0
    f.mouse(ekMouseUp, e.left + e.width + 60, 24)

  test "double click selects a word, triple click all":
    let f = newShown()
    let e = f.mkEdit("foo bar baz")
    f.settle()
    f.mouse(ekMouseDown, f.xAfter(e, "foo ") + 8, 24, 1)
    f.mouse(ekMouseUp, f.xAfter(e, "foo ") + 8, 24, 1)
    f.mouse(ekMouseDown, f.xAfter(e, "foo ") + 8, 24, 2, {ssDouble})
    check e.selText == "bar"
    f.mouse(ekMouseUp, f.xAfter(e, "foo ") + 8, 24, 2)
    f.mouse(ekMouseDown, f.xAfter(e, "foo ") + 8, 24, 3)
    f.mouse(ekMouseUp, f.xAfter(e, "foo ") + 8, 24, 3)
    check e.selText == "foo bar baz"

  test "placeholder only when empty and not composing":
    let f = newShown()
    let e = f.mkEdit()
    e.placeholder = "Name"
    check e.showsPlaceholder
    e.setFocus()
    check e.showsPlaceholder             # still shown while focused and empty
    f.compose("に")
    check not e.showsPlaceholder
    f.compose("")
    check e.showsPlaceholder
    f.typeText("x")
    check not e.showsPlaceholder
    e.text = ""
    check e.showsPlaceholder
    e.placeholder = ""
    check not e.showsPlaceholder
    f.settle()

  test "IME composition is shown, then committed":
    let f = newShown()
    let e = f.mkEdit("ab")
    e.onChange = proc(s: Control) = inc changes
    e.setFocus()
    f.key(keyLeft)                       # caret between a and b
    f.compose("にほ", 1, 1)
    check e.isComposing and e.compositionText == "にほ"
    check e.text == "ab" and changes == 0   # the model is untouched
    f.settle()
    f.compose("にほん")
    check e.text == "ab" and changes == 0
    f.typeText("日本")           # commit
    check not e.isComposing
    check e.text == "a日本b" and changes == 1
    f.compose("あ")
    check e.isComposing
    e.setFocus()                         # no-op, already focused
    f.ui.focusControl(nil)
    check not e.isComposing

  test "IME rect follows the caret":
    let f = newShown()
    let e = f.mkEdit("hello")
    e.setFocus()
    f.settle()
    let r = e.textInputRect
    check r == e.caretRect
    check r.x > e.left * 0 + 7 and r.h > 8
    f.key(keyHome)
    check e.textInputRect.x < r.x

  test "readOnly blocks edits but allows selection and copy":
    let f = newShown()
    let e = f.mkEdit("fixed text")
    e.readOnly = true
    e.setFocus()
    check not e.wantsTextInput
    f.typeText("x")
    f.key(keyBackspace); f.key(keyDelete)
    f.ctrl('x'); f.ctrl('v')
    check e.text == "fixed text"
    f.ctrl('a'); f.ctrl('c')
    check clip == "fixed text"
    f.key(keyHome); f.key(keyRight, {ssShift})
    check e.selText == "f"
    f.compose("あ")
    check not e.isComposing
    e.readOnly = false
    check e.wantsTextInput

  test "password edits never copy or cut":
    let f = newShown()
    let e = f.mkEdit("secret")
    e.password = true
    e.setFocus()
    clip = "untouched"
    f.ctrl('a'); f.ctrl('c')
    check clip == "untouched"
    f.ctrl('x')
    check clip == "untouched" and e.text == "secret"
    f.key(keyInsert, {ssCtrl})
    check clip == "untouched"
    check e.passwordChar == Rune(0x2022)
    f.settle()                           # paints the masked text
    e.password = false
    check not e.isPassword

  test "password click maps back to model indexes":
    let f = newShown()
    let e = f.mkEdit("aé漢z")
    e.password = true
    f.settle()
    let bw = f.ctx.measureDevice("••", e.font).w / f.ctx.scale
    f.clickAt(e.left + 7 + bw + 1)
    check e.caretPos == 3                # after two characters

  test "passwordChar: any character masks, \"\" and Rune(0) turn it off":
    let f = newShown()
    let e = f.mkEdit("secret")
    e.passwordChar = "*"
    check e.isPassword and e.passwordChar == Rune('*') and e.passwordCharText == "*"
    check e.password
    e.setFocus()
    clip = "untouched"
    f.ctrl('a'); f.ctrl('c')
    check clip == "untouched"
    e.passwordChar = "\u2022"
    check e.passwordChar == DefaultPasswordChar
    e.passwordChar = ""
    check not e.isPassword and e.passwordCharText == ""
    e.passwordChar = '#'
    check e.passwordChar == Rune('#')
    e.passwordChar = Rune(0)
    check not e.password
    f.ctrl('a'); f.ctrl('c')
    check clip == "secret"               # copying works again

  test "password and passwordChar in the registry and in form files":
    let ci = classByName("Edit")
    let e = newEdit(nil)
    e.name = "e"
    check ci.findProp("passwordChar").kind == pkString
    setProp(Obj(e), "passwordChar", pvString("*"))
    check e.passwordChar == Rune('*')
    check getProp(Obj(e), "password").b          # still a password edit
    let f = newForm(nil, 100, 100)
    f.name = "F"
    let e2 = newEdit(f)
    e2.name = "pw"
    e2.password = true                           # the default bullet: `password` is enough
    var text = formToNfm(f)
    check "password = true" in text and "passwordChar" notin text
    e2.passwordChar = "*"
    text = formToNfm(f)
    check "passwordChar = '*'" in text and "password = true" notin text
    let g = loadNfm(text)
    check Edit(g.findComponent("pw")).passwordChar == Rune('*')
    check formToNfm(g) == text
    check Edit(loadNfm("object F: Form\n  object pw: Edit\n    password = true\n  end\nend\n")
                .findComponent("pw")).passwordChar == DefaultPasswordChar

  test "scroll offset keeps the caret visible":
    let f = newShown()
    let e = f.mkEdit("")
    e.setFocus()
    f.settle()
    check e.scrollOffset == 0
    f.typeText("The quick brown fox jumps over the lazy dog, again and again and again")
    check e.scrollOffset > 0
    var r = e.caretRect
    check r.x >= 7 and r.x <= e.width - 7
    f.key(keyHome)
    check e.scrollOffset == 0
    r = e.caretRect
    check r.x >= 7 and r.x <= e.width - 7
    f.key(keyEnd)
    check e.scrollOffset > 0
    f.key(keyLeft, {ssCtrl})
    r = e.caretRect
    check r.x >= 0 and r.x <= e.width
    # deleting text pulls the scroll back
    f.ctrl('a'); f.typeText("short")
    check e.scrollOffset == 0

  test "focus by Tab with autoSelect, a click that focuses keeps the select-all":
    let f = newShown()
    let a = f.mkEdit("first")
    let b = f.mkEdit("second one", y = 50)
    b.autoSelect = true
    a.setFocus()
    f.key(keyTab)
    check b.focused
    check b.selText == "second one"
    f.key(keyTab, {ssShift})
    check a.focused and a.selLength == 0
    f.settle()
    f.clickAt(f.xAfter(b, "sec") + 1)    # y = 24 is in the first edit...
    check a.focused
    f.mouse(ekMouseDown, f.xAfter(b, "sec") + 1, 64)
    f.mouse(ekMouseUp, f.xAfter(b, "sec") + 1, 64)
    check b.focused and b.selText == "second one"     # the press that focused keeps it
    f.mouse(ekMouseDown, f.xAfter(b, "sec") + 1, 64)  # b already focused: a caret
    f.mouse(ekMouseUp, f.xAfter(b, "sec") + 1, 64)
    check b.selLength == 0 and b.caretPos == 3

  test "Tab and Enter are not swallowed":
    let f = newShown()
    let e = f.mkEdit("x")
    discard f.mkEdit("y", y = 50)
    var sawEnter = false
    f.ui.onUnhandledKey = proc(k: var Key, s: ShiftState) =
      if k == keyEnter: sawEnter = true
    e.setFocus()
    f.key(keyEnter)
    check sawEnter
    f.key(keyTab)
    check not e.focused

  test "caret blinks only while focused and the window is active":
    let f = newShown()
    let e = f.mkEdit("x")
    check not e.caretVisible
    e.setFocus()
    check e.caretVisible
    var t0 = getMonoTime()
    while e.caretVisible and (getMonoTime() - t0).inMilliseconds < 3000:
      Application.processMessages(20)
    check not e.caretVisible             # the blink timer hid it
    f.typeText("y")
    check e.caretVisible                 # typing resets the blink
    f.windowActivated(false)
    check not e.caretVisible
    f.windowActivated(true)
    f.ui.focusControl(nil)
    check not e.caretVisible

  test "filters: numbersOnly, maxLength, charCase":
    let f = newShown()
    let e = f.mkEdit()
    e.numbersOnly = true
    e.setFocus()
    f.typeText("a1b2")
    check e.text == "12"
    e.numbersOnly = false
    e.maxLength = 4
    f.typeText("漢字é")
    check e.text == "12漢字"
    e.text = ""
    e.maxLength = 0
    e.charCase = ecUpperCase
    f.typeText("abc")
    check e.text == "ABC"
    e.charCase = ecLowerCase
    e.text = ""
    f.typeText("ABC")
    check e.text == "abc"

  test "borderStyle none, disabled and selection paint without errors":
    let f = newShown()
    let e = f.mkEdit("some text to paint")
    e.setFocus()
    e.selectAll()
    f.settle()
    e.borderStyle = ebNone
    f.settle()
    e.borderStyle = ebSingle
    e.enabled = false
    f.settle()
    check not e.focused                  # disabling drops focus
    check e.borderStyle == ebSingle

  test "autoSize height comes from the font":
    let f = newShown()
    let e = f.mkEdit("x")
    f.settle()
    let ps = e.preferredSize()
    check ps.h >= 20 and ps.h <= 40

  test "insertText and replaceRange: one undo step, filters apply, onChange fires":
    let f = newShown()
    let e = f.mkEdit("hello world")
    var n = 0
    e.onChange = proc(s: Control) = inc n
    e.select(0, 5)
    check e.insertText("HOWDY")                  # replaces the selection
    check e.text == "HOWDY world" and e.caretPos == 5 and e.selLength == 0
    check n == 1
    check e.replaceRange(6, 5, "there")          # byte range of "world"
    check e.text == "HOWDY there" and e.caretPos == 11
    check e.replaceRange(5, 0, ",")              # length 0 inserts
    check e.text == "HOWDY, there"
    check e.replaceRange(5, 1, "")               # empty text deletes
    check e.text == "HOWDY there" and e.caretPos == 5
    check e.undo()
    check e.text == "HOWDY, there"
    e.caretPos = e.text.len                      # undo restored the selection
    e.maxLength = 12
    check not e.insertText("long")               # filtered out entirely: no change
    e.readOnly = true
    check not e.insertText("x") and not e.replaceRange(0, 1, "y")
    check e.text == "HOWDY, there"
    # utf-8: a byte range inside a character snaps to character boundaries
    e.readOnly = false
    e.maxLength = 0
    e.text = "aéb"
    check e.replaceRange(2, 1, "E")              # 2 is inside 'é' (bytes 1..2)
    check e.text.len > 0 and validateUtf8(e.text) == -1
    check n >= 5


  test "Shift+Backspace deletes like Backspace":
    let f = newShown()
    let e = f.mkEdit("Hello")
    e.setFocus()
    f.key(keyBackspace, {ssShift})
    check e.text == "Hell"
    f.key(keyBackspace, {ssShift, ssCtrl})
    check e.text == ""

  test "autoSelect: the press that focuses keeps select-all; a drag still selects":
    let f = newShown()
    let a = f.mkEdit("first")
    let b = f.mkEdit("second one", y = 50)
    b.autoSelect = true
    a.setFocus()
    f.settle()
    let x0 = f.xAfter(b, "sec")
    f.mouse(ekMouseDown, x0, 64)
    f.mouse(ekMouseUp, x0, 64)
    check b.focused and b.selText == "second one"
    # now drag from another edit into b: focus press, then a real drag
    a.setFocus()
    f.mouse(ekMouseDown, x0, 64)
    f.mouse(ekMouseMove, x0 + 1, 64)                  # within the click slop
    check b.selText == "second one"
    f.mouse(ekMouseMove, f.xAfter(b, "second"), 64)
    f.mouse(ekMouseUp, f.xAfter(b, "second"), 64)
    check b.selText == "ond"

  test "replaceRange restores the selection when the filter rejects the insert":
    let f = newShown()
    let e = f.mkEdit("12345")
    e.numbersOnly = true
    e.select(3, 2)
    check not e.replaceRange(1, 2, "ab")
    check e.text == "12345" and e.selStart == 3 and e.selLength == 2
    e.caretPos = 2
    check not e.replaceRange(0, 1, "x")
    check e.caretPos == 2 and e.selLength == 0

  test "paste maps tabs and line breaks to spaces":
    let f = newShown()
    let e = f.mkEdit("")
    clip = "a\tb\r\nc\nd"
    e.pasteFromClipboard()
    check e.text == "a b c d"

  test "blink timer stops while the form is hidden":
    let f = newShown()
    let e = f.mkEdit("x")
    e.setFocus()
    check e.blink != nil and e.blink.enabled
    f.hide()
    Application.processMessages(10)
    check not e.isShowing
    e.blink.onTimer(e.blink)                          # a tick on a hidden form
    check not e.blink.enabled
    f.show()
    check e.isShowing and e.blink.enabled
