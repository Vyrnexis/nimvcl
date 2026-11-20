## The `form` and `frame` macros: declare a window (or a reusable composite
## control) as a typed tree, like a Delphi .dfm but checked by the compiler.
## See docs/forms.md for the user guide.
##
## ```nim
## form LoginForm:
##   caption = "Sign in"
##   var attempts = 0
##   Edit user:
##     placeholder = "name"
##   Button ok:
##     caption = "OK"
##     onClick: self.attempts.inc
##   proc hello(self: LoginForm) = echo self.user.text
##   init:
##     self.hello()
## ```
##
## Generated (exported): `type LoginForm* = ref object of Form` with one field
## per named child and per `var`; `proc initLoginForm*(self, owner = nil)`;
## `proc newLoginForm*(owner = nil)`. For `frame` the base is `Frame` and the
## constructor is the usual `newXxx(parent, left, top, width, height)`.
##
## Construction order inside `initXxx`: base init, `var` defaults, every child
## top-down (`newT(parent)`), every property assignment in source order (so
## properties may refer to children declared later), then the `init:` blocks.
##
## Child types: any identifier `T` for which `newT(parent: Container)` exists
## (and a type `T` for the field). Custom controls only have to follow that
## convention.

import std/[macros, strutils, tables]
import ./nfmsyntax {.all.}

type
  Gen = object
    fields: seq[NimNode]            # IdentDefs of the generated type
    names: Table[string, bool]      # every field name (children and vars)
    checks, defaults, build, props, inits, procs: NimNode
    selfId: NimNode
    formName: string

proc nn(kind: NimNodeKind, src: NimNode, kids: varargs[NimNode]): NimNode =
  ## New node carrying `src`'s line info, so generated errors point at the
  ## user's source line.
  result = newNimNode(kind)
  result.copyLineInfo(src)
  for k in kids: result.add k

proc idn(s: string, src: NimNode): NimNode =
  result = ident(s)
  result.copyLineInfo(src)

proc dot(a: NimNode, b: string, src: NimNode): NimNode =
  nn(nnkDotExpr, src, a, idn(b, src))

proc errorStmt(msg: string, src: NimNode): NimNode =
  nn(nnkPragma, src, nn(nnkExprColonExpr, src, idn("error", src), newLit(msg)))

proc whenElse(cond: NimNode, yes, no: NimNode, src: NimNode): NimNode =
  nn(nnkWhenStmt, src,
     nn(nnkElifBranch, src, cond, nn(nnkStmtList, src, yes)),
     nn(nnkElse, src, nn(nnkStmtList, src, no)))

proc claim(g: var Gen, name: string, src: NimNode) =
  if isReservedFieldName(name):
    error("nimvcl form: `" & name & "` is reserved in `" & g.formName &
          "`: it is a field or property of Component/Control/Form, so a child " &
          "or `var` cannot use that name; pick another (e.g. `" & name &
          "Edit`)", src)
  if g.names.hasKey(name):
    error("nimvcl form: duplicate name `" & name & "` in `" & g.formName &
          "`: child and `var` names must be unique", src)
  g.names[name] = true

template nfmSetSub*(target, prop, sub, value: untyped) =
  ## `target.prop.sub = value` for a composite property that is read and written
  ## as a whole (`font`, `margins`, `padding`, `constraints`): the form macros
  ## use it for `font.size = 12`.
  block:
    var part = target.prop
    part.sub = value
    target.prop = part

proc propStmt(target: NimNode, tname: string, st: NimNode): NimNode =
  ## `prop = value` on `target`, with a readable error for unknown properties.
  let lhs = st[0]
  if lhs.kind == nnkDotExpr and lhs[0].kind == nnkIdent and lhs[1].kind == nnkIdent:
    # `font.size = 12`: a part of a composite property
    let call = nn(nnkCall, st, idn("nfmSetSub", st), target, lhs[0], lhs[1], st[1])
    return whenElse(nn(nnkCall, st, idn("compiles", st), call), call,
                    errorStmt("nimvcl form: `" & tname & "` has no property `" &
                              lhs[0].strVal & "` with a part `" & lhs[1].strVal &
                              "`, or the value does not fit it", st), st)
  if lhs.kind != nnkIdent:
    error("nimvcl form: expected `property = value`", st)
  let access = dot(target, lhs.strVal, lhs)
  let asg = nn(nnkAsgn, st, access, st[1])
  let cond = nn(nnkCall, st, idn("compiles", st), access)
  whenElse(cond, asg,
           errorStmt("nimvcl form: `" & tname & "` has no property `" &
                     lhs.strVal & "`", st), st)

