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

Text in Chinese, Japanese or Korean needs no setup when a common system CJK
font is installed (Noto Sans/Serif CJK, WenQuanYi, Droid Sans Fallback): nimvcl
finds it the first time text is drawn and uses it for the glyphs the bundled
fonts lack. See [painting](painting.md#fonts).

## Per-control colors and fonts

A single control can override the theme, the way Delphi does it:

```nim
let warn = newLabel(form, "Careful!", 16, 60)
warn.font = font(size = 16, style = {fsBold})
warn.fontColor = hex"#dc2626"          # same as font.color

let panel = newPanel(form, "", 16, 100, 200, 60)
panel.color = rgb(255, 244, 214)

let name = newEdit(form, "", 16, 180, 200)
name.color = hex"#fff7d6"              # the box fill, like TEdit.Color
```

`color` is the background of every control that has one, and `font.color` is
its text color. Both are inherited from the parent unless set (`parentColor`,
`parentFont`; setting either one turns the inheritance off). A Panel without an
assigned color uses `theme.surface`, so it follows theme switches. `font.color`
lives in the `FontSpec` (alpha 0, the default, means "the theme's text
color"), so a container's `font.color` is inherited by its children with
`parentFont`, as in the VCL.

What `color` paints, when it is set:

| Control | `color` is |
|---|---|
| `Edit`, `Memo`, `CodeEdit`, `SpinEdit` | The field fill (a disabled one fades it). `CodeEdit`'s gutter is a shade of it |
| `ListBox`, `ListView`, `TreeView`, `StringGrid`/`DrawGrid` | The items area. Hover rows, list headers and fixed grid cells are shades of it; the selection keeps the theme colors |
| `ComboBox` | The field and the drop-down list |
| `Button` | The face; hover, pressed and disabled are shades of it |
| `CheckBox`, `RadioButton`, `GroupBox`, `Frame`, `ScrollBox` | The area behind (nothing is painted without an own color) |
| `Panel`, `Label` (when not `transparent`), `Form` | The fill |
| `StatusBar`, `ToolBar` | The bar fill; tool buttons shade it |
| `PageControl`, `TabControl` | The page body and the selected tab |
| `ProgressBar`, `TrackBar`, `Bevel` (`bsBox`) | The track, the area behind, the box |

The theme look stays when no color is set. When a control has an own `color`
and no `font.color`, text uses the theme's text color unless that would not
read on the fill; then it switches to dark or white, so a dark `Edit` in the
light theme is still legible. Hover, pressed and disabled looks are derived
from the control's color, not from the theme. A `font.color` is used as is.

A fixed `font.color` is a fixed color: it stays the same when the theme
changes. To keep a text color that follows the theme, name it by its role
instead:

```nim
let hint = newLabel(form, "Press F1 for help", 16, 130)
hint.muted = true                    # the theme's textMuted, light or dark
let link = newLabel(form, "Learn more", 16, 150)
link.textRole = tcAccent             # the theme's accent

let card = newPanel(form, "Status", 16, 180, 200, 40)
card.textRole = tcMuted              # Panel captions too
```

`ThemeColor` is `tcText`, `tcMuted`, `tcAccent`, `tcDanger` or `tcDisabled`.
The color is looked up every time the control paints, so
`Application.theme = themeDark()` is enough. Setting `font.color` and setting a
role replace each other; `resetTextColor()` goes back to the plain theme text.
In your own controls use `theme.resolve(tcMuted)`.

`Label.textColor` and `Panel.textColor` are deprecated aliases of `font.color`.
In form files the color is written as `font.color = #rrggbb` (only when set);
an old `textColor = #rrggbb` still loads.

## HiDPI

Sizes are logical pixels. nimvcl reads the display scale from SDL and
renders text and shapes sharply at 1x, 1.5x, 2x and so on. To test another
scale, set `Application.forceScale = 1.5` before creating windows.

## In your own controls

Paint from `control.theme`, not from literals, and your control works in both
themes. See [painting](painting.md).

[Back to the index](../README.md)
