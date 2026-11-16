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
## This module has three layers:
##
## * the syntax tree, `parseNfm` and `writeNfm` (no dependencies beyond
##   `strutils`, so the parser also runs inside macros);
## * run-time use of the registry: `loadNfm`, `formToNfm`, `nfmToFormMacro`;
## * the `loadForm` macro.

import std/[strutils, tables, macros, os, sets]
import ../graphics/color
import ../core/[component, control, form]
import ../controls/[menus, statusbar, listview, actions]
import ./props_std
import ./formmacro {.all.}
export props_std.parseGridSizes, props_std.gridSizesToText

type
  NfmError* = object of CatchableError
    ## A syntax or load error. `line`/`col` are 1-based (0: no position).
    fileName*: string
    line*, col*: int

  NfmValueKind* = enum
    nvInt, nvFloat, nvBool, nvString, nvIdent, nvColor, nvSet, nvList

  NfmValue* = object
    kind*: NfmValueKind
    text*: string         ## literal text (numbers, colour), decoded string, identifier
    items*: seq[string]   ## nvSet: element names; nvList: decoded strings
    line*, col*: int

  NfmProp* = object
    name*: string         ## `caption`, or a dotted path `font.size`
    value*: NfmValue
    line*, col*: int

  NfmNode* = ref object
    name*: string         ## "" for an unnamed object
    className*: string
    props*: seq[NfmProp]
    children*: seq[NfmNode]
    line*, col*: int

# ------------------------------------------------------------------ errors

proc nfmError(fileName: string, line, col: int, msg: string): ref NfmError =
  result = newException(NfmError,
    (if fileName.len > 0: fileName & ":" else: "") &
    (if line > 0: $line & ":" & $col & ": " else: "") & msg)
  result.fileName = fileName
  result.line = line
  result.col = col

# ------------------------------------------------------------------- lexer

type
  TokKind = enum
    tkEof, tkIdent, tkInt, tkFloat, tkString, tkColor, tkPunct

  Token = object
    kind: TokKind
    text: string          # identifier, number text, decoded string, "#hex", punctuation
    line, col: int

  Lexer = object
    src: string
    pos, line, col: int
    fileName: string
    tok: Token

proc fail(lx: Lexer, line, col: int, msg: string) {.noreturn.} =
  raise nfmError(lx.fileName, line, col, msg)

proc isIdentStart(c: char): bool = c in {'a'..'z', 'A'..'Z', '_'}
proc isIdentChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '_', '0'..'9'}

proc cur(lx: Lexer): char =
  if lx.pos < lx.src.len: lx.src[lx.pos] else: '\0'

proc peekc(lx: Lexer, n = 1): char =
  if lx.pos + n < lx.src.len: lx.src[lx.pos + n] else: '\0'

proc advance(lx: var Lexer) =
  if lx.pos < lx.src.len:
    if lx.src[lx.pos] == '\n':
      inc lx.line
      lx.col = 1
    else:
      inc lx.col
    inc lx.pos

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc readString(lx: var Lexer): string =
  ## At the opening quote. Escapes: \\ \' \n \r \t \0 \xHH.
  let l0 = lx.line
  let c0 = lx.col
  lx.advance()
  while true:
    let c = lx.cur
    if lx.pos >= lx.src.len:
      lx.fail(l0, c0, "unterminated string (missing closing ')")
    if c == '\n':
      lx.fail(l0, c0, "unterminated string (a string ends on its line; use \\n for a line break)")
    if c == '\'':
      lx.advance()
      return
    if c == '\\':
      let el = lx.line
      let ec = lx.col
      lx.advance()
      let e = lx.cur
      case e
      of '\\': result.add '\\'
      of '\'': result.add '\''
      of 'n': result.add '\n'
      of 'r': result.add '\r'
      of 't': result.add '\t'
      of '0': result.add '\0'
      of 'x':
        let h1 = hexVal(lx.peekc(1))
        let h2 = hexVal(lx.peekc(2))
        if h1 < 0 or h2 < 0:
          lx.fail(el, ec, "bad escape \\x: two hex digits expected")
        result.add char(h1 * 16 + h2)
        lx.advance()
        lx.advance()
      else:
        lx.fail(el, ec, "unknown escape \\" & (if e == '\0': "" else: $e) &
                " (use \\\\ \\' \\n \\r \\t \\0 or \\xHH)")
      lx.advance()
    else:
      result.add c
      lx.advance()

