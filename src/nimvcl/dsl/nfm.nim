## `.nfm`: the text form format (the Delphi `.dfm` analogue). A form file
## describes a tree of objects and their non-default properties; the designer
## writes it, `loadForm` turns it into a typed form at compile time, and
## `loadNfm` builds the same tree at run time from the property registry
## (`props.nim`). See docs/guide/form-files.md for the reference.
##
## ```
## object MainForm: Form
##   caption = 'Sign in'
##   width = 420
##   object okButton: Button
##     caption = 'OK'
##     anchors = [akRight, akBottom]
##     font.size = 16
##     onClick = okClick
##   end
## end
## ```
##
## This is the full module (IDE, tools, run-time loading). It re-exports two
## lighter ones:
##
## * `nfmsyntax`: the syntax tree, `parseNfm` and `writeNfm` (no dependencies
##   beyond `std`, so the parser also runs inside macros);
## * `formload`: the `loadForm` macro, which needs no registry. An application
##   that only uses `loadForm` should import `nimvcl/dsl/formload` and the
##   modules of its controls instead of this one.
##
## What is defined here is the run-time use of the registry: `loadNfm`,
## `formToNfm`, `nfmToFormMacro`.

import std/[strutils, tables, macros, os, sets, hashes]
import ../graphics/[color, image]
import ../core/[component, control, form]
import ../controls/[menus, statusbar, listview, actions, flowpanel]
import ./props_std
import ./nfmsyntax {.all.}
import ./formload
export nfmsyntax, formload
export flowpanel.parseGridSizes, flowpanel.gridSizesToText

# ===================================================================== runtime

proc fmtFloat(f: float): string =
  let f32 = float32(f)
  if f32 == float32(int64(f32)) and abs(f32) < 1e9: $int64(f32)
  else: $f32

proc toNfmValue*(info: PropInfo, v: PropValue): NfmValue =
  ## The text-form value of a property value; raises `PropError` for values with
  ## no text form (images, composite kinds, unnamed objects).
  case v.kind
  of pkBool: nfmBool(v.b)
  of pkInt: nfmInt(v.i)
  of pkFloat:
    let t = fmtFloat(v.f)
    NfmValue(kind: (if '.' in t or 'e' in t: nvFloat else: nvInt), text: t)
  of pkString: nfmString(v.s)
  of pkEnum: nfmIdent(info.enumName(v.i))
  of pkSet:
    var r = NfmValue(kind: nvSet)
    for i, en in info.enumNames:
      if hasBit(v.bits, i): r.items.add en
    r
  of pkColor: NfmValue(kind: nvColor, text: v.color.toHex)
  of pkObject:
    if v.obj == nil: nfmIdent("nil")
    elif objectName(v.obj).len == 0:
      raise newException(PropError, "a referenced object needs a name")
    else: nfmIdent(objectName(v.obj))
  of pkStrings: NfmValue(kind: nvList, items: v.strs)
  of pkEvent: nfmIdent(v.handler)
  of pkImage:
    if v.image == nil or v.image.source.len == 0:
      raise newException(PropError, "property `" & info.name &
                         "` has an image without a file path (nothing to save)")
    nfmString(v.image.source)
  of pkImages:
    var r = NfmValue(kind: nvList)
    for img in v.imgs:
      if img != nil and img.source.len > 0: r.items.add img.source
    r
  of pkFont, pkSpacing, pkConstraints, pkCollection:
    raise newException(PropError, "property `" & info.name & "` has no text form")

type
  NfmOptions* = ref object
    ## How `loadNfm` treats problems and handlers.
    strict*: bool                 ## true: unknown classes/properties/handlers raise `NfmError`; false: they are skipped and listed in `warnings`
    baseDir*: string              ## image paths of the file (`picture = 'images/a.png'`) are relative to this folder; "" = the folder of the form file (or the current one)
    handlers*: HandlerResolver    ## binds `onXxx = name` to code; nil: names are only recorded
    warnings*: seq[string]        ## problems found while `strict` is false; also images that could not be loaded (a missing image never raises: a blank 1x1 image that keeps the path stands in, so saving the form does not lose it)

proc newNfmOptions*(strict = true, handlers: HandlerResolver = nil): NfmOptions =
  NfmOptions(strict: strict, handlers: handlers)

