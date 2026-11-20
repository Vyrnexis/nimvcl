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

import std/[strutils, tables, macros, os, sets, hashes, math]
import ../graphics/[color, image]
import ../core/[component, control, form]
import ../controls/[menus, statusbar, listview, actions, flowpanel]
import ./props_std
import ./nfmsyntax {.all.}
import ./formload
import ./propdeps
export nfmsyntax, formload
export flowpanel.parseGridSizes, flowpanel.gridSizesToText

# ===================================================================== runtime

proc toNfmValue*(info: PropInfo, v: PropValue): NfmValue =
  ## The text-form value of a property value; raises `PropError` for values with
  ## no text form (images, composite kinds, unnamed objects).
  case v.kind
  of pkBool: nfmBool(v.b)
  of pkInt: nfmInt(v.i)
  of pkFloat:
    if classify(v.f) in {fcNan, fcInf, fcNegInf}:
      raise newException(PropError, "property `" & info.name &
                         "` is not a finite number (nothing to save)")
    let t = formatNumber(v.f)
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
    overrideHandlers*: HandlerResolver
      ## Inherited forms: asked, after the ancestor is built, for the descendant's
      ## version of every handler the ancestor chain bound (by the same name; the
      ## usual `Button1Click` in both forms). A box it returns replaces the
      ## ancestor's binding of that event; nil keeps the ancestor's.
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
    try: pvInt(parseInt(v.text))
    except ValueError: bad("`" & info.name & "`: `" & v.text & "` is too large for a whole number")
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
  if node.inherited:
    raise nfmError(file, node.line, node.col,
                   "`inherited " & node.name & "` can only stand directly in an " &
                   "`inherited` object of the form (it names an object of the ancestor " &
                   "form, which cannot be moved into a new container)")
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
  # a file written before a property depended on another (`tabIndex` ahead of
  # `tabs`) is applied in the order the registry would write it
  var propNames: seq[string]
  for p in b.node.props: propNames.add p.name
  for pi in applyOrder(propNames):
    let p = b.node.props[pi]
    if p.name == "designLeft" or p.name == "designTop":
      # the design position of a non-visual component (Component.designLeft/Top)
      if not (b.obj of Component) or p.value.kind != nvInt:
        opt.problem(file, p.line, p.col, "`" & p.name & "` takes a whole number")
        continue
      let v = try: parseInt(p.value.text)
              except ValueError:
                opt.problem(file, p.line, p.col, "`" & p.name & "`: `" & p.value.text &
                            "` is too large for a whole number")
                continue
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
        if b.node.inherited and b.obj of Component and
           p.name notin Component(b.obj).handlerOverrides:
          Component(b.obj).handlerOverrides.add p.name
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

proc markInherited(o: Obj, seen: var HashSet[Obj]) =
  if seen.containsOrIncl(o): return
  if o of Component:
    Component(o).inherited = true
    Component(o).handlerOverrides.setLen 0    # the ancestor's own re-bindings are its business
  for k in kidsOf(o): markInherited(k, seen)
  if o of Component:
    for x in Component(o).components: markInherited(Obj(x), seen)

proc overlay(n: NfmNode, o: Obj, fileName: string, owner: Component, opt: NfmOptions,
             byName: var Table[string, Obj], built: var seq[Built]) =
  ## Inherited blocks select an existing object (their properties are applied
  ## later); `object` blocks create new ones.
  for c in n.children:
    if c.inherited:
      if not byName.hasKey(c.name):
        opt.problem(fileName, c.line, c.col,
                    "`inherited " & c.name & "`: the ancestor form has no object of that name")
        continue
      let co = byName[c.name]
      let ci = classOf(co)
      let want = classByName(c.className)
      if ci == nil or want == nil or ci != want:
        opt.problem(fileName, c.line, c.col,
                    "`" & c.name & "` is a `" & (if ci == nil: "?" else: ci.name) &
                    "` in the ancestor, not a `" & c.className & "`")
        continue
      built.add Built(node: c, obj: co, ci: ci)
      overlay(c, co, fileName, owner, opt, byName, built)
    else:
      buildTree(c, o, Obj(owner), fileName, opt, byName, built)

