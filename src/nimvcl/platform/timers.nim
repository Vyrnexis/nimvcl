## SDL timers. The SDL callback runs on SDL's timer thread, so it only pushes
## a user event carrying an integer id; the UI thread looks the id up.
##
## A timer posts at most one event at a time: the callback skips the push while
## the previous tick is still unhandled (`ackPlatformTimer` clears the mark), so
## a handler slower than the interval cannot make the event queue grow.

import std/[atomics, tables]
import sdl3 except Color, Cursor
import ./events

type
  TimerSlot = object
    ## Shared (non-GC) memory: the SDL thread reads it.
    id: int                     ## the tag the event carries
    pending: Atomic[bool]       ## an event for this timer is queued or running

var
  slots: Table[uint32, ptr TimerSlot]   # handle -> slot (UI thread only)
  freeSlots: seq[ptr TimerSlot]         # slots of stopped timers, for reuse

proc timerCallback(userdata: pointer, id: TimerID, interval: uint32): uint32 {.cdecl.} =
  let slot = cast[ptr TimerSlot](userdata)
  if not slot.pending.exchange(true):   # no GC memory touched
    pushTimerEvent(slot.id)
  interval                              # repeat

proc startPlatformTimer*(intervalMs: uint32, tag: int): uint32 =
  ## Starts a repeating timer that posts `ekTimer` events with `timerId = tag`.
  ## Returns a handle (0 on failure).
  let slot =
    if freeSlots.len > 0: freeSlots.pop()
    else: cast[ptr TimerSlot](createShared(TimerSlot))
  slot.id = tag
  slot.pending.store(false)
  let h = uint32(addTimer(max(intervalMs, 1'u32), timerCallback, slot))
  if h == 0:
    freeSlots.add slot
    return 0
  slots[h] = slot
  h

proc ackPlatformTimer*(handle: uint32) =
  ## The UI thread is about to handle the timer's event: lets it post the next.
  ## Unknown handles are ignored.
  let slot = slots.getOrDefault(handle)
  if slot != nil: slot.pending.store(false)

proc stopPlatformTimer*(handle: uint32) =
  if handle == 0: return
  discard removeTimer(TimerID(handle))
  var slot: ptr TimerSlot
  if slots.pop(handle, slot):
    # SDL may still run one callback that was under way; it only posts an event
    # for a timer id that is no longer registered, which is ignored
    freeSlots.add slot
