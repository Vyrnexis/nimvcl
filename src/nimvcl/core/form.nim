## `Form`: a top-level window. It is a `Container` (children are laid out in
## its client area), and owns one SDL window, renderer and `RenderContext`,
## created lazily on first `show`.
##
## The form's input router/painter is a `UiRoot` (`form.ui`), which is the
## `RootHost` of the tree. (A Form cannot inherit from both Container and
## RootHost, so the form owns its host instead of being one.)
##
## Registry: forms register themselves while they own a window. `Application`
## (application.nim) drives the event loop; the two are linked through
## `modalLoopProc` / `terminateProc`, which application.nim installs.
##
## Closing: `close()` runs `onCloseQuery`, then `onClose` (which may change
## the `CloseAction`): `caHide` hides, `caFree` frees the window (the form can
## be shown again later), `caNone` aborts. Closing the main form ends the
## application. A modal form that is closed gets `mrCancel` unless a result was
## set.
##
## Freeing order (UI thread): RenderContext.close, renderer, window.

import ../graphics/context
import ../platform/[window, events]
import ./component, ./control, ./input
export input

type
  CloseAction* = enum caNone, caHide, caFree
  ModalResult* = enum
    mrNone, mrOk, mrCancel, mrAbort, mrRetry, mrIgnore, mrYes, mrNo, mrClose
  FormPosition* = enum poDesigned, poScreenCenter, poMainFormCenter
  BorderStyle* = enum bsSizeable, bsSingle, bsNone
  FormStyle* = enum fsNormal, fsStayOnTop

  FormCloseEvent* = proc(sender: Form, action: var CloseAction)
  FormCloseQueryEvent* = proc(sender: Form, canClose: var bool)

  Form* = ref object of Container
    fUi: UiRoot
    fShown, fModal, fClosing, fSyncing: bool
    fModalResult: ModalResult
    fPosition: FormPosition
    fBorderStyle: BorderStyle
    fFormStyle: FormStyle
    onShow*, onHide*, onActivate*, onDeactivate*: NotifyEvent
    onClose*: FormCloseEvent
    onCloseQuery*: FormCloseQueryEvent

var
  gForms: seq[Form]            # forms that currently own a window
  gMainForm: Form
  gModals: seq[Form]           # active modal forms, innermost last
  gActive: Form
  gForcedScale: float32
  modalLoopProc*: proc(f: Form)   ## installed by application.nim
  terminateProc*: proc()          ## installed by application.nim

# --------------------------------------------------------------- registry

proc openForms*(): seq[Form] = gForms
  ## Forms that currently own a window.
proc mainForm*(): Form = gMainForm
proc setMainForm*(f: Form) = gMainForm = f
proc activeForm*(): Form = gActive
proc modalForm*(): Form =
  ## Innermost modal form, or nil.
  if gModals.len > 0: gModals[^1] else: nil

proc findForm*(windowId: uint32): Form =
  if windowId == 0: return nil
  for f in gForms:
    if f.fUi.win != nil and f.fUi.win.id == windowId: return f

proc acceptsInput*(f: Form): bool =
  ## False while another form is modal.
  gModals.len == 0 or gModals[^1] == f

func ui*(f: Form): UiRoot = f.fUi
func ctx*(f: Form): RenderContext = f.fUi.ctx
func win*(f: Form): PlatformWindow = f.fUi.win
func hasWindow*(f: Form): bool = f.fUi.win != nil

# ------------------------------------------------------------ construction

proc initForm*(f: Form, owner: Component = nil) =
  ## For subclass constructors.
  f.initContainer(owner)
  f.fUi = newUiRoot(f)
  f.fUi.rootGetsMouse = true
  f.fUi.autoSizeRoot = true
  f.fPosition = poScreenCenter
  Control(f).caption = "Form"
  f.setBounds(0, 0, 640, 480)

proc newForm*(owner: Component = nil, width = 640'f32, height = 480'f32): Form =
  new result
  result.initForm(owner)
  result.setBounds(0, 0, width, height)

# --------------------------------------------------------------- properties