proc buildNfmImpl(root: NfmNode, owner: Component, opt: NfmOptions,
                  fileName: string, byName: var Table[string, Obj],
                  chain: seq[string]): Obj =
  let baseDir = if opt.baseDir.len > 0: opt.baseDir
                elif fileName.len > 0: fileName.parentDir
                else: ""
  var built: seq[Built]
  if not root.inherited:
    buildTree(root, nil, Obj(owner), fileName, opt, byName, built)
    if built.len == 0: return nil
    for b in built: applyProps(b, fileName, opt, byName, baseDir)
    return built[0].obj
  # an inherited form: build the ancestor first, then lay the differences over it
  let dir = if fileName.len > 0: fileName.parentDir else: baseDir
  let apath = if root.ancestor.isAbsolute: root.ancestor
              elif dir.len > 0: dir / root.ancestor
              else: root.ancestor
  let key = absolutePath(apath)
  if key in chain or chain.len > 16:
    raise nfmError(fileName, root.line, root.col,
                   "the ancestor chain of `" & root.name & "` loops back to `" & root.ancestor & "`")
  if not fileExists(apath):
    raise nfmError(fileName, root.line, root.col,
                   "the ancestor form file `" & apath & "` does not exist")
  let aroot = parseNfm(readFile(apath), apath)
  legacyNames(aroot)
  let aobj = buildNfmImpl(aroot, owner, opt, apath, byName, chain & @[absolutePath(fileName)])
  if aobj == nil:
    raise nfmError(fileName, root.line, root.col, "the ancestor `" & root.ancestor &
                   "` did not build a form")
  var seen = initHashSet[Obj]()
  markInherited(aobj, seen)
  if aobj of Component:
    let c = Component(aobj)
    c.ancestorFile = root.ancestor
    c.ancestorPath = apath
    if root.name.len > 0:
      byName.del c.name
      c.name = root.name
      byName[root.name] = aobj
  if opt.overrideHandlers != nil:
    var seenO = initHashSet[Obj]()
    var todo = @[aobj]
    while todo.len > 0:
      let o = todo.pop()
      if seenO.containsOrIncl(o): continue
      for k in kidsOf(o): todo.add k
      if o of Component:
        for x in Component(o).components: todo.add Obj(x)
        let ci = classOf(o)
        if ci == nil: continue
        for (ev, h) in Component(o).handlerNames:
          let info = ci.findProp(ev)
          if info == nil or info.kind != pkEvent: continue
          let box = opt.overrideHandlers(h, info.typeName)
          if box != nil: discard info.bindHandler(o, box)
  built.add Built(node: root, obj: aobj, ci: classOf(aobj))
  overlay(root, aobj, fileName, owner, opt, byName, built)
  for b in built: applyProps(b, fileName, opt, byName, baseDir)
  aobj

proc buildNfm*(root: NfmNode, owner: Component = nil, options: NfmOptions = nil,
               fileName = ""): Obj =
  ## Builds the object tree described by `root` through the registry and
  ## returns the root object. Children are created first (top-down), then the
  ## properties are applied in file order (so a property may refer to any named
  ## object of the file), exactly like the `form` macro.
  ##
  ## For an inherited form (`inherited Form2: Form2` with an `ancestor`), the
  ## ancestor file (relative to `fileName`) is built first and the descendant's
  ## `inherited` blocks and new objects are applied on top; the objects that
  ## come from the ancestor have `inherited` set.
  let opt = if options == nil: newNfmOptions() else: options
  var byName: Table[string, Obj]
  let ownedBefore = if owner != nil: owner.components.len else: 0
  try:
    result = buildNfmImpl(root, owner, opt, fileName, byName, @[absolutePath(fileName)])
  except CatchableError:
    # a failed load leaves nothing of the half-built tree in `owner`
    if owner != nil:
      while owner.components.len > ownedBefore:
        owner.removeComponent(owner.components[^1])
    raise

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

type SaveCtx = object
  nested: HashSet[Obj]    ## objects that are written as the child of another one
  ancestors: Table[string, Obj]  ## inherited form: the named objects of a fresh ancestor
  inheriting: bool
  scope: HashSet[Obj]     ## every object the save writes; a reference to anything else is dropped
  scoped: bool

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
    result.scope.incl o
    for k in kidsOf(o): result.nested.incl k
  result.scoped = true

