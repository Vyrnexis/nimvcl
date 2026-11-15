# StatusBar

A bar of text panels at the bottom of a window (Delphi `TStatusBar`).

## Quick example

```nim
let status = newStatusBar(form)           # alBottom by default
let msg = status.addPanel("Ready", 220)
let pos = status.addPanel("Ln 1, Col 1", 120, taRight)
status.sizeGrip = true

msg.text = "Saved"                        # panels repaint themselves
pos.text = "Ln 4, Col 12"
```

For a single line:

```nim
let simple = newStatusBar(form, "Ready")  # simpleText
simple.simpleText = "Done"
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `panels` | `seq[StatusPanel]` | The panels. Each has `text`, `width`, `alignment` |
| `simplePanel` | bool | Show `simpleText` instead of the panels |
| `simpleText` | string | The one-line text |
| `sizeGrip` | bool | Draw the resize grip bottom-right |

## Events

Only the common ones (`onClick`, mouse events).

## Methods

| Method | Description |
|---|---|
| `addPanel(text = "", width = 100, alignment = taLeft)` | Append and return a `StatusPanel` |
| `clearPanels()` | Remove all panels |
| `panelRect(i)` | Panel rectangle in client coordinates |

## Tips

* The last panel takes all the space that is left. Its `width` is ignored.
* Keep the `StatusPanel` returned by `addPanel`; setting its `text` is enough to update.
* Setting `simpleText` (or passing it to `newStatusBar`) switches to simple mode.

[Back to the index](../README.md)
