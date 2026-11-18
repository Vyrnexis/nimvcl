## Property registry: the Delphi RTTI analogue. Classes and their designer
## ("published") properties are registered from the outside, without touching
## the control modules; the form file loader (`nfm.nim`), the object inspector
## (`controls/inspector.nim`) and the designer all work through it.
##
## ```nim
## registerClass(Button, parent = Control):
##   category Behaviour:
##     isDefault: bool
##     modalResult: ModalResult
##   category Appearance:
##     caption: string
##   category Events:
##     onClick: NotifyEvent
## ```
##
## `registerClass(T, parent = P, abstract = false, create = <expr>, attach =
## <expr>, kids = <expr>, name = "Name")`:
##
## * `T` is the Nim type; the class name is `T` unless `name` is given.
## * the default factory is `newT(parent: Container)` for a `Control` type and
##   `newT(owner)` for any other `Component`. `create` replaces it (the names
##   `owner: Component` and `parent: RootRef` are in scope); `abstract = true`
##   registers a class that cannot be created (a base for inheritance).
## * `attach` (names `parent`, `child`) runs after `create` for classes that are
##   not attached by their constructor (menu items, list columns, panels).
## * `protoParent` an expression making a parent for the instance whose values
##   serve as defaults, for classes that cannot exist without one.
## * `kids` (name `self`) lists the owned children a class shows in the tree
##   (a `Container` lists its `children`; classes with internal controls
##   override it).
##
## Body statements:
##
## * `name: Type` a property; its value is read and written with `self.name`.
##   A property with a proc type whose name is `onXxx` is an event.
## * `prop name, Type, getter, setter` a property with explicit accessor procs
##   `proc(self: T): Type` and `proc(self: T, v: Type)`.
## * `category Layout|Appearance|Behaviour|Data|Events:` followed by an
##   indented block sets the category of the properties inside.
## * `nostore a, b` the properties are never written to a form file (they are
##   implied by others).
## * `skipWhen text, (self.itemIndex >= 0)` the property is not stored while the
##   condition (over `self`) holds, because another property implies it.
## * `defaultWhen font, parentFont` the property counts as default while the
##   bool property `parentFont` is true.
##
## Defaults are measured, not declared: a property is "default" when it has the
## value a freshly created instance of the object's class has.

import std/[macros, tables, strutils]
import ../graphics/[color, font, image]
import ../core/[types, component, control]

type
  Obj* = RootRef
    ## A registered object: a `Component`, or a plain `ref object of RootObj`
    ## (list columns, status panels).

  PropKind* = enum
    pkBool, pkInt, pkFloat, pkString, pkEnum, pkSet, pkColor, pkFont,
    pkSpacing, pkConstraints, pkObject, pkImage, pkImages, pkStrings,
    pkCollection, pkEvent

  PropCategory* = enum
    pcLayout, pcAppearance, pcBehaviour, pcData, pcEvents

  PropValue* = object
    case kind*: PropKind
    of pkBool: b*: bool
    of pkInt, pkEnum, pkCollection: i*: int   ## number, enum ordinal, or the item count of a collection
    of pkFloat: f*: float
    of pkString: s*: string
    of pkSet: bits*: int64               ## bit `ord(e)` set when `e` is in the set
    of pkColor: color*: Color
    of pkFont: font*: FontSpec
    of pkSpacing: spacing*: Spacing
    of pkConstraints: cons*: SizeConstraints
    of pkObject:
      obj*: Obj                          ## referenced object (nil: none)
      objName*: string                   ## its name when read from text
    of pkImage: image*: Image
    of pkImages: imgs*: seq[Image]
    of pkStrings: strs*: seq[string]
    of pkEvent: handler*: string         ## handler name ("" none)

  HandlerBox*[T] = ref object of RootObj
    ## A typed event handler handed to the loader by a `HandlerResolver`.
    fn*: T

  HandlerResolver* = proc(handler, eventType: string): RootRef {.closure.}
    ## Finds the handler named `handler` for an event of type `eventType`
    ## (`"NotifyEvent"`, ...) and returns it as a `HandlerBox[EventType]`, or
    ## nil when there is none.

  PropError* = object of CatchableError

  EventParam* = object
    ## One parameter of an event's proc type.
    name*: string                        ## `sender`
    typeName*: string                    ## `Control`, `var CloseAction`

  CollectionOps* = ref object
    ## How a `pkCollection` property (the owned children a designer lists in a
    ## collection editor: columns, panels, menu items, pages, tool buttons)
    ## is read and changed.
    childClass*: string                  ## class of the items (`"ListColumn"`)
    items*: proc(o: Obj): seq[Obj] {.closure.}
    add*: proc(o: Obj): Obj {.closure.}  ## creates, attaches and returns a new item
    remove*: proc(o: Obj, child: Obj) {.closure.}
    move*: proc(o: Obj, child: Obj, newIndex: int) {.closure.}   ## nil: items cannot be reordered

  PropInfo* = ref object
    name*: string                        ## `"caption"`; a sub-property is `"font.size"`
    kind*: PropKind
    category*: PropCategory
    typeName*: string                    ## the Nim type as written at registration
    params*: seq[EventParam]             ## events: the handler's parameters (not counting a form's `self`)
    returnType*: string                  ## events: the result type, "" for none
    enumNames*: seq[string]              ## pkEnum: values by ordinal; pkSet: elements by bit
    stored*: bool                        ## written to form files when not default
    defaultWhen*: string                 ## default while this bool property is true
    skipWhen*: proc(o: Obj): bool {.closure.}   ## not stored while this returns true (value implied by another property)
    declaredIn*: ClassInfo
    get*: proc(o: Obj): PropValue {.closure.}
    set*: proc(o: Obj, v: PropValue) {.closure.}
    isAssigned*: proc(o: Obj): bool {.closure.}                  ## events: a handler is set
    bindHandler*: proc(o: Obj, h: RootRef): bool {.closure.}     ## events
    clearHandler*: proc(o: Obj) {.closure.}                      ## events
    coll*: CollectionOps                 ## pkCollection: the operations
    subs: seq[PropInfo]

  ClassInfo* = ref object
    name*: string                        ## class name used in form files
    nimType*: string                     ## name of the Nim type
    parent*: ClassInfo
    props*: seq[PropInfo]                ## own properties, in registration order
    abstract*: bool
    matches*: proc(o: Obj): bool {.closure.}
    create*: proc(owner: Component, parent: Obj): Obj {.closure.}
    attach*: proc(parent, child: Obj) {.closure.}
    kids*: proc(o: Obj): seq[Obj] {.closure.}
    protoParent*: proc(): Obj {.closure.}   ## parent for the default-measuring instance
    defaultsReady: bool
    defaults: Table[string, PropValue]