proc next(lx: var Lexer) =
  # skip white space and // comments
  while true:
    let c = lx.cur
    if lx.pos >= lx.src.len: break
    if c in {' ', '\t', '\r', '\n'}: lx.advance()
    elif c == '/' and lx.peekc() == '/':
      while lx.pos < lx.src.len and lx.cur != '\n': lx.advance()
    else: break
  var t = Token(line: lx.line, col: lx.col)
  if lx.pos >= lx.src.len:
    t.kind = tkEof
    lx.tok = t
    return
  let c = lx.cur
  if isIdentStart(c):
    t.kind = tkIdent
    while true:
      while isIdentChar(lx.cur):
        t.text.add lx.cur
        lx.advance()
      if lx.cur == '.' and isIdentStart(lx.peekc()):
        t.text.add '.'
        lx.advance()
      else: break
  elif c in {'0'..'9'} or (c == '-' and lx.peekc() in {'0'..'9'}):
    t.kind = tkInt
    if c == '-':
      t.text.add c
      lx.advance()
    while lx.cur in {'0'..'9'}:
      t.text.add lx.cur
      lx.advance()
    if lx.cur == '.' and lx.peekc() in {'0'..'9'}:
      t.kind = tkFloat
      t.text.add '.'
      lx.advance()
      while lx.cur in {'0'..'9'}:
        t.text.add lx.cur
        lx.advance()
    if lx.cur in {'e', 'E'} and
       (lx.peekc() in {'0'..'9'} or (lx.peekc() in {'+', '-'} and lx.peekc(2) in {'0'..'9'})):
      t.kind = tkFloat
      t.text.add lx.cur
      lx.advance()
      if lx.cur in {'+', '-'}:
        t.text.add lx.cur
        lx.advance()
      while lx.cur in {'0'..'9'}:
        t.text.add lx.cur
        lx.advance()
  elif c == '\'':
    t.kind = tkString
    t.text = lx.readString()
  elif c == '#':
    t.kind = tkColor
    t.text.add '#'
    lx.advance()
    while hexVal(lx.cur) >= 0:
      t.text.add lx.cur
      lx.advance()
    if t.text.len notin [4, 5, 7, 9]:
      lx.fail(t.line, t.col, "bad colour `" & t.text &
              "`: expected #rgb, #rgba, #rrggbb or #rrggbbaa")
  elif c in {'=', ':', '[', ']', '(', ')', ','}:
    t.kind = tkPunct
    t.text = $c
    lx.advance()
  else:
    lx.fail(t.line, t.col, "unexpected character `" &
            (if ord(c) < 32 or ord(c) > 126: "\\x" & toHex(ord(c), 2) else: $c) & "`")
  lx.tok = t

proc describe(t: Token): string =
  case t.kind
  of tkEof: "end of file"
  of tkIdent: "`" & t.text & "`"
  of tkInt, tkFloat, tkColor: "`" & t.text & "`"
  of tkString: "a string"
  of tkPunct: "`" & t.text & "`"

# ------------------------------------------------------------------ parser

proc isPunct(t: Token, p: string): bool = t.kind == tkPunct and t.text == p
proc isKeyword(t: Token, k: string): bool = t.kind == tkIdent and t.text == k

