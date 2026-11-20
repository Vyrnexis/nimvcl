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

import ../graphics/[context, image]
import ../platform/[window, events]
import ./component, ./control, ./input
export input

type
  CloseAction* = enum caNone, caHide, caFree
  ModalResult* = enum
    mrNone, mrOk, mrCancel, mrAbort, mrRetry, mrIgnore, mrYes, mrNo, mrClose
  FormPosition* = enum poDesigned, poScreenCenter, poMainFormCenter
  FormStyle* = enum fsNormal, fsStayOnTop

  FormCloseEvent* = proc(sender: Form, action: var CloseAction)
  FormCloseQueryEvent* = proc(sender: Form, canClose: var bool)

  Form* = ref object of Container
    fUi: UiRoot
    fShown, fModal, fClosing: bool
    fModalResult: ModalResult
    fOwner: Form                 ## the form a modal form is owned by / centred on
    menuBar*: Control            ## the form's `MainMenu` (set by controls/menus.nim)
    popupMenus*: seq[RootRef]    ## `PopupMenu`s attached to controls of this form (menus.nim)
    fPosition: FormPosition
    fBorderStyle: BorderStyle
    fFormStyle: FormStyle
    fIcon: Image                 ## the window icon (nil: the platform's default)
    onShow*, onHide*, onActivate*, onDeactivate*: NotifyEvent
    onClose*: FormCloseEvent
    onCloseQuery*: FormCloseQueryEvent

var
  gForms: seq[Form]            # forms that currently own a window
  gMainForm: Form
  gModals: seq[Form]           # active modal forms, innermost last
  gGates: int                  # nested modal states without a form (beginModalState)
  gActive: Form
  gForcedScale: float32
  modalLoopProc*: proc(f: Form)   ## installed by application.nim
  terminateProc*: proc()          ## installed by application.nim
  closePopupsProc*: proc(f: Form) ## installed by popup.nim; closes `f`'s popups (nil: all)

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
  ## False while another form is modal, or while a form-less modal state
  ## (`beginModalState`) is active.
  gGates == 0 and (gModals.len == 0 or gModals[^1] == f)

proc beginModalState*() =
  ## Gates the input of every form (a nested loop with no form of its own, e.g.
  ## waiting for a native file dialog). Pair with `endModalState`; prefer
  ## `runModalLoop` (application.nim), which does both.
  inc gGates
  if closePopupsProc != nil: closePopupsProc(nil)
  for f in openForms(): f.fUi.cancelInteraction()   # their button release will not arrive

proc endModalState*() =
  if gGates > 0: dec gGates
  for f in openForms(): f.fUi.refreshHover()

proc resetModalState*() =
  ## Forgets every modal form and gate (application shutdown).
  for f in gModals:
    f.fModal = false
    f.fOwner = nil
  gModals.setLen 0
  gGates = 0
  gActive = nil

func modalOwner*(f: Form): Form = f.fOwner
  ## The form a modal form is owned by (set by `showModal`), else nil.

func ui*(f: Form): UiRoot = f.fUi
func ctx*(f: Form): RenderContext = f.fUi.ctx
func win*(f: Form): PlatformWindow = f.fUi.win
func hasWindow*(f: Form): bool = f.fUi.win != nil

# ------------------------------------------------------------ construction

proc initForm*(f: Form, owner: Component = nil) =
  ## For subclass constructors.
  f.initContainer(owner)
  f.fUi = newUiRoot(f)
  f.fUi.hidden = true
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

method `caption=`*(f: Form, v: string) =
  ## Also sets the window title. (Overrides `Control.caption=`, so it applies
  ## through a `Control` reference too.)
  procCall `caption=`(Control(f), v)
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

func icon*(f: Form): Image = f.fIcon
proc `icon=`*(f: Form, v: Image) =
  ## The window icon (a form file stores its path as `icon = 'images/app.png'`).
  ## Applied to the window when it exists, and again when the form is shown.
  f.fIcon = v
  if f.fUi.win != nil and v != nil: f.fUi.win.setIcon(v)

