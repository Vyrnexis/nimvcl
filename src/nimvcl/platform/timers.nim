## SDL timers. The SDL callback runs on SDL's timer thread, so it only pushes
## a user event carrying an integer id; the UI thread looks the id up.

import sdl3 except Color, Cursor
import ./events

proc timerCallback(userdata: pointer, id: TimerID, interval: uint32): uint32 {.cdecl.} =
  pushTimerEvent(cast[int](userdata))   # no GC memory touched
  interval                              # repeat

proc startPlatformTimer*(intervalMs: uint32, tag: int): uint32 =
  ## Starts a repeating timer that posts `ekTimer` events with `timerId = tag`.
  ## Returns a handle (0 on failure).
  uint32(addTimer(max(intervalMs, 1'u32), timerCallback, cast[pointer](tag)))

proc stopPlatformTimer*(handle: uint32) =
  if handle != 0: discard removeTimer(TimerID(handle))
