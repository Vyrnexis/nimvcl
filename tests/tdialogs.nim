## Dialogs: message/input dialogs driven by queued events while they are modal,
## and the file dialog marshalling with a fake platform call. Headless.

import std/[unittest, monotimes, times, os, strutils]
import nimvcl/core/[types, control, form, application]
import nimvcl/platform/[events, window, dialogs]
import nimvcl/controls/[common, button, edit, dialogs]

var onMainThread {.threadvar.}: bool

proc key(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k,
                                     shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k,
                                     shift: shift))

template whileModal(body: untyped) =
  ## Runs `body` on the UI thread once the modal loop is running; `dlg` is the
  ## modal form.
  Application.queue(proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let dlg {.inject.} = modalForm()
      body)

proc buttonOf(d: Form, b: MsgDlgBtn): Button =
  for c in d.children:
    if c of Button and c.tag == ord(b): return Button(c)

proc clickButton(d: Form, b: MsgDlgBtn) =
  let btn = d.buttonOf(b)
  doAssert btn != nil
  let o = btn.formOrigin
  for kind in [ekMouseDown, ekMouseUp]:
    Application.dispatch(PlatformEvent(kind: kind, windowId: d.win.id,
      x: o.x + btn.width / 2, y: o.y + btn.height / 2, button: mbLeft, clicks: 1))

suite "message dialogs":
  setup:
    Application.init()
    Application.forceScale = 0
    onMainThread = true
  teardown:
    for f in openForms(): f.freeWindow()

  test "showMessage closes with Enter":
    whileModal:
      check dlg != nil
      dlg.key(keyEnter)
    showMessage("Hello")
    check modalForm() == nil

  test "every button returns its result":
    let table = [(mbYes, mrYes), (mbNo, mrNo), (mbOK, mrOk), (mbCancel, mrCancel),
                 (mbAbort, mrAbort), (mbRetry, mrRetry), (mbIgnore, mrIgnore)]
    for (btn, res) in table:
      whileModal:
        dlg.clickButton(btn)
      check messageDlg("Pick", mtConfirmation,
                       {mbYes, mbNo, mbOK, mbCancel, mbAbort, mbRetry, mbIgnore}) == res

  test "default button is focused and answers Enter":
    whileModal:
      check dlg.activeControl == Control(dlg.buttonOf(mbNo))
      check dlg.buttonOf(mbNo).isDefault and not dlg.buttonOf(mbYes).isDefault
      dlg.key(keyEnter)
    check messageDlg("Sure?", mtWarning, {mbYes, mbNo, mbCancel}, mbNo) == mrNo
    # default not among the buttons: the first one (Yes)
    whileModal:
      check dlg.activeControl == Control(dlg.buttonOf(mbYes))
      dlg.key(keyEnter)
    check messageDlg("Sure?", mtWarning, {mbYes, mbNo}) == mrYes

  test "Escape answers Cancel, No, the only button or Abort":
    proc esc(bs: MsgDlgButtons): ModalResult =
      whileModal:
        dlg.key(keyEscape)
      messageDlg("Esc", mtInformation, bs)
    check esc({mbOK, mbCancel}) == mrCancel
    check esc({mbYes, mbNo, mbCancel}) == mrCancel
    check esc({mbYes, mbNo}) == mrNo
    check esc({mbOK}) == mrOk
    check esc({mbAbort, mbRetry, mbIgnore}) == mrAbort
    check escapeButton({mbYes, mbNo}) == mbNo

  test "closing the window answers like Escape":
    whileModal:
      dlg.close()
    check messageDlg("x", mtInformation, {mbYes, mbNo}) == mrNo

  test "the dialog fits its text":
    var wShort, hShort, wLong, hLong: float32
    whileModal:
      wShort = dlg.width; hShort = dlg.height
      dlg.key(keyEnter)
    check messageDlg("Short", mtInformation) == mrOk
    let long = "This is a much longer message that has to wrap over several " &
               "lines because the dialog is limited to a maximum width, and " &
               "still everything must stay readable. " & "More words. ".repeat(6)
    whileModal:
      wLong = dlg.width; hLong = dlg.height
      let msg = dlg.children[1]
      check msg.top + msg.height <= dlg.height
      check dlg.buttonOf(mbOK).top >= msg.top + msg.height
      dlg.key(keyEnter)
    check messageDlg(long, mtError) == mrOk
    check wLong <= 360 + 2 * 20 + 40 + 16 and wLong >= wShort
    check hLong > hShort + 40
    check wShort >= 280

  test "inputQuery round trip":
    var v = "start"
    whileModal:
      let d = InputDlgForm(dlg)
      check d.input.text == "start"
      check d.activeControl == Control(d.input)
      check d.input.selLength == 5                  # preselected
      d.input.text = "changed"
      dlg.key(keyEnter)                             # Enter -> default button
    check inputQuery("Name", "Your name:", v)
    check v == "changed"
    whileModal:
      InputDlgForm(dlg).input.text = "ignored"
      dlg.key(keyEscape)
    check not inputQuery("Name", "Your name:", v)
    check v == "changed"
    whileModal:
      InputDlgForm(dlg).input.text = "typed"
      let b = InputDlgForm(dlg).okBtn
      let o = b.formOrigin
      for kind in [ekMouseDown, ekMouseUp]:
        Application.dispatch(PlatformEvent(kind: kind, windowId: dlg.win.id,
          x: o.x + b.width / 2, y: o.y + b.height / 2, button: mbLeft, clicks: 1))
    check inputQuery("Name", "Your name:", v)
    check v == "typed"