func keyPreview*(f: Form): bool = f.fUi.keyPreview
proc `keyPreview=`*(f: Form, v: bool) = f.fUi.keyPreview = v

# Overrides of `Control.visible`, `visible=` and `bringToFront` (see
# control.nim): a form shows/hides its window and raises it.
method visible*(f: Form): bool = f.fShown
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

# ------------------------------------------------------------- key handlers

proc addKeyHandler*(f: Form, id: string, hook: KeyHook, onRepeat = true) =
  ## Same as `f.ui.addKeyHandler` (input.nim): one chain per UiRoot, shared by
  ## forms and hosts.
  f.fUi.addKeyHandler(id, hook, onRepeat)

proc removeKeyHandler*(f: Form, id: string) = f.fUi.removeKeyHandler(id)

# ----------------------------------------------------------------- window

proc centerOnOwner(f: Form): bool =
  let o = f.fOwner
  if o != nil and o.fUi.win != nil and f.fUi.win != nil and f.fPosition != poDesigned:
    f.fUi.win.centerOn(o.fUi.win)
    result = true

proc applyPosition(f: Form) =
  let w = f.fUi.win
  if f.centerOnOwner(): return
  case f.fPosition
  of poScreenCenter: w.centerOnScreen()
  of poMainFormCenter:
    if gMainForm != nil and gMainForm != f and gMainForm.fUi.win != nil:
      w.centerOn(gMainForm.fUi.win)
    else: w.centerOnScreen()
  of poDesigned: w.setPosition(int(f.left), int(f.top))

proc applyConstraints(f: Form) =
  let w = f.fUi.win
  if w == nil: return
  let k = f.constraints
  w.setMinSize(k.minWidth, k.minHeight)
  w.setMaxSize(k.maxWidth, k.maxHeight)

method constraintsChanged*(f: Form) =
  f.applyConstraints()

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
  if f.fIcon != nil: w.setIcon(f.fIcon)
  f.applyConstraints()
  f.fUi.useBackbuffer = true      # partial repaints into a persistent target
  gForms.add f
  f.fUi.dirty = true

proc releaseWindow(f: Form) =
  ## Frees renderer-bound resources, then the renderer and window.
  let ui = f.fUi
  if ui.win == nil: return
  if closePopupsProc != nil: closePopupsProc(f)
  ui.cancelInteraction()
  ui.focusControl(nil)
  ui.closeContext()
  ui.win.destroy()
  ui.win = nil
  let i = gForms.find(f)
  if i >= 0: gForms.delete(i)
  if gActive == f: gActive = nil
  if gMainForm == f: gMainForm = nil
  let wasShown = f.fShown
  f.fShown = false
  ui.hidden = true
  if wasShown: Control(f).notifyVisibility()

proc freeWindow*(f: Form) =
  ## Destroys the window without running `close` events (application shutdown).
  releaseWindow(f)

proc syncMetrics*(f: Form) =
  ## Re-reads window size and scale (after a resize/scale event).
  f.fUi.syncMetrics()

proc setForcedScale*(s: float32) =
  ## Forces the render scale (headless testing); 0 restores the real density.
  gForcedScale = s
  for f in gForms:
    let w = f.fUi.win
    if w == nil: continue
    w.forcedScale = s
    w.setLogicalSize(f.width, f.height)   # keep the logical size: the window follows
    f.fUi.syncScale()

proc forcedScale*(): float32 = gForcedScale

method doResize*(f: Form) =
  procCall doResize(Container(f))
  let w = f.fUi.win
  if w != nil:               # a size that came from the window is already there
    let cur = w.logicalSize
    if cur.w != f.width or cur.h != f.height: w.setLogicalSize(f.width, f.height)

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
  f.fUi.hidden = false
  f.fUi.dirty = true
  Control(f).notifyVisibility()
  let h = f.onShow
  try:
    if h != nil: h(f)
  finally:
    discard f.centerOnOwner()    # onShow may have resized the form

