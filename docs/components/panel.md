# Panel and GroupBox

Containers that group other controls (Delphi `TPanel` and `TGroupBox`).

## Quick example

```nim
let card = newPanel(form, "", 16, 16, 260, 140)
card.borderStyle = pbSingle               # rounded card
card.padding = spacing(8)

let title = newLabel(card, "Account")
title.align = alTop
let user = newEdit(card)
user.align = alTop

let group = newGroupBox(form, "Options", 290, 16, 180, 100)
let opt = newCheckBox(group, "Enabled", left = 12, top = 28)
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `caption` | string | Panel: text drawn inside. GroupBox: the title on the border |
| `borderStyle` | `PanelBorder` | Panel: `pbNone` (flat), `pbSingle`, `pbRaised` |
| `alignment` | `HAlign` | Panel caption alignment (centered by default) |
| `color` | Color | Panel fill; default is `theme.surface` |
| `padding` | `Spacing` | Space kept free inside; used by aligned children |
| `align`, `anchors`, `margins` | | See [layout](../guide/layout.md) |
| `clientArea` | `RectF` | GroupBox only: area below the caption |

## Events

Only the common ones (`onClick`, `onResize`, mouse events).

## Methods

| Method | Description |
|---|---|
| `insertControl(c)` | Add a child (constructors do this when you pass `parent`) |
| `captionHeight()` | GroupBox: height of the caption strip |

## Tips

* Panel draws its caption behind its children. A `&` in a Panel caption is
  stripped but is not a mnemonic: nothing is underlined and Alt+letter does
  nothing (use a Label with `focusControl`, or a GroupBox).
* A GroupBox computes its own `padding`, so setting it has no effect. Aligned
  children sit below the caption. For `alNone` children add `captionHeight` to `top`
  or position inside `clientArea`.
* Children with `parentColor` inherit the panel color.
* Alt+letter on a GroupBox mnemonic focuses its first control.

[Back to the index](../README.md)