proc parseValue(lx: var Lexer): NfmValue =
  let t = lx.tok
  result.line = t.line
  result.col = t.col
  case t.kind
  of tkInt:
    result.kind = nvInt
    result.text = t.text
    lx.next()
  of tkFloat:
    result.kind = nvFloat
    result.text = t.text
    lx.next()
  of tkString:
    result.kind = nvString
    result.text = t.text
    lx.next()
  of tkColor:
    result.kind = nvColor
    result.text = t.text
    lx.next()
  of tkIdent:
    if t.text == "end" or t.text == "object":
      lx.fail(t.line, t.col, "expected a value, got `" & t.text & "`")
    if '.' in t.text:
      lx.fail(t.line, t.col, "a value cannot contain `.` (got `" & t.text & "`)")
    if t.text == "true" or t.text == "false":
      result.kind = nvBool
    else:
      result.kind = nvIdent
    result.text = t.text
    lx.next()
  of tkPunct:
    if t.text == "[":
      result.kind = nvSet
      lx.next()
      if lx.tok.isPunct("]"):
        lx.next()
        return
      while true:
        if lx.tok.kind != tkIdent or '.' in lx.tok.text:
          lx.fail(lx.tok.line, lx.tok.col,
                  "expected a set element, got " & describe(lx.tok))
        result.items.add lx.tok.text
        lx.next()
        if lx.tok.isPunct(","):
          lx.next()
        elif lx.tok.isPunct("]"):
          lx.next()
          break
        else:
          lx.fail(lx.tok.line, lx.tok.col,
                  "expected `,` or `]` in a set, got " & describe(lx.tok))
    elif t.text == "(":
      result.kind = nvList
      lx.next()
      while not lx.tok.isPunct(")"):
        if lx.tok.kind != tkString:
          lx.fail(lx.tok.line, lx.tok.col,
                  "expected a string or `)` in a list, got " & describe(lx.tok))
        result.items.add lx.tok.text
        lx.next()
      lx.next()
    else:
      lx.fail(t.line, t.col, "expected a value, got " & describe(t))
  of tkEof:
    lx.fail(t.line, t.col, "expected a value, got end of file")

proc parseObject(lx: var Lexer): NfmNode =
  ## At the `object` keyword.
  result = NfmNode(line: lx.tok.line, col: lx.tok.col)
  lx.next()
  if lx.tok.kind == tkIdent and not lx.tok.isKeyword("end"):
    if '.' in lx.tok.text:
      lx.fail(lx.tok.line, lx.tok.col, "an object name cannot contain `.`")
    result.name = lx.tok.text
    lx.next()
  if not lx.tok.isPunct(":"):
    lx.fail(lx.tok.line, lx.tok.col,
            "expected `:` and a class name after the object name (`object name: Class`), got " &
            describe(lx.tok))
  lx.next()
  if lx.tok.kind != tkIdent or lx.tok.isKeyword("end") or lx.tok.isKeyword("object"):
    lx.fail(lx.tok.line, lx.tok.col, "expected a class name, got " & describe(lx.tok))
  if '.' in lx.tok.text:
    lx.fail(lx.tok.line, lx.tok.col, "a class name cannot contain `.`")
  result.className = lx.tok.text
  lx.next()
  while true:
    let t = lx.tok
    case t.kind
    of tkEof:
      lx.fail(t.line, t.col, "missing `end` for the object " &
              (if result.name.len > 0: "`" & result.name & "`" else: "of class `" & result.className & "`") &
              " opened at " & $result.line & ":" & $result.col)
    of tkIdent:
      if t.text == "end":
        lx.next()
        return
      elif t.text == "object":
        result.children.add parseObject(lx)
      else:
        var p = NfmProp(name: t.text, line: t.line, col: t.col)
        lx.next()
        if not lx.tok.isPunct("="):
          lx.fail(lx.tok.line, lx.tok.col,
                  "expected `=` after the property name `" & p.name & "`, got " &
                  describe(lx.tok))
        lx.next()
        p.value = parseValue(lx)
        result.props.add p
    else:
      lx.fail(t.line, t.col,
              "expected a property, `object` or `end`, got " & describe(t))

proc parseNfm*(text: string, fileName = ""): NfmNode =
  ## Parses a form file into its root object. Raises `NfmError` with the
  ## position of the problem (`file:line:col: message`).
  var lx = Lexer(src: text, line: 1, col: 1, fileName: fileName)
  lx.next()
  if not lx.tok.isKeyword("object"):
    lx.fail(lx.tok.line, lx.tok.col,
            "a form file starts with `object Name: Class`, got " & describe(lx.tok))
  result = parseObject(lx)
  if lx.tok.kind != tkEof:
    lx.fail(lx.tok.line, lx.tok.col,
            "unexpected " & describe(lx.tok) & " after the end of the root object")

# ------------------------------------------------------------------ writer

