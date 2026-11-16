## `.nfm` form files: parser, writer, run-time loader, `loadForm`, converters.

import std/[unittest, strutils, tables, os, osproc]
import nimvcl
import nimvcl/dsl/nfm

const
  here = currentSourcePath().parentDir
  root = here.parentDir

# --------------------------------------------------------------- loadForm

loadForm Sample, "nfm/sample.nfm"

var clicks, exits: int
proc okClick(self: Sample, sender: Control) = inc clicks
proc exitClick(self: Sample, sender: MenuItem) = inc exits

# --------------------------------------------------- the `form` equivalent

form Equiv:
  name = "Equiv"
  width = 300; height = 200
  caption = "Eq"
  Label hello:
    left = 10; top = 5
    caption = "It's"
    focusControl = self.name1
  Edit name1:
    left = 10; top = 30
    anchors = {akLeft, akTop, akRight}
  Button go:
    left = 10; top = 60
    caption = "Go"
    isDefault = true
    onClick: inc clicks

const equivNfm = """object Equiv: Form
  width = 300
  height = 200
  caption = 'Eq'
  object hello: Label
    left = 10
    top = 5
    caption = 'It\'s'
    focusControl = name1
  end
  object name1: Edit
    left = 10
    top = 30
    anchors = [akLeft, akTop, akRight]
  end
  object go: Button
    left = 10
    top = 60
    caption = 'Go'
    isDefault = true
  end
end
"""

proc fails(src: string, line, col: int, msg: string, fileName = "t.nfm") =
  try:
    discard parseNfm(src, fileName)
    checkpoint "expected an NfmError for: " & src
    fail()
  except NfmError as e:
    check e.line == line
    check e.col == col
    check msg in e.msg
    check e.msg.startsWith(fileName & ":" & $line & ":" & $col & ": ")

suite "parser and writer":
  test "round trip of canonical files":
    const files = [
      "object A: Form\nend\n",
      "object A: Form\n  caption = 'x'\n  width = 12\n  left = -3\n  top = 0.5\n  visible = false\nend\n",
      "object A: Form\n  anchors = [akLeft, akTop]\n  font.size = 14\n  font.style = []\n  color = #336699\n  hint = ()\nend\n",
      "object A: Panel\n  object b: Button\n    caption = 'It\\'s \\\\ \\n \\t \\x01 \\0 end'\n  end\n  object: Label\n  end\nend\n",
      "object A: Form\n  items = (\n    'a'\n    'it\\'s'\n  )\n  onClick = go\nend\n"]
    for f in files:
      check writeNfm(parseNfm(f)) == f
    check writeNfm(parseNfm(readFile(here / "nfm" / "sample.nfm"))) ==
          readFile(here / "nfm" / "sample.nfm")

  test "structure":
    let n = parseNfm(readFile(here / "nfm" / "sample.nfm"), "sample.nfm")
    check n.name == "Sample"
    check n.className == "Form"
    check n.props.len == 3
    check n.props[2].name == "caption"
    check n.props[2].value.kind == nvString and n.props[2].value.text == "Sign in"
    check n.children.len == 7
    let bar = n.children[0]
    check bar.className == "MainMenu"
    check bar.children[0].children[0].name == ""
    check bar.children[0].children[0].props[1].value.text == "Ctrl+Q"
    let ok = n.children[3]
    check ok.props[0].name == "left" and ok.props[0].line == 29
    check ok.props[1].value.kind == nvInt
    check ok.props[3].name == "font.style" and ok.props[3].value.items == @["fsBold"]
    check ok.props[4].value.kind == nvColor
    check ok.props[6].value.kind == nvBool
    check n.children[4].props[2].value.items == @["Viewer", "Editor"]
    check n.children[0].line == 5 and n.children[0].col == 3

  test "comments and layout freedom":
    let n = parseNfm("// header\nobject A: Form   // root\n  caption='x'  width=3\n  object b:Button end\nend")
    check n.props.len == 2 and n.children.len == 1
    check writeNfm(n) == "object A: Form\n  caption = 'x'\n  width = 3\n  object b: Button\n  end\nend\n"

  test "syntax errors carry line:col":
    fails("", 1, 1, "starts with `object Name: Class`")
    fails("form A: Form end", 1, 1, "starts with `object")
    fails("object A: Form\n  caption = 'x'\n", 3, 1, "missing `end` for the object `A` opened at 1:1")
    fails("object A Form\nend", 1, 10, "expected `:` and a class name")
    fails("object A:\nend", 2, 1, "expected a class name")
    fails("object A: Form\n  caption 'x'\nend", 2, 11, "expected `=` after the property name `caption`")
    fails("object A: Form\n  caption = 'abc\nend", 2, 13, "unterminated string")
    fails("object A: Form\n  caption = 'a\\qb'\nend", 2, 15, "unknown escape \\q")
    fails("object A: Form\n  caption = 'a\\xZZ'\nend", 2, 15, "bad escape \\x")
    fails("object A: Form\n  color = #12\nend", 2, 11, "bad colour `#12`")
    fails("object A: Form\n  color = @\nend", 2, 11, "unexpected character `@`")
    fails("object A: Form\n  width = \nend", 3, 1, "expected a value, got `end`") # `end` is read as an identifier value
    fails("object A: Form\n  anchors = [akLeft akTop]\nend", 2, 21, "expected `,` or `]`")
    fails("object A: Form\n  items = ('a', 'b')\nend", 2, 15, "expected a string or `)`")
    fails("object A: Form\nend\nobject B: Form\nend", 3, 1, "after the end of the root object")
    fails("object A: Form\n  a.b = x.y\nend", 2, 9, "a value cannot contain `.`")
    fails("object a.b: Form\nend", 1, 8, "an object name cannot contain `.`", "x.nfm")