proc sameValue(a, b: NfmValue): bool =
  a.kind == b.kind and a.text == b.text and a.items == b.items

proc ownProps(o: Obj, ctx: SaveCtx): seq[NfmProp] =
  ## The properties of `o` that differ from a fresh instance, in registry order.
  ## An object reference is written only when its target is part of the saved
  ## tree (`ctx.scope`, when set): a deleted component another one still points
  ## at would make a file that cannot be loaded.
  let ci = classOf(o)
  if o of Component:
    let c = Component(o)
    if c.designLeft != 0 or c.designTop != 0:
      result.add NfmProp(name: "designLeft", value: nfmInt(c.designLeft))
      result.add NfmProp(name: "designTop", value: nfmInt(c.designTop))
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
        result.add NfmProp(name: p.name, value: toNfmValue(p, v))
    of pkImages:
      let v = p.get(o)
      if v.imgs.len > 0:
        result.add NfmProp(name: p.name, value: toNfmValue(p, v))
    of pkFont, pkSpacing, pkConstraints:
      for s in subProps(p):
        if not isDefault(o, s):
          result.add NfmProp(name: s.name, value: toNfmValue(s, s.get(o)))
    of pkEvent:
      let h = handlerNameOf(o, p.name)
      if h.len > 0: result.add NfmProp(name: p.name, value: nfmIdent(h))
    of pkObject:
      if not isDefault(o, p):
        let v = p.get(o)
        if v.obj == nil or (objectName(v.obj).len > 0 and
                            (not ctx.scoped or v.obj in ctx.scope)):
          result.add NfmProp(name: p.name, value: toNfmValue(p, v))
    else:
      if not isDefault(o, p):
        result.add NfmProp(name: p.name, value: toNfmValue(p, p.get(o)))

proc diffProps(o, anc: Obj, ctx: SaveCtx): seq[NfmProp] =
  ## What `o` sets differently from its ancestor's counterpart `anc`: changed or
  ## new values, plus the default value of a property the ancestor sets and `o`
  ## does not (an event cannot be unset, so it is skipped).
  let mine = ownProps(o, ctx)
  var plain = ctx
  plain.scoped = false             # the ancestor's references are its own
  let theirs = ownProps(anc, plain)
  var theirIdx = initTable[string, int]()
  for i, p in theirs: theirIdx[p.name] = i
  var mineNames = initHashSet[string]()
  for p in mine:
    mineNames.incl p.name
    if theirIdx.hasKey(p.name) and sameValue(theirs[theirIdx[p.name]].value, p.value) and
       not (o of Component and p.name in Component(o).handlerOverrides): continue
    result.add p
  let ci = classOf(o)
  for p in theirs:
    if p.name in mineNames: continue
    if p.name == "designLeft" or p.name == "designTop":
      result.add NfmProp(name: p.name, value: nfmInt(0))
      continue
    let info = ci.findProp(p.name)
    if info == nil or info.kind == pkEvent: continue
    case info.kind
    of pkImage: result.add NfmProp(name: p.name, value: nfmString(""))
    of pkImages: result.add NfmProp(name: p.name, value: NfmValue(kind: nvList))
    else:
      try: result.add NfmProp(name: p.name, value: toNfmValue(info, ci.defaultOf(info)))
      except PropError: discard

proc nodeOf(o: Obj, ctx: SaveCtx, nameOverride = "", anc: Obj = nil,
            kidList: seq[Obj] = @[], useKidList = false): NfmNode =
  let ci = classOf(o)
  if ci == nil: return nil
  result = NfmNode(className: ci.name,
                   name: if nameOverride.len > 0: nameOverride else: objectName(o))
  if anc != nil:
    result.inherited = true
    result.props = diffProps(o, anc, ctx)
  else:
    result.props = ownProps(o, ctx)
  var kids = if useKidList: kidList else: kidsOf(o)
  if o of Component and not useKidList:
    # non-visual components owned by this one, as Delphi writes them
    for x in Component(o).components:
      if x.isStandalone and Obj(x) notin ctx.nested: kids.add Obj(x)
  for k in kids:
    var a: Obj
    if ctx.inheriting:
      let nm = objectName(k)
      if nm.len > 0: a = ctx.ancestors.getOrDefault(nm)
    let n = nodeOf(k, ctx, "", a)
    # an inherited object nothing changed in is not written
    if n != nil and not (n.inherited and n.props.len == 0 and n.children.len == 0):
      result.children.add n