proc quoteNfm*(s: string): string =
  ## `s` as a single-quoted `.nfm` string.
  result = "'"
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '\'': result.add "\\'"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\0': result.add "\\0"
    of '\x01'..'\x08', '\x0b', '\x0c', '\x0e'..'\x1f', '\x7f':
      result.add "\\x" & toHex(ord(c), 2).toLowerAscii
    else: result.add c
  result.add '\''

proc writeProp(o: var string, p: NfmProp, indent: string) =
  o.add indent & p.name & " = "
  let v = p.value
  case v.kind
  of nvInt, nvFloat, nvBool, nvIdent, nvColor: o.add v.text
  of nvString: o.add quoteNfm(v.text)
  of nvSet: o.add "[" & v.items.join(", ") & "]"
  of nvList:
    if v.items.len == 0: o.add "()"
    else:
      o.add "(\n"
      for s in v.items: o.add indent & "  " & quoteNfm(s) & "\n"
      o.add indent & ")"
  o.add '\n'

proc writeNode(o: var string, n: NfmNode, indent: string) =
  o.add indent & "object" & (if n.name.len > 0: " " & n.name & ": " else: ": ") &
        n.className & "\n"
  for p in n.props: writeProp(o, p, indent & "  ")
  for c in n.children: writeNode(o, c, indent & "  ")
  o.add indent & "end\n"

proc writeNfm*(n: NfmNode): string =
  ## Canonical text of a tree: two spaces per level, properties before child
  ## objects, one property per line. `writeNfm(parseNfm(x)) == x` for a file
  ## already in that form.
  writeNode(result, n, "")

proc `$`*(n: NfmNode): string = writeNfm(n)

proc newNfmNode*(name, className: string): NfmNode =
  NfmNode(name: name, className: className)

proc add*(n: NfmNode, name: string, v: NfmValue) =
  n.props.add NfmProp(name: name, value: v)

func nfmInt*(i: int64): NfmValue = NfmValue(kind: nvInt, text: $i)
func nfmString*(s: string): NfmValue = NfmValue(kind: nvString, text: s)
func nfmIdent*(s: string): NfmValue = NfmValue(kind: nvIdent, text: s)
func nfmBool*(b: bool): NfmValue = NfmValue(kind: nvBool, text: (if b: "true" else: "false"))

iterator walk*(n: NfmNode): NfmNode =
  ## The node and all its descendants, parents first.
  var stack = @[n]
  while stack.len > 0:
    let x = stack.pop()
    yield x
    for i in countdown(x.children.high, 0): stack.add x.children[i]

# ============================================================ shared helpers

proc nimStr(s: string): string =
  ## `s` as a Nim string literal (UTF-8 stays as it is).
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\0'..'\x08', '\x0b', '\x0c', '\x0e'..'\x1f', '\x7f':
      result.add "\\x" & toHex(ord(c), 2)
    else: result.add c
  result.add '"'

proc isEventProp(name: string): bool =
  name.len > 2 and name.startsWith("on") and name[2] in {'A'..'Z'}

proc nimExpr(cls, prop: string, v: NfmValue,
             names: HashSet[string]): tuple[prop, expr: string] =
  ## The Nim expression for a property value, and the (possibly renamed)
  ## property it is assigned to. A few properties have a text form that is not
  ## their Nim type: `shortcut`, `columns`/`rows` of a `GridPanel`, `lines` of a
  ## `Memo`.
  result.prop = prop
  case v.kind
  of nvInt, nvFloat, nvBool: result.expr = v.text
  of nvString:
    if prop == "shortcut": result.expr = "shortcut(" & nimStr(v.text) & ")"
    elif cls == "GridPanel" and (prop == "columns" or prop == "rows"):
      result.expr = "parseGridSizes(" & nimStr(v.text) & ")"
    else: result.expr = nimStr(v.text)
  of nvIdent:
    result.expr = if v.text in names: "self." & v.text else: v.text
  of nvColor: result.expr = "hex(" & nimStr(v.text) & ")"
  of nvSet: result.expr = "{" & v.items.join(", ") & "}"
  of nvList:
    if cls == "Memo" and prop == "lines":
      result.prop = "text"
      result.expr = nimStr(v.items.join("\n"))
    else:
      var parts: seq[string]
      for s in v.items: parts.add nimStr(s)
      result.expr = "@[" & parts.join(", ") & "]"

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
  of pkImage, pkFont, pkSpacing, pkConstraints:
    raise newException(PropError, "property `" & info.name & "` has no text form")