suite "run-time loading":
  test "builds the tree of the form macro equivalent":
    let a = loadNfm(equivNfm)
    let b = newEquiv()
    check formToNfm(a) == formToNfm(b)
    check formToNfm(b) == equivNfm
    check a.findComponent("go") != nil
    check Button(a.findComponent("go")).isDefault
    check Label(a.findComponent("hello")).focusControl == Control(a.findComponent("name1"))
    check a.name == "Equiv"

  test "formToNfm(loadNfm(x)) == x":
    let x = readFile(here / "nfm" / "sample.nfm")
    let f = loadNfm(x)
    check formToNfm(f) == x
    check f.caption == "Sign in"
    let ok = Button(f.findComponent("okButton"))
    check ok.font.size == 18
    check ok.font.style == {fsBold}
    check ok.color == hex"#336699"
    check ok.isDefault
    check ComboBox(f.findComponent("roleCombo")).itemIndex == 1
    let lv = ListView(f.findComponent("table"))
    check lv.columns.len == 2
    check lv.columns[1].alignment == taRight
    check StatusBar(f.findComponent("status")).panels[0].text == "Ready"
    let m = MainMenu(f.findComponent("mainMenu"))
    check m.items[0].caption == "&File"
    check m.items[0][0].shortcut == shortcut("Ctrl+Q")
    check f.menuBar == Control(m)

  test "handlers are bound by name":
    var got: seq[string]
    var table: Table[string, NotifyEvent]
    table["okClick"] = proc(s: Control) = got.add "ok"
    let src = "object A: Form\n  object b: Button\n    onClick = okClick\n  end\nend\n"
    let f = loadNfm(src, table)
    let b = Button(f.findComponent("b"))
    b.onClick(b)
    check got == @["ok"]
    check formToNfm(f) == src                      # the name is remembered
    try:
      discard loadNfm(src.replace("okClick", "nope"), table)
      fail()
    except NfmError as e:
      check "no handler `nope`" in e.msg
      check e.line == 3 and e.col == 15
    # without a resolver the names are only recorded
    let g = loadNfm(src)
    check Button(g.findComponent("b")).onClick == nil
    check formToNfm(g) == src

  test "problems are reported with positions, or collected when not strict":
    template loadFails(src: string, ln, cl: int, expected: string) =
      try:
        discard loadNfm(src, fileName = "t.nfm")
        fail()
      except NfmError as e:
        check e.line == ln
        check e.col == cl
        check expected in e.msg
    loadFails("object A: Form\n  object b: Buttn\n  end\nend", 2, 3, "unknown class `Buttn`")
    loadFails("object A: Form\n  object b: Button\n    captoin = 'x'\n  end\nend", 3, 5,
              "class `Button` has no property `captoin`")
    loadFails("object A: Form\n  object b: Button\n    align = alMiddle\n  end\nend", 3, 13,
              "`alMiddle` is not a value of Align")
    loadFails("object A: Form\n  object b: Button\n    align = alMiddle\n  end\nend", 3, 13, "alClient")
    loadFails("object A: Form\n  object b: Button\n    width = 'wide'\n  end\nend", 3, 13,
              "`width` expects a number")
    loadFails("object A: Form\n  object b: Button\n    anchors = [akSide]\n  end\nend", 3, 15,
              "`akSide` is not an element of Anchors")
    loadFails("object A: Form\n  object b: Label\n    focusControl = ghost\n  end\nend", 3, 20,
              "`ghost` (value of `focusControl`) is not an object")
    loadFails("object A: Form\n  object b: Button\n  end\n  object b: Button\n  end\nend", 4, 3,
              "duplicate object name `b`")
    loadFails("object A: Button\nend", 1, 1, "not a Form")
    loadFails("object A: Form\n  object b: Button\n    font = 3\n  end\nend", 3, 12,
              "is set through its parts")
    let opts = newNfmOptions(strict = false)
    let f = loadNfm("object A: Form\n  bogus = 1\n  object b: Buttn\n    caption = 'x'\n  end\n  object c: Button\n    caption = 'y'\n  end\nend", options = opts)
    check opts.warnings.len == 2
    check "unknown class `Buttn`" in opts.warnings[0]
    check "has no property `bogus`" in opts.warnings[1]
    check f.findComponent("b") == nil
    check Button(f.findComponent("c")).caption == "y"

  test "sub-properties, escapes and all value kinds survive a round trip":
    let src = "object A: Form\n  object p: Panel\n    margins.left = 4\n    margins.bottom = 2.5\n" &
              "    constraints.minWidth = 50\n    font.family = 'mono'\n    caption = 'a\\n\\tb \\'q\\' \\\\'\n" &
              "    color = #11223344\n    align = alTop\n    anchors = []\n  end\nend\n"
    let f = loadNfm(src)
    let p = Panel(f.findComponent("p"))
    check p.margins == spacing(4, 0, 0, 2.5)
    check p.caption == "a\n\tb 'q' \\"
    check p.color == rgba(0x11, 0x22, 0x33, 0x44)
    check p.anchors == {}
    check p.font.family == "mono"
    let again = formToNfm(f)
    check again.contains("anchors = []")
    check formToNfm(loadNfm(again)) == again