suite "input box":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "inputBox returns the text or the default":
    whileModal:
      let d = InputDlgForm(dlg)
      d.input.text = "abc"
      d.okBtn.click()
    check inputBox("T", "P", "def") == "abc"
    whileModal:
      let d = InputDlgForm(dlg)
      d.input.text = "abc"
      d.cancelBtn.click()
    check inputBox("T", "P", "def") == "def"

# ------------------------------------------------------------ file dialogs

type
  FakeArgs = tuple[token: int, done: FileDialogDone, ok: bool,
                   files: seq[string], delayMs: int]

var
  lastReq: FileDialogRequest
  fakeOk = true
  fakeFiles: seq[string]
  fakeThreads: seq[Thread[FakeArgs]]
  realImpl: FileDialogImpl

proc fakeThread(a: FakeArgs) {.thread.} =
  sleep a.delayMs
  a.done(a.token, a.ok, a.files)      # from a foreign thread, like SDL

proc fakeImpl(req: FileDialogRequest, token: int, done: FileDialogDone) =
  lastReq = req
  fakeThreads.add Thread[FakeArgs]()
  createThread(fakeThreads[^1], fakeThread, (token, done, fakeOk, fakeFiles, 30))

suite "file dialogs":
  setup:
    Application.init()
    Application.forceScale = 0
    onMainThread = true
    realImpl = showFileDialogImpl
    showFileDialogImpl = fakeImpl
    fakeOk = true
    fakeFiles = @["/tmp/a.txt", "/tmp/b.txt"]
  teardown:
    for t in fakeThreads.mitems: joinThread(t)
    fakeThreads.setLen 0
    showFileDialogImpl = realImpl
    for f in openForms(): f.freeWindow()

  test "execute: the callback arrives on the UI thread":
    let d = newOpenDialog()
    d.title = "Open it"
    d.initialDir = "/tmp"
    d.filters = @[("Text", "txt"), ("All", "*")]
    d.multiSelect = true
    var called = 0
    var gotOk = false
    var gotFiles: seq[string]
    var onMain = false
    d.execute(proc(ok: bool, files: seq[string]) =
      inc called
      gotOk = ok
      gotFiles = files
      onMain = onMainThread)
    check d.isRunning
    check lastReq.kind == fdkOpen and lastReq.title == "Open it"
    check lastReq.initialDir == "/tmp" and lastReq.multiSelect
    check lastReq.filters == @[("Text", "txt"), ("All", "*")]
    let t0 = getMonoTime()
    while called == 0 and (getMonoTime() - t0).inMilliseconds < 3000:
      Application.processMessages(50)
    check called == 1
    check gotOk and gotFiles == fakeFiles
    check onMain
    check d.files == fakeFiles and d.fileName == "/tmp/a.txt"
    check not d.isRunning

  test "execute: cancel keeps the previous selection":
    let d = newSaveDialog()
    d.files = @["old"]
    fakeOk = false
    fakeFiles = @[]
    var res = true
    var called = false
    d.execute(proc(ok: bool, files: seq[string]) =
      called = true
      res = ok)
    let t0 = getMonoTime()
    while not called and (getMonoTime() - t0).inMilliseconds < 3000:
      Application.processMessages(50)
    check called and not res
    check d.files == @["old"]
    check lastReq.kind == fdkSave

  test "executeModal blocks in a nested loop":
    let d = newSelectFolderDialog()
    fakeFiles = @["/home/x"]
    check d.executeModal()
    check d.fileName == "/home/x"
    check lastReq.kind == fdkFolder
    fakeOk = false
    check not d.executeModal()

  test "a running dialog ignores a second execute":
    let d = newOpenDialog()
    var n = 0
    d.execute(proc(ok: bool, files: seq[string]) = inc n)
    d.execute(proc(ok: bool, files: seq[string]) = inc n)
    check fakeThreads.len == 1
    check not d.executeModal()                     # refused while running
    let t0 = getMonoTime()
    while n == 0 and (getMonoTime() - t0).inMilliseconds < 3000:
      Application.processMessages(50)
    check n == 1

  test "the parent window is the active form's":
    let f = newForm(nil, 200, 100)
    f.show()
    Application.dispatch(PlatformEvent(kind: ekWindowFocusGained, windowId: f.win.id))
    let d = newOpenDialog()
    check d.executeModal()
    check lastReq.parent == f.win
