## Platform events: SDL events translated into nimvcl-level events, plus the
## SDL init/quit lifecycle and the event pump. Only `platform/` and `graphics/`
## import sdl3.
##
## Coordinates in a `PlatformEvent` are WINDOW POINTS (what SDL reports); the
## input router converts them to logical pixels (they differ only when a scale
## is forced for headless testing).

import sdl3 except Color, Cursor
import ../core/types
import ./sdlutil

export sdl3.Event

type
  EventKind* = enum
    ekNone,            ## an event nimvcl does not care about
    ekQuit, ekWake, ekTimer,
    ekMouseMove, ekMouseDown, ekMouseUp, ekMouseWheel,
    ekKeyDown, ekKeyUp, ekTextInput, ekTextEditing,
    ekWindowClose, ekWindowResized, ekWindowPixelSize, ekWindowScale,
    ekWindowExposed, ekWindowShown, ekWindowHidden, ekWindowMoved,
    ekWindowMouseLeave, ekWindowFocusGained, ekWindowFocusLost

  PlatformEvent* = object
    kind*: EventKind
    windowId*: uint32       ## 0 for events that belong to no window
    x*, y*: float32         ## mouse position (window points)
    dx*, dy*: float32       ## wheel delta
    button*: MouseButton
    clicks*: int            ## 1 single, 2 double click
    shift*: ShiftState      ## keyboard modifiers (+ mouse buttons for motion)
    key*: Key
    repeat*: bool
    text*: string           ## ekTextInput, ekTextEditing
    editStart*, editLength*: int  ## ekTextEditing: selected part of the composition (characters; start -1 = no cursor)
    timerId*: int           ## ekTimer

var
  evWake, evTimer: uint32   # registered user event types (0 until initEvents)
  sdlInitialised = false
  ttfInitialised = false

proc ensureTtf*() =
  ## Initialises SDL_ttf once (a host app may already have done so; that is fine).
  if not ttfInitialised:
    if not initTtf(): raise newException(IOError, "TTF_Init: " & sdlError())
    ttfInitialised = true

