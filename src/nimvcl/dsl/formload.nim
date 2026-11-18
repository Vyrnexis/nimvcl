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

import std/[macros, os, sets, strutils]
import ../graphics/[color, font, image]
import ../core/component
import ./nfmsyntax {.all.}
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

macro declHandler*(evType: typedesc, formType: typed, handler: untyped): untyped =
  ## Forward-declares `proc handler(self: formType, <event parameters>)`; the
  ## calling module defines it later (`loadForm` uses this for every handler
  ## named in a form file).
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
  let key = formType.repr & "." & handler.strVal & "." & sig
  if key in declSeen: return newStmtList()
  declSeen.incl key
  result = newTree(nnkProcDef, handler, newEmptyNode(), newEmptyNode(),
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

  var names = initHashSet[string]()
  for n in walk(root):
    if n.name.len == 0: continue
    if n.name in reservedNames and n != root:
      error("loadForm: " & nfmPos(file, n.line, n.col) & ": `" & n.name &
            "` is reserved in `" & formName & "`: it is a field or property of " &
            "Component/Control/Form, so an object cannot use that name", site)
    if n.name in names:
      error("loadForm: " & nfmPos(file, n.line, n.col) & ": duplicate object name `" &
            n.name & "`", site)
    names.incl n.name

  var fields, creates, assigns, decls, classChecks: seq[string]
  var counter = 0
  let isFrame = root.className == "Frame"

  proc errStmt(msg: string): string = "{.error: " & nimStr(msg) & ".}"

  proc genProps(n: NfmNode, target: string) =
    for p in n.props:
      let pos = nfmPos(file, p.line, p.col)
      if p.name.isEventProp:
        if p.value.kind != nvIdent:
          error("loadForm: " & pos & ": `" & p.name & "` expects a handler name", site)
        let ev = target & "." & p.name
        decls.add "when compiles(typeof(" & n.className & "(nil)." & p.name & ")):\n" &
                  "  declHandler(typeof(" & n.className & "(nil)." & p.name & "), " &
                  formName & ", " & p.value.text & ")"
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
  # `genNode` appends a node's own properties before its children's: assigns are
  # in file order (properties of an object, then of its children), as in `form`.

  var src = ""
  for c in classChecks: src.add c & "\n"
  src.add "type " & formName & "* = ref object of " & root.className & "\n"
  for f in fields: src.add f & "\n"
  src.add "\n"
  for d in decls: src.add d & "\n"
  let baseInit = "init" & root.className
  src.add "proc init" & formName & "*(self: " & formName & ", owner: Component = nil) =\n"
  src.add "  when compiles(" & baseInit & "(self, owner)):\n    " & baseInit &
          "(self, owner)\n  else:\n    " & baseInit & "(self)\n"
  proc indentBlock(s: string): string =
    for line in s.splitLines: result.add "  " & line & "\n"
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
  when defined(nfmDump): echo src
  result = parseStmt(src)
  setLineInfoRec(result, site)
