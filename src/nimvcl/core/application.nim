## `Application`: the global event loop, form registry and cross-thread queue.
##
## Loop (`run`): paint dirty forms, block in `waitEvent` (zero CPU while
## idle), dispatch it, drain the rest of the queue with `pollEvent`, run
## queued procs, `onIdle`, repeat. `showModal` runs the same loop nested.
##
## `queue` is the only thread-safe entry point (like TThread.Queue): work runs
## later on the UI thread, in the order it was queued by each thread. Prefer the
## two overloads that cannot be misused:
##
## ```nim
## proc show(msg: string) = echo msg          # a plain top-level proc
## # in any worker thread:
## runOnUi("done", show)                      # data is moved to the UI thread
## ```
##
## `runOnUi` is the gcsafe free-proc form of the two `queue` overloads below;
## use it from workers so no `{.cast(gcsafe).}` is needed.
##
## * `queue(a, data, handler)`: `data` is moved into a heap box and handed to
##   `handler(data)` on the UI thread. `handler` is a `{.nimcall.}` proc, so it
##   has no captured environment to share between threads. Give it an owned
##   value (string, seq, object of those) or an `Isolated[T]` (`isolate(x)`) for
##   ref graphs. Do not pass refs that the worker keeps using.
## * `queue(a, handler)`: the same without data.
##
## The closure overload `queue(a, p: QueuedProc)` is only for closures that
## are created by a helper proc and passed straight in (see below), and for
## calls made on the UI thread itself.
##
## ORC caveat for closures: an environment that is reference-counted on two
## threads corrupts the cycle collector's per-thread root table. A closure
## literal written inside a worker proc shares its environment with that proc's
## frame, which is exactly that case. So build the closure in a small helper
## that returns it, and pass the result straight to `queue` (taken by move):
##
## ```nim
## proc job(v: int): QueuedProc = result = proc() = show(v)
## Application.queue(job(42))
## ```

import std/[locks, isolation]
import ../platform/[events, cursors, sdlutil]
import ./theme, ./control, ./form, ./timer, ./input

type
  TApplication* = ref object
    terminated: bool
    initialised: bool
    onIdle*: proc()                       ## after each batch of events, before blocking
    onException*: proc(e: ref Exception)  ## handler errors; default re-raises

  QueuedProc* = proc() {.closure, gcsafe.}

  Job = object
    ## One queued unit of work: a closure, a plain proc, or boxed data plus the
    ## typed trampoline that unboxes it and calls the handler.
    closure: QueuedProc
    plain: proc() {.nimcall.}
    run: proc(box, handler: pointer) {.nimcall.}
    box, handler: pointer

var
  Application* = TApplication()           ## the singleton
  queueLock: Lock
  queued: seq[Job]

initLock(queueLock)

proc init*(a: TApplication) =
  ## Initialises SDL, SDL_ttf and the user event types and clears a pending
  ## `terminate` (idempotent otherwise; `Form` and `Timer` also initialise SDL
  ## on demand).
  initPlatform()
  a.initialised = true
  a.terminated = false

proc forms*(a: TApplication): seq[Form] = openForms()
proc mainForm*(a: TApplication): Form = form.mainForm()
proc `mainForm=`*(a: TApplication, f: Form) = setMainForm(f)
proc activeForm*(a: TApplication): Form = form.activeForm()
proc terminated*(a: TApplication): bool = a.terminated

proc terminate*(a: TApplication) =
  ## Ends `run` (and any modal loop) after the current event.
  a.terminated = true
  pushWake()

# ------------------------------------------------------------- theme etc.

proc theme*(a: TApplication): Theme = currentTheme()
proc `theme=`*(a: TApplication, t: Theme) =
  ## Switches the global theme and repaints every form.
  setTheme(t)
  for f in openForms():
    f.relayoutAll()
    f.invalidate()

proc forceScale*(a: TApplication): float32 = forcedScale()
proc `forceScale=`*(a: TApplication, s: float32) =
  ## Forces the display scale (headless testing; 0 = real density). Affects
  ## windows created afterwards and re-syncs open ones.
  setForcedScale(s)

proc clipboard*(a: TApplication): string = getClipboard()
proc `clipboard=`*(a: TApplication, text: string) = discard setClipboard(text)

# ---------------------------------------------------------------- queueing

proc push(j: sink Job) =
  {.cast(gcsafe).}:
    withLock queueLock:
      queued.add j
  pushWake()

proc queue*(a: TApplication, p: sink QueuedProc) =
  ## Runs `p` on the UI thread later. Safe to call from any thread; wakes the
  ## loop. Only for closures created via helper procs (see the module comment)
  ## or called on the UI thread; from workers prefer the `data, handler` form.
  push Job(closure: move(p))

proc queue*(a: TApplication, handler: proc() {.nimcall.}) =
  ## Runs the plain proc `handler` on the UI thread later. Thread-safe.
  push Job(plain: handler)

proc trampoline[T](box, handler: pointer) {.nimcall.} =
  let b = cast[ptr T](box)
  let h = cast[proc(data: T) {.nimcall.}](handler)
  var data = move b[]
  `=destroy`(b[])
  deallocShared(box)
  h(data)

