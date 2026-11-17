# Design mode

`FormDesigner` turns a container into a design surface, like the form designer
in Delphi: controls are selected, moved and resized instead of operated. It is
the building block for a visual form editor; it knows nothing about control
classes, properties or file formats, so the application supplies those through
hooks.

```nim
import nimvcl

let form = newForm(nil, 700, 480)
let surface = newPanel(form, "", 20, 20, 420, 320)   # "the form being designed"
newButton(surface, "OK", 24, 24, 90, 28)
newEdit(surface, "text", 24, 70, 200, 26)
form.show()

let designer = newFormDesigner(surface)              # attached right away
designer.createControl = proc(className: string): Control =
  case className
  of "Button": newButton(nil, "Button")
  of "Edit": newEdit(nil, "")
  else: nil
designer.onSelectionChanged = proc(d: FormDesigner, sel: seq[Control]) =
  echo sel.len, " selected"

designer.beginCreate "Button"                        # then click or drag
```

The designed container can be a `Form` in its own window (`newFormDesigner(form)`)
or any container inside another form, which is what an IDE does; the rest of
the window keeps working normally.

## What changes while a designer is attached

* Mouse and keyboard input inside the container goes to the designer. Buttons
  do not click, edits do not take focus or text, list boxes do not scroll,
  nothing is hovered.
* Painting is normal. The designer paints on top (`Container.onPaintOver`):
  grid dots on the empty background, selection handles, drag outlines, guide
  lines and the rubber band.
* The keyboard belongs to the designer after the user presses in the designed
  area, until a control outside it takes focus. Keys it does not use (for
  example menu shortcuts) continue through the normal key-handler chain.

With no designer attached nothing changes and nothing is paid for.

`designer.detach()` returns to normal operation; `designer.attach()` starts
again (call it after moving the container into another form).
`newFormDesigner(root, attachNow = false)` creates a detached one, for when the
container is not in a form yet.

## Mouse and keyboard

| Input | Result |
|---|---|
| Click | Selects the topmost control under the pointer; empty area of a container selects the container |
| Shift+click | Adds or removes from the selection (one parent only) |
| Drag on the empty design root, or Ctrl+drag in another container | Rubber band; selects the children it touches |
| Drag a selected control | Moves the selection; drop on a container to reparent |
| Alt while dragging | No grid or guide snapping |
| Drag a handle | Resizes (live); `constraints` and `minSize` apply |
| Drag the right, bottom or corner handle of the design root | Resizes the designed form (see below) |
| Arrows | Move by 1 px; Ctrl: by the grid |
| Shift+arrows | Resize by 1 px; Ctrl+Shift: by the grid |
| Delete | Deletes the selection |
| Esc | Cancels a drag or a pending creation, otherwise selects the parent |
| Tab, Shift+Tab | Next and previous sibling |
| Ctrl+A | Selects all siblings |
| Ctrl+C, Ctrl+X, Ctrl+V | Raise `onCopy`, `onCut`, `onPaste` |
| Ctrl+Z, Ctrl+Y (or Ctrl+Shift+Z) | Undo, redo |
| Double click | Raises `onDoubleClick` |
| Right click | Selects the control (if not selected) and raises `onContextMenu` |

The first selected control is the primary one (blue handles); the others have
grey handles. Moving, resizing and the align commands act on the whole
selection.

Controls can only be dropped into containers that accept children:
`Panel` (and subclasses such as `FlowPanel`), `GroupBox`, `TabSheet`,
`TabControl` and `ScrollBox`. Other controls (a `Button`, a `ToolBar`...) are
selected as a unit and never entered. Set `designer.acceptsChildren` to change
the rule. The scroll bars of a scrolling control are not design children.

### Resizing the design root

With the design root selected, three handles (right, bottom and bottom-right)
sit just inside its corner, as Delphi lets you size the form in the designer.
Dragging one resizes the root live (the size snaps to the grid, `constraints`
and `minSize` apply), Esc cancels it, and the change is one undo step that also
fires `onModified`. The root's position never changes and it cannot be moved by
dragging; a root with an `align` other than `alNone` has no handles, since its
layout owns the size. Anchored and aligned children follow as in the running
form. A `Form` root resizes its window.

### Aligned controls

A control with `align != alNone` cannot be moved (layout owns its position).
Only the handle of its free edge is shown (`alTop`: the bottom edge, `alLeft`:
the right edge, and so on) and only that size can change. `alClient` controls
show no handles.

## Snapping

| Property | Default | |
|---|---|---|
| `grid` | 8 | Grid size in px (below 2 disables the grid) |
| `showGrid` | true | Dots on the background |
| `snapToGrid` | true | Positions and resized edges snap, relative to the parent's origin |
| `snapLines` | true | Moves snap to edges and centres of sibling controls and of the container; the lines are drawn |
| `snapDistance` | 5 | Reach of the snap lines in px |
| `minSize` | 4 | Smallest size a resize can produce |

