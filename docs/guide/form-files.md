# Form files, the property registry and `loadForm`

A form can be described in a text file, a Delphi `.dfm` for nimvcl, called
`.nfm`. The file is the designer's source of truth. At compile time
`loadForm` turns it into a typed form, just like the `form` macro (see
[Forms and frames](../forms.md)); at run time `loadNfm` builds the same tree
from the file's text. Both are built on the **property registry**, nimvcl's
answer to Delphi's RTTI.

```nim
import nimvcl                    # or only the modules the form uses, see below
import nimvcl/dsl/formload       # `loadForm`; light (no registry)

loadForm LoginForm, "LoginForm.nfm"          # path relative to this module

proc okClick(self: LoginForm, sender: Control) =
  echo self.user.text

Application.run(newLoginForm())
```

`LoginForm.nfm`:

```
object LoginForm: Form
  width = 400
  height = 200
  caption = 'Sign in'
  object user: Edit
    left = 16
    top = 20
    width = 360
    anchors = [akLeft, akTop, akRight]
  end
  object ok: Button
    left = 16
    top = 70
    caption = 'OK'
    onClick = okClick
  end
end
```

## The `.nfm` format

A file is one `object`. Objects nest; each has properties, then child objects:

```
object name: Class
  property = value
  object child: Class
    ...
  end
end
```

* `name` is the object's `name` (and, with `loadForm`, the field of the typed
  form). An object without a name is written `object: Class`; use that for
  things that do not need a field (menu items, columns, panels).
* `Class` is a class registered with the registry: `Form`, `Button`, `Edit`,
  `MenuItem`, `ListColumn`, ... With `loadForm` it is also the Nim type name, so
  it must be a type with a constructor (`newButton`) in scope. The image control
  is `ImageControl` (the runtime loader also accepts `Image`).
* The whole file is free-form: only the order of tokens matters, not the
  indentation or line breaks. `//` starts a comment up to the end of the line.
  `writeNfm` and `formToNfm` write the canonical layout: two spaces per level,
  one property per line, properties before children, no comments.

### Values

| Kind | Written as | Examples |
|---|---|---|
| bool | `true` / `false` | `visible = false` |
| int, float | decimal number | `width = 120`, `left = -4`, `top = 0.5`, `x = 1e-3` |
| string | single quotes | `caption = 'OK'` |
| enum | the value name | `align = alClient`, `modalResult = mrOk` |
| set | brackets, comma separated | `anchors = [akLeft, akTop]`, `anchors = []` |
| colour | `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa` | `color = #336699` |
| string list | parentheses, one string per entry | see below |
| object reference | the other object's name, or `nil` | `focusControl = user`, `images = icons`, `popupMenu = menu1`, `action = saveAct` |
| image | the file path as a string, relative to the `.nfm` | `picture = 'images/logo.png'` |
| image list | parentheses, one path per entry | `images = ( 'a.png' 'b.png' )` |
| event | the handler's name | `onClick = okClick` |

String escapes: `\\` `\'` `\n` `\r` `\t` `\0` and `\xHH`. A string ends on its
line, so write `\n` for a line break; non-ASCII text stays as it is (UTF-8).

String lists (`ComboBox.items`, `ListBox.items`, `Memo.lines`, `TabControl.tabs`,
and the rows of `ListView.items` / `StringGrid.cells` / the outline of
`TreeView.items`, see below):

```
items = (
  'Viewer'
  'Editor'
)
```

### Pictures

`ImageControl.picture`, `ToolButton.image`, `Form.icon` and `ImageList.images` are written
as paths relative to the folder of the `.nfm` (forward slashes). `loadNfm` reads
them from disk (relative to the `.nfm`, or to `NfmOptions.baseDir`); `loadForm`
embeds the file bytes in the program (`staticRead`) so a shipped binary needs no
image files, and fails to compile when a file is missing. A file that is missing
at run time gives a warning in `NfmOptions.warnings` and a blank image that keeps
the path. An image made in code has no path (`img.source` is ""): it is not
written. `loadImage(path)` records its path.

