## The `.nfm` text form format: syntax tree, lexer, parser, writer and the
## compile-time helpers shared by `loadForm` (`formload.nim`) and the converters
## in `nfm.nim`. No dependency beyond `std`, so it also runs inside macros and
## costs a program that only uses `loadForm` almost nothing to compile.
## See docs/guide/form-files.md for the format.

import std/[strutils, sets]


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
    inherited*: bool      ## `inherited Name: Class`: the object exists in the ancestor form; `props` holds only what differs from it
    ancestor*: string     ## root of an inherited form only: the ancestor's `.nfm` file, relative to this one (`ancestor = 'unit1.nfm'`)

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

proc validNfmName*(s: string): bool =
  ## True when `s` can be written as an object or handler name in a form file:
  ## letters, digits and `_`, not starting with a digit, and not one of the
  ## words the format reserves (`end`, `object`, `inherited`, `true`, `false`).
  if s.len == 0 or not isIdentStart(s[0]): return false
  for c in s:
    if not isIdentChar(c): return false
  s notin ["end", "object", "inherited", "true", "false"]

const reservedNames = [
  # Component / Control / Container / Form fields, properties and public procs:
  # a form field of the same name would clash with (or shadow) them. Kept in
  # step with the property registry by a test (tnfm).
  "acceptsInput", "actionLink", "activateMnemonic", "activeControl",
  "addKeyHandler", "afterLayout", "align", "altChanged", "anchors",
  "arrangeChildren", "autoSize", "beforeLayout", "beginModalState",
  "borderStyle", "boundsRect", "bringToFront", "canFocus", "caption",
  "captureLost", "childBoundsChanged", "children", "clientClicked",
  "clientRect", "clientToForm", "clientToParent", "close", "color",
  "componentCount", "components", "constraints", "constraintsChanged",
  "controlAtPoint", "controlCount", "controlLost", "controls", "cursor",
  "cursorChanged", "customAlign", "designBase", "designBaseSet",
  "designRect", "doClick", "doDblClick", "doEnter", "doExit", "doKeyDown",
  "doKeyPress", "doKeyUp", "doMouseDown", "doMouseEnter", "doMouseLeave",
  "doMouseMove", "doMouseUp", "doMouseWheel", "doResize", "doTextEditing",
  "enabled", "endModalState", "findComponent", "focusTarget", "font",
  "fontColor", "forcedScale", "formOrigin", "formStyle", "formToClient",
  "free", "freeWindow", "hasWindow", "height", "hide", "hint", "hitTest",
  "host", "icon", "images", "inheritedColor", "insertComponent",
  "insertControl", "invalidate", "invalidateRect", "isAncestorOf",
  "isEnabled", "isMaximized", "isMinimized", "isModal", "isShowing",
  "isTabStop", "isVisible", "keyPreview", "left", "margins",
  "maximize", "menu", "menuBar", "minimize", "modalOwner", "modalResult",
  "name", "notifyCreated", "notifyVisibility", "onActivate", "onClick",
  "onClose", "onCloseQuery", "onCreate", "onDblClick", "onDeactivate",
  "onEnter", "onExit", "onHide", "onMouseDown", "onMouseEnter",
  "onMouseLeave", "onMouseMove", "onMouseUp", "onResize", "onShow", "owner",
  "padding", "paint", "paintIfDirty", "paintTree", "parent", "parentColor",
  "parentFont", "parentToClient", "popupMenus", "position", "preferredSize",
  "rectInAncestor", "relayout", "relayoutAll", "release", "releaseResources",
  "removeComponent", "removeControl", "removeKeyHandler", "requestLayout",
  "resetModalState", "restore", "revealControl", "root", "screenshot",
  "scrollChanged", "scrollOffset", "sendToBack", "setBounds",
  "setForcedScale", "setHostSize", "setScrollOffset", "show", "showModal",
  "style", "syncMetrics", "tabOrder", "tabStop", "tag", "text",
  "textInputRect", "theme", "top", "ui", "viewportRect", "visibilityChanged",
  "visible", "visualRect", "wantsTextInput", "width", "win",
  "windowActivated", "windowState",
  "popupMenu", "action", "onMouseWheel", "onKeyDown", "onKeyUp", "onKeyPress",
  "onPaint"]