suite "loadForm (compile time)":
  test "a typed form with a field per named object":
    let f = newSample()
    check f of Form
    check f.name == "Sample"
    check f.userEdit.placeholder == "you@example.com"
    check f.userEdit.anchors == {akLeft, akTop, akRight}
    check f.okButton.font.size == 18
    check f.okButton.font.style == {fsBold}
    check f.okButton.color == hex"#336699"
    check f.userLabel.focusControl == Control(f.userEdit)
    check f.roleCombo.itemIndex == 1
    check f.table.columns.len == 2
    check f.status.panels.len == 1
    check f.fileMenu.count == 1
    check f.fileMenu[0].shortcut == shortcut("Ctrl+Q")
    check f.width == 420 and f.height == 300
    check f.okButton.name == "okButton"
    check f.userEdit.parent == Container(f)

  test "handlers named in the file are bound (event types are respected)":
    let f = newSample()
    clicks = 0
    exits = 0
    f.okButton.onClick(f.okButton)
    f.fileMenu[0].onClick(f.fileMenu[0])
    check clicks == 1
    check exits == 1

  test "the same tree as the run-time loader":
    let x = readFile(here / "nfm" / "sample.nfm")
    check formToNfm(newSample()) == x
    check formToNfm(newSample()) == formToNfm(loadNfm(x))

suite "converters":
  test "nfmToFormMacro":
    let src = "object Login: Form\n  caption = 'Sign in'\n  width = 420\n  object user: Edit\n" &
              "    anchors = [akLeft, akRight]\n    color = #336699\n    font.size = 16\n    font.style = [fsBold]\n  end\n" &
              "  object ok: Button\n    caption = 'It\\'s'\n    onClick = okClick\n  end\n" &
              "  object lbl: Label\n    focusControl = user\n  end\nend\n"
    let m = nfmToFormMacro(src)
    check m == "form Login:\n  name = \"Login\"\n  caption = \"Sign in\"\n  width = 420\n" &
               "  Edit user:\n    anchors = {akLeft, akRight}\n    color = hex(\"#336699\")\n" &
               "    font.size = 16\n    font.style = {fsBold}\n" &
               "  Button ok:\n    caption = \"It's\"\n    onClick: okClick(self, sender)\n" &
               "  Label lbl:\n    focusControl = self.user\n" &
               "  proc okClick(self: Login, sender: Control) = discard\n"

  test "the generated source compiles and builds the same form":
    let src = "object Conv: Form\n  width = 300\n  caption = 'Hi'\n  object user: Edit\n" &
              "    left = 8\n    anchors = [akLeft, akRight]\n    font.size = 16\n  end\n" &
              "  object ok: Button\n    caption = 'OK'\n    onClick = okClick\n  end\nend\n"
    let prog = "import std/strutils\nimport nimvcl\nimport nimvcl/dsl/nfm\n\n" & nfmToFormMacro(src) &
               "\nconst src = " & escape(src) & "\n" &
               "let f = newConv()\n" &
               "doAssert f.user.font.size == 16\n" &
               "doAssert f.ok.onClick != nil\n" &
               "doAssert formToNfm(f).replace(\"    onClick = okClick\\n\", \"\") == src.replace(\"    onClick = okClick\\n\", \"\")\n"
    let dir = root / "build" / ("nfmconv_" & $getCurrentProcessId())
    createDir dir
    writeFile(dir / "conv.nim", prog)
    let (output, code) = execCmdEx("nim c --hints:off --warnings:off --path:" & quoteShell(root / "src") &
      " --nimcache:" & quoteShell(dir / "cache") & " -o:" & quoteShell(dir / "conv") &
      " -r " & quoteShell(dir / "conv.nim"))
    if code != 0: echo output
    check code == 0
    removeDir dir
