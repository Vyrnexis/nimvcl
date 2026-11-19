## `loadForm`: turns a `.nfm` form file into a typed form at compile time.
##
## ```nim
## import nimvcl/core/[control, form, application]   # what the form uses,
## import nimvcl/controls/[button, edit]              # plus one module per class
## import nimvcl/dsl/formload
## loadForm MainForm, "MainForm.nfm"
## ```
##
## This is the light half of the form file support: it needs only the `.nfm`
## syntax (`nfmsyntax`) and emits plain assignments, so an application that
## uses `loadForm` does not compile the property registry (`props`,
## `props_std`), the object inspector or the run-time loader. Those live in
## `nimvcl/dsl/nfm` (which re-exports this module) and are for the IDE and for
## programs that load forms at run time with `loadNfm`.
##
## The calling module imports the modules of the classes the file names (the
## macro reports an unknown class otherwise), and the core modules the
## generated code uses (`core/control`, `core/form`; `controls/flowpanel` for a
## `GridPanel`'s `columns`, `controls/menus` for `shortcut`).

import std/[macros, os, sets, strutils, tables]
import ../graphics/[color, font, image]
import ../core/component
import ./nfmsyntax {.all.}
import ./propdeps
import ./formmacro {.all.}
## Re-exported: the generated code writes colours (`hex"#rrggbb"`) and font parts
## (`font.size = 12`), which need these modules in the caller's scope.
export color, font, formmacro.nfmSetSub


macro eventClosure*(evType: typedesc, selfExpr: typed, handler: untyped): untyped =
  ## A closure of the event type `evType` that calls `handler(selfExpr, params...)`.
  var impl = evType.getTypeInst[1].getTypeImpl
  while impl.kind == nnkBracketExpr or impl.kind == nnkSym: impl = impl.getTypeImpl
  if impl.kind != nnkProcTy:
    error("eventClosure: not a proc type", evType)
  var params = @[impl[0][0]]
  var call = newCall(handler, selfExpr)
  var i = 0
  for d in impl[0][1 .. ^1]:
    for j in 0 ..< d.len - 2:
      let n = ident("p" & $i)
      inc i
      params.add newIdentDefs(n, d[^2])
      call.add n
  result = newTree(nnkLambda, newEmptyNode(), newEmptyNode(), newEmptyNode(),
                   newTree(nnkFormalParams, params), newEmptyNode(), newEmptyNode(),
                   newStmtList(call))

var declSeen {.compileTime.}: HashSet[string]

macro declHandler*(evType: typedesc, formType: typed, handler: untyped,
                   exported: static[bool] = false): untyped =
  ## Forward-declares `proc handler(self: formType, <event parameters>)`; the
  ## calling module defines it later (`loadForm` uses this for every handler
  ## named in a form file; `exported` when the definition is `proc name*(...)`).
  var impl = evType.getTypeInst[1].getTypeImpl
  while impl.kind == nnkBracketExpr or impl.kind == nnkSym: impl = impl.getTypeImpl
  if impl.kind != nnkProcTy:
    error("declHandler: not a proc type", evType)
  var params = @[impl[0][0], newIdentDefs(ident"self", formType)]
  var sig = ""
  for d in impl[0][1 .. ^1]:
    for j in 0 ..< d.len - 2:
      params.add newIdentDefs(ident(d[j].strVal), d[^2])
      sig.add d[^2].repr & ","
  # per module: the same form type name in two modules needs a declaration in each
  let key = handler.lineInfoObj.filename & ":" & formType.repr & "." & handler.strVal & "." & sig
  if key in declSeen: return newStmtList()
  declSeen.incl key
  let nameNode = if exported: newTree(nnkPostfix, ident"*", handler) else: handler
  result = newTree(nnkProcDef, nameNode, newEmptyNode(), newEmptyNode(),
                   newTree(nnkFormalParams, params), newEmptyNode(), newEmptyNode(),
                   newEmptyNode())

proc nfmNote*(c: Component, event, handler: string) =
  ## Records the handler name of an event bound by `loadForm`, so that
  ## `formToNfm` writes it back.
  for i in 0 ..< c.handlerNames.len:
    if c.handlerNames[i][0] == event:
      c.handlerNames[i][1] = handler
      return
  c.handlerNames.add (event, handler)

proc setLineInfoRec(n, src: NimNode) =
  n.copyLineInfo(src)
  for c in n: setLineInfoRec(c, src)

