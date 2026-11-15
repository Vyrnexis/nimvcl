# Theming

Controls never use hard-coded colors. They read tokens from a `Theme`. nimvcl
ships a flat light theme (the default) and a dark one.

## Switch the theme

```nim
Application.theme = themeDark()     # every open form repaints
Application.theme = themeLight()
```

Toggle from a handler:

```nim
var dark = false
let toggle = newButton(form, "Toggle theme", 16, 16, 130, 30)
toggle.onClick = proc(sender: Control) =
  dark = not dark
  Application.theme = if dark: themeDark() else: themeLight()
```

You can also theme one window: `form.theme = themeDark()`.
`Application.theme` returns the current global theme.

## Customize a theme

`themeLight()` and `themeDark()` return a fresh `Theme` object. Change what you
like and install it:

```nim
let t = themeDark()
t.accent = hex"#e11d48"                 # buttons, focus, progress
t.radius = 2                            # sharper corners
t.font = font("sans", 15)
Application.theme = t
```

Main tokens (all `Color` unless noted):

| Token | Used for |
|---|---|
| `window`, `surface`, `surfaceAlt` | Window, panels and inputs, secondary fills |
| `text`, `textMuted`, `textDisabled` | Text |
| `accent`, `accentText` | Primary color and the text on it |
| `border`, `borderStrong`, `focusRing` | Outlines |
| `selection`, `selectionText`, `selectionInactive` | Selected rows and text |
| `hover`, `pressed`, `danger` | States |
| `scrollTrack`, `scrollThumb`, `scrollThumbHover` | Scrollbars |
| `menuBg`, `menuHover`, `tooltipBg`, `tooltipText`, ... | Menus and hints |
| `radius`, `borderWidth`, `controlHeight`, `spacing`, `focusRingWidth` (float32) | Metrics |
| `font`, `monoFont` (`FontSpec`) | Fonts |

## Per-control colors and fonts

A single control can override the theme:

```nim
let warn = newLabel(form, "Careful!", 16, 60)
warn.font = font(size = 16, style = {fsBold})
warn.textColor = hex"#dc2626"

let panel = newPanel(form, "", 16, 100, 200, 60)
panel.color = rgb(255, 244, 214)
```

`color` and `font` are inherited from the parent unless set (`parentColor`,
`parentFont`). A Panel without an assigned color uses `theme.surface`, so it
follows theme switches.

## HiDPI

Sizes are logical pixels. nimvcl reads the display scale from SDL and
renders text and shapes sharply at 1x, 1.5x, 2x and so on. To test another
scale, set `Application.forceScale = 1.5` before creating windows.

## In your own controls

Paint from `control.theme`, not from literals, and your control works in both
themes. See [painting](painting.md).

[Back to the index](../README.md)
