## The login demo (phase 3 exit criterion) driven with the keyboard only.

import std/[unittest, strutils]
import nimvcl
import ../examples/login_demo

proc keyDown(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k,
                                     shift: shift))
proc keyUp(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k,
                                     shift: shift))
proc tap(f: Form, k: Key, shift: ShiftState = {}) = f.keyDown(k, shift); f.keyUp(k, shift)
proc typeText(f: Form, s: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id, text: s))

template queued(body: untyped) =
  Application.queue(proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      body)

proc focusName(l: LoginForm): string =
  let c = l.activeControl
  if c == nil: "-" else: c.name

proc newShown(): LoginForm =
  result = newLoginForm()
  result.show()

suite "login demo, keyboard only":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "focus starts in the user edit; Tab order is user, password, remember, server, OK, Cancel":
    let l = newShown()
    var order = @[l.focusName]
    for i in 1 .. 6:
      l.tap(keyTab)
      order.add l.focusName
    check order == @["user", "password", "remember", "production", "ok", "cancel", "user"]
    l.tap(keyTab, {ssShift})                     # Shift+Tab goes back
    check l.focusName == "cancel"

  test "typing, Space and arrows":
    let l = newShown()
    l.typeText "bob"
    l.tap(keyTab)
    l.typeText "pw"
    l.tap(keyTab)
    check l.user.text == "bob" and l.password.text == "pw"
    check l.remember.checked
    l.tap(keySpace)
    check not l.remember.checked
    l.tap(keySpace)
    check l.remember.checked
    l.tap(keyTab)
    check l.focusName == "production"
    l.tap(keyDown)
    check l.staging.checked and not l.production.checked and l.focusName == "staging"
    l.tap(keyTab)                                # one stop per group
    check l.focusName == "ok"
    l.tap(keyLeft, {})                           # no effect on a button
    check l.staging.checked

  test "Enter in an edit presses the default button; success opens the modal welcome":
    let l = newShown()
    l.typeText "  carol  "
    l.tap(keyTab)
    l.typeText "secret"
    queued:
      let m = modalForm()
      m.tap(keyEnter)                                 # its OK is default and focused
    l.tap(keyEnter)                              # from the password edit
    check l.welcomeShown == 1 and l.welcomeResult == mrOk
    check l.greeted == "carol"
    check "carol" in l.status.caption
    check l.visible and modalForm() == nil

  test "validation: empty user returns focus to the user edit":
    let l = newShown()
    l.tap(keyTab)                                # to password
    l.typeText "x"
    l.tap(keyEnter)
    check l.welcomeShown == 0
    check "user name" in l.status.caption
    check l.focusName == "user"

  test "validation: empty password focuses the password edit":
    let l = newShown()
    l.typeText "dave"
    l.tap(keyEnter)
    check l.welcomeShown == 0
    check "password" in l.status.caption
    check l.focusName == "password"

  test "a focused OK button is activated by Space":
    let l = newShown()
    l.tap(keyEnter)                              # error, focus stays on user
    check l.focusName == "user"
    for i in 1 .. 4: l.tap(keyTab)
    check l.focusName == "ok"
    l.status.caption = ""
    l.tap(keySpace)
    check l.status.caption.len > 0                    # OK ran (validation error)

  test "Esc presses Cancel from any control":
    let l = newShown()
    l.typeText "x"
    l.tap(keyEscape)                             # from an edit
    check not l.visible

  test "Esc from the radio group closes too":
    let l = newShown()
    for i in 1 .. 3: l.tap(keyTab)
    check l.focusName == "production"
    l.tap(keyEscape)
    check not l.visible

  test "label focusControl moves focus":
    let l = newShown()
    l.userLabel.doClick()
    check l.focusName == "user"
    l.passLabel.doClick()
    check l.focusName == "password"