proc nfmPos(file: string, line, col: int): string =
  file & ":" & $line & ":" & $col

template nfmIsImage*(T: typedesc): bool = T is Image
  ## `loadForm` uses these to tell an image property from a string one.
template nfmIsImages*(T: typedesc): bool = T is seq[Image]

template nfmEmbed*(path: static[string]): string =
  ## The bytes of a file, read at compile time (`loadForm` embeds pictures).
  const data = staticRead(path)
  data

proc nfmImage*(data, source: string): Image =
  ## An image decoded from the bytes `loadForm` embedded at compile time
  ## (`staticRead` of the file) with the path the form file named.
  imageFromMemory(data, source)

type AncestorInfo = object
  ## What a compile-time `loadForm` of an inherited form needs from the chain
  ## of ancestor files.
  typeName: string                    ## the Nim type of the direct ancestor (its root name)
  baseClass: string                   ## class of the first non-inherited root
  classes: Table[string, string]      ## every named object of the ancestors -> class
  files: seq[string]                  ## the ancestor files (for `staticRead`)
  events: seq[tuple[target, className, event, handler: string]]
    ## every event bound in the ancestor chain (the last binding of an event
    ## wins); `target` is `self` or `self.<name>`

proc collectAncestors(root: NfmNode, dir, shownFile: string, site: NimNode,
                      info: var AncestorInfo, depth = 0) =
  ## Reads the ancestor of the inherited form `root` (and its ancestors).
  if depth > 16:
    error("loadForm: the ancestor chain of `" & shownFile & "` is too deep (a cycle?)", site)
  let apath = if root.ancestor.isAbsolute: root.ancestor else: dir / root.ancestor
  if not fileExists(apath):
    error("loadForm: " & nfmPos(shownFile, root.line, root.col) & ": the ancestor form file `" &
          apath & "` does not exist", site)
  if apath in info.files:
    error("loadForm: the ancestor chain of `" & shownFile & "` loops back to `" & apath & "`", site)
  info.files.add apath
  var a: NfmNode
  try: a = parseNfm(readFile(apath), root.ancestor)
  except NfmError as e: error("loadForm: " & e.msg, site)
  legacyNames(a)
  if a.name.len == 0:
    error("loadForm: the root object of the ancestor `" & root.ancestor &
          "` has no name (its Nim type is named after it)", site)
  if depth == 0: info.typeName = a.name
  if a.inherited:
    collectAncestors(a, apath.parentDir, root.ancestor, site, info, depth + 1)
    for n in walk(a):
      if n.name.len > 0 and not n.inherited: info.classes[n.name] = n.className
  else:
    info.baseClass = a.className
    for n in walk(a):
      if n.name.len > 0: info.classes[n.name] = n.className
  # the events this file binds (a later binding of the same event replaces an earlier one)
  for n in walk(a):
    let isRoot = n == a
    if n.name.len == 0 and not isRoot: continue
    let target = if isRoot: "self" else: "self." & n.name
    let cls = if isRoot: info.baseClass else: n.className
    for p in n.props:
      if p.name.isEventProp and p.value.kind == nvIdent:
        var found = false
        for e in info.events.mitems:
          if e.target == target and e.event == p.name:
            e.handler = p.value.text
            found = true
        if not found:
          info.events.add (target: target, className: cls, event: p.name, handler: p.value.text)

type HandlerDefs = Table[string, int]
  ## "name/FormType" -> 1 (defined) or 2 (defined and exported)

proc scanHandlerDefs(src: string): HandlerDefs =
  ## One pass over `src`: every `proc name(self: T` / `func name*(self: T` at
  ## the start of a line. Index based, so the VM stays cheap on big units.
  var i = 0
  let n = src.len
  template skipWs() =
    while i < n and src[i] in {' ', '\t'}: inc i
  template expect(s: string): bool =
    (i + s.len <= n and src.continuesWith(s, i))
  while i < n:
    let lineEnd = block:
      var e = i
      while e < n and src[e] notin {'\n', '\r'}: inc e
      e
    skipWs()
    if expect("proc ") or expect("func "):
      i += 5
      skipWs()
      let s0 = i
      while i < lineEnd and (isIdentChar(src[i]) or src[i] == '`'): inc i
      let name = src[s0 ..< i]
      var exp = false
      if i < lineEnd and src[i] == '*':
        exp = true
        inc i
      skipWs()
      if name.len > 0 and i < lineEnd and src[i] == '(':
        inc i
        skipWs()
        if expect("self") and i + 4 < lineEnd and not isIdentChar(src[i + 4]):
          i += 4
          skipWs()
          if i < lineEnd and src[i] == ':':
            inc i
            skipWs()
            let t0 = i
            while i < lineEnd and isIdentChar(src[i]): inc i
            if i > t0:
              let key = name & "/" & src[t0 ..< i]
              result[key] = max(result.getOrDefault(key), if exp: 2 else: 1)
    i = lineEnd
    while i < n and src[i] in {'\n', '\r'}: inc i

