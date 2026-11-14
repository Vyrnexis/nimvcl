# Phase 3 demo: a login form that is fully usable with the keyboard alone.
#
# Keys: Tab / Shift+Tab move focus (user, password, remember me, server,
#       OK, Cancel), Space toggles the check box, arrows switch the server,
#       Enter = OK (default button), Esc = Cancel. D toggles dark/light when
#       the focus is not in an edit.
#
# Env:
#   NIMVCL_SCREENSHOT   lay out, render one frame to this BMP and exit
#   NIMVCL_SCALE        force the display scale (headless testing of 1.5x etc.)
#   NIMVCL_DARK=1       start with the dark theme
#   NIMVCL_FILL=1       (screenshot) type a user name and a password first
#   NIMVCL_ERROR=1      (screenshot) press OK with an empty user name
#
# Build: nim c --outdir:build examples/login_demo.nim

import std/[os, strutils]
import nimvcl

type
  LoginForm* = ref object
    form*: Form
    userLabel*, passLabel*, serverLabel*, status*: Label
    userEdit*, passEdit*: Edit
    remember*: CheckBox
    production*, staging*: RadioButton
    ok*, cancel*: Button
    welcomeShown*: int            ## how many times the welcome form was shown
    welcomeResult*: ModalResult   ## what the last welcome form returned
    greeted*: string              ## user name of the last successful login

proc showError(l: LoginForm, msg: string) =
  l.status.textColor = l.form.theme.danger
  l.status.caption = msg

proc showWelcome(l: LoginForm) =
  let d = newForm(nil, 320, 160)
  d.caption = "Welcome"
  d.position = poMainFormCenter
  d.borderStyle = bsSingle
  let server = if l.production.checked: "Production" else: "Staging"
  let msg = newLabel(d, "Welcome, " & l.greeted & "!", 24, 24)
  msg.font = font(size = 18, style = {fsBold})
  let sub = newLabel(d, "Signed in to " & server & (if l.remember.checked: " (remembered)" else: ""),
                     24, 62)
  sub.textColor = d.theme.textMuted
  let ok = newButton(d, "OK", 206, 104, 90)
  ok.isDefault = true
  ok.modalResult = mrOk
  d.onShow = proc(s: Control) = d.activeControl = ok
  inc l.welcomeShown
  l.welcomeResult = d.showModal()

proc login(l: LoginForm) =
  let user = l.userEdit.text.strip()
  if user.len == 0:
    l.showError "Please enter your user name."
    setFocus(l.userEdit)
    return
  if l.passEdit.text.len == 0:
    l.showError "Please enter your password."
    setFocus(l.passEdit)
    return
  l.greeted = user
  l.status.textColor = l.form.theme.textMuted
  l.status.caption = "Signed in as " & user
  l.showWelcome()

proc buildLoginForm*(): LoginForm =
  let l = LoginForm()
  let f = newForm(nil, 420, 392)
  l.form = f
  f.caption = "Sign in"
  f.borderStyle = bsSingle

  let title = newLabel(f, "Sign in", 20, 14)
  title.font = font(size = 20, style = {fsBold})

  let g = newGroupBox(f, "Account", 20, 54, 380, 238)
  g.name = "group"

  l.userEdit = newEdit(g, "", 16, 56, 348, 28)
  l.userEdit.name = "user"
  l.userEdit.placeholder = "name@example.com"
  l.userLabel = newLabel(g, "User name", 16, 34)
  l.userLabel.focusControl = l.userEdit

  l.passEdit = newEdit(g, "", 16, 112, 348, 28)
  l.passEdit.name = "password"
  l.passEdit.placeholder = "Password"
  l.passEdit.passwordChar = '*'
  l.passLabel = newLabel(g, "Password", 16, 90)
  l.passLabel.focusControl = l.passEdit

  l.remember = newCheckBox(g, "Remember me", true, 16, 154)
  l.remember.name = "remember"

  l.serverLabel = newLabel(g, "Server", 16, 186)
  l.production = newRadioButton(g, "Production", true, 16, 208)
  l.production.name = "production"
  l.staging = newRadioButton(g, "Staging", false, 140, 208)
  l.staging.name = "staging"

  l.ok = newButton(f, "OK", 212, 306, 90)
  l.ok.name = "ok"
  l.ok.isDefault = true
  l.cancel = newButton(f, "Cancel", 310, 306, 90)
  l.cancel.name = "cancel"
  l.cancel.isCancel = true

  l.status = newLabel(f, "Enter your credentials.", 20, 352)
  l.status.name = "status"
  l.status.textColor = f.theme.textMuted

  l.ok.onClick = proc(s: Control) = l.login()
  l.cancel.onClick = proc(s: Control) = f.close()
  f.onShow = proc(s: Control) = f.activeControl = l.userEdit
  l

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let l = buildLoginForm()
  if shot.len > 0:
    l.form.show()
    if getEnv("NIMVCL_FILL") == "1":
      l.userEdit.text = "alice@example.com"
      l.passEdit.text = "secret"
      l.staging.checked = true
      setFocus(l.passEdit)
    if getEnv("NIMVCL_ERROR") == "1": l.ok.click()
    if not l.form.screenshot(shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", l.form.ctx.scale
    Application.shutdown()
  else:
    Application.run(l.form)

when isMainModule:
  main()
