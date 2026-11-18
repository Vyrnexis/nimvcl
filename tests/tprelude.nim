## `nimvcl/prelude` gives handler code what it needs without a component:
## dialogs, colours, fonts, timers, the clipboard, forms and the application.
## Headless: the dialogs are only referenced, not shown.

import std/unittest
import nimvcl/prelude

type Probe = ref object of Form
  count: int

proc handler(f: Form) =
  # nothing here may need another import
  f.color = rgb(255, 0, 0)
  f.font = FontSpec(family: "sans", size: 12, style: {fsBold})
  let t = newTimer(f, 500)
  t.enabled = false
  f.onClose = proc(sender: Form, action: var CloseAction) = action = caHide
  Application.clipboard = "hello"

proc dialogsCompile() =
  # referenced only; never called, so no window opens
  if false:
    showMessage("hi")
    discard messageDlg("sure?", mtConfirmation, {mbYes, mbNo})
    var v = "x"
    discard inputQuery("Title", "Prompt", v)
    discard inputBox("Title", "Prompt", "d")
    let od = newOpenDialog()
    od.title = "Open"
    discard newSaveDialog()
    discard newSelectFolderDialog()

suite "prelude":
  test "forms, colours, fonts, timers and the clipboard":
    dialogsCompile()
    Application.init()
    let f = newForm(nil, 200, 100)
    handler(f)
    check f.color == rgb(255, 0, 0)
    check Application.clipboard == "hello"
    f.freeWindow()