proc eventStmt(target: NimNode, tname: string, st: NimNode): NimNode =
  ## `onX: body` shorthand for a NotifyEvent.
  let ev = st[0].strVal
  if st.len != 2 or st[1].kind != nnkStmtList:
    error("nimvcl form: expected `" & ev & ": <statements>`", st)
  let access = dot(target, ev, st[0])
  let lam = nn(nnkLambda, st, newEmptyNode(), newEmptyNode(), newEmptyNode(),
               nn(nnkFormalParams, st, newEmptyNode(),
                  nn(nnkIdentDefs, st, idn("sender", st), idn("Control", st),
                     newEmptyNode())),
               newEmptyNode(), newEmptyNode(), st[1])
  let asg = nn(nnkAsgn, st, access, lam)
  let isNotify = nn(nnkInfix, st, idn("is", st),
                    nn(nnkCall, st, idn("typeof", st), access),
                    idn("NotifyEvent", st))
  let inner = whenElse(isNotify, asg,
    errorStmt("nimvcl form: `" & ev & "` of `" & tname &
              "` is not a NotifyEvent; the `" & ev & ": ...` shorthand only " &
              "works for events of type proc(sender: Control). Write `" & ev &
              " = proc(...) = ...` in full instead", st), st)
  whenElse(nn(nnkCall, st, idn("compiles", st), access), inner,
           errorStmt("nimvcl form: `" & tname & "` has no event `" & ev & "`",
                     st), st)

proc walk(g: var Gen, body, target: NimNode, tname: string, top: bool) =
  for st in body:
    case st.kind
    of nnkCommentStmt, nnkDiscardStmt: discard
    of nnkAsgn:
      g.props.add propStmt(target, tname, st)
    of nnkVarSection:
      if not top: error("nimvcl form: `var` is only allowed at form level", st)
      for d in st:
        let typ = d[^2]
        let def = d[^1]
        if typ.kind == nnkEmpty and def.kind == nnkEmpty:
          error("nimvcl form: `var` needs a type or a value", d)
        for i in 0 ..< d.len - 2:
          var nm = d[i]
          if nm.kind == nnkPostfix: nm = nm[1]
          g.claim(nm.strVal, nm)
          let ft = if typ.kind != nnkEmpty: typ
                   else: nn(nnkCall, d, idn("typeof", d), def)
          g.fields.add nn(nnkIdentDefs, nm,
                          nn(nnkPostfix, nm, idn("*", nm), nm), ft, newEmptyNode())
          if def.kind != nnkEmpty:
            g.defaults.add nn(nnkAsgn, nm, dot(g.selfId, nm.strVal, nm), def)
    of nnkProcDef, nnkFuncDef, nnkMethodDef, nnkTemplateDef, nnkIteratorDef,
       nnkConverterDef:
      if not top:
        error("nimvcl form: procs are only allowed at form level", st)
      g.procs.add st
    of nnkCommand, nnkCall:
      var typeId, nameId, sub: NimNode = nil
      if st.kind == nnkCall:
        let head = st[0]
        if head.kind != nnkIdent: error("nimvcl form: unsupported statement", st)
        if head.eqIdent("init"):
          if not top: error("nimvcl form: `init:` is only allowed at form level", st)
          if st.len != 2 or st[1].kind != nnkStmtList:
            error("nimvcl form: expected `init:` followed by statements", st)
          for s in st[1]: g.inits.add s
          continue
        if isEventProp(head.strVal):
          g.props.add eventStmt(target, tname, st)
          continue
        if st.len != 2 or st[1].kind != nnkStmtList:
          error("nimvcl form: unsupported statement", st)
        typeId = head; sub = st[1]
      else:
        if st.len notin 2 .. 3 or st[0].kind != nnkIdent or st[1].kind != nnkIdent or
           (st.len == 3 and st[2].kind != nnkStmtList):
          error("nimvcl form: expected `Type name:` (a child), `Type:` (an " &
                "unnamed child) or `property = value`", st)
        typeId = st[0]; nameId = st[1]
        if st.len == 3: sub = st[2]
      # ---- a child control
      let ts = typeId.strVal
      let sym = genSym(nskLet, "ch")
      let newCall = nn(nnkCall, st, idn("new" & ts, typeId), target)
      let probe = nn(nnkCall, st, idn("new" & ts, typeId),
                     nn(nnkCall, st, idn("Container", st), newNilLit()))
      let known = nn(nnkInfix, st, idn("and", st),
                     nn(nnkCall, st, idn("declared", st), idn(ts, typeId)),
                     nn(nnkCall, st, idn("compiles", st), probe))
      g.checks.add nn(nnkWhenStmt, st, nn(nnkElifBranch, st,
        nn(nnkPrefix, st, idn("not", st), known),
        nn(nnkStmtList, st, errorStmt("nimvcl form: unknown control type `" & ts &
           "`: no type `" & ts & "` with a `new" & ts & "(parent: Container)` " &
           "constructor found (see docs/forms.md)", typeId))))
      g.build.add nn(nnkLetSection, st,
        nn(nnkIdentDefs, st, nn(nnkPragmaExpr, st, sym, nn(nnkPragma, st, idn("used", st))),
           newEmptyNode(), newCall))
      if nameId != nil:
        g.claim(nameId.strVal, nameId)
        g.fields.add nn(nnkIdentDefs, nameId,
                        nn(nnkPostfix, nameId, idn("*", nameId), nameId), typeId,
                        newEmptyNode())
        g.build.add nn(nnkAsgn, nameId, dot(g.selfId, nameId.strVal, nameId), sym)
        g.build.add nn(nnkAsgn, nameId, dot(sym, "name", nameId), newLit(nameId.strVal))
      if sub != nil: g.walk(sub, sym, ts, false)
    else:
      error("nimvcl form: unsupported statement (expected `property = value`, " &
            "`Type name:`, `onEvent: ...`, `var`, `proc` or `init:`)", st)

