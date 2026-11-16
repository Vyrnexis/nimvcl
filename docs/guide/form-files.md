# Form files, the property registry and `loadForm`

A form can be described in a text file, a Delphi `.dfm` for nimvcl, called
`.nfm`. The file is the designer's source of truth. At compile time
`loadForm` turns it into a typed form, just like the `form` macro (see
[Forms and frames](../forms.md)); at run time `loadNfm` builds the same tree
from the file's text. Both are built on the **property registry**, nimvcl's
answer to Delphi's RTTI.

```nim
import nimvcl
import nimvcl/dsl/nfm            # not part of `import nimvcl`: it pulls in the registry

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
| object reference | the other object's name, or `nil` | `focusControl = user` |
| event | the handler's name | `onClick = okClick` |

String escapes: `\\` `\'` `\n` `\r` `\t` `\0` and `\xHH`. A string ends on its
line, so write `\n` for a line break; non-ASCII text stays as it is (UTF-8).

String lists (`ComboBox.items`, `ListBox.items`, `Memo.lines`, `TabControl.tabs`):

```
items = (
  'Viewer'
  'Editor'
)
```

### Sub-properties

`font`, `margins`, `padding` and `constraints` are written one part at a time,
and only the parts that differ from the default:

```
font.size = 18
font.style = [fsBold]
margins.left = 8
constraints.minWidth = 100
```

The parts: `font.family`, `font.size`, `font.style`; `margins.left|top|right|bottom`
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

### What is stored

The writer emits only properties that differ from a fresh instance of the same
class, in registry order: ancestors' properties first (`left`, `top`, `width`,
`height`, `align`, ...), then the class's own, and events last. `name` is not a
property line (it is in the `object` line). Properties that are implied by
others (`parentFont`, `parentColor`, `CheckBox.checked`) are not written, and a
`ComboBox.text` is left out while an item is selected. Images, data of a
`TreeView`, the cells of a grid and the items of a `ListView` have no text form;
`DockSite` layouts are saved with `saveLayout` instead.

## `loadForm` (compile time)

```nim
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
items through `nfmMake`), then every property is assigned in file order, so a
property may refer to any named object, also one further down. A root of class
`Frame` produces a `Frame` subtype with the usual `newX(parent, left, top, width,
height)`. A root of another class uses `initThatClass(self, owner)` as the `form`
macro does for `form Name of Base`.

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
| `warnings` | Collected problems when not strict |

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
(`import nimvcl/dsl/nfm` imports it for you).

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
```

| Call | Result |
|---|---|
| `classByName(name)`, `allClasses()`, `classOf(obj)` | lookup; `classOf` answers the nearest registered class of a user subclass |
| `propsOf(ci)`, `findProp(ci, name)` | the properties (inherited first); `findProp` accepts `font.size`, `anchors.akLeft` |
| `getProp(obj, name)`, `setProp(obj, name, value)` | `PropValue` access; `PropError` for an unknown name or a value of the wrong kind |
| `isDefault(obj, name)`, `defaultOf(ci, prop)` | defaults are measured on a fresh instance of the object's class |
| `kidsOf(obj)`, `createObject(ci, owner, parent)` | the owned children (controls, menu items, columns, panels) and creation |
| `handlerNameOf(obj, "onClick")`, `setHandlerName` | the handler names recorded for events |
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
| `skipWhen p, (cond)` | not written while `cond` (over `self`) holds |
| `defaultWhen p, flag` | counts as default while the bool property `flag` is true |

Options: `parent = Base`, `abstract = true` (cannot be created), `name = "..."`,
`create = <expr>` (names `owner: Component`, `parent: RootRef`), `attach = <expr>`
(`parent`, `child`; for items not added by their constructor), `kids = <expr>`
(`self`; the owned children a class shows), `protoParent = <expr>` (a parent for the
instance that measures defaults).

## Limitations

* The registry covers the stock controls. `DockSite`, tree nodes, list items and
  grid cells are not registered (they are data, not design).
* `GridPanel` cell positions of children are not stored (no property for them
  yet), and a `Control` has no `popupMenu` property: attach menus in code.
* A handler named in a file is bound at run time only for event types whose
  resolver you provide (`NotifyEvent` through a table).
* `loadForm` cannot see the registry (it runs in the compiler), so it relies on
  the compiler to resolve classes, properties and enum names; a property of a
  custom class needs a plain Nim setter, or one of the special cases of the
  macro (`shortcut`, `GridPanel.columns`/`rows`, `Memo.lines`).