### Item data

`ListView.items` is one string per row, the cells separated by a tab
character; `TreeView.items` is an outline, one node per entry, indented by two
spaces per level; `StringGrid.cells` is one string per row, the cells separated
by tabs. Per-item data are parallel string lists, written after `items`:

| Property | Class | Content |
|---|---|---|
| `itemImages` | `ListView`, `TreeView` | the `imageIndex` of each item (in order); trailing "none" (-1) entries are left out |
| `itemSelectedImages` | `TreeView` | the `selectedIndex` of each node |
| `checkedItems` | `ListView`, `TreeView` | the indexes of the checked items (a grayed tree node is derived from its children) |

```
items = (
  'Root'
  '  Child'
)
itemImages = (
  '0'
  '1'
)
checkedItems = (
  '1'
)
```

`DrawGrid.colWidths` / `rowHeights` are one string, "64, 120, 64", listing every
column or row (not written while all have the default size). Expansion of tree
nodes is not stored.

`Form.menu` (a `MainMenu`), `Button.images` (an `ImageList`) are object
references by name, `Button.imageIndex` / `imageAlignment` plain values and
`Edit.passwordChar` a one-character string (`password = true` stands for the
default bullet).

### Sub-properties

`font`, `margins`, `padding` and `constraints` are written one part at a time,
and only the parts that differ from the default:

```
font.size = 18
font.style = [fsBold]
font.color = #dc2626
margins.left = 8
constraints.minWidth = 100
```

The parts: `font.family`, `font.size`, `font.style`, `font.color` (written only
when set; an old `textColor` of a label or panel still loads as `font.color`); `margins.left|top|right|bottom`
(also `padding`); `constraints.minWidth|minHeight|maxWidth|maxHeight`. Giving a
`font` part makes the control use its own font (`parentFont` is cleared, as in
Delphi); the same goes for `color`.

### Collections

Things a control owns are nested objects: the items of a `MainMenu`, a
`PopupMenu` or a `MenuItem`; the columns of a `ListView`; the panels of a
`StatusBar`; the actions of an `ActionList`; the buttons of a `ToolBar`; the
sheets of a `PageControl`.

```
object mainMenu: MainMenu
  object fileMenu: MenuItem
    caption = '&File'
    object: MenuItem
      caption = 'E&xit'
      shortcut = 'Ctrl+Q'
      onClick = exitClick
    end
  end
end
```

A `shortcut` is written as the string `shortcut("...")` takes. The grid sizes of a
`GridPanel` (`columns`, `rows`) are strings such as `'100, 50%, auto'`.

### Non-visual components

Components that are not controls (`Timer`, `ImageList`, `PopupMenu`,
`ActionList`) are written as objects of the component that owns them, as Delphi
writes them inside the form, after the owner's controls:

```
object Form1: Form
  object box: Panel
    object tick: Timer
      designLeft = 12
      designTop = 4
      interval = 250
    end
  end
  object pop: PopupMenu
    images = imgs
    object cut: MenuItem
      caption = 'Cut'
    end
  end
  object imgs: ImageList
  end
end
```

`loadNfm` and `loadForm` create them with the enclosing object as owner, and
`formToNfm` writes every non-visual component owned by the form (or by a
container in it), but each only once: menu items and actions are written inside
their menu or list even when the form owns them, and the helper timers a
control creates for itself are not owned by it and never appear.