const hardReservedNames = [
  # The names the `form`/`loadForm` macros have always refused: a child of the
  # same name breaks the generated code. The rest of `reservedNames` only
  # shadows a member, which compiled before, so the macros warn about those
  # (old forms keep building) while the designer does not hand them out.
  "name", "tag", "owner", "components", "actionLink", "caption", "parent",
  "left", "top", "width", "height", "align", "anchors", "margins", "padding",
  "constraints", "autoSize", "visible", "enabled", "hint", "cursor", "font",
  "parentFont", "color", "parentColor", "tabStop", "tabOrder", "children",
  "host", "ui", "win", "menuBar", "popupMenus", "position", "borderStyle",
  "formStyle", "modalResult", "designRect", "designBase", "designBaseSet",
  "onClick", "onDblClick", "onMouseEnter", "onMouseLeave", "onEnter", "onExit",
  "onResize", "onMouseDown", "onMouseUp", "onMouseMove", "onShow", "onHide",
  "onActivate", "onDeactivate", "onClose", "onCloseQuery", "onCreate",
  "windowState"]

proc sameName(r, s: string): bool =
  s.len > 0 and r[0] == s[0] and cmpIgnoreStyle(r, s) == 0

proc isHardReservedName*(s: string): bool =
  ## True for the names the `form`/`loadForm` macros refuse outright (a child
  ## of that name breaks the generated code); see `isReservedFieldName`.
  for r in hardReservedNames:
    if sameName(r, s): return true

proc isReservedFieldName*(s: string): bool =
  ## True when a child or variable called `s` would clash with a field,
  ## property or public proc of Component/Control/Form (`icon`, `menu`, `text`,
  ## `show`, `close`...; compared like Nim identifiers). The designer does not
  ## hand them out; the `form`/`loadForm` macros refuse `isHardReservedName`
  ## names and warn about the others (the form's own name is exempt).
  if isHardReservedName(s): return true
  for r in reservedNames:
    if sameName(r, s): return true

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
    if t.text == "end" or t.text == "object" or t.text == "inherited":
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

proc parseObject(lx: var Lexer, inheritedTree: bool): NfmNode =
  ## At the `object` (or, in an inherited form, `inherited`) keyword.
  result = NfmNode(line: lx.tok.line, col: lx.tok.col,
                   inherited: lx.tok.isKeyword("inherited"))
  let kw = lx.tok.text
  lx.next()
  if lx.tok.kind == tkIdent and not lx.tok.isKeyword("end"):
    if '.' in lx.tok.text:
      lx.fail(lx.tok.line, lx.tok.col, "an object name cannot contain `.`")
    result.name = lx.tok.text
    lx.next()
  if result.inherited and result.name.len == 0:
    lx.fail(result.line, result.col, "an `inherited` object needs a name (`inherited name: Class`)")
  if not lx.tok.isPunct(":"):
    lx.fail(lx.tok.line, lx.tok.col,
            "expected `:` and a class name after the object name (`" & kw & " name: Class`), got " &
            describe(lx.tok))
  lx.next()
  if lx.tok.kind != tkIdent or lx.tok.isKeyword("end") or lx.tok.isKeyword("object") or
     lx.tok.isKeyword("inherited"):
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
        result.children.add parseObject(lx, inheritedTree)
      elif t.text == "inherited":
        if not inheritedTree:
          lx.fail(t.line, t.col, "`inherited` is only allowed in a form that starts " &
                  "with `inherited Name: Class` (an inherited form)")
        result.children.add parseObject(lx, inheritedTree)
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
  if text.len >= 3 and text[0] == '\xEF' and text[1] == '\xBB' and text[2] == '\xBF':
    lx.pos = 3                      # a UTF-8 byte order mark
  lx.next()
  if not lx.tok.isKeyword("object") and not lx.tok.isKeyword("inherited"):
    lx.fail(lx.tok.line, lx.tok.col,
            "a form file starts with `object Name: Class` (or `inherited Name: Class`), got " &
            describe(lx.tok))
  let inh = lx.tok.isKeyword("inherited")
  result = parseObject(lx, inh)
  if inh:
    var found = false
    for i, p in result.props:
      if p.name == "ancestor":
        if p.value.kind != nvString or p.value.text.len == 0:
          lx.fail(p.value.line, p.value.col, "`ancestor` expects the path of the ancestor " &
                  "form file, like 'unit1.nfm'")
        # stored with '/'; a form file written on Windows may say '\\'
        result.ancestor = p.value.text.replace('\\', '/')
        result.props.delete(i)
        found = true
        break
    if not found:
      lx.fail(result.line, result.col, "an inherited form needs `ancestor = 'file.nfm'` " &
              "(the form file it inherits from, relative to this one)")
  if lx.tok.kind != tkEof:
    lx.fail(lx.tok.line, lx.tok.col,
            "unexpected " & describe(lx.tok) & " after the end of the root object")