proc notifyHandlers*(table: Table[string, NotifyEvent]): HandlerResolver =
  ## A resolver for events of type `NotifyEvent` that looks names up in `table`.
  result = proc(handler, eventType: string): RootRef =
    if eventType == "NotifyEvent" and table.hasKey(handler):
      HandlerBox[NotifyEvent](fn: table[handler])
    else: nil

proc problem(opt: NfmOptions, file: string, line, col: int, msg: string) =
  if opt.strict: raise nfmError(file, line, col, msg)
  opt.warnings.add (if file.len > 0: file & ":" else: "") & $line & ":" & $col & ": " & msg

proc enumList(info: PropInfo): string =
  var parts: seq[string]
  for n in info.enumNames: parts.add n
  parts.join(", ")

proc loadPicture(opt: NfmOptions, baseDir, file: string, v: NfmValue,
                 path: string): Image =
  ## The image of a form file path; a blank stand-in (with the path) and a
  ## warning when the file cannot be read.
  let full = if path.isAbsolute: path else: baseDir / path
  try:
    result = loadImage(full)
  except CatchableError as e:
    result = newImage(1, 1)
    opt.warnings.add (if file.len > 0: file & ":" else: "") & $v.line & ":" & $v.col &
                     ": cannot load image `" & path & "`: " & e.msg
  result.source = path

proc convertValue(info: PropInfo, v: NfmValue, file: string,
                  byName: Table[string, Obj], opt: NfmOptions,
                  baseDir: string): PropValue =
  ## Raises `NfmError` (at the value's position) when `v` does not fit `info`.
  template bad(msg: string) = raise nfmError(file, v.line, v.col, msg)
  case info.kind
  of pkBool:
    if v.kind != nvBool: bad("`" & info.name & "` expects true or false")
    pvBool(v.text == "true")
  of pkInt:
    if v.kind != nvInt: bad("`" & info.name & "` expects a whole number")
    pvInt(parseInt(v.text))
  of pkFloat:
    if v.kind notin {nvInt, nvFloat}: bad("`" & info.name & "` expects a number")
    pvFloat(parseFloat(v.text))
  of pkString:
    if v.kind != nvString: bad("`" & info.name & "` expects a 'string'")
    pvString(v.text)
  of pkEnum:
    if v.kind != nvIdent: bad("`" & info.name & "` expects one of: " & enumList(info))
    let i = info.enumValue(v.text)
    if i < 0:
      bad("`" & v.text & "` is not a value of " & info.typeName & " (property `" &
          info.name & "`); use one of: " & enumList(info))
    pvEnum(i)
  of pkSet:
    if v.kind != nvSet:
      bad("`" & info.name & "` expects a set like [" & info.enumNames[0] & "]; elements: " &
          enumList(info))
    var bits = 0'i64
    for it in v.items:
      let i = info.enumValue(it)
      if i < 0:
        bad("`" & it & "` is not an element of " & info.typeName & " (property `" &
            info.name & "`); use: " & enumList(info))
      bits = withBit(bits, i, true)
    pvSet(bits)
  of pkColor:
    if v.kind != nvColor: bad("`" & info.name & "` expects a colour like #336699")
    pvColor(parseColor(v.text))
  of pkStrings:
    if v.kind != nvList: bad("`" & info.name & "` expects a list like ( 'a' 'b' )")
    pvStrings(v.items)
  of pkObject:
    if v.kind != nvIdent: bad("`" & info.name & "` expects the name of an object (or nil)")
    if v.text == "nil": pvObject(nil)
    elif byName.hasKey(v.text): pvObject(byName[v.text], v.text)
    else: bad("`" & v.text & "` (value of `" & info.name & "`) is not an object of this form")
  of pkEvent:
    if v.kind != nvIdent: bad("`" & info.name & "` expects a handler name")
    pvEvent(v.text)
  of pkImage:
    if v.kind != nvString: bad("`" & info.name & "` expects the path of an image file, like 'images/logo.png'")
    if v.text.len == 0: PropValue(kind: pkImage, image: nil)
    else: PropValue(kind: pkImage, image: loadPicture(opt, baseDir, file, v, v.text))
  of pkImages:
    if v.kind != nvList: bad("`" & info.name & "` expects a list of image paths like ( 'a.png' 'b.png' )")
    var imgs: seq[Image]
    for p in v.items: imgs.add loadPicture(opt, baseDir, file, v, p)
    PropValue(kind: pkImages, imgs: imgs)
  of pkCollection:
    bad("`" & info.name & "` is made of child objects (`object name: Class ... end`)")
  of pkFont, pkSpacing, pkConstraints:
    bad("`" & info.name & "` is set through its parts, e.g. `" & info.name & "." &
        subNames(info.kind)[0] & " = ...`")

