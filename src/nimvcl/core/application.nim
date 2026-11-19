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
import ./theme, ./control, ./form, ./timer, ./input, ./popup
export popup

type
  TApplication* = ref object
    terminated: bool
    onIdle*: proc()                       ## after each batch of events, before blocking
    onException*: proc(e: ref Exception)  ## handler errors; default re-raises
    idleHooks: seq[tuple[id: string, hook: proc()]]

  EventObserver* = proc(f: Form, pe: PlatformEvent)
    ## Sees every event after it was routed. `f` is the form it belongs to (the
    ## owner for popup windows), nil for events of no form. Used by hints and
    ## menus; must not raise.

  QueuedProc* = proc() {.closure, gcsafe.}

  Job = object
    ## One queued unit of work: a closure, a plain proc, or boxed data plus the
    ## typed trampoline that unboxes it and calls the handler.
    closure: QueuedProc
    plain: proc() {.nimcall.}
    run: proc(box, handler: pointer) {.nimcall.}
    box, handler: pointer
    drop: proc(box: pointer) {.nimcall.}   ## frees `box` without running the handler

var
  Application* = TApplication()           ## the singleton
  queueLock: Lock
  queued: seq[Job]
  observers: seq[EventObserver]
  notifying = 0                 ## `notify` calls in progress

initLock(queueLock)

proc init*(a: TApplication) =
  ## Initialises SDL, SDL_ttf and the user event types and clears a pending
  ## `terminate` (idempotent otherwise; `Form` and `Timer` also initialise SDL
  ## on demand).
  initPlatform()
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
  ## windows created afterwards; open windows are re-synced (their logical size
  ## is kept, the window and the render scale follow).
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

proc dropBox[T](box: pointer) {.nimcall.} =
  let b = cast[ptr T](box)
  `=destroy`(b[])
  deallocShared(box)

proc queue*[T](a: TApplication, data: sink T, handler: proc(data: T) {.nimcall.}) =
  ## Moves `data` to the UI thread and calls `handler(data)` there. Thread-safe.
  ## `data` must own what it references (see the module comment); `handler`
  ## cannot capture anything, so nothing else is shared between the threads.
  let box = cast[ptr T](allocShared0(sizeof(T)))
  box[] = move data
  push Job(run: trampoline[T], box: box, handler: cast[pointer](handler),
           drop: dropBox[T])

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
  push Job(run: trampoline[T], box: box, handler: cast[pointer](handler),
           drop: dropBox[T])

proc handleError(a: TApplication, e: ref Exception) =
  let h = a.onException
  if h != nil: h(e) else: raise e

proc runQueued(a: TApplication) =
  ## Runs the queued jobs. A job that raises goes to `handleError` and the
  ## others still run; when `handleError` re-raises (the default), the jobs not
  ## run yet are put back at the front of the queue for the next round.
  var batch: seq[Job]
  {.cast(gcsafe).}:
    withLock queueLock:
      swap(batch, queued)
  var i = 0
  try:
    while i < batch.len:
      var j = move batch[i]
      inc i
      try:
        if j.run != nil: j.run(j.box, j.handler)
        elif j.plain != nil: j.plain()
        elif j.closure != nil: j.closure()
      except CatchableError as e: a.handleError(e)
  finally:
    if i < batch.len:
      {.cast(gcsafe).}:
        withLock queueLock:
          var rest = batch[i .. ^1]
          rest.add queued          # keep the order: leftovers first
          queued = move rest
      pushWake()

proc dropQueued() =
  ## Discards the queued jobs, freeing the data boxed for the UI thread.
  var batch: seq[Job]
  {.cast(gcsafe).}:
    withLock queueLock:
      swap(batch, queued)
  for j in batch:
    if j.box != nil and j.drop != nil: j.drop(j.box)

# ---------------------------------------------------------------- dispatch

proc addEventObserver*(a: TApplication, o: EventObserver) =
  ## Registers a function that is called after each dispatched window event.
  observers.add o

proc removeEventObserver*(a: TApplication, o: EventObserver) =
  ## Unregisters an observer added with `addEventObserver` (the same proc value);
  ## no effect when it is not registered. An observer may remove itself.
  let i = observers.find(o)
  if i < 0: return
  if notifying > 0: observers[i] = nil       # compacted when the notification ends
  else: observers.delete i