proc legacyNames(n: NfmNode) =
  ## Older files wrote the text colour of a label or panel as `textColor`; it
  ## is now `font.color` (an explicit `font.color` in the same object wins).
  var hasFontColor = false
  for p in n.props:
    if p.name == "font.color": hasFontColor = true
  var i = 0
  while i < n.props.len:
    if n.props[i].name == "textColor":
      if hasFontColor:
        n.props.delete i
        continue
      n.props[i].name = "font.color"
    inc i
  for c in n.children: legacyNames(c)

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
  o.add indent & (if n.inherited: "inherited" else: "object") &
        (if n.name.len > 0: " " & n.name & ": " else: ": ") & n.className & "\n"
  if n.ancestor.len > 0:
    writeProp(o, NfmProp(name: "ancestor", value: NfmValue(kind: nvString, text: n.ancestor)), indent & "  ")
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

func formatNumber*(f: float): string =
  ## A number as short text: a whole `float32` value without the fraction.
  let f32 = float32(f)
  if abs(f32) < 1e9 and f32 == float32(int64(f32)): $int64(f32) else: $f32

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
  ## `Memo`, the item lists of the views and grids (`items`, `cells`,
  ## `colWidths`, `rowHeights`).
  result.prop = prop
  case v.kind
  of nvInt, nvFloat, nvBool: result.expr = v.text
  of nvString:
    if prop == "shortcut": result.expr = "shortcut(" & nimStr(v.text) & ")"
    elif cls == "GridPanel" and (prop == "columns" or prop == "rows"):
      result.expr = "parseGridSizes(" & nimStr(v.text) & ")"
    elif cls in ["DrawGrid", "StringGrid"] and (prop == "colWidths" or prop == "rowHeights"):
      # not the Nim `colWidths` (an indexable view): the text accessors
      result.prop = prop & "Text"
      result.expr = nimStr(v.text)
    else: result.expr = nimStr(v.text)
  of nvIdent:
    result.expr = if v.text in names: "self." & v.text else: v.text
  of nvColor: result.expr = "hex(" & nimStr(v.text) & ")"
  of nvSet: result.expr = "{" & v.items.join(", ") & "}"
  of nvList:
    if cls == "Memo" and prop == "lines":
      result.prop = "text"
      result.expr = nimStr(v.items.join("\n"))
    elif cls == "StringGrid" and prop == "cells":
      result.prop = "cellLines"
      var parts: seq[string]
      for s in v.items: parts.add nimStr(s)
      result.expr = "@[" & parts.join(", ") & "]"
    elif (cls == "ListView" or cls == "TreeView") and prop == "items":
      # not the Nim `items` (an object): the outline/row text accessors
      result.prop = if cls == "ListView": "itemLines" else: "nodeLines"
      var parts: seq[string]
      for s in v.items: parts.add nimStr(s)
      result.expr = "@[" & parts.join(", ") & "]"
    else:
      var parts: seq[string]
      for s in v.items: parts.add nimStr(s)
      result.expr = "@[" & parts.join(", ") & "]"
