# Forms and frames

`form` declares a window as a typed tree, like a Delphi `.dfm` that the Nim
compiler checks. `frame` does the same for a reusable composite control
(VCL `TFrame`). Both are exported by `import nimvcl`.

```nim
import nimvcl

form LoginForm:
  caption = "Sign in"
  width = 420; height = 380
  var attempts: int                      # extra field (also: var x = 3)
  GroupBox account:                      # named child -> field `account: GroupBox`
    caption = "Account"
    align = alTop; height = 220
    Label userLbl:
      caption = "User name"
      focusControl = self.user           # a later sibling: fine
    Edit user:
      placeholder = "you@example.com"
  Label:                                 # unnamed child: in the tree, no field
    caption = "hello"
  Button ok:
    caption = "OK"; isDefault = true
    onClick: self.validate()             # NotifyEvent shorthand, `sender` available
  Button cancel:
    caption = "Cancel"
    onClick = proc(sender: Control) = self.close()   # any closure, assigned as is
  proc validate(self: LoginForm) =       # methods live inside the block
    inc self.attempts
  init:                                  # runs last (like FormCreate)
    self.ok.caption = "Sign in"

when isMainModule:
  Application.run(newLoginForm())
```

## Syntax

Inside a `form`/`frame` block, every statement is one of:

| Statement | Meaning |
|---|---|
| `prop = value` | property assignment on the enclosing node (`self` at top level). `value` is any expression |
| `Type name:` + block | child of the enclosing node, stored in the field `name` (and `name.name = "name"`) |
| `Type:` + block | unnamed child (a local only) |
| `onEvent: stmts` | shorthand for `onEvent = proc(sender: Control) = stmts`; only for events of type `NotifyEvent` |
| `var x: T`, `var x = v`, `var x: T = v` | extra field on the generated type, default applied first. Top level only |
| `proc` / `func` / `method` / `template` / `iterator` / `converter` | emitted between the type and the init proc, so event closures can call them. Top level only |
| `init:` | statements run at the end of construction. May appear several times. Top level only |

`self` is the form (typed) everywhere. Child names and `var` names must be
unique within a form and must not clash with existing properties
(`tag`, `name`, `caption`, ...).

## What is generated

For `form LoginForm` (and `form LoginForm of Base`, `Base` a `Form` subtype):

```nim
type LoginForm* = ref object of Form      # or of Base; one field per named child and var
proc initLoginForm*(self: LoginForm, owner: Component = nil)
proc newLoginForm*(owner: Component = nil): LoginForm
```

`initLoginForm` runs, in this order:

1. the base init (`initForm`, or `initBase`; for a hand-written base the proc
   `initBase(self, owner)` or `initBase(self)` must exist),
2. `var` defaults,
3. every child, top-down: `newT(parent)` with the enclosing child as parent,
4. every property and event assignment, in source order,
5. the `init:` blocks.

Steps 3 and 4 are separate passes, so a property can refer to any child, also
one declared further down. Because the base init runs first, `form B of A`
builds A's children and runs A's `init:` before B's; B's assignments are applied
after A's and win.

`frame AddressFrame:` generates `type AddressFrame* = ref object of Frame`
(`Frame` is a transparent `Panel` that draws nothing) and the usual control
constructor `newAddressFrame(parent: Container = nil, left, top, width, height)`,
so frames are children like any other control:

```nim
frame AddressFrame:
  width = 200; height = 60
  Edit street:
    placeholder = "Street"
  Edit city:
    top = 30

form Order:
  AddressFrame billing:
    top = 10
  AddressFrame shipping:
    top = 90
  init:
    self.billing.street.text = "Main St"   # two independent instances
```

## Custom controls as children

Any identifier `T` works as a child type if there is a type `T` and a
constructor callable as `newT(parent)` with `parent: Container` (every other
parameter defaulted):

```nim
type Badge* = ref object of Panel
proc newBadge*(parent: Container = nil): Badge =
  new result
  result.initPanel(parent)
  if parent != nil: parent.insertControl result
```

(Stock controls use `placeControl`, see `controls/common.nim`.)

## Errors

* `nimvcl form: `Button` has no property `captoin``, at the property's line.
* `nimvcl form: unknown control type `Buttn`: ...`, at the child's line.
* `nimvcl form: duplicate name `ok` ...`.
* `nimvcl form: `caption` is reserved in `MyForm`...`: a child (or `var`) cannot
  be named like a field or property of `Component`, `Control` or `Form`, since
  the generated field would clash with it. Reserved: `name`, `tag`, `owner`,
  `components`, `actionLink`, `caption`, `parent`, `left`, `top`, `width`,
  `height`, `align`, `anchors`, `margins`, `padding`, `constraints`,
  `autoSize`, `visible`, `enabled`, `hint`, `cursor`, `font`, `parentFont`,
  `color`, `parentColor`, `tabStop`, `tabOrder`, `children`, `host`, `ui`,
  `win`, `menuBar`, `popupMenus`, `position`, `borderStyle`, `formStyle`,
  `modalResult`, `designRect`, `designBase`, `designBaseSet` and the event
  names `onClick`, `onDblClick`, `onMouseEnter`, `onMouseLeave`, `onEnter`,
  `onExit`, `onResize`, `onMouseDown`, `onMouseUp`, `onMouseMove`, `onShow`,
  `onHide`, `onActivate`, `onDeactivate`, `onClose`, `onCloseQuery`. Pick
  another name, such as `captionEdit`.
* `onChange: ...` on a non-`NotifyEvent` event (e.g. `Form.onClose`) is
  rejected with a hint to write the full `proc`.
* A value of the wrong type gives the compiler's own type error on the
  property's line.

## Limitations

* Properties are assigned with a plain `child.prop = value`; nested targets
  such as `font.size = 12` are not supported (assign a whole `font(...)`).
* Child types must be a plain identifier (no module qualification). Their
  constructor is looked up by name, so import the module that defines it.
* Procs inside the block are not forward-declared: a proc can only call procs
  written above it (order them by dependency or add a forward declaration).
* The shorthand body is a statement block; a trailing non-void expression
  needs `discard`. (Control constructors themselves are `{.discardable.}`, so
  `newLabel(...)` as a statement needs nothing.)
* Generated code refers to `Form`, `Frame`, `Container`, `Component`, `Control`,
  `NotifyEvent`, `placeControl` by name, so `import nimvcl` is required in the
  module that uses the macros.