`designLeft` and `designTop` (fields of `Component`, like Delphi's `DesignInfo`)
are the position of the component's tile in the form designer. They are ignored
at run time and written only when they are not both 0. A designer reads them
when it shows the tile and keeps them current while the tile is dragged.

### Property order

Some setters only accept a value that other properties make valid: `tabIndex`
needs the `tabs`, `itemIndex` the `items`, `value` the `minValue` / `maxValue`,
`cells` the `colCount` / `rowCount`, `itemImages` and `checkedItems` the
`items`, `imageIndex` the `images`. One table, `nimvcl/dsl/propdeps`
(`propDeps`, `applyOrder`), says which property follows which. The writer
(`propsOf` lists the properties in that order), `loadNfm` and the compile-time
`loadForm` all use it, so a file loads the same whatever order its properties
are written in, and a hand-written file need not know the rules. A dependency
on a property the class does not have is ignored. The table has no imports, so
`loadForm` still does not pull in the registry.

### What is stored

The writer emits only properties that differ from a fresh instance of the same
class, in registry order: ancestors' properties first (`left`, `top`, `width`,
`height`, `align`, ...), then the class's own, and events last. `name` is not a
property line (it is in the `object` line). Properties that are implied by
others (`parentFont`, `parentColor`, `CheckBox.checked`) are not written, and a
`ComboBox.text` is left out while an item is selected. The cells of a grid have
text form in the `cells` list (see "Item data"); `DockSite` layouts are saved with `saveLayout` instead. A
`popupMenu` is an ordinary object reference (`popupMenu = menu1`); context menus
are served by the library's own event path, so the control's event fields stay free.

## `loadForm` (compile time)

```nim
import nimvcl/dsl/formload
loadForm MainForm, "MainForm.nfm"
```

reads the file with the compiler (so the file is a build dependency) and
declares, exported:

```nim
type MainForm* = ref object of Form          # of the root's class; a field per named object
proc initMainForm*(self: MainForm, owner: Component = nil)
proc newMainForm*(owner: Component = nil): MainForm
```

The construction code is the one the `form` macro writes: first every object is
created top-down (`newButton(parent)`; `newMenuItem` and the other non-control
items through `nfmMake`), then the properties of each object are assigned in
file order (except for the dependencies in "Property order" above), so a
property may refer to any named object, also one further down. A root of class
`Frame` produces a `Frame` subtype with the usual `newX(parent, left, top, width,
height)`. A root of another class uses `initThatClass(self, owner)` as the `form`
macro does for `form Name of Base`.

### What `loadForm` imports

`loadForm` lives in `nimvcl/dsl/formload`, which needs only the `.nfm` syntax
(`nimvcl/dsl/nfmsyntax`, plain `std`) and the small `graphics/color`,
`graphics/font`, `graphics/image` and `core/component` modules. It does **not**
import the property registry (`props`, `props_std`), the object inspector and
its editors, or the run-time loader: the macro reads the class names and
values from the file and emits plain assignments, and the compiler resolves
them. An application that uses `loadForm` therefore compiles quickly: a small form
(label, edit, button, image list) builds in under 2 s warm instead of about 5 s
with `import nimvcl` plus `dsl/nfm`.

The calling module imports what the generated code uses:

* `nimvcl/core/[control, form]` (the base classes; `core/application` to run it);
* the module of every class the file names, e.g. `nimvcl/controls/button` for a
  `Button`, `nimvcl/controls/menus` for `MainMenu` / `MenuItem` (a missing one
  is reported as `unknown class` at the `loadForm` line);
* `nimvcl/controls/common` when a property uses one of the shared value types
  (`Orientation`, `HAlign`, ...): it re-exports the geometry, colour, canvas and
  theme modules.