proc objectToNfmNode*(o: Obj, rootName = ""): NfmNode =
  ## The syntax tree of an object and its children: only properties that
  ## differ from a fresh instance, in registry order. Events appear when a
  ## handler name was recorded for them (by `loadNfm` or `setProp`).
  nodeOf(o, newSaveCtx(o), rootName)

proc objectToNfm*(o: Obj, rootName = ""): string =
  let n = objectToNfmNode(o, rootName)
  if n == nil: raise newException(PropError, "object is not of a registered class")
  writeNfm(n)

proc formToNfmNode*(f: Form, kids: openArray[Obj], rootName = ""): NfmNode =
  ## The syntax tree `formToNfm` writes, for a form whose children are not
  ## where the form keeps them (a designer that shows them in a panel of its
  ## own): the root's own properties are the form's, its children are `kids`
  ## (controls and non-visual components, in file order). For an inherited form
  ## (`ancestorPath` is set) the tree holds only the differences from a freshly
  ## built ancestor, see `formToNfm`.
  let n = f.name
  let nm = if n.len > 0: n else: (if rootName.len > 0: rootName else: "Form1")
  var ctx: SaveCtx
  ctx.scoped = true
  ctx.scope.incl Obj(f)
  for k in kids:
    let kc = newSaveCtx(k)
    for x in kc.nested: ctx.nested.incl x
    for x in kc.scope: ctx.scope.incl x
  var anc: Obj
  if f.ancestorPath.len > 0:
    anc = loadNfmFile(f.ancestorPath, nil, newNfmOptions(strict = false))
    ctx.inheriting = true
    var all: seq[Obj]
    var seen: HashSet[Obj]
    gatherAll(anc, all, seen)
    for o in all:
      let nmo = objectName(o)
      if nmo.len > 0: ctx.ancestors[nmo] = o
  result = nodeOf(f, ctx, nm, anc, @kids, true)
  if anc != nil:
    result.inherited = true
    result.className = nm
    result.ancestor = f.ancestorFile

proc formToNfm*(f: Form, rootName = ""): string =
  ## Serialises a live form through the registry; this is what a designer
  ## saves. `rootName` names the root when the form has no `name`.
  ##
  ## An inherited form (one `loadNfm` built from a file that starts with
  ## `inherited`; `ancestorPath` is set) is written as the difference from a
  ## freshly built ancestor: `inherited` blocks with only the changed
  ## properties, `object` blocks for new components, and nothing for ancestor
  ## components that were left alone.
  if f.ancestorPath.len == 0:
    let n = f.name
    return objectToNfm(f, if n.len > 0: "" else: (if rootName.len > 0: rootName else: "Form1"))
  var kids: seq[Obj]
  var ctxAll = newSaveCtx(f)
  for k in kidsOf(f): kids.add k
  for x in f.components:
    if x.isStandalone and Obj(x) notin ctxAll.nested: kids.add Obj(x)
  writeNfm(formToNfmNode(f, kids, rootName))

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
  if root.inherited:
    raise nfmError(fileName, root.line, root.col,
                   "the `form` macro has no inherited forms; use `loadForm` with the file")
  var names = initHashSet[string]()
  for n in walk(root):
    if n.name.len > 0: names.incl n.name
  var o = ""
  var stubs: seq[string]
  var seenStub = initHashSet[string]()
  let formName = if root.name.len > 0: root.name else: "Form1"
  proc emit(n: NfmNode, level: int) =
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
      emit(c, level + 1)
  let head =
    if root.className == "Frame": "frame " & formName & ":\n"
    elif root.className == "Form": "form " & formName & ":\n"
    else: "form " & formName & " of " & root.className & ":\n"
  o.add head
  if root.name.len > 0: o.add "  name = " & nimStr(root.name) & "\n"
  emit(root, 1)
  for s in stubs: o.add s
  o