proc caption*(f: Form): string = Control(f).caption
proc `caption=`*(f: Form, v: string) =
  `caption=`(Control(f), v)
  if f.fUi.win != nil: f.fUi.win.setTitle(v)

func position*(f: Form): FormPosition = f.fPosition
proc `position=`*(f: Form, v: FormPosition) = f.fPosition = v

func borderStyle*(f: Form): BorderStyle = f.fBorderStyle
proc `borderStyle=`*(f: Form, v: BorderStyle) =
  f.fBorderStyle = v
  let w = f.fUi.win
  if w != nil:
    w.setBordered(v != bsNone)
    w.setResizable(v == bsSizeable)

func formStyle*(f: Form): FormStyle = f.fFormStyle
proc `formStyle=`*(f: Form, v: FormStyle) =
  f.fFormStyle = v
  if f.fUi.win != nil: f.fUi.win.setStayOnTop(v == fsStayOnTop)

func keyPreview*(f: Form): bool = f.fUi.keyPreview
proc `keyPreview=`*(f: Form, v: bool) = f.fUi.keyPreview = v

func visible*(f: Form): bool = f.fShown
func isModal*(f: Form): bool = f.fModal

func modalResult*(f: Form): ModalResult = f.fModalResult
proc `modalResult=`*(f: Form, v: ModalResult) =
  ## While the form is modal, a value other than `mrNone` closes it (the modal
  ## loop notices on its next iteration).
  f.fModalResult = v

func activeControl*(f: Form): Control = f.fUi.focusedControl
proc `activeControl=`*(f: Form, c: Control) = f.fUi.focusControl(c)

proc theme*(f: Form): Theme = Control(f).theme
proc `theme=`*(f: Form, t: Theme) =
  ## Per-form theme override (nil = the global theme).
  f.fUi.theme = t
  f.relayoutAll()
  f.invalidate()

# ----------------------------------------------------------------- window

proc applyPosition(f: Form) =
  let w = f.fUi.win
  case f.fPosition
  of poScreenCenter: w.centerOnScreen()
  of poMainFormCenter:
    if gMainForm != nil and gMainForm != f and gMainForm.fUi.win != nil:
      w.centerOn(gMainForm.fUi.win)
    else: w.centerOnScreen()
  of poDesigned: w.setPosition(int(f.left), int(f.top))

proc ensureWindow(f: Form) =
  if f.fUi.win != nil: return
  initPlatform()
  let w = createPlatformWindow(f.caption, f.width, f.height,
    resizable = f.fBorderStyle == bsSizeable, borderless = f.fBorderStyle == bsNone,
    stayOnTop = f.fFormStyle == fsStayOnTop, forcedScale = gForcedScale)
  f.fUi.win = w
  try:
    f.fUi.ctx = newRenderContext(w.renderer, w.scale)
  except IOError:
    w.destroy()
    f.fUi.win = nil
    raise
  if f.fBorderStyle == bsSingle: w.setResizable(false)
  gForms.add f
  f.fUi.dirty = true

proc releaseWindow(f: Form) =
  ## Frees renderer-bound resources, then the renderer and window.
  let ui = f.fUi
  if ui.win == nil: return
  ui.cancelInteraction()
  ui.focusControl(nil)
  ui.closeContext()
  ui.win.destroy()
  ui.win = nil
  let i = gForms.find(f)
  if i >= 0: gForms.delete(i)
  if gActive == f: gActive = nil
  if gMainForm == f: gMainForm = nil
  f.fShown = false

proc freeWindow*(f: Form) =
  ## Destroys the window without running `close` events (application shutdown).
  releaseWindow(f)

proc syncMetrics*(f: Form) =
  ## Re-reads window size and scale (after a resize/scale event).
  f.fSyncing = true
  try: f.fUi.syncMetrics()
  finally: f.fSyncing = false

proc setForcedScale*(s: float32) =
  ## Forces the render scale (headless testing); 0 restores the real density.
  gForcedScale = s
  for f in gForms:
    f.fUi.win.forcedScale = s
    f.syncMetrics()