`formload` itself re-exports `graphics/color` (colour literals) and
`graphics/font` (`font.size = 12`). `GridPanel.columns` needs
`controls/flowpanel` (the class's module) and `shortcut = '...'` needs
`controls/menus` (`MenuItem` and `Action` modules bring it in).
Objects that are not `newT(parent: Container)` controls (menu items, list
columns, status panels, actions) are created by an `nfmMake(T, parent)` that
their own module defines, so importing the class's module is enough.

`import nimvcl` plus `import nimvcl/dsl/formload` also works, with the
compile-time cost of the umbrella module. `import nimvcl/dsl/nfm` is the full
module for tools and run-time loading (`loadNfm`, `formToNfm`,
`nfmToFormMacro`); it re-exports `formload`, so existing code that imports it
keeps working.

The IDE generates form units that import exactly the control modules of the
classes on the form (see the IDE's user guide).

### Handlers

Every `onXxx = name` needs a proc `name`, defined **after** the `loadForm` line
in the same module, with the form as its first parameter and the event's own
parameters after it:

| Event type | Handler |
|---|---|
| `NotifyEvent` (`onClick`, `onChange`, ...) | `proc name(self: MainForm, sender: Control)` |
| `MenuItemEvent` (`MenuItem.onClick`) | `proc name(self: MainForm, sender: MenuItem)` |
| `FormCloseEvent` (`Form.onClose`) | `proc name(self: MainForm, sender: Form, action: var CloseAction)` |
| `KeyEvent` | `proc name(self: MainForm, sender: Control, key: var Key, shift: ShiftState)` |

The macro forward-declares each handler, so a missing one is the compile
error `implementation of 'proc name(...)' expected`, and a wrong signature is a
type error. The handler name is also recorded on the object, so
`formToNfm(form)` writes `onClick = okClick` again.

### Errors

Problems are reported at the `loadForm` line, with the position in the file in
the message:

* `MainForm.nfm:2:13: unterminated string ...` (syntax errors, see below);
* `MainForm.nfm:3:5: `Button` has no property `captoin``;
* `MainForm.nfm:3:5: the value of `width` does not fit its type in `Button``;
* `MainForm.nfm:3:5: `Button` has no event `onTap``;
* `MainForm.nfm:2:3: unknown class `Buttn` ...`;
* `MainForm.nfm:4:3: duplicate object name `ok``;
* an object named like a field of `Form` (`caption`, `width`, ...) is refused, as
  in the `form` macro.

The syntax errors name what was expected: `expected `=` after the property name
`caption``, ``missing `end` for the object `A` opened at 1:1``, `bad colour `#12``,
``unknown escape \q``, `unexpected character `@``.

## Loading at run time

```nim
import std/tables
import nimvcl
import nimvcl/dsl/nfm

var handlers: Table[string, NotifyEvent]
handlers["okClick"] = proc(s: Control) = echo "ok"
let form = loadNfm(readFile("LoginForm.nfm"), handlers)     # or loadNfmFile(path)
Application.run(form)
```

`loadNfm(text, owner = nil, options = nil, fileName = "")` returns a `Form`;
`buildNfm(root: NfmNode, ...)` builds any registered root (a `Panel`, a
`Frame`). The tree is created through the registry, so no code is needed for the
classes, and the result is the same tree `loadForm` builds.

`NfmOptions` (`newNfmOptions(strict = true, handlers = nil)`):

| Field | Meaning |
|---|---|
| `strict` | `true` (default): an unknown class, property or handler raises `NfmError` with `file:line:col`. `false`: the item is skipped and a line is added to `warnings` |
| `handlers` | A `HandlerResolver` that binds `onXxx = name`. `nil`: names are only recorded (a designer's view of the form). With a resolver an unknown name is a problem |
| `baseDir` | The folder image paths are relative to (default: the folder of the form file given to `loadNfm`, else the current folder) |
| `warnings` | Collected problems when not strict; also pictures that could not be loaded (those never raise) |

`notifyHandlers(table)` is a resolver for `NotifyEvent`s. A resolver for other
event types receives the event's type name and returns a `HandlerBox[T]`:

```nim
let resolver: HandlerResolver = proc(name, eventType: string): RootRef =
  if name == "closing" and eventType == "FormCloseEvent":
    HandlerBox[FormCloseEvent](fn: proc(f: Form, a: var CloseAction) = a = caHide)
  else: nil
```

## Saving

```nim
writeFile("LoginForm.nfm", formToNfm(form))
```

`formToNfm(form, rootName = "")` (and `objectToNfm(obj)`) serialise a live form
through the registry. For a file in canonical form, `formToNfm(loadNfm(text)) ==
text`. `parseNfm(text)` gives the syntax tree (`NfmNode`: `name`, `className`,
`props`, `children`, positions) and `writeNfm(node)` writes it back.

## Form inheritance

A form can inherit from another one, as in Delphi: the descendant has everything
the ancestor has, can change properties of the inherited objects and can add
objects of its own. Changing the ancestor changes every descendant the next time
it is built; there are no copies.

```
inherited Form2: Form2
  ancestor = 'unit1.nfm'
  caption = 'Details'
  inherited okButton: Button
    caption = 'Save'
    onClick = okClick
  end
  object cancelButton: Button
    caption = 'Cancel'
    onClick = cancelClick
  end
end
```

* The file starts with `inherited Name: Name` instead of `object`. The class is
  the form's own name, like `TForm2` in Delphi.
* `ancestor = '...'` is the first property: the ancestor's `.nfm`, relative to
  this file. The file is the single place that names the ancestor, so `loadForm`,
  `loadNfm`, the IDE and `formToNfm` all find it the same way (Delphi reads it
  from the Pascal class declaration; here the form file is the declaration).
  `loadForm Form2, "unit2.nfm"` needs no extra argument.
* `inherited Button1: Button` selects an object of the ancestor (found by name,
  at any depth; nest the blocks the way the ancestor does). It lists only the
  properties that differ from the ancestor. `object` blocks are new objects
  (inside an inherited block they are children of that inherited object).
  Objects nothing changed in are not written. `inherited` is only allowed in a
  file whose root is `inherited`.

**`loadForm`.** `Form2` becomes `ref object of Form1`, where `Form1` is the root
name of the ancestor file; the unit declaring it must be imported. The
ancestor's fields and handlers are inherited, so `self.okButton` works in
`Form2` handlers. `initForm2` calls `initForm1`, then applies the differences
and creates the new objects, so the ancestor's file is applied first. Handlers
are looked up like in any form, as `proc name(self: Form2, ...)`. A handler the
ancestor chain binds (`onClick = okClick` in `Form1`) is overridden by writing a
`proc okClick(self: Form2, ...)` in the descendant's module: `initForm2` runs
`initForm1` and then re-binds every such event to the descendant's proc (the
overload with the more specific `self` wins), like a Delphi override. The
descendant's file need not mention the event; naming it (`onClick = okClick` in
an `inherited` block) works too and also binds a handler of another name. Call
the ancestor's version with `okClick(Form1(self), sender)`; export it with
`proc okClick*(self: Form1, ...)` so another module sees it. The calling
module's source is scanned for the `proc name(self: Form2` lines, so write the
overrides out in that file (an `include`d or macro-generated one is not seen).
(The ancestor's own code keeps calling the ancestor's proc, as it is bound at
compile time.) Like all `loadForm` output, none of this
uses the registry.

**`loadNfm`.** The ancestor file is resolved relative to the descendant's file
(`loadNfmFile`, or the `fileName` argument of `loadNfm`) and built first; the
returned form has the descendant's name. Components that come from an ancestor
have `inherited = true` (`Component.inherited`), and the root has `ancestorFile`
and `ancestorPath`. A missing or looping ancestor chain is an `NfmError`. Handlers are found by
name only, so the same name in both forms is one handler; to give the
descendant its own, set `NfmOptions.overrideHandlers`, a second resolver that is
asked after the ancestor is built for every handler name the ancestor bound and
whose answer replaces that binding.

**`formToNfm`** writes a descendant as the difference to a freshly built
ancestor, so a file in this form loads and saves back byte for byte. A property
set back to the ancestor's value disappears from the file; one the ancestor sets
and the descendant clears is written with the default value. A handler the
descendant binds again is kept (`Component.handlerOverrides`) even when the name
equals the ancestor's (an override that exists only as a proc in the module is
not in the form file at all).