type Built = object
  node: NfmNode
  obj: Obj
  ci: ClassInfo

proc buildTree(node: NfmNode, parent, rootOwner: Obj, file: string, opt: NfmOptions,
               byName: var Table[string, Obj], built: var seq[Built]) =
  var ci = classByName(node.className)
  if ci == nil:
    opt.problem(file, node.line, node.col,
                "unknown class `" & node.className & "` (not registered with registerClass)")
    return
  var obj: Obj
  try:
    let owner = if parent != nil and parent of Component: Component(parent)
                elif rootOwner != nil and rootOwner of Component: Component(rootOwner)
                else: nil
    obj = ci.createObject(owner, parent)
  except PropError as e:
    raise nfmError(file, node.line, node.col, e.msg)
  if node.name.len > 0:
    if byName.hasKey(node.name):
      raise nfmError(file, node.line, node.col,
                     "duplicate object name `" & node.name & "`")
    byName[node.name] = obj
    if obj of Component: Component(obj).name = node.name
  built.add Built(node: node, obj: obj, ci: ci)
  for c in node.children:
    buildTree(c, obj, rootOwner, file, opt, byName, built)

proc applyProps(b: Built, file: string, opt: NfmOptions,
                byName: Table[string, Obj], baseDir: string) =
  for p in b.node.props:
    if p.name == "designLeft" or p.name == "designTop":
      # the design position of a non-visual component (Component.designLeft/Top)
      if not (b.obj of Component) or p.value.kind != nvInt:
        opt.problem(file, p.line, p.col, "`" & p.name & "` takes a whole number")
        continue
      let v = try: parseInt(p.value.text) except ValueError: 0
      if p.name == "designLeft": Component(b.obj).designLeft = v
      else: Component(b.obj).designTop = v
      continue
    let info = b.ci.findProp(p.name)
    if info == nil:
      opt.problem(file, p.line, p.col,
                  "class `" & b.ci.name & "` has no property `" & p.name & "`")
      continue
    if info.name == "name":
      opt.problem(file, p.line, p.col,
                  "the name of an object is given in its `object name: Class` line")
      continue
    try:
      if info.kind == pkEvent:
        if p.value.kind != nvIdent:
          raise nfmError(file, p.value.line, p.value.col,
                         "`" & p.name & "` expects a handler name")
        info.set(b.obj, pvEvent(p.value.text))
        if opt.handlers != nil:
          let box = opt.handlers(p.value.text, info.typeName)
          if box == nil or not info.bindHandler(b.obj, box):
            opt.problem(file, p.value.line, p.value.col,
                        "no handler `" & p.value.text & "` for the event `" & p.name &
                        "` (" & info.typeName & ")")
      else:
        info.set(b.obj, convertValue(info, p.value, file, byName, opt, baseDir))
    except PropError as e:
      raise nfmError(file, p.line, p.col, "property `" & p.name & "`: " & e.msg)

proc buildNfm*(root: NfmNode, owner: Component = nil, options: NfmOptions = nil,
               fileName = ""): Obj =
  ## Builds the object tree described by `root` through the registry and
  ## returns the root object. Children are created first (top-down), then the
  ## properties are applied in file order (so a property may refer to any named
  ## object of the file), exactly like the `form` macro.
  let opt = if options == nil: newNfmOptions() else: options
  var byName: Table[string, Obj]
  var built: seq[Built]
  buildTree(root, nil, Obj(owner), fileName, opt, byName, built)
  if built.len == 0: return nil
  let baseDir = if opt.baseDir.len > 0: opt.baseDir
                elif fileName.len > 0: fileName.parentDir
                else: ""
  for b in built: applyProps(b, fileName, opt, byName, baseDir)
  built[0].obj

