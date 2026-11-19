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
  per element. The `font.family` value is an editable drop-down grouped as Bundled,
  Project (`onGetFontFamilies`, by default the registered families) and System
  (marked as possibly missing on other machines); a free name can be typed.
* The divider between the columns can be dragged.

## Editing

Click a value (or select the row and press Enter):

| Property | Editor |
|---|---|
| string, int, float | an `Edit`; Enter applies, Esc cancels. A number that does not parse is rejected: the row stays in edit mode and `lastError` explains (`` `abc` is not a whole number ``) |
| enum, bool | a drop-down `ComboBox`; a double click cycles to the next value |
| colour | an editable combo: type `#rrggbb` or a palette name, or pick from the palette list |
| reference to another object (`Label.focusControl`, `images`) | a combo of the named objects of the same form |
| string list (`items`, `lines`, `tabs`), image (`picture`), image list (`ImageList.images`), collection (`columns`, `panels`, `pages`, `buttons`, menu `items`) | a "..." button that calls `onEditExtra`; `attachEditors` (below) opens ready-made dialogs. Delete on an image row clears it |
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

## Property editor dialogs

`import nimvcl/controls/propeditors` has the dialogs behind the "..." button:

```nim
let host = newPropEditorHost(baseDir = projectDir, imagesDir = projectDir / "images")
host.onChanged = proc(target: Obj, prop: string) = markModified()
host.onItemAdded = proc(parent, item: Obj) = item.name = freshName()   # a new collection item
attachEditors(inspector, host)          # sets inspector.onEditExtra
```

| Property kind | Dialog | What it does |
|---|---|---|
| `seq[string]` | `StringListDlgForm` (`editStringList`) | A memo, one entry per line |
| `Image` | `PictureDlgForm` | Preview, Load... (a file dialog for PNG/JPG/BMP), Clear, OK, Cancel |
| `ImageList.images` | `ImageListDlgForm` | Thumbnails; Add... (several files), Delete, Up, Down |
| `StringGrid.cells` | `StringGridDlgForm` | An editable grid with Add / Delete row and column; OK also sets `colCount` / `rowCount` |
| `ListView.items`, `TreeView.items` | `ItemsDlgForm` | The Items Editor: Add, Add child / Indent / Outdent (tree), Delete, Up, Down, and per item the caption, sub-items (list), image index, selected image index (tree) and check state; OK sets `items`, `itemImages`, `itemSelectedImages` and `checkedItems` |
| collection (`pkCollection`) | `CollectionDlgForm` | The items with Add, Delete, Up, Down, and an inspector for the selected item (which offers these editors again, so menu items nest) |

A picked picture goes through `host.importFile`: a file inside `host.baseDir`
is stored relative to it, any other file is copied into `host.imagesDir`
(default `baseDir/images`; a number is appended when another file has the name)
and its relative path is stored. `loadPicture(host, path)` does the same without
a dialog.

The dialogs are plain forms (`newPictureDlg(host, image)`, `newImageListDlg`,
`newStringListDlg`, `newCollectionDlg`, `newStringGridDlg`, `newItemsDlg`) whose procs (`loadFile`, `clearPicture`,
`addFiles`, `moveSelected`, `addItem`, `deleteItem`, `moveItem`, ...) tests call
directly; `host.runModal` (default `showModal`) is what `attachEditors` uses to
run them, so a test replaces it to drive a dialog without showing anything.
Collections are registered with `addCollection(classInfo, name, childClass,
CollectionOps(...))` (`props_std` does it for `ListView.columns`,
`StatusBar.panels`, `PageControl.pages`, `ToolBar.buttons`, and `items` of
`MainMenu`, `PopupMenu` and `MenuItem`); the property is never stored, the items
are the object's child nodes in the form file.

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
| `onEditExtra(sender, target: Obj, prop: string)` | The "..." button of a string list, image, image list or collection was pressed |
| `onGetChoices(sender, target: Obj, prop: string): seq[Obj]` | The objects an object-reference property offers (filtered by the property's class). When nil, the named objects of the target's form are found by walking up from the target; set it when the target lives inside a design surface |
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
| `setValue(name, value)` | Set a property of all targets as if edited (also a hidden one, or one on another tab) |
| `valueTextOf(name)`, `isBold(name)`, `rowCount`, `rowName(i)`, `indexOfProp(name)` | Inspect the grid (tests, accessibility) |
| `rowRect(i)`, `nameRect(i)`, `valueRect(i)` | Geometry of a row in client coordinates |

## Tips

* A designer (see `FormDesigner`) shows its selection with
  `ins.inspect(selected)` and saves with `formToNfm`.
* `knownHandlers` can be filled by scanning the form's `.nim` file for procs
  with the right signature; `onCreateHandler` is where an IDE adds the stub.
* Dark and light themes work; the grid uses the theme's surface, selection and
  border colours.