**Designer.** `FormDesigner` and `ObjectInspector` treat inherited components
as Delphi does: they carry a small flag, the inspector title says `(inherited)`,
they can be moved, resized and edited but not deleted (`deleteSelection` refuses)
or renamed. New components can be added anywhere.

## Converting to the `form` macro

`nfmToFormMacro(text)` returns the `form` macro source for a file:

```nim
echo nfmToFormMacro("object Login: Form\n  caption = 'Hi'\n  object ok: Button\n    onClick = okClick\n  end\nend\n")
```

```nim
form Login:
  name = "Login"
  caption = "Hi"
  Button ok:
    onClick: okClick(self, sender)
  proc okClick(self: Login, sender: Control) = discard
```

Sub-properties stay `font.size = 12` (the `form` macro accepts that for `font`,
`margins`, `padding` and `constraints`). Events other than `NotifyEvent` are
written as comments, since the `form` shorthand only exists for `NotifyEvent`.
Menu items, columns and panels need `loadForm` or `loadNfm`: the `form` macro
builds children with `newT(parent: Container)` only.

## The property registry

The registry (`nimvcl/dsl/props`) knows each registered class with its parent,
factory and **published properties**: name, kind, category, getter, setter. It is
what `loadNfm`, `formToNfm`, the [object inspector](../components/inspector.md)
and a designer use. `nimvcl/dsl/props_std` registers every stock control
(`import nimvcl/dsl/nfm` imports it for you; `loadForm` does not need it).