proc loadNfm*(text: string, owner: Component = nil, options: NfmOptions = nil,
              fileName = ""): Form =
  ## Parses `text` and builds the form it describes. The root object must be a
  ## `Form` (or a registered subclass). Raises `NfmError` with `file:line:col`.
  let root = parseNfm(text, fileName)
  legacyNames(root)
  let o = buildNfm(root, owner, options, fileName)
  if o == nil or not (o of Form):
    raise nfmError(fileName, root.line, root.col,
                   "the root object `" & root.className & "` is not a Form")
  Form(o)

proc loadNfm*(text: string, handlers: Table[string, NotifyEvent],
              owner: Component = nil): Form =
  ## Like `loadNfm` with `NotifyEvent` handlers looked up by name.
  loadNfm(text, owner, newNfmOptions(true, notifyHandlers(handlers)))

proc loadNfmFile*(path: string, owner: Component = nil,
                  options: NfmOptions = nil): Form =
  loadNfm(readFile(path), owner, options, path)

# ------------------------------------------------------------------ saving

proc hash(o: Obj): Hash = hash(cast[pointer](o))

type SaveCtx = object
  nested: HashSet[Obj]    ## objects that are written as the child of another one

proc needsParent(ci: ClassInfo): bool =
  ## Classes created through `attach` (menu items) cannot stand alone.
  var c = ci
  while c != nil:
    if c.attach != nil: return true
    c = c.parent

proc isStandalone(x: Component): bool =
  ## A non-visual component (a timer, an image list, a popup menu...) that a
  ## form file writes as an object of its owner.
  if x of Control: return false
  let ci = classOf(x)
  ci != nil and not ci.needsParent

proc gatherAll(o: Obj, all: var seq[Obj], seen: var HashSet[Obj]) =
  if seen.containsOrIncl(o): return
  all.add o
  for k in kidsOf(o): gatherAll(k, all, seen)
  if o of Component:
    for x in Component(o).components:
      if x.isStandalone: gatherAll(x, all, seen)

proc newSaveCtx(root: Obj): SaveCtx =
  ## Finds everything that appears as a child of something (menu items in a
  ## menu, actions in a list...), so a component owned by the form that is
  ## also such a child is not written twice.
  var all: seq[Obj]
  var seen: HashSet[Obj]
  gatherAll(root, all, seen)
  for o in all:
    for k in kidsOf(o): result.nested.incl k

proc nodeOf(o: Obj, ctx: SaveCtx, nameOverride = ""): NfmNode =
  let ci = classOf(o)
  if ci == nil: return nil
  result = NfmNode(className: ci.name,
                   name: if nameOverride.len > 0: nameOverride else: objectName(o))
  if o of Component:
    let c = Component(o)
    if c.designLeft != 0 or c.designTop != 0:
      result.props.add NfmProp(name: "designLeft", value: nfmInt(c.designLeft))
      result.props.add NfmProp(name: "designTop", value: nfmInt(c.designTop))
  var ordered: seq[PropInfo]
  for p in ci.propsOf:
    if p.kind != pkEvent: ordered.add p
  for p in ci.propsOf:
    if p.kind == pkEvent: ordered.add p
  for p in ordered:
    if p.name == "name" or not p.stored: continue
    case p.kind
    of pkCollection: continue
    of pkImage:
      let v = p.get(o)
      if v.image != nil and v.image.source.len > 0:
        result.props.add NfmProp(name: p.name, value: toNfmValue(p, v))
    of pkImages:
      let v = p.get(o)
      if v.imgs.len > 0:
        result.props.add NfmProp(name: p.name, value: toNfmValue(p, v))
    of pkFont, pkSpacing, pkConstraints:
      for s in subProps(p):
        if not isDefault(o, s):
          result.props.add NfmProp(name: s.name, value: toNfmValue(s, s.get(o)))
    of pkEvent:
      let h = handlerNameOf(o, p.name)
      if h.len > 0: result.props.add NfmProp(name: p.name, value: nfmIdent(h))
    of pkObject:
      if not isDefault(o, p):
        let v = p.get(o)
        if v.obj == nil or objectName(v.obj).len > 0:
          result.props.add NfmProp(name: p.name, value: toNfmValue(p, v))
    else:
      if not isDefault(o, p):
        result.props.add NfmProp(name: p.name, value: toNfmValue(p, p.get(o)))
  for k in kidsOf(o):
    let n = nodeOf(k, ctx)
    if n != nil: result.children.add n
  if o of Component:
    # non-visual components owned by this one, as Delphi writes them
    for x in Component(o).components:
      if x.isStandalone and Obj(x) notin ctx.nested:
        let n = nodeOf(x, ctx)
        if n != nil: result.children.add n