proc generate(head, body: NimNode, isFrame: bool): NimNode =
  var nameId = head
  var baseId = idn(if isFrame: "Frame" else: "Form", head)
  if head.kind == nnkInfix and head[0].eqIdent("of"):
    nameId = head[1]; baseId = head[2]
  if nameId.kind != nnkIdent or baseId.kind != nnkIdent:
    error("nimvcl form: expected `" & (if isFrame: "frame" else: "form") &
          " Name:` or `Name of Base:`", head)
  var g = Gen(checks: newStmtList(), defaults: newStmtList(), build: newStmtList(), props: newStmtList(),
              inits: newStmtList(), procs: newStmtList(),
              selfId: ident"self", formName: nameId.strVal)
  g.walk(body, g.selfId, nameId.strVal, true)

  let initName = ident("init" & nameId.strVal)
  let newName = ident("new" & nameId.strVal)
  let baseInit = ident("init" & baseId.strVal)
  let selfId = g.selfId
  let recList = if g.fields.len == 0: newEmptyNode()
                else: nn(nnkRecList, head, g.fields)
  let typeDef = nn(nnkTypeSection, head,
    nn(nnkTypeDef, head, nn(nnkPostfix, head, ident"*", nameId), newEmptyNode(),
       nn(nnkRefTy, head, nn(nnkObjectTy, head, newEmptyNode(),
          nn(nnkOfInherit, head, baseId), recList))))
  var stmts = newStmtList()
  stmts.add g.defaults
  stmts.add g.build
  stmts.add g.props
  stmts.add g.inits
  let initProc = quote do:
    proc `initName`*(`selfId`: `nameId`, owner: Component = nil) =
      when compiles(`baseInit`(`selfId`, owner)):
        `baseInit`(`selfId`, owner)
      else:
        `baseInit`(`selfId`)
      `stmts`
  let newProc =
    if isFrame:
      quote do:
        proc `newName`*(parent: Container = nil, left = 0'f32, top = 0'f32,
                        width = -1'f32, height = -1'f32): `nameId` =
          new result
          result.`initName`(parent)
          result.placeControl(parent, left, top, width, height)
    else:
      quote do:
        proc `newName`*(owner: Component = nil): `nameId` =
          new result
          result.`initName`(owner)
          result.notifyCreated()
  result = newStmtList(g.checks)     # first, so unknown types are reported by us
  result.add typeDef
  for p in g.procs: result.add p
  result.add initProc
  result.add newProc

macro form*(head, body: untyped): untyped =
  ## Declares a `Form` subtype. `form Name:` or `form Name of Base:`.
  generate(head, body, false)

macro frame*(head, body: untyped): untyped =
  ## Declares a reusable composite control (base `Frame`, a transparent
  ## `Panel`). `frame Name:` or `frame Name of Base:`.
  generate(head, body, true)