var
  classTable: Table[string, ClassInfo]
  classList: seq[ClassInfo]
  aliasTable: Table[string, string]

# ------------------------------------------------------------------ values

func pvBool*(b: bool): PropValue = PropValue(kind: pkBool, b: b)
func pvInt*(i: int): PropValue = PropValue(kind: pkInt, i: i)
func pvFloat*(f: float): PropValue = PropValue(kind: pkFloat, f: f)
func pvString*(s: string): PropValue = PropValue(kind: pkString, s: s)
func pvEnum*(i: int): PropValue = PropValue(kind: pkEnum, i: i)
func pvSet*(bits: int64): PropValue = PropValue(kind: pkSet, bits: bits)
func pvColor*(c: Color): PropValue = PropValue(kind: pkColor, color: c)
func pvFont*(f: FontSpec): PropValue = PropValue(kind: pkFont, font: f)
func pvSpacing*(s: Spacing): PropValue = PropValue(kind: pkSpacing, spacing: s)
func pvConstraints*(c: SizeConstraints): PropValue =
  PropValue(kind: pkConstraints, cons: c)
func pvObject*(o: Obj, name = ""): PropValue =
  PropValue(kind: pkObject, obj: o, objName: name)
func pvStrings*(s: seq[string]): PropValue = PropValue(kind: pkStrings, strs: s)
func pvEvent*(handler: string): PropValue = PropValue(kind: pkEvent, handler: handler)

func `==`*(a, b: PropValue): bool =
  if a.kind != b.kind: return false
  case a.kind
  of pkBool: a.b == b.b
  of pkInt, pkEnum, pkCollection: a.i == b.i
  of pkFloat: a.f == b.f
  of pkString: a.s == b.s
  of pkSet: a.bits == b.bits
  of pkColor: a.color == b.color
  of pkFont: a.font.family == b.font.family and a.font.size == b.font.size and
             a.font.style == b.font.style
  of pkSpacing: a.spacing == b.spacing
  of pkConstraints: a.cons == b.cons
  of pkObject: a.obj == b.obj
  of pkImage: a.image == b.image
  of pkImages: a.imgs == b.imgs
  of pkStrings: a.strs == b.strs
  of pkEvent: a.handler == b.handler