| Kind (`PropKind`) | Nim types | `PropValue` field |
|---|---|---|
| `pkBool` | `bool` | `b` |
| `pkInt` | integers | `i` |
| `pkFloat` | `float32`, `float` | `f` |
| `pkString` | `string` | `s` |
| `pkEnum` | any enum | `i` (the ordinal; names in `PropInfo.enumNames`) |
| `pkSet` | `set[SomeEnum]` | `bits` (bit `ord(e)`) |
| `pkColor` | `Color` | `color` |
| `pkFont`, `pkSpacing`, `pkConstraints` | `FontSpec`, `Spacing`, `SizeConstraints` | `font`, `spacing`, `cons` (parts are sub-properties) |
| `pkObject` | any `ref` to a registered object | `obj`, `objName` |
| `pkImage` | `Image` | `image` |
| `pkStrings` | `seq[string]` | `strs` |
| `pkEvent` | proc types (`NotifyEvent`, ...) | `handler` (the handler's name) |

Categories (`PropCategory`): `pcLayout`, `pcAppearance`, `pcBehaviour`,
`pcData`, `pcEvents`.

```nim
import nimvcl/dsl/props_std

let ci = classByName("Button")                     # nil when unknown
for p in ci.propsOf: echo p.name, " ", p.kind, " ", p.category   # inherited ones included
let b = newButton(nil, "OK")
setProp(b, "caption", pvString("Go"))
setProp(b, "font.size", pvFloat(18))               # sub-properties by dotted name
echo getProp(b, "caption").s                       # Go
echo isDefault(b, "caption")                       # false: differs from a fresh Button
echo classOf(b).name                               # Button: the most derived registered class
let a = ci.findProp("align")
echo a.enumNames                                   # @["alNone", "alTop", ...]
echo a.enumValue("alClient"), " ", a.enumName(5)   # 5 alClient
let btn2 = ci.createObject(nil, nil)               # a new instance through the registered factory
for p in classByName("Form").findProp("onClose").params:
  echo p.name, ": ", p.typeName                    # sender: Form / action: var CloseAction
```

Event types such as `NotifyEvent`, `FormCloseEvent` and `PopupEvent` are public,
so an IDE can build a handler stub from `params` without its own table. Every
`Component` also has an identity `hash`, so `Table[Control, X]` and
`HashSet[Component]` work without a local `hash` proc.

| Call | Result |
|---|---|
| `classByName(name)`, `allClasses()`, `classOf(obj)` | lookup; `classOf` answers the nearest registered class of a user subclass |
| `propsOf(ci)`, `findProp(ci, name)` | the properties (inherited first); `findProp` accepts `font.size`, `anchors.akLeft` |
| `ci.defaultEvent`, `defaultEventOf(obj)` | the event a double click on the object in a designer creates a handler for (`onClick` for controls, `onChange` for Edit, Memo, ComboBox, ListBox, CheckBox, RadioButton, TrackBar, ScrollBar and SpinEdit, `onTimer` for Timer, `onCreate` for Form); a class that sets none inherits its parent's |
| `getProp(obj, name)`, `setProp(obj, name, value)` | `PropValue` access; `PropError` for an unknown name or a value of the wrong kind |
| `isDefault(obj, name)`, `defaultOf(ci, prop)` | defaults are measured on a fresh instance of the object's class |
| `kidsOf(obj)`, `createObject(ci, owner, parent)` | the owned children (controls, menu items, columns, panels) and creation |
| `handlerNameOf(obj, "onClick")`, `setHandlerName` | the handler names recorded for events |
| `PropInfo.params`, `PropInfo.returnType` | of an event: the handler's parameters (`name`, `typeName` as written, e.g. `var CloseAction`) and result type, from the event's proc type |
| `subProps(prop)` | the virtual sub-properties of a composite or a set |

### Registering your own classes

`registerClass` registers a class without touching its module. The default
factory is `newT(parent: Container)` for a `Control` and `newT(owner)` for any
other component.

```nim
import nimvcl
import nimvcl/dsl/props

type Badge = ref object of Panel
  fLevel: int
proc level*(b: Badge): int = b.fLevel
proc `level=`*(b: Badge, v: int) = b.fLevel = v
proc newBadge*(parent: Container = nil): Badge =
  new result
  result.initPanel(parent)
  if parent != nil: parent.insertControl result

registerClass(Badge, parent = Panel):
  category Data:
    level: int
```

After that `object b: Badge` works in `.nfm` files (with `loadForm` the type and
constructor just have to be in scope). The statements:

| Statement | Meaning |
|---|---|
| `name: Type` | a property, read and written as `self.name` |
| `prop name, Type, getter, setter` | a property with accessor procs `proc(self: T): Type` / `proc(self: T, v: Type)` |
| `category Layout\|Appearance\|Behaviour\|Data\|Events:` + block | category of the properties inside (default `Behaviour`; a proc-typed property is an event) |
| `nostore a, b` | never written to a form file (implied by another property) |
| `hide a, b` | written to form files but not listed by the object inspector (edited together with another property by its dialog) |
| `skipWhen p, (cond)` | not written while `cond` (over `self`) holds |
| `defaultWhen p, flag` | counts as default while the bool property `flag` is true |

Properties of your own classes are applied in the order you register them;
the dependencies of "Property order" are keyed by property name, so a property
that has one of those names (`items`, `itemIndex`, ...) is ordered too, and
there is no per-class way to declare a dependency.

Options: `parent = Base`, `abstract = true` (cannot be created), `name = "..."`,
`create = <expr>` (names `owner: Component`, `parent: RootRef`), `attach = <expr>`
(`parent`, `child`; for items not added by their constructor), `kids = <expr>`
(`self`; the owned children a class shows), `protoParent = <expr>` (a parent for the
instance that measures defaults).

## Limitations

* The registry covers the stock controls. `DockSite` is not registered (its
  layout is saved with `saveLayout`); the items of `TreeView`, `ListView` and
  `StringGrid` are text lists (see "Item data").
* `GridPanel` cell positions of children are not stored (no property for them
  yet).
* A handler named in a file is bound at run time only for event types whose
  resolver you provide (`NotifyEvent` through a table).
* `loadForm` does not use the registry (see "What `loadForm` imports"), so it relies on
  the compiler to resolve classes, properties and enum names; a property of a
  custom class needs a plain Nim setter, or one of the special cases of the
  macro (`shortcut`, `GridPanel.columns`/`rows`, `Memo.lines`,
  `ListView.items`/`TreeView.items`, `StringGrid.cells`,
  `DrawGrid.colWidths`/`rowHeights`, and string values for `Image` /
  `seq[Image]` properties, which are embedded).
