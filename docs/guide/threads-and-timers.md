# Threads and timers

All UI work happens on one thread, the one that calls `Application.run`. Never
touch a control from another thread. Use `Timer` for periodic work and
`runOnUi` / `Application.queue` to send results back from workers.

## Timer

`Timer` (Delphi `TTimer`) calls `onTimer` on the UI thread. It is a
component, not a control.

```nim
var seconds = 0
let clock = newLabel(form, "0", 16, 16)

let tick = newTimer(form, 1000)           # owner, interval in ms
tick.onTimer = proc(sender: Timer) =
  inc seconds
  clock.caption = $seconds
tick.enabled = true                       # starts the timer
```

A new timer is disabled. Set `enabled = true` to start it and `false` to stop it.
`interval` can change while it runs. An enabled timer stays alive through the
registry, so set `enabled = false` (or call `free`) when you are done with it;
freeing the control that owns a timer stops it. Ticks are not queued up: a
handler slower than the interval misses ticks rather than being called back to
back.

See [Timer](../components/timer.md).

## Run code on the UI thread

`runOnUi` is the safe way to report from a worker thread. It moves `data` to the
UI thread and calls a plain top-level proc there.

```nim
import std/os
import nimvcl

var status: Label                          # created on the UI thread

proc showResult(msg: string) =             # runs on the UI thread
  status.caption = msg

proc work() {.thread.} =
  sleep(1500)                              # the long job
  runOnUi("Done!", showResult)

let form = newForm()
status = newLabel(form, "Working...", 16, 16)

var worker: Thread[void]
createThread(worker, work)
Application.run(form)
```

Rules:

* The handler must be a top-level proc (no captured variables).
* The data must be an owned value: string, seq, an object of those.
  For ref graphs wrap them with `isolate(x)` and use `Application.queue`.
* Order is kept per sending thread.

## Application.queue

`Application.queue` is the general form (Delphi `TThread.Queue`). It is the
only thread-safe entry point of the library.

| Call | Use |
|---|---|
| `queue(data, handler)` | `handler(data)` runs on the UI thread; `handler` is `proc(data: T) {.nimcall.}` |
| `queue(isolate(x), handler)` | Same for ref graphs |
| `queue(handler)` | A plain `proc() {.nimcall.}` with no data |
| `queue(p: QueuedProc)` | A closure; see the caveat below |

From a worker thread you need `{.cast(gcsafe).}` around `Application.queue`,
because `Application` is a global. `runOnUi` has that built in, so prefer it.

Closure caveat: with ORC, a closure whose environment is shared by two threads
corrupts the cycle collector. Build the closure in a small helper proc and pass
the result straight in:

```nim
proc job(v: int): QueuedProc =
  result = proc() = echo v
Application.queue(job(42))
```

## Idle work

`Application.onIdle` runs after each batch of events, and
`Application.addIdleHook(id, hook)` adds named hooks. Both run on the UI
thread, only when events happened. For a long job on the UI thread, call
`Application.processMessages()` now and then. Prefer a worker thread.

[Back to the index](../README.md)
