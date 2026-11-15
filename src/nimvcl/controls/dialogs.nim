## Standard dialogs.
##
## Message dialogs (drawn by us, built with the `form` macro, shown with
## `showModal` and centred on the active form):
##
## * `showMessage(text)`: OK only, no icon.
## * `messageDlg(text, dlgType, buttons, defaultButton, title)`: returns the
##   `ModalResult` of the pressed button (`mrYes mrNo mrOk mrCancel mrAbort
##   mrRetry mrIgnore`). The icon (a coloured circle + glyph) follows
##   `dlgType`; the text wraps and the dialog sizes itself to it within a
##   maximum width. Buttons are shown in the order Yes, No, OK, Abort, Retry,
##   Ignore, Cancel. `defaultButton` (when not in `buttons`: the first one) is
##   focused and answers Enter. Esc / the window close button give the "escape"
##   answer: Cancel, else No, else the only button, else Abort, else
##   `mrCancel`.
## * `inputQuery(caption, prompt, value: var string): bool` (true = OK, `value`
##   updated) and `inputBox(caption, prompt, default): string` (the default
##   when cancelled).
##
## File dialogs use SDL's native ones (platform/dialogs.nim), which are
## asynchronous and report from any thread; results are marshalled to the UI
## thread through `runOnUi`.
##
## * `OpenDialog`, `SaveDialog`, `SelectFolderDialog` components with `title`,
##   `initialDir`, `filters` (`@[("Images", "png;jpg"), ("All", "*")]`) and
##   `multiSelect`.
## * `execute(onDone)`: starts the dialog and returns at once; `onDone(ok,
##   files)` runs later on the UI thread. `files` / `fileName` are set too.
## * `executeModal(): bool`: runs a nested modal loop (`runModalLoop`: the
##   input of the application's forms is gated) until the dialog reports, then
##   returns ok.

import std/tables
import ../core/[form, application]
import ../platform/dialogs
import ../dsl/formmacro
import ./[common, label, button, edit, paintbox]

export dialogs.FileDialogRequest, dialogs.FileDialogKind

type
  MsgDlgType* = enum mtInformation, mtWarning, mtError, mtConfirmation
  MsgDlgBtn* = enum mbYes, mbNo, mbOK, mbCancel, mbAbort, mbRetry, mbIgnore
  MsgDlgButtons* = set[MsgDlgBtn]

const
  DlgPad = 20'f32
  IconSize = 40'f32
  MaxTextWidth = 360'f32
  BtnGap = 8'f32
  BtnHeight = 28'f32

# ------------------------------------------------------------- helpers

func dlgResult(b: MsgDlgBtn): ModalResult =
  case b
  of mbYes: mrYes
  of mbNo: mrNo
  of mbOK: mrOk
  of mbCancel: mrCancel
  of mbAbort: mrAbort
  of mbRetry: mrRetry
  of mbIgnore: mrIgnore

func btnCaption(b: MsgDlgBtn): string =
  case b
  of mbYes: "Yes"
  of mbNo: "No"
  of mbOK: "OK"
  of mbCancel: "Cancel"
  of mbAbort: "Abort"
  of mbRetry: "Retry"
  of mbIgnore: "Ignore"

func orderedButtons(bs: MsgDlgButtons): seq[MsgDlgBtn] =
  for b in [mbYes, mbNo, mbOK, mbAbort, mbRetry, mbIgnore, mbCancel]:
    if b in bs: result.add b

func escapeButton*(bs: MsgDlgButtons): MsgDlgBtn =
  ## The button Esc (and closing the window) answers for; see the module doc.
  if mbCancel in bs: mbCancel
  elif mbNo in bs: mbNo
  elif bs.card == 1: orderedButtons(bs)[0]
  elif mbAbort in bs: mbAbort
  else: mbCancel

func defaultCaption(t: MsgDlgType): string =
  case t
  of mtInformation: "Information"
  of mtWarning: "Warning"
  of mtError: "Error"
  of mtConfirmation: "Confirm"

proc drawDlgIcon*(c: Canvas, r: RectF, t: Theme, kind: MsgDlgType) =
  ## The message icon: a coloured disc with a white glyph.
  let col =
    case kind
    of mtInformation: t.accent
    of mtWarning: hex"#e8a317"
    of mtError: t.danger
    of mtConfirmation: hex"#16a34a"
  c.fillEllipse(r, col)
  let white = clWhite
  case kind
  of mtError:
    let m = r.w * 0.3
    c.line(r.x + m, r.y + m, r.right - m, r.bottom - m, white, 3)
    c.line(r.right - m, r.y + m, r.x + m, r.bottom - m, white, 3)
  else:
    let g = case kind
            of mtInformation: "i"
            of mtWarning: "!"
            else: "?"
    c.textRect(g, font(size = r.h * 0.6, style = {fsBold}), r, white, taCenter, vaCenter)

# ------------------------------------------------------------ message form

