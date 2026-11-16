# Form file demo: the form is described in nfm_demo.nfm and turned into a typed
# `LoginForm` at compile time by `loadForm`. The handlers named in the file
# (`onClick = okClick`, ...) are ordinary procs below, taking the form as the
# first parameter; a missing one is a compile error.
#
#   Edit the .nfm (a caption, a position, a new Edit) and rebuild: the compiler
#   rebuilds the form from the file, and checks every property and handler.
#
# Screenshot mode (headless):
#   SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software \
#     nim c -r examples/nfm_demo.nim --shots build/nfm_shots
#
# Build: nim c --outdir:build examples/nfm_demo.nim

import std/os
import nimvcl
import nimvcl/dsl/nfm

loadForm LoginForm, "nfm_demo.nfm"

proc say(self: LoginForm, text: string) = self.status.simpleText = text

proc okClick(self: LoginForm, sender: Control) =
  if self.userEdit.text.len == 0:
    self.say "Please enter a user name."
    self.userEdit.setFocus()
  elif self.passEdit.text.len < 4:
    self.say "The password is too short."
    self.passEdit.setFocus()
  else:
    self.say "Welcome, " & self.userEdit.text & (if self.remember.checked: " (remembered)" else: "")

proc cancelClick(self: LoginForm, sender: Control) = self.close()
proc exitClick(self: LoginForm, sender: MenuItem) = self.close()
proc clearClick(self: LoginForm, sender: MenuItem) =
  self.userEdit.text = ""
  self.passEdit.text = ""
  self.say "Cleared."
proc rememberChange(self: LoginForm, sender: Control) =
  self.say(if self.remember.checked: "Will remember you." else: "Will not remember you.")

proc shots(dir: string) =
  createDir dir
  Application.init()
  let f = newLoginForm()
  f.show()
  f.userEdit.text = "ada@example.com"
  f.passEdit.text = "analytical"
  f.okButton.onClick(f.okButton)
  discard f.paintIfDirty()
  Application.paintForms()
  if not f.screenshot(dir / "nfm_demo.png"): quit "screenshot failed"
  echo "wrote ", dir / "nfm_demo.png"

when isMainModule:
  let args = commandLineParams()
  if args.len >= 1 and args[0] == "--shots":
    shots(if args.len >= 2: args[1] else: "build/nfm_shots")
  else:
    Application.init()
    Application.run(newLoginForm())
