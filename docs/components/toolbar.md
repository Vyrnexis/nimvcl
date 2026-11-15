# ToolBar

A row of tool buttons (Delphi `TToolBar` and `TToolButton`). The bar is `alTop`
and sizes its own height.

## Quick example

```nim
let bar = newToolBar(form)

let open = newToolButton(bar, "Open")
open.hint = "Open a file"
open.onClick = proc(sender: Control) = echo "open"

discard newToolButton(bar, kind = tbsSeparator)   # a gap
let bold = newToolButton(bar, "Bold", tbsCheck)   # toggles `down`
bold.onClick = proc(sender: Control) =
  echo "bold is ", ToolButton(sender).down
```

With icons from an [ImageList](imagelist.md):

```nim
let icons = newImageList(16, 16)
let openIcon = icons.add(loadImage("open.png"))
bar.images = icons
open.imageIndex = openIcon
open.showCaption = false
```

## Common properties

ToolBar:

| Name | Type | Description |
|---|---|---|
| `images` | `ImageList` | Icons for `imageIndex` |
| `flat` | bool | Buttons have no face until hovered (default true) |

ToolButton:

| Name | Type | Description |
|---|---|---|
| `kind` | `ToolButtonKind` | `tbsButton`, `tbsCheck`, `tbsSeparator`, `tbsDivider` |
| `caption` | string | Text |
| `showCaption` | bool | Hide the text when false |
| `down` | bool | Pressed state of a check button |
| `groupIndex` | int | `> 0`: radio group of check buttons |
| `allowAllUp` | bool | A grouped button can be released again |
| `imageIndex` / `image` / `glyph` | int / Image / `GlyphProc` | Icon: glyph wins over image over imageIndex |
| `hint` | string | Tooltip |
| `action` | Action | Link to an [Action](../guide/actions.md) |

## Events

| Event | Description |
|---|---|
| `onClick` | After the state change |

## Methods

`newToolButton(parent, caption, kind, glyph)`; `parent` is the bar.

## Tips

* Tool buttons never take keyboard focus.
* Buttons are `alCustom` children that the bar places in order. Any control can
  sit on the bar if you set `align = alCustom`.
* `glyph` is `proc(c: Canvas, r: RectF, color: Color)`: draw a vector icon in the
  given color so it follows the theme.

[Back to the index](../README.md)