proc objectToNfmNode*(o: Obj, rootName = ""): NfmNode =
  ## The syntax tree of an object and its children: only properties that
  ## differ from a fresh instance, in registry order. Events appear when a
  ## handler name was recorded for them (by `loadNfm` or `setProp`).
  nodeOf(o, newSaveCtx(o), rootName)

proc objectToNfm*(o: Obj, rootName = ""): string =
  let n = objectToNfmNode(o, rootName)
  if n == nil: raise newException(PropError, "object is not of a registered class")
  writeNfm(n)

proc formToNfm*(f: Form, rootName = ""): string =
  ## Serialises a live form through the registry; this is what a designer
  ## saves. `rootName` names the root when the form has no `name`.
  let n = f.name
  objectToNfm(f, if n.len > 0: "" else: (if rootName.len > 0: rootName else: "Form1"))

# --------------------------------------------------------- form-macro source

proc nfmToFormMacro*(text: string, fileName = ""): string =
  ## The `form` macro source equivalent to a form file. Handlers become
  ## `onXxx: name(self, sender)` plus an empty `proc name(self: Form, sender: Control)`
  ## stub inside the block for `NotifyEvent` events; other event types are
  ## written as comments (the shorthand only exists for `NotifyEvent`).
  ## Parts of composite properties stay `font.size = 12` (the `form` macro
  ## supports that form).
  let root = parseNfm(text, fileName)
  legacyNames(root)
  var names = initHashSet[string]()
  for n in walk(root):
    if n.name.len > 0: names.incl n.name
  var o = ""
  var stubs: seq[string]
  var seenStub = initHashSet[string]()
  let formName = if root.name.len > 0: root.name else: "Form1"
  proc emit(n: NfmNode, level: int, top: bool) =
    let ind = "  ".repeat(level)
    for i, p in n.props:
      if p.name.isEventProp:
        let ev = classByName(n.className)
        var typ = "NotifyEvent"
        if ev != nil:
          let info = ev.findProp(p.name)
          if info != nil: typ = info.typeName
        if typ == "NotifyEvent":
          o.add ind & p.name & ": " & p.value.text & "(self, sender)\n"
          if p.value.text notin seenStub:
            seenStub.incl p.value.text
            stubs.add "  proc " & p.value.text & "(self: " & formName &
                      ", sender: Control) = discard\n"
        else:
          o.add ind & "# " & p.name & " = " & p.value.text & "  (" & typ &
                ": assign a proc with this event's parameters)\n"
      elif '.' in p.name:
        let dot = p.name.find('.')
        let (_, e) = nimExpr(n.className, p.name[dot + 1 .. ^1], p.value, names)
        o.add ind & p.name & " = " & e & "\n"
      else:
        var (pn, e) = nimExpr(n.className, p.name, p.value, names)
        let ci = classByName(n.className)
        let info = if ci != nil: ci.findProp(p.name) else: nil
        if info != nil and info.kind == pkImage and p.value.kind == nvString:
          e = "loadImage(" & nimStr(p.value.text) & ")"   # read from disk at run time
        elif info != nil and info.kind == pkImages and p.value.kind == nvList:
          var parts: seq[string]
          for it in p.value.items: parts.add "loadImage(" & nimStr(it) & ")"
          e = "@[" & parts.join(", ") & "]"
        o.add ind & pn & " = " & e & "\n"
    for c in n.children:
      if c.name.len > 0: o.add ind & c.className & " " & c.name & ":\n"
      else: o.add ind & c.className & ":\n"
      emit(c, level + 1, false)
  let head =
    if root.className == "Frame": "frame " & formName & ":\n"
    elif root.className == "Form": "form " & formName & ":\n"
    else: "form " & formName & " of " & root.className & ":\n"
  o.add head
  if root.name.len > 0: o.add "  name = " & nimStr(root.name) & "\n"
  emit(root, 1, true)
  for s in stubs: o.add s
  o