form MsgDlgForm:
  borderStyle = bsSingle
  position = poScreenCenter
  var kind: MsgDlgType
  var showIcon: bool
  var buttonSet: MsgDlgButtons
  var buttonList: seq[Button]
  PaintBox icon:
    width = IconSize; height = IconSize
    onPaint = proc(sender: Control, canvas: Canvas) =
      let d = MsgDlgForm(sender.parent)
      canvas.drawDlgIcon(sender.clientRect, sender.theme, d.kind)
  Label msg:
    autoSize = false
    wordWrap = true
    layout = vaTop
  proc setup(self: MsgDlgForm, text: string, kind: MsgDlgType, showIcon: bool,
             buttons: MsgDlgButtons, default: MsgDlgBtn) =
    self.kind = kind
    self.showIcon = showIcon
    self.buttonSet = buttons
    self.msg.caption = text
    self.icon.visible = showIcon
    let list = orderedButtons(buttons)
    let defBtn = if default in buttons: default else: list[0]
    let escBtn = escapeButton(buttons)
    for b in list:
      let btn = newButton(self, btnCaption(b))
      btn.modalResult = dlgResult(b)
      btn.isDefault = b == defBtn
      btn.isCancel = b == escBtn
      btn.tag = ord(b)
      self.buttonList.add btn
      if b == defBtn: self.activeControl = btn
  proc fit(self: MsgDlgForm) =
    ## Sizes and arranges everything (needs the window, so it runs on show).
    var rowW = 0'f32
    for b in self.buttonList:
      b.width = max(88'f32, self.textWidth(b.caption, b.font) + 32)
      b.height = BtnHeight
      rowW += b.width
    rowW += BtnGap * float32(max(self.buttonList.len - 1, 0))
    let iconW = if self.showIcon: IconSize + 16 else: 0'f32
    var textW = MaxTextWidth
    var textH = 0'f32
    if self.canMeasure:
      let sz = self.msg.measure(self.msg.caption, self.msg.font, MaxTextWidth)
      textW = min(ceil(sz.w) + 2, MaxTextWidth)
      textH = ceil(sz.h)
    else:
      textH = 20
    textW = max(textW, 80'f32)
    let contentW = max(iconW + textW, rowW)
    let w = max(contentW + 2 * DlgPad, 280'f32)
    let topH = max(if self.showIcon: IconSize else: 0'f32, textH)
    self.icon.setBounds(DlgPad, DlgPad, IconSize, IconSize)
    self.msg.setBounds(DlgPad + iconW, DlgPad + floor((topH - textH) / 2), textW, textH)
    let by = DlgPad + topH + 24
    var x = w - DlgPad - rowW
    for b in self.buttonList:
      b.setBounds(x, by, b.width, BtnHeight)
      x += b.width + BtnGap
    self.setBounds(self.left, self.top, w, by + BtnHeight + DlgPad - 4)
  onShow: MsgDlgForm(sender).fit()

proc runMessageDlg(text: string, kind: MsgDlgType, showIcon: bool,
                   buttons: MsgDlgButtons, default: MsgDlgBtn,
                   title: string): ModalResult =
  let bs = if buttons == {}: {mbOK} else: buttons
  let d = newMsgDlgForm()
  d.caption = if title.len > 0: title else: defaultCaption(kind)
  d.setup(text, kind, showIcon, bs, default)
  try:
    result = d.showModal()
  finally:
    d.freeWindow()
  if result == mrCancel: result = dlgResult(escapeButton(bs))

proc messageDlg*(text: string, dlgType = mtInformation, buttons: MsgDlgButtons = {mbOK},
                 defaultButton = mbOK, title = ""): ModalResult {.discardable.} =
  ## Modal message box; see the module comment.
  runMessageDlg(text, dlgType, true, buttons, defaultButton, title)

proc showMessage*(text: string) =
  ## OK-only message without an icon.
  discard runMessageDlg(text, mtInformation, false, {mbOK}, mbOK, "Message")

proc newMessageDlg*(text: string, dlgType = mtInformation,
                    buttons: MsgDlgButtons = {mbOK}, defaultButton = mbOK,
                    title = ""): MsgDlgForm =
  ## The dialog form without showing it (headless screenshots, tests).
  let bs = if buttons == {}: {mbOK} else: buttons
  result = newMsgDlgForm()
  result.caption = if title.len > 0: title else: defaultCaption(dlgType)
  result.setup(text, dlgType, true, bs, defaultButton)

# --------------------------------------------------------------- input form

form InputDlgForm:
  borderStyle = bsSingle
  position = poScreenCenter
  Label promptLbl:
    autoSize = false
    wordWrap = true
  Edit input:
    autoSelect = true
  Button okBtn:
    caption = "OK"
    isDefault = true
    modalResult = mrOk
  Button cancelBtn:
    caption = "Cancel"
    isCancel = true
    modalResult = mrCancel
  proc fit(self: InputDlgForm) =
    let w = 380'f32
    let innerW = w - 2 * DlgPad
    var ph = 20'f32
    if self.canMeasure:
      ph = ceil(self.promptLbl.measure(self.promptLbl.caption, self.promptLbl.font, innerW).h)
    self.promptLbl.setBounds(DlgPad, DlgPad, innerW, ph)
    let ey = DlgPad + ph + 10
    self.input.setBounds(DlgPad, ey, innerW, 28)
    let by = ey + 28 + 20
    self.cancelBtn.setBounds(w - DlgPad - 88, by, 88, BtnHeight)
    self.okBtn.setBounds(w - DlgPad - 88 * 2 - BtnGap, by, 88, BtnHeight)
    self.setBounds(self.left, self.top, w, by + BtnHeight + DlgPad - 4)
    self.activeControl = self.input
    self.input.selectAll()
  onShow: InputDlgForm(sender).fit()

proc newInputDlg*(caption, prompt, value: string): InputDlgForm =
  ## The input dialog form without showing it.
  result = newInputDlgForm()
  result.caption = caption
  result.promptLbl.caption = prompt
  result.input.text = value

proc inputQuery*(caption, prompt: string, value: var string): bool =
  ## Asks for a line of text; true (and `value` updated) when OK was pressed.
  let d = newInputDlg(caption, prompt, value)
  let r = d.showModal()
  if r == mrOk:
    value = d.input.text
    result = true
  d.freeWindow()

proc inputBox*(caption, prompt, default: string): string =
  ## Like `inputQuery` but returns the text, or `default` when cancelled.
  var v = default
  if inputQuery(caption, prompt, v): v else: default

# -------------------------------------------------------------- file dialogs

type
  FileDialogDoneProc* = proc(ok: bool, files: seq[string])

  FileDialogBase* = ref object of Component
    title*, initialDir*: string
    filters*: seq[(string, string)]
    multiSelect*: bool
    files*: seq[string]          ## the selection of the last successful run
    running: bool

  OpenDialog* = ref object of FileDialogBase
  SaveDialog* = ref object of FileDialogBase
  SelectFolderDialog* = ref object of FileDialogBase

  DoneMsg = object
    token: int
    ok: bool
    files: seq[string]

var
  pending: Table[int, FileDialogDoneProc]   # UI thread only
  nextToken = 1

proc deliver(msg: DoneMsg) {.nimcall.} =
  ## UI thread: hands a result to its waiting callback.
  var cb: FileDialogDoneProc
  if pending.pop(msg.token, cb) and cb != nil: cb(msg.ok, msg.files)

proc platformDone(token: int, ok: bool, files: seq[string]) {.nimcall, gcsafe.} =
  ## Called by the platform layer from ANY thread.
  runOnUi(DoneMsg(token: token, ok: ok, files: files), deliver)

func fileName*(d: FileDialogBase): string =
  if d.files.len > 0: d.files[0] else: ""

func isRunning*(d: FileDialogBase): bool = d.running

proc request(d: FileDialogBase, kind: FileDialogKind): FileDialogRequest =
  result = FileDialogRequest(kind: kind, title: d.title, initialDir: d.initialDir,
                             filters: d.filters, multiSelect: d.multiSelect)
  let a = activeForm()
  if a != nil and a.hasWindow: result.parent = a.win

proc start(d: FileDialogBase, kind: FileDialogKind, onDone: FileDialogDoneProc) =
  if d.running: return
  d.running = true
  let token = nextToken
  inc nextToken
  pending[token] = proc(ok: bool, files: seq[string]) =
    d.running = false
    if ok: d.files = files
    if onDone != nil: onDone(ok, files)
  try:
    showFileDialog(d.request(kind), token, platformDone)
  except Exception:
    # the platform never took the request: no callback will come
    pending.del token
    d.running = false
    raise

method kind(d: FileDialogBase): FileDialogKind {.base.} = fdkOpen
method kind(d: OpenDialog): FileDialogKind = fdkOpen
method kind(d: SaveDialog): FileDialogKind = fdkSave
method kind(d: SelectFolderDialog): FileDialogKind = fdkFolder

proc execute*(d: FileDialogBase, onDone: FileDialogDoneProc = nil) =
  ## Starts the dialog (ignored while it is already running). `onDone(ok,
  ## files)` runs later on the UI thread; `ok` is false when cancelled.
  d.start(d.kind, onDone)

proc executeModal*(d: FileDialogBase): bool =
  ## Starts the dialog and runs a nested event loop until it reports.
  if d.running: return false
  var finished, accepted = false
  d.start(d.kind, proc(ok: bool, files: seq[string]) =
    finished = true
    accepted = ok)
  runModalLoop(proc(): bool = finished)
  result = accepted

proc newOpenDialog*(owner: Component = nil): OpenDialog =
  new result
  result.initComponent(owner)
proc newSaveDialog*(owner: Component = nil): SaveDialog =
  new result
  result.initComponent(owner)
proc newSelectFolderDialog*(owner: Component = nil): SelectFolderDialog =
  new result
  result.initComponent(owner)