func hasBit*(bits: int64, i: int): bool = (bits and (1'i64 shl i)) != 0
func withBit*(bits: int64, i: int, on: bool): int64 =
  if on: bits or (1'i64 shl i) else: bits and not (1'i64 shl i)

# -------------------------------------------------- type <-> PropValue glue

proc enumNamesOf*[E: enum](t: typedesc[E]): seq[string] =
  for e in E: result.add $e

proc enumNamesOf*[E: enum](t: typedesc[set[E]]): seq[string] =
  for e in E: result.add $e

proc enumOrdinals[E: enum](t: typedesc[E]): seq[int] =
  for e in E: result.add ord(e)

proc setToBits*[E: enum](s: set[E]): int64 =
  for e in s: result = result or (1'i64 shl ord(e))

proc bitsToSet*[E: enum](bits: int64): set[E] =
  for e in E:
    if hasBit(bits, ord(e)): result.incl e

proc setFromPV[E: enum](v: PropValue, t: typedesc[set[E]]): set[E] =
  if v.kind != pkSet: raise newException(PropError, "expected a set value")
  bitsToSet[E](v.bits)

template kindOfType*(T: typedesc): PropKind =
  when T is bool: pkBool
  elif T is Color: pkColor
  elif T is FontSpec: pkFont
  elif T is Spacing: pkSpacing
  elif T is SizeConstraints: pkConstraints
  elif T is string: pkString
  elif T is seq[string]: pkStrings
  elif T is Image: pkImage
  elif T is seq[Image]: pkImages
  elif T is enum: pkEnum
  elif T is set: pkSet
  elif T is SomeInteger: pkInt
  elif T is SomeFloat: pkFloat
  elif T is (proc): pkEvent
  elif T is ref: pkObject
  else: {.error: "registry: unsupported property type " & $T.}

proc objectName*(o: Obj): string =
  if o != nil and o of Component: result = Component(o).name

proc toPV*[T](x: T): PropValue =
  when T is bool: pvBool(x)
  elif T is Color: pvColor(x)
  elif T is FontSpec: pvFont(x)
  elif T is Spacing: pvSpacing(x)
  elif T is SizeConstraints: pvConstraints(x)
  elif T is string: pvString(x)
  elif T is seq[string]: pvStrings(x)
  elif T is Image: PropValue(kind: pkImage, image: x)
  elif T is seq[Image]: PropValue(kind: pkImages, imgs: x)
  elif T is enum: pvEnum(ord(x))
  elif T is set: pvSet(setToBits(x))
  elif T is SomeInteger: pvInt(int(x))
  elif T is SomeFloat: pvFloat(float(x))
  elif T is ref: pvObject(Obj(x), objectName(Obj(x)))
  else: {.error: "registry: unsupported property type " & $T.}

proc kindError(want: string, v: PropValue): ref PropError =
  newException(PropError, "expected " & want & ", got " & $v.kind)

proc fromPV*[T](v: PropValue, t: typedesc[T]): T =
  when T is bool:
    if v.kind != pkBool: raise kindError("a bool", v)
    v.b
  elif T is Color:
    if v.kind != pkColor: raise kindError("a colour", v)
    v.color
  elif T is FontSpec:
    if v.kind != pkFont: raise kindError("a font", v)
    v.font
  elif T is Spacing:
    if v.kind != pkSpacing: raise kindError("a spacing", v)
    v.spacing
  elif T is SizeConstraints:
    if v.kind != pkConstraints: raise kindError("constraints", v)
    v.cons
  elif T is string:
    if v.kind != pkString: raise kindError("a string", v)
    v.s
  elif T is seq[string]:
    if v.kind != pkStrings: raise kindError("a string list", v)
    v.strs
  elif T is Image:
    if v.kind != pkImage: raise kindError("an image", v)
    v.image
  elif T is seq[Image]:
    if v.kind != pkImages: raise kindError("an image list", v)
    v.imgs
  elif T is enum:
    if v.kind != pkEnum: raise kindError("an enum value", v)
    if v.i < ord(low(T)) or v.i > ord(high(T)):
      raise newException(PropError, "enum value " & $v.i & " out of range for " & $T)
    T(v.i)
  elif T is set:
    setFromPV(v, T)
  elif T is SomeInteger:
    case v.kind
    of pkInt: T(v.i)
    of pkFloat:
      if v.f != float(int(v.f)): raise kindError("an integer", v)
      T(int(v.f))
    else: raise kindError("an integer", v)
  elif T is SomeFloat:
    case v.kind
    of pkFloat: T(v.f)
    of pkInt: T(v.i)
    else: raise kindError("a number", v)
  elif T is ref:
    if v.kind != pkObject: raise kindError("an object reference", v)
    if v.obj == nil: T(nil)
    elif v.obj of T: T(v.obj)
    else: raise newException(PropError, "object of the wrong class for " & $T)
  else: {.error: "registry: unsupported property type " & $T.}

# ------------------------------------------------------------ handler names

proc handlerNameOf*(o: Obj, event: string): string =
  ## Name of the handler bound to `event` by a form file ("" none).
  if o != nil and o of Component:
    for (e, h) in Component(o).handlerNames:
      if e == event: return h

proc setHandlerName*(o: Obj, event, handler: string) =
  if o == nil or not (o of Component): return
  let c = Component(o)
  for i in 0 ..< c.handlerNames.len:
    if c.handlerNames[i][0] == event:
      if handler.len == 0: c.handlerNames.delete(i)
      else: c.handlerNames[i][1] = handler
      return
  if handler.len > 0: c.handlerNames.add (event, handler)

# ---------------------------------------------------------------- PropInfo

macro eventSignature(T: typedesc): untyped =
  ## `(params, returnType)` of a proc type, as literals.
  var impl = T.getTypeInst[1].getTypeImpl
  while impl.kind == nnkBracketExpr or impl.kind == nnkSym: impl = impl.getTypeImpl
  var params = newTree(nnkBracket)
  var ret = newLit("")
  if impl.kind == nnkProcTy:
    if impl[0][0].kind != nnkEmpty: ret = newLit(impl[0][0].repr)
    for d in impl[0][1 .. ^1]:
      for j in 0 ..< d.len - 2:
        params.add newTree(nnkObjConstr, bindSym"EventParam",
                           newTree(nnkExprColonExpr, ident"name", newLit(d[j].strVal)),
                           newTree(nnkExprColonExpr, ident"typeName", newLit(d[^2].repr)))
  result = newTree(nnkTupleConstr, prefix(params, "@"), ret)

proc propInfo*[C, V](name: string, cat: PropCategory, typeName: string,
                     getter: proc(c: C): V, setter: proc(c: C, v: V)): PropInfo =
  ## One property of class `C` with value type `V`.
  result = PropInfo(name: name, category: cat, typeName: typeName,
                    kind: kindOfType(V), stored: true)
  when V is enum or V is set:
    result.enumNames = enumNamesOf(V)
  when V is (proc):
    result.category = pcEvents
    let sig = eventSignature(V)
    result.params = sig[0]
    result.returnType = sig[1]
    result.get = proc(o: Obj): PropValue = pvEvent(handlerNameOf(o, name))
    result.set = proc(o: Obj, v: PropValue) =
      if v.kind != pkEvent: raise kindError("a handler name", v)
      setHandlerName(o, name, v.handler)
      if v.handler.len == 0: setter(C(o), nil)
    result.isAssigned = proc(o: Obj): bool = getter(C(o)) != nil
    result.bindHandler = proc(o: Obj, h: RootRef): bool =
      if h != nil and h of HandlerBox[V]:
        setter(C(o), HandlerBox[V](h).fn)
        true
      else: false
    result.clearHandler = proc(o: Obj) =
      setter(C(o), nil)
      setHandlerName(o, name, "")
  else:
    result.get = proc(o: Obj): PropValue = toPV(getter(C(o)))
    result.set = proc(o: Obj, v: PropValue) = setter(C(o), fromPV(v, V))

proc eventTypeOf*(p: PropInfo): string = p.typeName

proc collectionProp*(name, childClass: string, ops: CollectionOps,
                     cat = pcData): PropInfo =
  ## A read-only property standing for the owned items of an object: its value
  ## is the item count, it is never stored (the items are the object's child
  ## nodes in a form file) and the inspector offers a "..." button for it.
  ops.childClass = childClass
  result = PropInfo(name: name, category: cat, typeName: childClass,
                    kind: pkCollection, stored: false, coll: ops)
  result.get = proc(o: Obj): PropValue =
    PropValue(kind: pkCollection, i: ops.items(o).len)
  result.set = proc(o: Obj, v: PropValue) =
    ## the items are changed through `ops`; setting the count it already has is a no-op
    if v.kind != pkCollection:
      raise kindError("a collection", v)

# ---------------------------------------------------------------- registry

proc newClassInfo*(name, nimType: string, parent: ClassInfo): ClassInfo =
  ClassInfo(name: name, nimType: nimType, parent: parent)

proc addProp*(ci: ClassInfo, p: PropInfo) =
  p.declaredIn = ci
  ci.props.add p

proc addAlias*(alias, className: string) =
  aliasTable[alias] = className

proc registerClassInfo*(ci: ClassInfo) =
  if classTable.hasKey(ci.name):
    raise newException(PropError, "class " & ci.name & " is already registered")
  classTable[ci.name] = ci
  classList.add ci

proc classByName*(name: string): ClassInfo =
  ## The registered class `name` (an alias such as `Image` for `ImageControl`
  ## also works); nil when unknown.
  if classTable.hasKey(name): return classTable[name]
  if aliasTable.hasKey(name): return classTable.getOrDefault(aliasTable[name])

proc addCollection*(ci: ClassInfo, name, childClass: string, ops: CollectionOps,
                    cat = pcData) =
  ci.addProp collectionProp(name, childClass, ops, cat)

proc allClasses*(): seq[ClassInfo] = classList

proc depth*(ci: ClassInfo): int =
  var c = ci
  while c != nil:
    inc result
    c = c.parent

proc isA*(ci, base: ClassInfo): bool =
  ## `ci` is `base` or inherits from it.
  var c = ci
  while c != nil:
    if c == base: return true
    c = c.parent

proc classOf*(o: Obj): ClassInfo =
  ## The most derived registered class `o` is an instance of (a user subclass
  ## of `Panel` answers `Panel`); nil when none matches.
  var best = 0
  for ci in classList:
    if ci.matches != nil and ci.matches(o):
      let d = ci.depth
      if d > best:
        best = d
        result = ci

proc propsOf*(ci: ClassInfo): seq[PropInfo] =
  ## Every property of the class including inherited ones: ancestors' first,
  ## each in registration order. A property redeclared in a subclass replaces
  ## the inherited one in place.
  var chain: seq[ClassInfo]
  var c = ci
  while c != nil:
    chain.add c
    c = c.parent
  for i in countdown(chain.high, 0):
    for p in chain[i].props:
      var found = -1
      for j in 0 ..< result.len:
        if result[j].name == p.name: found = j
      if found >= 0: result[found] = p else: result.add p

proc isDescendantOf*(o: Obj, className: string): bool =
  let ci = classOf(o)
  let base = classByName(className)
  ci != nil and base != nil and ci.isA(base)

# ------------------------------------------------------------ sub-properties

const
  SpacingSubs = ["left", "top", "right", "bottom"]
  ConstraintSubs = ["minWidth", "minHeight", "maxWidth", "maxHeight"]
  FontSubs = ["family", "size", "style"]

proc fontStyleNames*(): seq[string] = enumNamesOf(FontStyle)

proc subNames*(kind: PropKind): seq[string] =
  ## Names of the sub-properties of a composite kind.
  case kind
  of pkFont: @FontSubs
  of pkSpacing: @SpacingSubs
  of pkConstraints: @ConstraintSubs
  else: @[]

proc getSub*(v: PropValue, sub: string): PropValue =
  ## The part `sub` of a composite value.
  case v.kind
  of pkFont:
    case sub
    of "family": return pvString(v.font.family)
    of "size": return pvFloat(float(v.font.size))
    of "style": return pvSet(setToBits(v.font.style))
    else: discard
  of pkSpacing:
    case sub
    of "left": return pvFloat(float(v.spacing.left))
    of "top": return pvFloat(float(v.spacing.top))
    of "right": return pvFloat(float(v.spacing.right))
    of "bottom": return pvFloat(float(v.spacing.bottom))
    else: discard
  of pkConstraints:
    case sub
    of "minWidth": return pvFloat(float(v.cons.minWidth))
    of "minHeight": return pvFloat(float(v.cons.minHeight))
    of "maxWidth": return pvFloat(float(v.cons.maxWidth))
    of "maxHeight": return pvFloat(float(v.cons.maxHeight))
    else: discard
  else: discard
  raise newException(PropError, "no sub-property `" & sub & "`")

proc num(x: PropValue): float =
  case x.kind
  of pkFloat: x.f
  of pkInt: float(x.i)
  else: raise kindError("a number", x)

proc withSub*(v: PropValue, sub: string, x: PropValue): PropValue =
  ## `v` with its part `sub` replaced by `x`.
  result = v
  case v.kind
  of pkFont:
    case sub
    of "family":
      if x.kind != pkString: raise kindError("a string", x)
      result.font.family = x.s
    of "size": result.font.size = float32(num(x))
    of "style":
      if x.kind != pkSet: raise kindError("a set", x)
      result.font.style = bitsToSet[FontStyle](x.bits)
    else: raise newException(PropError, "no sub-property `" & sub & "`")
  of pkSpacing:
    case sub
    of "left": result.spacing.left = float32(num(x))
    of "top": result.spacing.top = float32(num(x))
    of "right": result.spacing.right = float32(num(x))
    of "bottom": result.spacing.bottom = float32(num(x))
    else: raise newException(PropError, "no sub-property `" & sub & "`")
  of pkConstraints:
    case sub
    of "minWidth": result.cons.minWidth = float32(num(x))
    of "minHeight": result.cons.minHeight = float32(num(x))
    of "maxWidth": result.cons.maxWidth = float32(num(x))
    of "maxHeight": result.cons.maxHeight = float32(num(x))
    else: raise newException(PropError, "no sub-property `" & sub & "`")
  else: raise newException(PropError, "no sub-property `" & sub & "`")

proc subKindOf(kind: PropKind, sub: string): PropKind =
  case kind
  of pkFont:
    case sub
    of "family": pkString
    of "style": pkSet
    else: pkFloat
  else: pkFloat

proc makeBitSub(parent: PropInfo, bit: int, en: string): PropInfo =
  result = PropInfo(name: parent.name & "." & en, kind: pkBool,
                    category: parent.category, typeName: "bool", stored: false,
                    declaredIn: parent.declaredIn)
  result.get = proc(o: Obj): PropValue = pvBool(hasBit(parent.get(o).bits, bit))
  result.set = proc(o: Obj, v: PropValue) =
    if v.kind != pkBool: raise kindError("a bool", v)
    var cur = parent.get(o)
    cur.bits = withBit(cur.bits, bit, v.b)
    parent.set(o, cur)

proc makeSub(parent: PropInfo, sub: string): PropInfo =
  result = PropInfo(name: parent.name & "." & sub, kind: subKindOf(parent.kind, sub),
                    category: parent.category, typeName: "float32", stored: false,
                    declaredIn: parent.declaredIn)
  if result.kind == pkSet: result.enumNames = fontStyleNames()
  if result.kind == pkString: result.typeName = "string"
  result.get = proc(o: Obj): PropValue = getSub(parent.get(o), sub)
  result.set = proc(o: Obj, v: PropValue) =
    parent.set(o, withSub(parent.get(o), sub, v))

proc subProps*(p: PropInfo): seq[PropInfo] =
  ## Expandable parts of a property as virtual properties named
  ## `"font.size"`, `"margins.left"`, `"anchors.akLeft"` (one bool per element
  ## of a set). Their getters and setters read and write through `p`.
  if p.subs.len > 0 or p.kind in {pkBool, pkInt, pkFloat, pkString, pkEnum, pkColor,
                                  pkObject, pkImage, pkImages, pkStrings,
                                  pkCollection, pkEvent}:
    return p.subs
  if p.kind == pkSet:
    for i, en in p.enumNames: p.subs.add makeBitSub(p, i, en)
  else:
    for sn in subNames(p.kind): p.subs.add makeSub(p, sn)
  p.subs

proc findProp*(ci: ClassInfo, name: string): PropInfo =
  ## Property `name` (inherited ones included); nil when there is none. A dotted
  ## name addresses a sub-property (`"font.size"`, `"anchors.akLeft"`,
  ## `"font.style.fsBold"`).
  let parts = name.split('.')
  var c = ci
  var cur: PropInfo = nil
  while c != nil and cur == nil:
    for p in c.props:
      if p.name == parts[0]:
        cur = p
        break
    c = c.parent
  if cur == nil: return nil
  var path = parts[0]
  for i in 1 ..< parts.len:
    path.add "." & parts[i]
    var next: PropInfo = nil
    for s in subProps(cur):
      if s.name == path:
        next = s
        break
    if next == nil: return nil
    cur = next
  cur

# ------------------------------------------------------------ object access

proc requireProp(o: Obj, name: string): PropInfo =
  let ci = classOf(o)
  if ci == nil:
    raise newException(PropError, "object is not of a registered class")
  result = ci.findProp(name)
  if result == nil:
    raise newException(PropError, "class " & ci.name & " has no property `" & name & "`")

proc getProp*(o: Obj, name: string): PropValue =
  requireProp(o, name).get(o)

proc setProp*(o: Obj, name: string, v: PropValue) =
  ## Sets a property by name (`"font.size"` works). Raises `PropError` for an
  ## unknown property or a value of the wrong kind.
  requireProp(o, name).set(o, v)

proc enumValue*(p: PropInfo, name: string): int =
  ## Ordinal of the enum value (or set element) called `name`; -1 when unknown.
  p.enumNames.find(name)

proc enumName*(p: PropInfo, ordinal: int): string =
  if ordinal in 0 ..< p.enumNames.len: p.enumNames[ordinal] else: $ordinal

proc ensureDefaults(ci: ClassInfo) =
  if ci.defaultsReady: return
  ci.defaultsReady = true
  var cur = ci
  while cur != nil and cur.create == nil: cur = cur.parent
  if cur == nil: return
  var proto: Obj
  try: proto = ci.create(nil, (if ci.protoParent != nil: ci.protoParent() else: nil))
  except CatchableError: proto = nil
  if proto == nil: return
  for p in ci.propsOf:
    if p.kind == pkEvent: ci.defaults[p.name] = pvEvent("")
    else:
      try: ci.defaults[p.name] = p.get(proto)
      except CatchableError: discard

proc defaultOf*(ci: ClassInfo, p: PropInfo): PropValue =
  ## Value of `p` in a freshly created instance of `ci` (the value is not
  ## stored when equal to it). Sub-properties work too.
  ci.ensureDefaults()
  let parts = p.name.split('.')
  if ci.defaults.hasKey(parts[0]):
    result = ci.defaults[parts[0]]
    var cur = ci.findProp(parts[0])
    for i in 1 ..< parts.len:
      if cur.kind == pkSet:
        result = pvBool(hasBit(result.bits, cur.enumValue(parts[i])))
      else:
        result = getSub(result, parts[i])
      cur = ci.findProp(parts[0 .. i].join("."))
    return
  PropValue(kind: p.kind)

proc isDefault*(o: Obj, p: PropInfo): bool =
  ## True when `p` has the value of a fresh instance of the object's class.
  let ci = classOf(o)
  if ci == nil: return false
  let base = p.name.split('.')[0]
  let bp = ci.findProp(base)
  if bp != nil and bp.skipWhen != nil and bp.skipWhen(o): return true
  if bp != nil and bp.defaultWhen.len > 0:
    let flag = ci.findProp(bp.defaultWhen)
    if flag != nil and flag.get(o).b: return true
  if p.kind == pkEvent:
    return handlerNameOf(o, p.name).len == 0 and not p.isAssigned(o)
  ci.ensureDefaults()
  if not ci.defaults.hasKey(base): return false
  p.get(o) == defaultOf(ci, p)

proc isDefault*(o: Obj, name: string): bool =
  let p = requireProp(o, name)
  isDefault(o, p)

proc createObject*(ci: ClassInfo, owner: Component, parent: Obj): Obj =
  ## Creates an instance (and attaches it to `parent` when the class needs
  ## that done separately). Raises `PropError` for an abstract class.
  var c = ci
  while c != nil and c.create == nil: c = c.parent
  if c == nil or ci.abstract:
    raise newException(PropError, "class " & ci.name & " cannot be created")
  result = c.create(owner, parent)
  var a = ci
  while a != nil and a.attach == nil: a = a.parent
  if a != nil and parent != nil: a.attach(parent, result)

proc kidsOf*(o: Obj): seq[Obj] =
  ## The owned children `o` shows in a form tree.
  var c = classOf(o)
  while c != nil:
    if c.kids != nil: return c.kids(o)
    c = c.parent

# --------------------------------------------------------------- helpers

proc asContainer*(p: Obj): Container =
  if p == nil: return nil
  if p of Container: return Container(p)
  raise newException(PropError, "the parent is not a container")

proc asOwner*(owner: Component, parent: Obj): Component =
  if parent != nil and parent of Component: Component(parent) else: owner

proc toObjs*[T](xs: openArray[T]): seq[Obj] =
  for x in xs: result.add Obj(x)

proc noKids*(): seq[Obj] = @[]

# ------------------------------------------------------------------- macro

proc propStmt(cls, ci: NimNode, name: string, typ: NimNode, cat: string,
              getter, setter: NimNode): NimNode =
  let c = ident"c"
  let v = ident"v"
  var g, s: NimNode
  if getter == nil:
    let acc = newDotExpr(c, ident(name))
    g = quote do:
      proc(`c`: `cls`): `typ` = `acc`
    s = quote do:
      proc(`c`: `cls`, `v`: `typ`) = `acc` = `v`
  else:
    g = quote do:
      proc(`c`: `cls`): `typ` = `getter`(`c`)
    s = quote do:
      proc(`c`: `cls`, `v`: `typ`) = `setter`(`c`, `v`)
  let catId = ident("pc" & cat)
  let nameLit = newLit(name)
  let typeLit = newLit(typ.repr.replace("\n", " "))
  result = quote do:
    addProp(`ci`, propInfo[`cls`, `typ`](`nameLit`, `catId`, `typeLit`, `g`, `s`))

macro registerClass*(args: varargs[untyped]): untyped =
  ## Registers a class and its properties; see the module comment.
  if args.len < 1:
    error("registerClass: expected `registerClass(Type, parent = Base): <properties>`", args)
  let hasBody = args[^1].kind == nnkStmtList
  let lastOpt = if hasBody: args.len - 2 else: args.len - 1
  let cls = args[0]
  var tname = cls.repr
  var parentName = ""
  var abstract = false
  var createExpr, attachExpr, kidsExpr, protoExpr: NimNode = nil
  for i in 1 .. lastOpt:
    let a = args[i]
    if a.kind != nnkExprEqExpr:
      error("registerClass: expected `name = value`", a)
    let k = a[0].strVal
    case k
    of "parent":
      if not (a[1].kind == nnkNilLit): parentName = a[1].repr
    of "abstract": abstract = a[1].eqIdent("true")
    of "name": tname = a[1].strVal
    of "create": createExpr = a[1]
    of "attach": attachExpr = a[1]
    of "kids": kidsExpr = a[1]
    of "protoParent": protoExpr = a[1]
    else: error("registerClass: unknown option `" & k & "`", a)
  let ci = genSym(nskLet, "ci")
  var stmts = newStmtList()
  let nameLit = newLit(tname)
  let typeLit = newLit(cls.repr)
  let parentLit = newLit(parentName)
  stmts.add quote do:
    let `ci` = newClassInfo(`nameLit`, `typeLit`,
                            (if `parentLit`.len > 0: classByName(`parentLit`) else: nil))
    if `parentLit`.len > 0 and `ci`.parent == nil:
      raise newException(PropError, "registerClass " & `nameLit` &
                         ": parent class " & `parentLit` & " is not registered")
  let o = ident"o"
  stmts.add quote do:
    `ci`.matches = proc(`o`: Obj): bool = `o` of `cls`
  if abstract:
    stmts.add quote do:
      `ci`.abstract = true
  elif createExpr != nil:
    let owner = ident"owner"
    let parent = ident"parent"
    stmts.add quote do:
      `ci`.create = proc(`owner`: Component, `parent`: Obj): Obj = Obj(`createExpr`)
  else:
    let ctor = ident("new" & cls.repr)
    let owner = ident"owner"
    let parent = ident"parent"
    stmts.add quote do:
      `ci`.create = proc(`owner`: Component, `parent`: Obj): Obj =
        when `cls` is Control: Obj(`ctor`(asContainer(`parent`)))
        else: Obj(`ctor`(asOwner(`owner`, `parent`)))
  if attachExpr != nil:
    let parent = ident"parent"
    let child = ident"child"
    stmts.add quote do:
      `ci`.attach = proc(`parent`, `child`: Obj) = `attachExpr`
  if protoExpr != nil:
    stmts.add quote do:
      `ci`.protoParent = proc(): Obj = Obj(`protoExpr`)
  if kidsExpr != nil:
    let selfId = ident"self"
    stmts.add quote do:
      `ci`.kids = proc(`o`: Obj): seq[Obj] =
        let `selfId` = `cls`(`o`)
        `kidsExpr`

  proc walk(stmts: var NimNode, body: NimNode, cat: string, cls, ci: NimNode) =
    for st in body:
      case st.kind
      of nnkCommentStmt: discard
      of nnkCommand, nnkCall:
        let head = st[0]
        if head.kind == nnkIdent and head.eqIdent("category") and st.len == 3 and
           st[^1].kind == nnkStmtList:
          walk(stmts, st[^1], st[1].strVal, cls, ci)
        elif head.kind == nnkIdent and head.eqIdent("prop") and st.len == 5:
          stmts.add propStmt(cls, ci, st[1].strVal, st[2], cat, st[3], st[4])
        elif head.kind == nnkIdent and head.eqIdent("nostore"):
          for j in 1 ..< st.len:
            let nm = newLit(st[j].strVal)
            stmts.add quote do:
              findProp(`ci`, `nm`).stored = false
        elif head.kind == nnkIdent and head.eqIdent("skipWhen") and st.len == 3:
          let nm = newLit(st[1].strVal)
          let cond = st[2]
          let selfId = ident"self"
          let o = ident"o"
          stmts.add quote do:
            findProp(`ci`, `nm`).skipWhen = proc(`o`: Obj): bool =
              let `selfId` = `cls`(`o`)
              `cond`
        elif head.kind == nnkIdent and head.eqIdent("defaultWhen") and st.len == 3:
          let nm = newLit(st[1].strVal)
          let flag = newLit(st[2].strVal)
          stmts.add quote do:
            findProp(`ci`, `nm`).defaultWhen = `flag`
        elif head.kind == nnkIdent and st.len == 2 and st[1].kind == nnkStmtList and
             st[1].len == 1:
          stmts.add propStmt(cls, ci, head.strVal, st[1][0], cat, nil, nil)
        else:
          error("registerClass: expected `name: Type`, `prop name, Type, get, set`, " &
                "`category X:`, `nostore a, b` or `defaultWhen a, b`", st)
      else:
        error("registerClass: unsupported statement", st)
  if hasBody: walk(stmts, args[^1], "Behaviour", cls, ci)
  stmts.add quote do:
    registerClassInfo(`ci`)
  result = newBlockStmt(stmts)

func categoryName*(c: PropCategory): string =
  case c
  of pcLayout: "Layout"
  of pcAppearance: "Appearance"
  of pcBehaviour: "Behaviour"
  of pcData: "Data"
  of pcEvents: "Events"
