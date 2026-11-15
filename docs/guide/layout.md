# Layout

Placement works like the VCL. Each control has `left`, `top`, `width`, `height`
(logical pixels, relative to its parent), plus `align`, `anchors`, `margins`,
`constraints` and `autoSize`. A container lays out its children whenever it or
a child changes.

## Align

`align` docks a control to a side of its parent.

| Value | Effect |
|---|---|
| `alNone` | Free placement with `left`/`top` (default), see anchors |
| `alTop`, `alBottom` | Full width, keeps its own `height` |
| `alLeft`, `alRight` | Full height, keeps its own `width` |
| `alClient` | Fills what is left |
| `alCustom` | The parent decides (`customAlign`, used by ToolBar) |

Order matters. Same-aligned siblings stack in child order (the order you
created them): top ones from the top down, bottom ones from the bottom up, then
left, right, and finally `alClient`.

```nim
let header = newPanel(form, "Header")
header.align = alTop
header.height = 40

let side = newPanel(form, "Sidebar")
side.align = alLeft
side.width = 160

let body = newPanel(form, "Body")
body.align = alClient
```

## Anchors

For `alNone` controls, `anchors` says which edges keep their distance when the
parent is resized. The default is `{akLeft, akTop}`.

```nim
let edit = newEdit(form, "", 16, 16, 300)
edit.anchors = {akLeft, akTop, akRight}      # grows with the window

let ok = newButton(form, "OK", 220, 250, 80, 28)
ok.anchors = {akRight, akBottom}             # sticks to the bottom-right corner
```

* left and right: the width grows,
* only right: the control moves right,
* neither: it keeps its proportional center.

### The design-size baseline

As in Delphi, anchors work from the size the form was *designed* at. A control
remembers the rectangle you gave it and the parent size that went with it.
At layout time nimvcl adds the total size change since then. Two consequences:

* A tiling window manager may resize the window before your first frame. That
  does not count as a design change, so your layout is not distorted.
* Resizing is drift-free. Returning to the design size restores the exact
  original positions.

Set `left`, `top`, `width`, `height` (or call `setBounds`) when you place a
control. That is what records the baseline.

#### Containers that your layout sizes

A container that you never sized yourself has no design size of its own. It
starts at its constructor's default (a panel is 200x100) and is then stretched
by `align`, so its *first layout* size is its baseline. The natural code works:

```nim
let body = newPanel(page)            # no width/height given
body.align = alClient
let edit = newEdit(body, "", 10, 10, 100)
edit.anchors = {akLeft, akTop, akRight}
form.show()
# edit keeps left 10 and width 100 at the panel's first real size; from there
# it follows every resize (it grows when the panel grows).
```

The rule in one sentence: **a container's design size is the size you gave it
explicitly (`width = ...`, `setBounds`, or width/height passed to the
constructor); without one, it is its size at its first layout.** Children you
add before that first layout are placed against that size. Children you add
later are relative to the container's size at that moment.

If you do size a container explicitly, say `newPanel(page, "", 0, 0, 400, 300)`
and then `align = alClient`, the anchors are relative to 400x300 and the child
moves or stretches by however much bigger the panel turns out. Use this when you
laid your children out for a particular size. Containers that are hidden
(`visible = false`, like the inactive pages of a `PageControl`) get their first
layout when they are first shown.

## Margins and padding

`margins` (on a control) is the space around it. `padding` (on a container) is
the space kept free inside it. Both take a `Spacing`:

```nim
let a = spacing(8)             # all four sides
let b = spacing(12, 6)         # horizontal, vertical
let c = spacing(1, 2, 3, 4)    # left, top, right, bottom
```

```nim
let card = newPanel(form)
card.align = alClient
card.padding = spacing(12)           # children stay 12 px from the edges

let label = newLabel(card, "Name")
label.align = alTop
label.margins = spacing(0, 0, 0, 4)  # 4 px gap below
```

Padding only affects aligned children. `GroupBox` computes its own padding so
children sit below the caption; use its `clientArea` for `alNone` children.

## Constraints

`constraints` clamps the size. A value of 0 means "no limit".

```nim
form.constraints = constraints(minWidth = 400, minHeight = 300)
```

## autoSize

With `autoSize = true` a control takes its `preferredSize()` in the dimension its
`align` lets it own. Labels, check boxes and radio buttons are autoSize by
default (until you pass an explicit width or height to the constructor).

```nim
let lbl = newLabel(form, "Some text")   # sizes itself to the text
let btn = newButton(form, "Wide button")
btn.autoSize = true                     # width follows the caption
```

Measuring text needs a window, so a label keeps its size until its form is
shown.

## FlowPanel and GridPanel

Two panels position their children themselves and ignore their `align`:

* [FlowPanel](../components/flowpanel.md): children flow in rows and wrap.
* [GridPanel](../components/gridpanel.md): rows and columns with absolute,
  auto and percent tracks.

## Scrolling content

Children with `alNone` inside a [ScrollBox](../components/scrollbox.md) live in
content coordinates and scroll. Aligned children stay put.

## Rounding

Every position and size computed by layout is snapped to a whole logical pixel,
so there are no gaps or overlaps between neighbors.

[Back to the index](../README.md)