proc forcedScale*(): float32 = gForcedScale

method doResize*(f: Form) =
  procCall doResize(Container(f))
  if not f.fSyncing and f.fUi.win != nil:
    f.fUi.win.setLogicalSize(f.width, f.height)

# ----------------------------------------------------------- show and hide

proc show*(f: Form) =
  if f.fShown: return
  f.ensureWindow()
  if gMainForm == nil and not f.fModal: gMainForm = f
  let w = f.fUi.win
  f.syncMetrics()
  f.applyPosition()
  w.show()
  f.fShown = true
  f.fUi.dirty = true
  if f.onShow != nil: f.onShow(f)

proc hide*(f: Form) =
  if not f.fShown: return
  f.fShown = false
  f.fUi.cancelInteraction()
  if f.fUi.win != nil: f.fUi.win.hide()
  if gActive == f: gActive = nil
  if f.onHide != nil: f.onHide(f)

proc `visible=`*(f: Form, v: bool) =
  if v: f.show() else: f.hide()

proc bringToFront*(f: Form) =
  if f.fUi.win != nil: f.fUi.win.raiseWindow()

proc close*(f: Form) =
  ## Closes the form (see the module comment). No-op while closing or hidden.
  if f.fClosing or not f.fShown: return
  f.fClosing = true
  try:
    var can = true
    if f.onCloseQuery != nil: f.onCloseQuery(f, can)
    if not can:
      if f.fModal: f.fModalResult = mrNone
      return
    var action = caHide
    if f.onClose != nil: f.onClose(f, action)
    if action == caNone:
      if f.fModal: f.fModalResult = mrNone
      return
    let wasMain = f == gMainForm and not f.fModal
    if f.fModal and f.fModalResult == mrNone: f.fModalResult = mrCancel
    if action == caFree: f.releaseWindow() else: f.hide()
    if wasMain and terminateProc != nil: terminateProc()
  finally:
    f.fClosing = false

proc showModal*(f: Form): ModalResult =
  ## Shows the form modally: other forms ignore input and a nested event loop
  ## runs until `modalResult` is set to something other than `mrNone` (or the
  ## form is closed, giving `mrCancel`). Returns the result.
  if f.fModal: return f.fModalResult
  f.fModalResult = mrNone
  f.ensureWindow()
  let parent =
    if gModals.len > 0: gModals[^1]
    elif gMainForm != nil and gMainForm != f: gMainForm
    else: nil
  f.fModal = true
  gModals.add f
  if parent != nil and parent.fUi.win != nil: f.fUi.win.setModalFor(parent.fUi.win)
  f.show()
  if modalLoopProc != nil: modalLoopProc(f)
  if f.fModalResult == mrNone: f.fModalResult = mrCancel
  result = f.fModalResult
  let i = gModals.find(f)
  if i >= 0: gModals.delete(i)
  f.fModal = false
  if f.fUi.win != nil:
    f.fUi.win.clearModal()
    if f.fShown: f.hide()
  f.fModalResult = mrNone
  if parent != nil and parent.fUi.win != nil: parent.bringToFront()

# --------------------------------------------------------- loop integration

proc windowActivated*(f: Form, active: bool) =
  ## Called by the application for focus gained/lost events.
  f.fUi.setWindowActive(active)
  if active:
    gActive = f
    if f.onActivate != nil: f.onActivate(f)
  else:
    if gActive == f: gActive = nil
    f.fUi.cancelInteraction()
    if f.onDeactivate != nil: f.onDeactivate(f)

proc paintIfDirty*(f: Form): bool =
  ## Layout + paint + present when needed. Returns true if a frame was drawn.
  if not f.fShown or f.fUi.win == nil or not f.fUi.needsPaint: return false
  f.fUi.paintFrame(clear = true, present = true)
  true

proc screenshot*(f: Form, path: string): bool =
  ## Headless helper: shows the form, lays out, paints one frame (without
  ## presenting) and saves it as a BMP.
  f.show()
  f.syncMetrics()
  f.fUi.paintFrame(clear = true, present = false)
  f.fUi.win.writeBmp(path)