proc hide*(f: Form) =
  if not f.fShown: return
  f.fShown = false
  f.fUi.hidden = true
  Control(f).notifyVisibility()
  if closePopupsProc != nil: closePopupsProc(f)
  f.fUi.cancelInteraction()
  if f.fUi.win != nil: f.fUi.win.hide()
  if gActive == f: gActive = nil
  let h = f.onHide
  if h != nil: h(f)

method `visible=`*(f: Form, v: bool) =
  if v: f.show() else: f.hide()

method bringToFront*(f: Form) =
  if f.fUi.win != nil: f.fUi.win.raiseWindow()

proc close*(f: Form) =
  ## Closes the form (see the module comment). No-op while closing or hidden.
  if f.fClosing or not f.fShown: return
  f.fClosing = true
  try:
    var can = true
    let hq = f.onCloseQuery
    if hq != nil: hq(f, can)
    if not can:
      if f.fModal: f.fModalResult = mrNone
      return
    var action = caHide
    let hc = f.onClose
    if hc != nil: hc(f, action)
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
  func usable(o: Form): bool = o != nil and o != f and o.fShown and o.fUi.win != nil
  let parent =                       # active form, else innermost modal, else main
    if usable(gActive): gActive
    elif gModals.len > 0 and usable(gModals[^1]): gModals[^1]
    elif usable(gMainForm): gMainForm
    else: nil
  f.fOwner = parent
  if closePopupsProc != nil: closePopupsProc(nil)   # menus of the form below
  for o in openForms():             # a press that opened the dialog never ends
    if o != f: o.fUi.cancelInteraction()
  f.fModal = true
  gModals.add f
  try:
    if parent != nil and parent.fUi.win != nil: f.fUi.win.setModalFor(parent.fUi.win)
    f.show()
    if modalLoopProc != nil: modalLoopProc(f)
    if f.fModalResult == mrNone: f.fModalResult = mrCancel
    result = f.fModalResult
  finally:
    # always restore the modal state, also when show/onShow/a handler raised
    let i = gModals.find(f)
    if i >= 0: gModals.delete(i)
    f.fModal = false
    f.fOwner = nil
    if f.fUi.win != nil:
      f.fUi.win.clearModal()
      if f.fShown: f.hide()
    f.fModalResult = mrNone
    for o in openForms(): o.fUi.refreshHover()
    if parent != nil and parent.fUi.win != nil: parent.bringToFront()

# --------------------------------------------------------- loop integration

proc windowActivated*(f: Form, active: bool) =
  ## Called by the application for focus gained/lost events.
  f.fUi.setWindowActive(active)
  if active:
    gActive = f
    let h = f.onActivate
    if h != nil: h(f)
  else:
    if gActive == f: gActive = nil
    f.fUi.cancelInteraction()
    let h = f.onDeactivate
    if h != nil: h(f)

proc paintIfDirty*(f: Form): bool =
  ## Layout + paint + present when needed. Returns true if a frame was drawn.
  if not f.fShown or f.fUi.win == nil or not f.fUi.needsPaint: return false
  f.fUi.paintFrame(clear = true, present = true)
  true

proc screenshot*(f: Form, path: string, full = false): bool =
  ## Headless helper: shows the form, lays out, paints one frame (without
  ## presenting) and saves it as a PNG when `path` ends in `.png`, else as a BMP.
  ## The image is the form's backbuffer, so it shows what a window would show:
  ## pending dirty regions are repainted first. `full = true` discards the
  ## backbuffer content and repaints the whole form (a reference image).
  f.show()
  f.syncMetrics()
  if full: f.fUi.invalidateAll()
  f.fUi.paintFrame(clear = true, present = false)
  f.fUi.win.writeImage(path)