proc notify(f: Form, pe: PlatformEvent) =
  if f != nil:                   # Alt state, also for keys that went to a popup
    case pe.kind
    of ekKeyDown:
      if pe.key == keyLAlt or pe.key == keyRAlt: f.ui.setAlt(true)
    of ekKeyUp:
      if pe.key == keyLAlt or pe.key == keyRAlt: f.ui.setAlt(false)
    of ekWindowFocusLost: f.ui.setAlt(false)
    else: discard
  inc notifying
  try:
    for i in 0 ..< observers.len:       # (an observer added meanwhile waits for the next event)
      let o = observers[i]
      if o != nil: o(f, pe)
  finally:
    dec notifying
    if notifying == 0:
      for i in countdown(observers.high, 0):
        if observers[i] == nil: observers.delete i

proc dispatch*(a: TApplication, pe: PlatformEvent) =
  ## Routes one translated event to its form (the loop's single entry point).
  case pe.kind
  of ekNone, ekWake: discard
  of ekQuit:                    # SIGINT/SIGTERM: ask like a click on the close box
    let m = mainForm()
    if m != nil and m.visible and m.acceptsInput: m.close()
    else: a.terminate()
  of ekTimer: discard dispatchTimer(pe.timerId)
  of ekRenderReset:
    for f in openForms(): f.ui.resetBackbuffer()   # contents lost: repaint fully
  else:
    let po = popupOwnerOf(pe.windowId)
    if handlePopupEvent(pe):
      notify(if po != nil: po else: findForm(pe.windowId), pe)
      return
    let f = findForm(pe.windowId)
    if f == nil: return
    defer: notify(f, pe)
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

proc popupPaintFailed(e: ref CatchableError) =
  Application.handleError(e)

proc paintForms*(a: TApplication) =
  ## Paints the dirty forms and popups. A failure in layout or paint goes to
  ## `onException` like an event handler error (re-raised by default).
  for f in openForms():
    try: discard f.paintIfDirty()
    except CatchableError as e: a.handleError(e)
  paintPopups(popupPaintFailed)

proc safeDispatch(a: TApplication, pe: PlatformEvent) =
  try: a.dispatch(pe)
  except CatchableError as e: a.handleError(e)

proc addIdleHook*(a: TApplication, id: string, hook: proc()) =
  ## Registers `hook` to run, like `onIdle`, after each batch of events (once per
  ## wake-up of the loop, never continuously). Same `id` replaces. Used by
  ## actions (`onUpdate`).
  for h in a.idleHooks.mitems:
    if h.id == id:
      h.hook = hook
      return
  a.idleHooks.add (id, hook)

proc removeIdleHook*(a: TApplication, id: string) =
  for i in 0 ..< a.idleHooks.len:
    if a.idleHooks[i].id == id:
      a.idleHooks.delete(i)
      return

proc pump(a: TApplication, timeoutMs: int) =
  ## Waits up to `timeoutMs` (-1 = forever) for one event, drains the pending
  ## ones, runs queued procs and the idle hook.
  var pe: PlatformEvent
  if waitPlatformEvent(pe, timeoutMs):
    a.safeDispatch(pe)
    while pollPlatformEvent(pe): a.safeDispatch(pe)
  a.runQueued()
  let idle = a.onIdle           # copies: a hook may change `onIdle` or the hook list
  if idle != nil:
    try: idle()
    except CatchableError as e: a.handleError(e)
  let hooks = a.idleHooks
  for h in hooks:
    try: h.hook()
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
  closeAllPopups(nil)
  for f in openForms(): f.freeWindow()
  freeCursors()
  setMainForm(nil)
  resetModalState()
  dropQueued()
  quitPlatform()

proc run*(a: TApplication, mainForm: Form = nil) =
  ## Shows `mainForm` (if given) and runs the loop until `terminate` or the
  ## main form closes; then shuts down.
  a.init()
  a.terminated = false
  try:
    if mainForm != nil:
      setMainForm(mainForm)
      mainForm.show()
    let hooks = a.idleHooks
    for h in hooks:                   # initial action state before the first frame
      try: h.hook()
      except CatchableError as e: a.handleError(e)
    while not a.terminated and openForms().len > 0:
      a.paintForms()
      a.pump(-1)
  finally:
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


proc runModalLoop*(until: proc(): bool) =
  ## Runs a nested event loop (painting, dispatching, queued procs) until
  ## `until()` returns true or the application terminates. Input of every form
  ## is gated meanwhile (`beginModalState`); popups close. Use it to wait for
  ## something that has no form of its own, such as a native file dialog.
  ## `until` is checked after every batch of events; something must wake the
  ## loop (an event or `runOnUi`/`queue`) when it becomes true.
  let a = Application
  beginModalState()
  try:
    while not until() and not a.terminated:
      a.paintForms()
      a.pump(-1)
  finally:
    endModalState()
