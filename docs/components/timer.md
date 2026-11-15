# Timer

Calls `onTimer` at an interval on the UI thread (Delphi `TTimer`). It is a
component: it has an owner, not a parent.

## Quick example

```nim
let clock = newLabel(form, "", 16, 16, 200)
let tick = newTimer(form, 1000)                  # owner, interval in ms
tick.onTimer = proc(sender: Timer) =
  clock.caption = "tick"
tick.enabled = true                              # a new timer is off
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `interval` | int | Milliseconds between ticks (default 1000). Changing it while running restarts the timer |
| `enabled` | bool | Start and stop |

## Events

| Event | Description |
|---|---|
| `onTimer(sender: Timer)` | A tick, on the UI thread |

## Methods

| Method | Description |
|---|---|
| `free()` | Disable it and drop it from the registry |

## Tips

* An enabled timer is kept alive by the library. Disable or `free` it when done,
  for example when a form closes.
* Ticks are delivered through the event loop, so a long handler delays everything.
  Do not start a job that outlasts the interval.
* A debounce is a timer you restart on each keystroke, then disable inside
  `onTimer`.
* Timers also work in host mode.
* Background threads: see [Threads and timers](../guide/threads-and-timers.md).

[Back to the index](../README.md)