proc initPlatform*() =
  ## Idempotent: SDL video + events, SDL_ttf, the user event types.
  if sdlInitialised: return
  discard setHint(HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0")  # the Application decides
  if not initSdl(): raise newException(IOError, "SDL_Init: " & sdlError())
  sdlInitialised = true
  ensureTtf()
  let base = registerEvents(2)
  if base == 0'u32: raise newException(IOError, "registerEvents: " & sdlError())
  evWake = base
  evTimer = base + 1

proc quitPlatform*() =
  ## Quits SDL_ttf and SDL; a later `initPlatform` starts them again.
  if ttfInitialised:
    quitTtf()
    ttfInitialised = false
  if sdlInitialised:
    quitSdl()
    sdlInitialised = false
    evWake = 0
    evTimer = 0

proc isPlatformInitialised*(): bool = sdlInitialised

proc pushUser(kind: uint32, data: int) =
  ## Thread safe. Allocates no GC memory (also called from SDL's timer thread).
  if kind == 0: return
  var ev: Event
  ev.user.`type` = kind
  ev.user.data1 = cast[pointer](data)
  discard pushEvent(ev)

proc pushWake*() =
  ## Wakes a blocked `waitPlatformEvent`. Safe from any thread.
  {.cast(gcsafe).}:
    pushUser(evWake, 0)

proc pushTimerEvent*(id: int) =
  ## Safe from any thread (used by the SDL timer callback).
  {.cast(gcsafe).}:
    pushUser(evTimer, id)

# ---------------------------------------------------------------- translate

proc modsToShift*(m: uint32): ShiftState =
  if (m and KMOD_SHIFT) != 0: result.incl ssShift
  if (m and KMOD_CTRL) != 0: result.incl ssCtrl
  if (m and KMOD_ALT) != 0: result.incl ssAlt
  if (m and KMOD_GUI) != 0: result.incl ssSuper

proc buttonsToShift(b: uint32): ShiftState =
  if (b and BUTTON_LMASK) != 0: result.incl ssLeft
  if (b and BUTTON_RMASK) != 0: result.incl ssRight
  if (b and BUTTON_MMASK) != 0: result.incl ssMiddle

proc mapButton(b: uint8): MouseButton =
  case b
  of 1: mbLeft
  of 2: mbMiddle
  of 3: mbRight
  of 4: mbX1
  else: mbX2

proc translate*(ev: Event): PlatformEvent =
  ## Translates one SDL event. The kind is read as `common.type` (uint32) so
  ## registered user events do not become invalid enum values.
  let t = ev.common.`type`
  if evWake != 0 and t == evWake: return PlatformEvent(kind: ekWake)
  if evTimer != 0 and t == evTimer:
    return PlatformEvent(kind: ekTimer, timerId: cast[int](ev.user.data1))
  template simple(k: EventKind): PlatformEvent =
    PlatformEvent(kind: k, windowId: ev.window.windowID)
  if t == uint32(EVENT_QUIT): return PlatformEvent(kind: ekQuit)
  elif t == uint32(EVENT_MOUSE_MOTION):
    let m = ev.motion
    return PlatformEvent(kind: ekMouseMove, windowId: m.windowID, x: m.x, y: m.y,
      shift: modsToShift(uint32(getModState())) + buttonsToShift(m.state))
  elif t == uint32(EVENT_MOUSE_BUTTON_DOWN) or t == uint32(EVENT_MOUSE_BUTTON_UP):
    let b = ev.button
    return PlatformEvent(
      kind: (if t == uint32(EVENT_MOUSE_BUTTON_DOWN): ekMouseDown else: ekMouseUp),
      windowId: b.windowID, x: b.x, y: b.y, button: mapButton(b.button),
      clicks: int(b.clicks), shift: modsToShift(uint32(getModState())))
  elif t == uint32(EVENT_MOUSE_WHEEL):
    let w = ev.wheel
    return PlatformEvent(kind: ekMouseWheel, windowId: w.windowID,
      x: w.mouse_x, y: w.mouse_y, dx: w.x, dy: w.y,
      shift: modsToShift(uint32(getModState())))
  elif t == uint32(EVENT_KEY_DOWN) or t == uint32(EVENT_KEY_UP):
    let k = ev.key
    return PlatformEvent(
      kind: (if t == uint32(EVENT_KEY_DOWN): ekKeyDown else: ekKeyUp),
      windowId: k.windowID, key: Key(k.key), repeat: k.repeat,
      shift: modsToShift(uint32(k.`mod`)))
  elif t == uint32(EVENT_TEXT_INPUT):
    let s = if ev.text.text == nil: "" else: $ev.text.text
    return PlatformEvent(kind: ekTextInput, windowId: ev.text.windowID, text: s)
  elif t == uint32(EVENT_TEXT_EDITING):
    let e = ev.edit
    return PlatformEvent(kind: ekTextEditing, windowId: e.windowID,
      text: (if e.text == nil: "" else: $e.text),
      editStart: int(e.start), editLength: int(e.length))
  elif t == uint32(EVENT_WINDOW_CLOSE_REQUESTED): return simple(ekWindowClose)
  elif t == uint32(EVENT_WINDOW_RESIZED): return simple(ekWindowResized)
  elif t == uint32(EVENT_WINDOW_PIXEL_SIZE_CHANGED): return simple(ekWindowPixelSize)
  elif t == uint32(EVENT_WINDOW_DISPLAY_SCALE_CHANGED): return simple(ekWindowScale)
  elif t == uint32(EVENT_WINDOW_EXPOSED): return simple(ekWindowExposed)
  elif t == uint32(EVENT_WINDOW_SHOWN): return simple(ekWindowShown)
  elif t == uint32(EVENT_WINDOW_HIDDEN): return simple(ekWindowHidden)
  elif t == uint32(EVENT_WINDOW_MOVED): return simple(ekWindowMoved)
  elif t == uint32(EVENT_WINDOW_MOUSE_LEAVE): return simple(ekWindowMouseLeave)
  elif t == uint32(EVENT_WINDOW_FOCUS_GAINED): return simple(ekWindowFocusGained)
  elif t == uint32(EVENT_WINDOW_FOCUS_LOST): return simple(ekWindowFocusLost)
  PlatformEvent(kind: ekNone)

# --------------------------------------------------------------------- pump

proc waitPlatformEvent*(pe: var PlatformEvent, timeoutMs = -1): bool =
  ## Blocks for the next event (forever when `timeoutMs` < 0). False on timeout.
  var ev: Event
  let ok = if timeoutMs < 0: waitEvent(ev) else: waitEventTimeout(ev, int32(timeoutMs))
  if not ok: return false
  pe = translate(ev)
  true

proc pollPlatformEvent*(pe: var PlatformEvent): bool =
  ## Next pending event without blocking; false when the queue is empty.
  var ev: Event
  if not pollEvent(ev): return false
  pe = translate(ev)
  true

proc pushPlatformEvent*(ev: var Event): bool =
  ## Pushes a raw SDL event (tests).
  pushEvent(ev)