type
  NfmOptions* = ref object
    ## How `loadNfm` treats problems and handlers.
    strict*: bool                 ## true: unknown classes/properties/handlers raise `NfmError`; false: they are skipped and listed in `warnings`
    handlers*: HandlerResolver    ## binds `onXxx = name` to code; nil: names are only recorded
    warnings*: seq[string]        ## problems found while `strict` is false

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

proc convertValue(info: PropInfo, v: NfmValue, file: string,
                  byName: Table[string, Obj]): PropValue =
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
  of pkImage: bad("`" & info.name & "` cannot be set from a form file")
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
                byName: Table[string, Obj]) =
  for p in b.node.props:
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
        info.set(b.obj, convertValue(info, p.value, file, byName))
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
  for b in built: applyProps(b, fileName, opt, byName)
  built[0].obj

proc loadNfm*(text: string, owner: Component = nil, options: NfmOptions = nil,
              fileName = ""): Form =
  ## Parses `text` and builds the form it describes. The root object must be a
  ## `Form` (or a registered subclass). Raises `NfmError` with `file:line:col`.
  let root = parseNfm(text, fileName)
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

proc nodeOf(o: Obj, nameOverride = ""): NfmNode =
  let ci = classOf(o)
  if ci == nil: return nil
  result = NfmNode(className: ci.name,
                   name: if nameOverride.len > 0: nameOverride else: objectName(o))
  var ordered: seq[PropInfo]
  for p in ci.propsOf:
    if p.kind != pkEvent: ordered.add p
  for p in ci.propsOf:
    if p.kind == pkEvent: ordered.add p
  for p in ordered:
    if p.name == "name" or not p.stored: continue
    case p.kind
    of pkImage: continue
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
    let n = nodeOf(k)
    if n != nil: result.children.add n

proc objectToNfmNode*(o: Obj, rootName = ""): NfmNode =
  ## The syntax tree of an object and its children: only properties that
  ## differ from a fresh instance, in registry order. Events appear when a
  ## handler name was recorded for them (by `loadNfm` or `setProp`).
  nodeOf(o, rootName)

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
        let (pn, e) = nimExpr(n.className, p.name, p.value, names)
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

# ======================================================= loadForm: compile time

# Construction of objects that are not `newT(parent: Container)` controls:
# `loadForm` tries `nfmMake(T, parent)` first.

proc nfmMake*(T: typedesc[MenuItem], parent: MenuItem): MenuItem =
  result = newMenuItem(owner = parent)
  parent.add result

proc nfmMake*(T: typedesc[MenuItem], parent: MainMenu): MenuItem =
  result = newMenuItem(owner = parent)
  parent.add result

proc nfmMake*(T: typedesc[MenuItem], parent: PopupMenu): MenuItem =
  result = newMenuItem(owner = parent)
  parent.add result

proc nfmMake*(T: typedesc[StatusPanel], parent: StatusBar): StatusPanel =
  parent.addPanel()

proc nfmMake*(T: typedesc[ListColumn], parent: ListView): ListColumn =
  parent.columns.add()

proc nfmMake*(T: typedesc[Action], parent: ActionList): Action =
  newAction(parent)

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
  setHandlerName(Obj(c), event, handler)

proc setLineInfoRec(n, src: NimNode) =
  n.copyLineInfo(src)
  for c in n: setLineInfoRec(c, src)

proc nfmPos(file: string, line, col: int): string =
  file & ":" & $line & ":" & $col

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
  if not fileExists(nfmPath):
    error("loadForm: cannot read `" & nfmPath & "` (the path is relative to the calling module)", site)
  let text = readFile(nfmPath)
  var root: NfmNode
  try: root = parseNfm(text, path)
  except NfmError as e: error("loadForm: " & e.msg, site)
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
        assigns.add "when compiles(" & access & "):\n  when compiles((" & access & " = " & e &
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
