# ProgressBar

Shows how far a task has come (Delphi `TProgressBar`), or that something is
happening when you do not know how long it takes.

## Quick example

```nim
let bar = newProgressBar(form, 16, 16, 260, 18)
bar.max = 100
bar.step = 10

let timer = newTimer(form, 300)
timer.onTimer = proc(sender: Timer) =
  bar.stepIt()                            # position += step
  if bar.position >= bar.max: timer.enabled = false
timer.enabled = true

let busy = newProgressBar(form, 16, 48, 260, 18)
busy.style = pbsMarquee                   # indeterminate
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `position` | int | Current value |
| `min`, `max` | int | Range (default 0..100) |
| `step` | int | Amount added by `stepIt` (default 10) |
| `style` | `ProgressStyle` | `pbsNormal` or `pbsMarquee` (sliding block) |
| `orientation` | `Orientation` | `orHorizontal` or `orVertical` |
| `fraction` | float32 | `position` as 0..1 (read-only) |
| `color` | Color | Own background: the track; the bar stays `theme.accent`. Set it and `parentColor` turns off |
| `font.color` | Color | Text color (VCL `Font.Color`); alpha 0 (the default) uses the theme's text color. `fontColor` is a shortcut |

## Events

| Event | Description |
|---|---|
| `onChange` | `position` changed |

## Methods

| Method | Description |
|---|---|
| `stepIt()` | Advance by `step` |
| `stepBy(delta)` | Advance by any amount |

## Tips

* Set `position` only from the UI thread. From a worker, use
  [`runOnUi`](../guide/threads-and-timers.md).
* The marquee runs only while the bar is visible and costs nothing otherwise.
* `position` is clamped to `min .. max`.

[Back to the index](../README.md)
