## `Timer`: periodic `onTimer` on the UI thread.
##
## SDL's timer thread only pushes a user event with an integer id; the id is
## looked up here on the UI thread. An enabled timer is kept alive by the
## registry: set `enabled = false` (or call `free`) when done with it.

import std/tables
import ../platform/[events, timers]
import ./component

type
  Timer* = ref object of Component
    fInterval: int
    fEnabled: bool
    fId: int
    fHandle: uint32
    onTimer*: TimerEvent

  TimerEvent* = proc(sender: Timer)

var
  registry: Table[int, Timer]
  nextId = 1
  startTimerImpl*: proc(intervalMs: uint32, tag: int): uint32 = startPlatformTimer
    ## Test seam: replaces `startPlatformTimer`.

proc stop(t: Timer) =
  if t.fHandle != 0:
    stopPlatformTimer(t.fHandle)
    t.fHandle = 0
  if t.fId != 0:
    registry.del t.fId
    t.fId = 0

proc start(t: Timer) =
  t.stop()
  initPlatform()
  t.fId = nextId
  inc nextId
  t.fHandle = startTimerImpl(uint32(max(t.fInterval, 1)), t.fId)
  if t.fHandle == 0:
    t.fId = 0
    raise newException(IOError, "SDL_AddTimer failed")
  registry[t.fId] = t

proc newTimer*(owner: Component = nil, interval = 1000): Timer {.discardable.} =
  new result
  result.initComponent(owner)
  result.fInterval = interval

func interval*(t: Timer): int = t.fInterval
proc `interval=`*(t: Timer, ms: int) =
  if ms == t.fInterval: return
  t.fInterval = ms
  if t.fEnabled:
    try: t.start()
    except CatchableError:
      t.fEnabled = false
      raise

func enabled*(t: Timer): bool = t.fEnabled
proc `enabled=`*(t: Timer, v: bool) =
  if v == t.fEnabled: return
  if v:
    t.start()              # raises when SDL fails: the timer stays disabled
    t.fEnabled = true
  else:
    t.fEnabled = false
    t.stop()

proc free*(t: Timer) =
  ## Disables the timer and drops it from the registry.
  t.enabled = false

proc dispatchTimer*(id: int): bool =
  ## Runs the handler of timer `id` (UI thread). False when it is unknown
  ## (already disabled).
  let t = registry.getOrDefault(id)
  if t == nil: return false
  let h = t.onTimer       # copy: the handler may clear or replace itself
  if h != nil: h(t)
  true

proc stopAllTimers*() =
  ## Cancels every running timer (application shutdown).
  var all: seq[Timer]
  for _, t in registry.pairs: all.add t
  for t in all:
    t.fEnabled = false
    t.stop()
