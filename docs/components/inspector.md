# ObjectInspector

A property grid for one or several objects: Delphi's Object Inspector. It reads
and writes properties through the [property registry](../guide/form-files.md), so
it works for every registered control and component (`Button`, `Edit`,
`MenuItem`, `Timer`, ...), and for your own classes once they are registered with
`registerClass`.

It is not part of the `import nimvcl` umbrella (the registry adds to compile
time): `import nimvcl/controls/inspector`.

## Quick example

```nim
import nimvcl
import nimvcl/controls/inspector

let form = newForm(nil, 700, 500)
let ok = newButton(form, "OK", 20, 20)
ok.name = "okButton"

let ins = newObjectInspector(form)
ins.align = alRight
ins.width = 320
ins.inspect(ok)                                   # show its properties

ins.onPropertyChanged = proc(sender: Control, target: Obj, prop: string) =
  echo objectName(target), ".", prop, " changed"
ins.onCreateHandler = proc(sender: Control, target: Obj, event: string): string =
  result = objectName(target) & event[2 .. ^1]    # e.g. okButtonClick
```

`examples/inspector_demo.nim` is a complete program: a form on the left, the
inspector on the right bound to the control you click, "Save .nfm" and "Reload
from .nfm".

## What it shows

* A title line (`okButton: Button`, or `3 objects selected`).
* The tabs **Properties** and **Events**, and a button that switches between
  rows grouped by category (collapsible) and one flat alphabetical list.
* One row per property: `name | value`. A value that differs from the default of
  a fresh object of the same class is drawn **bold**. Composite properties and
  sets have a chevron: `font` expands into `family`, `size`, `style`; `margins`,
  `padding` and `constraints` into their four parts; `anchors` into one check box
  per element.
* The divider between the columns can be dragged.

## Editing

Click a value (or select the row and press Enter):

| Property | Editor |
|---|---|
| string, int, float | an `Edit`; Enter applies, Esc cancels. A number that does not parse is rejected: the row stays in edit mode and `lastError` explains (`` `abc` is not a whole number ``) |
| enum, bool | a drop-down `ComboBox`; a double click cycles to the next value |
| colour | an editable combo: type `#rrggbb` or a palette name, or pick from the palette list |
| reference to another object (`Label.focusControl`, `images`) | a combo of the named objects of the same form |
| string list (`items`, `lines`), image | a "..." button that calls `onEditExtra`; the application opens its own dialog |
| set element (`anchors.akLeft`) | a check box; one click toggles it |
| event | an editable combo of handler names; a double click on an empty row asks `onCreateHandler` for a new name |

Edits go through the registry (`setProp`), so a bad value raises nothing in the
inspector: it is reported in `lastError` (and drawn in a line at the bottom of the
inspector) and the old value stays. Before an edit is applied
`onPropertyChanging` can refuse it (see below). Every applied
change calls `onPropertyChanged(sender, target, propName)`; a sub-property is
reported by its dotted name (`font.size`, `anchors.akRight`). The inspector does
not repaint the target for you: the property setters already do.

With several targets (`inspect([a, b])`) the rows are the properties all of them
have, with the same type; a value shows when they agree and the cell is blank when
they do not. An edit applies to every target.

Keyboard: Up, Down, PageUp, PageDown, Home, End move the selection; Enter edits;
Esc cancels; Tab applies and edits the next row (Shift+Tab: the previous one);
Left and Right collapse and expand; Space toggles a check box.

## Properties

| Name | Type | Description |
|---|---|---|
| `tab` | `InspectorTab` | `itProperties` (default) or `itEvents` |
| `sortedFlat` | bool | `true`: one alphabetical list; `false`: grouped by category |
| `knownHandlers` | `seq[string]` | Handler names offered by the event editors |
| `splitX` | float32 | Width of the name column |
| `targets` | `seq[Obj]` | What is inspected (read-only) |
| `lastError` | string | Why the last edit was rejected ("" when fine); shown at the bottom of the inspector until the next edit, `inspect` or Esc |

## Events

| Event | Description |
|---|---|
| `onPropertyChanging(sender, target: Obj, prop: string, newValue: PropValue, accept: var bool, message: var string)` | Before a value is applied, for each target. Set `accept = false` to refuse: nothing changes (with several targets one refusal stops the whole edit), `message` (or a default text) becomes `lastError` and shows in the error line, and a typed edit stays open. Also asked before a handler name is created by double click. `prop` is the dotted name (`font.size`) |
| `onPropertyChanged(sender, target: Obj, prop: string)` | A value was changed by the user (after it was applied) |
| `onCreateHandler(sender, target: Obj, event: string): string` | Double click on an event row without a handler: return the name of a new handler (the application writes the stub), or "" to do nothing. When nil, `<Name><Event>` is used |
| `onEditExtra(sender, target: Obj, prop: string)` | The "..." button of a string list or image was pressed |
| `onGetHandlers(sender, target: Obj, event: string): seq[string]` | More handler names for the event editor, besides `knownHandlers` |
| `onSelectionChanged` | The selected row changed |

## Methods

| Method | Description |
|---|---|
| `inspect(obj)`, `inspect(objs)`, `inspect(newSeq[Obj]())` | Choose the target(s); the selected property is kept when the new target has it |
| `refresh()` | Re-read the values after the target changed behind the inspector's back |
| `selectProp(name)`, `selectedProp()` | Select a row by property name (expands its parents) |
| `setExpanded(name, on)` | Expand or collapse a composite property or a category (`"cat:Layout"`) |
| `beginEdit(name, openList = true)`, `commitEdit()`, `cancelEdit()` | Drive the editor from code |
| `setValue(name, value)` | Set a property of all targets as if edited |
| `valueTextOf(name)`, `isBold(name)`, `rowCount`, `rowName(i)`, `indexOfProp(name)` | Inspect the grid (tests, accessibility) |
| `rowRect(i)`, `nameRect(i)`, `valueRect(i)` | Geometry of a row in client coordinates |

## Tips

* A designer (see `FormDesigner`) shows its selection with
  `ins.inspect(selected)` and saves with `formToNfm`.
* `knownHandlers` can be filled by scanning the form's `.nim` file for procs
  with the right signature; `onCreateHandler` is where an IDE adds the stub.
* Dark and light themes work; the grid uses the theme's surface, selection and
  border colours.