## Creating controls

```nim
designer.createControl = proc(className: string): Control = ...
designer.nameControl = proc(d: FormDesigner, c: Control, className: string): string = ...
designer.beginCreate "Button"
```

After `beginCreate`, a click on a container creates a control of its default
size at the (snapped) point, and a drag creates it with that rectangle. The
control is named (`Button1`, `Button2`..., unique among the controls and
components under the design root; override with `nameControl`), owned by
`componentOwner` (default: the design root), selected, and `onCreated` fires.
A `createControl` that returns `nil` creates nothing. Esc or a right click
cancels. `designer.creating` tells which class is waiting.

`designer.insertNew(parent, control, className)` adds a control you built
yourself (a paste) with the same naming, selection and undo handling; its
bounds are used as they are.

## Events

All events receive the designer first.

| Event | When |
|---|---|
| `onSelectionChanged(selection)` | The selection changed |
| `onModified` | Something was changed, undone or redone |
| `onCreated(control)` | A control was created |
| `onDeleting(controls, allow)` | Before a delete; set `allow = false` to veto |
| `onDeleted(controls)` | After a delete |
| `onDoubleClick(control)` | Double click (an IDE adds the default handler here) |
| `onContextMenu(control, point)` | Right click; `point` is in form coordinates |
| `onCopy(controls)`, `onCut(controls)` | Ctrl+C, Ctrl+X (cut falls back to `onCopy` and then deletes) |
| `onPaste(target)` | Ctrl+V; `target` is the container the paste goes into |

Serialisation for copy and paste is the application's job (with the `.nfm` form
files, if you use them): in `onPaste`, build the controls and call `insertNew`.

## Undo and redo

Moves, resizes, reparenting, z-order changes, the align commands, creation and
deletion are undoable (`undo()`, `redo()`, `canUndo`, `canRedo`, `undoLimit`,
`clearUndo()`). One drag or one command is one step.

A deleted control is kept in the undo stack and put back as the same object.
If you set `snapshot` and `restore` the designer serialises it on delete,
frees it, and `restore(snapshot, parent, index)` rebuilds it on undo (the
function inserts the new control into `parent` at `index`); the undo history
is updated to point at the new object.

## Commands

For menus and toolbars:

| Method | |
|---|---|
| `bringToFront()`, `sendToBack()` | Z-order of the selection |
| `alignSelection(aeLefts / aeRights / aeTops / aeBottoms / aeHCenters / aeVCenters)` | Align to the primary control |
| `makeSameSize(width, height)` | Give the primary control's width and/or height to the others |
| `spaceEvenly(horizontal)` | Equal gaps between three or more controls |
| `centerInParent(horizontal, vertical)` | Centre each selected control |
| `nudge(dx, dy, resize)` | What the arrow keys do |
| `deleteSelection()` | What Delete does (returns false when vetoed) |
| `select(c)`, `select(list)`, `toggle(c)`, `clearSelection()` | Selection |
| `selectParent()` | What Esc does |

## Non-visual components

Timers, image lists, menus and the like have no place in the control tree.
Register them to show a tile on the surface:

```nim
let timer = newComponent(surface)
timer.name = "Timer1"
designer.addNonVisual(timer, 40, 380, kind = "Timer")   # optional icon: Image
```

`designer.addNonVisual(timer, kind = "Timer")` (no position) puts the tile at
the component's saved `designLeft`/`designTop`, the way a form file stores
them, or in the next free spot of a row along the top when it has none. While a
tile is moved, nudged, undone or redone its component's `designLeft` and
`designTop` follow, so `formToNfm` saves the layout of the tiles.

The tile shows the first two letters of `kind` (or the icon) and the name
under it. It is selected, dragged (inside the design root only) and deleted
like a control and appears in selections as a `NonVisualTile` (its `component`
field is the component). `nonVisuals` lists the tiles and `removeNonVisual`
removes one.

## Hidden controls

With `showHidden = true`, controls with `visible = false` are selectable and
drawn as dashed outlines with their name.

## Keeping the overlay correct

Changes made through the designer repaint the right areas. After you change the
geometry of a selected control yourself (an inspector editing `left`), call
`designer.refresh()` so the old handle area is repainted; layout changes that
move a selected control are picked up on the next frame.

## The hook underneath

The interception is a small core feature: `UiRoot.addDesigner(hook)` with a
`DesignHook` (`core/design.nim`) whose `scope` is a container. Mouse events
whose target is inside the scope, and the keyboard while focus is free or
inside it, call `designMouseDown/Move/Up/Wheel` and `designKeyDown/Up` on the
hook instead of the controls. A press inside the scope captures the pointer
until every button is released. Several hooks (several design forms in tabs)
can be attached to one window; each owns the area of its own scope. You only
need this to write a different kind of design surface.

See `examples/designer_demo.nim` for a palette, a design form, a property list
and a status bar.