proc queue*[T](a: TApplication, data: sink T, handler: proc(data: T) {.nimcall.}) =
  ## Moves `data` to the UI thread and calls `handler(data)` there. Thread-safe.
  ## `data` must own what it references (see the module comment); `handler`
  ## cannot capture anything, so nothing else is shared between the threads.
  let box = cast[ptr T](allocShared0(sizeof(T)))
  box[] = move data
  push Job(run: trampoline[T], box: box, handler: cast[pointer](handler))

proc queue*[T](a: TApplication, data: sink Isolated[T],
               handler: proc(data: T) {.nimcall.}) =
  ## Like the plain `data` overload for an isolated ref graph.
  a.queue(extract(data), handler)

proc runOnUi*(handler: proc() {.nimcall.}) {.gcsafe.} =
  ## Same as `Application.queue(handler)`, callable from worker threads
  ## without `{.cast(gcsafe).}` (it does not touch the `Application` global).
  push Job(plain: handler)

proc runOnUi*[T](data: sink T, handler: proc(data: T) {.nimcall.}) {.gcsafe.} =
  ## Same as `Application.queue(data, handler)`, callable from worker threads
  ## without `{.cast(gcsafe).}`.
  let box = cast[ptr T](allocShared0(sizeof(T)))
  box[] = move data
  push Job(run: trampoline[T], box: box, handler: cast[pointer](handler))

proc handleError(a: TApplication, e: ref Exception) =
  if a.onException != nil: a.onException(e) else: raise e

proc runQueued(a: TApplication) =
  var batch: seq[Job]
  {.cast(gcsafe).}:
    withLock queueLock:
      swap(batch, queued)
  for j in batch:
    try:
      if j.run != nil: j.run(j.box, j.handler)
      elif j.plain != nil: j.plain()
      elif j.closure != nil: j.closure()
    except CatchableError as e: a.handleError(e)

# ---------------------------------------------------------------- dispatch

proc dispatch*(a: TApplication, pe: PlatformEvent) =
  ## Routes one translated event to its form (the loop's single entry point).
  case pe.kind
  of ekNone, ekWake: discard
  of ekQuit: a.terminate()
  of ekTimer: discard dispatchTimer(pe.timerId)
  else:
    let f = findForm(pe.windowId)
    if f == nil: return
    case pe.kind
    of ekWindowClose:
      if f.acceptsInput: f.close()
    of ekWindowFocusGained: f.windowActivated(true)
    of ekWindowFocusLost:
      f.windowActivated(false)
    of ekMouseMove, ekMouseDown, ekMouseUp, ekMouseWheel, ekKeyDown, ekKeyUp,
       ekTextInput, ekTextEditing, ekWindowMouseLeave:
      if f.acceptsInput: discard f.ui.handle(pe)
      elif pe.kind == ekWindowMouseLeave: discard f.ui.handle(pe)
    of ekWindowResized, ekWindowPixelSize, ekWindowScale:
      f.syncMetrics()
    else: discard f.ui.handle(pe)

proc dispatchEvent*(a: TApplication, ev: var Event) =
  ## Translates and dispatches a raw SDL event; the same path the loop uses.
  a.dispatch(translate(ev))

proc paintForms*(a: TApplication) =
  for f in openForms(): discard f.paintIfDirty()

proc safeDispatch(a: TApplication, pe: PlatformEvent) =
  try: a.dispatch(pe)
  except CatchableError as e: a.handleError(e)

proc pump(a: TApplication, timeoutMs: int) =
  ## Waits up to `timeoutMs` (-1 = forever) for one event, drains the pending
  ## ones, runs queued procs and the idle hook.
  var pe: PlatformEvent
  if waitPlatformEvent(pe, timeoutMs):
    a.safeDispatch(pe)
    while pollPlatformEvent(pe): a.safeDispatch(pe)
  a.runQueued()
  if a.onIdle != nil:
    try: a.onIdle()
    except CatchableError as e: a.handleError(e)

proc processMessages*(a: TApplication, timeoutMs = 0) =
  ## Handles pending events and queued procs, then paints dirty forms. Waits up
  ## to `timeoutMs` for the first event (0 = do not wait).
  a.pump(timeoutMs)
  a.paintForms()

# ------------------------------------------------------------ run / modal

proc shutdown*(a: TApplication) =
  ## Frees every form (renderer-bound resources first), stops timers, quits
  ## SDL_ttf and SDL. A later `init` starts them again.
  stopAllTimers()
  for f in openForms(): f.freeWindow()
  freeCursors()
  setMainForm(nil)
  quitPlatform()
  a.initialised = false

proc run*(a: TApplication, mainForm: Form = nil) =
  ## Shows `mainForm` (if given) and runs the loop until `terminate` or the
  ## main form closes; then shuts down.
  a.init()
  a.terminated = false
  if mainForm != nil:
    setMainForm(mainForm)
    mainForm.show()
  while not a.terminated and openForms().len > 0:
    a.paintForms()
    a.pump(-1)
  a.shutdown()

proc modalLoop(f: Form) =
  let a = Application
  while f.visible and not a.terminated:
    if f.modalResult != mrNone:
      f.close()          # runs the close handlers; may veto (result reset)
      continue
    a.paintForms()
    a.pump(-1)
  if a.terminated and f.visible:
    f.modalResult = mrCancel

modalLoopProc = modalLoop
terminateProc = proc() = Application.terminate()