proc handlerDef(defs: HandlerDefs, name, formType: string): int =
  ## 0: no `proc name(self: formType, ...)` (or `func`) at the start of a
  ## line; 1: there is one; 2: it is exported (`name*`).
  defs.getOrDefault(name & "/" & formType)

macro loadForm*(name: untyped, path: static[string]): untyped =
  ## Reads the form file `path` (relative to the calling module) at compile time
  ## and declares the typed form `name`, like the `form` macro would for the
  ## same tree:
  ##
  ## ```nim
  ## loadForm MainForm, "MainForm.nfm"
  ## proc okClick(self: MainForm, sender: Control) = ...   # one per `onXxx = okClick`
  ## Application.run(newMainForm())
  ## ```
  ##
  ## Generated (exported): `type MainForm* = ref object of Form` with a field for
  ## every named object, `initMainForm` and `newMainForm`. Handlers named in the
  ## file must be defined by the calling module, after the `loadForm` line, as
  ## `proc name(self: MainForm, <the event's parameters>)`; a missing one is a
  ## compile error. Parse errors are reported as `file:line:col: message` at the
  ## `loadForm` line.
  ##
  ## A form file that starts with `inherited Form2: Form2` and names its ancestor
  ## (`ancestor = 'unit1.nfm'`) declares `type Form2* = ref object of Form1`,
  ## where `Form1` is the root name of the ancestor file (the calling module
  ## imports the unit that declares it). The ancestor's fields and handlers are
  ## inherited; `initForm2` runs `initForm1`, then applies the `inherited`
  ## blocks (changed properties of ancestor objects, reached as `self.button1`)
  ## and creates the new objects. A handler named in the descendant is
  ## `proc name(self: Form2, ...)` and overrides the ancestor's for that event.
  ## So does a `proc name(self: Form2, ...)` in the calling module for a handler
  ## that the ancestor chain binds (the usual case: both forms have a
  ## `Button1Click`): `initForm2` re-binds those events to the descendant's proc
  ## after `initForm1`, like a Delphi override. Call the ancestor's version with
  ## `name(Form1(self), ...)` (it must be exported with `*` to be seen from
  ## another module). The calling module's source is scanned for the
  ## definitions, so they must be written out in that file (not `include`d or
  ## generated by a macro).
  let site = name        # carries the position of the `loadForm` line
  if name.kind != nnkIdent:
    error("loadForm: expected `loadForm Name, \"file.nfm\"`", name)
  let formName = name.strVal
  let srcFile = site.lineInfoObj.filename
  let nfmPath = if path.isAbsolute: path else: srcFile.parentDir / path
  let nfmDir = nfmPath.parentDir
  if not fileExists(nfmPath):
    error("loadForm: cannot read `" & nfmPath & "` (the path is relative to the calling module)", site)
  let text = readFile(nfmPath)
  var root: NfmNode
  try: root = parseNfm(text, path)
  except NfmError as e: error("loadForm: " & e.msg, site)
  legacyNames(root)
  let file = path
  let callerSrc = if fileExists(srcFile): readFile(srcFile) else: ""
  let callerDefs = scanHandlerDefs(callerSrc)

  var anc: AncestorInfo
  if root.inherited:
    collectAncestors(root, nfmDir, file, site, anc)

  proc checkInheritedNesting(n: NfmNode) =
    ## `inherited x` selects an object of the ancestor where the ancestor has
    ## it, so it can only stand in another `inherited` object.
    for c in n.children:
      if c.inherited and not n.inherited:
        error("loadForm: " & nfmPos(file, c.line, c.col) & ": `inherited " & c.name &
              "` can only stand directly in an `inherited` object of the form (it names " &
              "an object of the ancestor form, which cannot be moved into a new container)", site)
      checkInheritedNesting(c)
  checkInheritedNesting(root)

  var names = initHashSet[string]()
  for k in anc.classes.keys: names.incl k
  for n in walk(root):
    if n.name.len == 0: continue
    if n.inherited and n != root:
      if n.name notin anc.classes:
        error("loadForm: " & nfmPos(file, n.line, n.col) & ": `inherited " & n.name &
              "`: the ancestor form has no object of that name", site)
      if anc.classes[n.name] != n.className:
        error("loadForm: " & nfmPos(file, n.line, n.col) & ": `" & n.name &
              "` is a `" & anc.classes[n.name] & "` in the ancestor, not a `" &
              n.className & "`", site)
      continue
    if n.name in reservedNames and n != root:
      error("loadForm: " & nfmPos(file, n.line, n.col) & ": `" & n.name &
            "` is reserved in `" & formName & "`: it is a field or property of " &
            "Component/Control/Form, so an object cannot use that name", site)
    if n.name in names and n != root:
      error("loadForm: " & nfmPos(file, n.line, n.col) & ": duplicate object name `" &
            n.name & "`", site)
    names.incl n.name

  var fields, creates, assigns, decls, classChecks, rebinds: seq[string]
  var counter = 0
  let isFrame = (if root.inherited: anc.baseClass else: root.className) == "Frame"

  proc errStmt(msg: string): string = "{.error: " & nimStr(msg) & ".}"

  proc genProps(n: NfmNode, target: string) =
    # a file written before a property depended on another (`tabIndex` ahead of
    # `tabs`) is applied in the order the registry would write it
    var propNames: seq[string]
    for p in n.props: propNames.add p.name
    for pi in applyOrder(propNames):
      let p = n.props[pi]
      let pos = nfmPos(file, p.line, p.col)
      if p.name.isEventProp:
        if p.value.kind != nvIdent:
          error("loadForm: " & pos & ": `" & p.name & "` expects a handler name", site)
        let ev = target & "." & p.name
        decls.add "when compiles(typeof(" & n.className & "(nil)." & p.name & ")):\n" &
                  "  declHandler(typeof(" & n.className & "(nil)." & p.name & "), " &
                  formName & ", " & p.value.text & ", " &
                  $(handlerDef(callerDefs, p.value.text, formName) == 2) & ")"
        assigns.add "when compiles(typeof(" & ev & ")):\n  " & ev &
          " = eventClosure(typeof(" & ev & "), self, " & p.value.text & ")\n  nfmNote(" &
          target & ", " & nimStr(p.name) & ", " & nimStr(p.value.text) & ")\nelse:\n  " &
          errStmt(pos & ": `" & n.className & "` has no event `" & p.name & "`")
      elif '.' in p.name:
        let dot = p.name.find('.')
        let base = p.name[0 ..< dot]
        let sub = p.name[dot + 1 .. ^1]
        let (_, e) = nimExpr(n.className, sub, p.value, names)
        let call = "nfmSetSub(" & target & ", " & base & ", " & sub & ", " & e & ")"
        assigns.add "when compiles(" & call & "):\n  " & call & "\nelse:\n  " &
          errStmt(pos & ": `" & n.className & "` has no property `" & p.name &
                  "`, or the value does not fit it")
      else:
        let (pn, e) = nimExpr(n.className, p.name, p.value, names)
        let access = target & "." & pn
        # image properties: the file bytes are embedded in the program
        var imgBranch = ""
        proc embed(rel: string): string =
          "nfmImage(nfmEmbed(" & nimStr(nfmDir / rel) & "), " & nimStr(rel) & ")"
        if p.value.kind == nvString and p.value.text.len > 0:
          imgBranch = "  when nfmIsImage(typeof(" & access & ")):\n    " & access & " = " &
                      embed(p.value.text) & "\n  el"
        elif p.value.kind == nvList and p.value.items.len > 0:
          var parts: seq[string]
          for it in p.value.items: parts.add embed(it)
          imgBranch = "  when nfmIsImages(typeof(" & access & ")):\n    " & access &
                      " = @[" & parts.join(", ") & "]\n  el"
        assigns.add "when compiles(" & access & "):\n" &
          (if imgBranch.len > 0: imgBranch & "if" else: "  when") &
          " compiles((" & access & " = " & e &
          ")):\n    " & access & " = " & e & "\n  else:\n    " &
          errStmt(pos & ": the value of `" & p.name & "` does not fit its type in `" &
                  n.className & "`") & "\nelse:\n  " &
          errStmt(pos & ": `" & n.className & "` has no property `" & p.name & "`")

  proc genNode(n: NfmNode, target: string, isRoot: bool) =
    if isRoot and n.name.len > 0:
      assigns.add "self.name = " & nimStr(n.name)
    genProps(n, target)
    for c in n.children:
      if c.inherited:
        # an object of the ancestor: a field the base type already has
        genNode(c, "self." & c.name, false)
        continue
      inc counter
      let sym = "ch" & $counter
      let ctor = "new" & c.className
      let pos = nfmPos(file, c.line, c.col)
      classChecks.add "when not declared(" & c.className & "):\n  " &
        errStmt(pos & ": unknown class `" & c.className & "`: no type of that name is declared " &
                "(import its module; a custom class needs a `" & ctor & "` constructor)")
      creates.add "when not (declared(" & c.className & ") and (declared(" & ctor &
        ") or compiles(nfmMake(" & c.className & ", " & target & ")))):\n  " &
        errStmt(pos & ": unknown class `" & c.className & "`: no type `" & c.className &
                "` with a `" & ctor & "` constructor found")
      creates.add "let " & sym & " {.used.} = when compiles(nfmMake(" & c.className & ", " &
        target & ")): nfmMake(" & c.className & ", " & target & ")\n" &
        "  elif compiles(" & ctor & "(" & target & ")): " & ctor & "(" & target & ")\n" &
        "  else: " & ctor & "(owner = " & target & ")"
      if c.name.len > 0:
        fields.add "  " & c.name & "*: " & c.className
        creates.add "self." & c.name & " = " & sym
        creates.add sym & ".name = " & nimStr(c.name)
      genNode(c, sym, false)
  genNode(root, "self", true)
  if root.inherited:
    for e in anc.events:
      let def = handlerDef(callerDefs, e.handler, formName)
      if def == 0: continue
      let ev = e.target & "." & e.event
      decls.add "when compiles(typeof(" & e.className & "(nil)." & e.event & ")):\n" &
                "  declHandler(typeof(" & e.className & "(nil)." & e.event & "), " &
                formName & ", " & e.handler & ", " & $(def == 2) & ")"
      rebinds.add "when compiles(typeof(" & ev & ")):\n  " & ev &
        " = eventClosure(typeof(" & ev & "), self, " & e.handler & ")\n  nfmNote(" &
        e.target & ", " & nimStr(e.event) & ", " & nimStr(e.handler) & ")"
  # `genNode` appends a node's own properties before its children's: assigns are
  # in file order (properties of an object, then of its children), as in `form`.

  var src = ""
  for c in classChecks: src.add c & "\n"
  let baseType = if root.inherited: anc.typeName else: root.className
  src.add "type " & formName & "* = ref object of " & baseType & "\n"
  for f in fields: src.add f & "\n"
  src.add "\n"
  for d in decls: src.add d & "\n"
  let baseInit = "init" & baseType
  src.add "proc init" & formName & "*(self: " & formName & ", owner: Component = nil) =\n"
  src.add "  when compiles(" & baseInit & "(self, owner)):\n    " & baseInit &
          "(self, owner)\n  else:\n    " & baseInit & "(self)\n"
  proc indentBlock(s: string): string =
    for line in s.splitLines: result.add "  " & line & "\n"
  for r in rebinds: src.add indentBlock(r)
  for c in creates: src.add indentBlock(c)
  for a in assigns: src.add indentBlock(a)
  if isFrame:
    src.add "proc new" & formName & "*(parent: Container = nil, left = 0'f32, top = 0'f32,\n" &
            "                width = -1'f32, height = -1'f32): " & formName & " =\n" &
            "  new result\n  result.init" & formName & "(parent)\n" &
            "  result.placeControl(parent, left, top, width, height)\n"
  else:
    src.add "proc new" & formName & "*(owner: Component = nil): " & formName & " =\n" &
            "  new result\n  result.init" & formName & "(owner)\n"
  src.add "static: discard staticRead(" & nimStr(nfmPath) & ")\n"
  for f in anc.files: src.add "static: discard staticRead(" & nimStr(f) & ")\n"
  when defined(nfmDump): echo src
  result = parseStmt(src)
  setLineInfoRec(result, site)
