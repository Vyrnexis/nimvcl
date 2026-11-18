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

form WelcomeForm:
  caption = "Welcome"
  width = 320; height = 160
  position = poMainFormCenter
  borderStyle = bsSingle
  Label message:
    left = 24; top = 24
    font = font(size = 18, style = {fsBold})
  Label detail:
    left = 24; top = 62
    font.color = self.theme.textMuted
  Button ok:
    caption = "OK"; left = 206; top = 104; width = 90
    isDefault = true
    modalResult = mrOk
  onShow: self.activeControl = self.ok

form LoginForm:
  caption = "Sign in"
  width = 420; height = 392
  borderStyle = bsSingle
  var welcomeShown: int            ## how many times the welcome form was shown
  var welcomeResult: ModalResult   ## what the last welcome form returned
  var greeted: string              ## user name of the last successful login
  Label:
    caption = "Sign in"; left = 20; top = 14
    font = font(size = 20, style = {fsBold})
  GroupBox group:
    caption = "Account"; left = 20; top = 54; width = 380; height = 238
    Label userLabel:
      caption = "User name"; left = 16; top = 34
      focusControl = self.user
    Edit user:
      left = 16; top = 56; width = 348; height = 28
      placeholder = "name@example.com"
    Label passLabel:
      caption = "Password"; left = 16; top = 90
      focusControl = self.password
    Edit password:
      left = 16; top = 112; width = 348; height = 28
      placeholder = "Password"; passwordChar = '*'
    CheckBox remember:
      caption = "Remember me"; checked = true; left = 16; top = 154
    Label:
      caption = "Server"; left = 16; top = 186
    RadioButton production:
      caption = "Production"; checked = true; left = 16; top = 208
    RadioButton staging:
      caption = "Staging"; left = 140; top = 208
  Button ok:
    caption = "OK"; left = 212; top = 306; width = 90
    isDefault = true
    onClick: self.login()
  Button cancel:
    caption = "Cancel"; left = 310; top = 306; width = 90
    isCancel = true
    onClick: self.close()
  Label status:
    caption = "Enter your credentials."; left = 20; top = 352
    font.color = self.theme.textMuted
  onShow: self.activeControl = self.user

  proc showError(self: LoginForm, msg: string) =
    self.status.fontColor = self.theme.danger
    self.status.caption = msg

  proc showWelcome(self: LoginForm) =
    let d = newWelcomeForm()
    d.message.caption = "Welcome, " & self.greeted & "!"
    d.detail.caption = "Signed in to " & (if self.production.checked: "Production" else: "Staging") &
                       (if self.remember.checked: " (remembered)" else: "")
    inc self.welcomeShown
    self.welcomeResult = d.showModal()

  proc login(self: LoginForm) =
    let name = self.user.text.strip()
    if name.len == 0:
      self.showError "Please enter your user name."
      setFocus(self.user)
    elif self.password.text.len == 0:
      self.showError "Please enter your password."
      setFocus(self.password)
    else:
      self.greeted = name
      self.status.fontColor = self.theme.textMuted
      self.status.caption = "Signed in as " & name
      self.showWelcome()

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let l = newLoginForm()
  if shot.len > 0:
    l.show()
    if getEnv("NIMVCL_FILL") == "1":
      l.user.text = "alice@example.com"
      l.password.text = "secret"
      l.staging.checked = true
      setFocus(l.password)
    if getEnv("NIMVCL_ERROR") == "1": l.ok.click()
    if not l.screenshot(shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", l.ctx.scale
    Application.shutdown()
  else:
    Application.run(l)

when isMainModule:
  main()
