## Visual form inheritance: `inherited` blocks in `.nfm` files, `loadForm` of a
## descendant form, run-time `loadNfm` of one, and `formToNfm` writing only the
## differences from the ancestor.

import std/[unittest, strutils, tables, os]
import nimvcl
import nimvcl/dsl/nfm
import nimvcl/controls/inspector

const dir = currentSourcePath().parentDir / "nfm" / "inherit"

# ------------------------------------------------------------ loadForm

loadForm Base, "nfm/inherit/base.nfm"
loadForm Derived, "nfm/inherit/derived.nfm"
loadForm Grand, "nfm/inherit/grand.nfm"
loadForm Over, "nfm/inherit/over.nfm"

var log: seq[string]
proc okClick(self: Base, sender: Control) = log.add "base.ok"
proc okClick(self: Derived, sender: Control) = log.add "derived.ok"
proc extraClick(self: Derived, sender: Control) = log.add "extra"
# the descendant's own okClick; over.nfm does not mention it
proc okClick(self: Over, sender: Control) =
  log.add "over.ok"
  okClick(Base(self), sender)             # the ancestor's version

proc named(c: Component, name: string): Component =
  ## A component of the form tree by name (anywhere below `c`).
  if c.name == name: return c
  for x in c.components:
    let r = named(x, name)
    if r != nil: return r
  if c of Container:
    for k in Container(c).children:
      let r = named(k, name)
      if r != nil: return r

# ---------------------------------------------------------------- syntax

const sample = """inherited F2: F2
  ancestor = 'f1.nfm'
  caption = 'x'
  inherited b: Button
    left = 3
  end
  object c: Label
  end
end
"""

suite "inherited syntax":
  test "parse and write round trip":
    let n = parseNfm(sample)
    check n.inherited
    check n.ancestor == "f1.nfm"
    check n.props.len == 1
    check n.children[0].inherited
    check not n.children[1].inherited
    check writeNfm(n) == sample

  test "errors":
    expect NfmError: discard parseNfm("inherited F: F\nend\n")             # no ancestor
    expect NfmError: discard parseNfm("object F: Form\n  inherited b: Button\n  end\nend\n")
    expect NfmError: discard parseNfm("inherited F: F\n  ancestor = 'a.nfm'\n  inherited : Button\n  end\nend\n")
    expect NfmError: discard parseNfm("inherited F: F\n  ancestor = 3\nend\n")

suite "loadForm with an inherited form":
  test "type and fields come from the ancestor":
    let f = newDerived()
    check f of Base
    check f.name == "Derived"
    check f.okButton.caption == "Fine"          # overridden
    check f.panel1.width == 300                 # overridden
    check f.panel1.height == 100                # from the ancestor
    check f.nameEdit.text == "base"
    check f.caption == "Derived form"
    check f.width == 400                        # ancestor's
    check f.extraButton.caption == "Extra"      # added
    check f.extraButton.parent == Container(f.panel1)
    check f.extraLabel.caption == "Added"

  test "handlers: overridden and new":
    let f = newDerived()
    log.setLen 0
    f.okButton.onClick(f.okButton)
    f.extraButton.onClick(f.extraButton)
    check log == @["derived.ok", "extra"]
    let b = newBase()
    b.okButton.onClick(b.okButton)
    check log[^1] == "base.ok"

  test "a descendant's proc of the same name replaces the ancestor's binding":
    let f = newOver()
    log.setLen 0
    f.okButton.onClick(f.okButton)
    check log == @["over.ok", "base.ok"]
    check f.okButton.handlerNames == @[("onClick", "okClick")]
    # the ancestor itself is not affected, nor a grandchild that defines nothing
    log.setLen 0
    newBase().okButton.onClick(newBase().okButton)
    check log == @["base.ok"]
    log.setLen 0
    let g = newGrand()
    g.okButton.onClick(g.okButton)
    check log == @["derived.ok"]

  test "three levels":
    let g = newGrand()
    check g of Derived
    check g of Base
    check g.nameEdit.text == "grand"
    check g.height == 350
    check g.extraLabel.caption == "Added"
    check g.okButton.caption == "Fine"

suite "run-time loadNfm of an inherited form":
  proc rtOk(s: Control) = log.add "rt.ok"
  proc rtExtra(s: Control) = log.add "rt.extra"
  let handlers = {"okClick": NotifyEvent(rtOk), "extraClick": NotifyEvent(rtExtra)}.toTable
  test "ancestor first, then the differences":
    let f = loadNfmFile(dir / "derived.nfm", nil,
                        newNfmOptions(true, notifyHandlers(handlers)))
    check f.name == "Derived"
    check f.caption == "Derived form"
    check f.width == 400
    let ok = Button(f.named("okButton"))
    check ok.caption == "Fine"
    check ok.inherited
    check f.inherited                                  # the form comes from the ancestor
    check f.ancestorFile == "base.nfm"
    let extra = Button(f.named("extraButton"))
    check extra != nil and not extra.inherited
    check Label(f.named("extraLabel")) != nil
    check not Label(f.named("extraLabel")).inherited
    log.setLen 0
    ok.onClick(ok)
    check log == @["rt.ok"]

  test "overrideHandlers: the descendant's version of a handler of the same name":
    let o = newNfmOptions(true, notifyHandlers(handlers))
    o.overrideHandlers = notifyHandlers({"okClick": NotifyEvent(rtExtra)}.toTable)
    let f = loadNfmFile(dir / "over.nfm", nil, o)
    let ok = Button(f.named("okButton"))
    log.setLen 0
    ok.onClick(ok)
    check log == @["rt.extra"]
    check ok.handlerNames == @[("onClick", "okClick")]

  test "a descendant of a descendant":
    let f = loadNfmFile(dir / "grand.nfm")
    check Edit(f.named("nameEdit")).text == "grand"
    check f.height == 350
    check f.ancestorFile == "derived.nfm"

  test "errors name the file and position":
    expect NfmError:
      discard loadNfm("inherited F: F\n  ancestor = 'nothere.nfm'\nend\n", nil, nil, dir / "x.nfm")
    expect NfmError:
      discard loadNfm("inherited F: F\n  ancestor = 'base.nfm'\n  inherited ghost: Button\n  end\nend\n",
                      nil, nil, dir / "x.nfm")

suite "formToNfm of an inherited form":
  test "writes only the differences, byte-identical":
    for name in ["derived.nfm", "grand.nfm"]:
      let text = readFile(dir / name)
      let f = loadNfmFile(dir / name)
      check formToNfm(f) == text

  test "edits show up as inherited blocks":
    let f = loadNfmFile(dir / "derived.nfm")
    Edit(f.named("nameEdit")).text = "changed"
    Button(f.named("okButton")).caption = "OK"      # back to the ancestor's value
    f.height = 123
    let out1 = formToNfm(f)
    check "  inherited nameEdit: Edit\n    text = 'changed'\n  end\n" in out1
    check "height = 123" in out1
    check "caption = 'OK'" notin out1       # back to the ancestor's value: nothing to write
    check "inherited okButton: Button\n      onClick = okClick\n" in out1   # the re-bound handler stays
    # unchanged inherited objects are not written
    let f2 = loadNfmFile(dir / "base.nfm")
    check formToNfm(f2).startsWith("object Base: Form")
    let g = loadNfm(out1, nil, nil, dir / "derived.nfm")
    check g.height == 123
    check Edit(g.named("nameEdit")).text == "changed"
    check Button(g.named("okButton")).caption == "OK"
    check formToNfm(g) == out1
    # a value the ancestor sets and the descendant clears is written explicitly
    Edit(f.named("nameEdit")).text = ""
    check "    text = ''\n" in formToNfm(f)

  test "an unchanged descendant lists only its new objects":
    let f = loadNfm("inherited D: D\n  ancestor = 'base.nfm'\nend\n", nil, nil, dir / "d.nfm")
    check formToNfm(f) == "inherited D: D\n  ancestor = 'base.nfm'\nend\n"

suite "the parsed ancestor is cached (Q9)":
  test "a change of the ancestor file is seen by the next save":
    let tmp = getTempDir() / ("nimvcl_q9_" & $getCurrentProcessId())
    createDir tmp
    defer: removeDir tmp
    writeFile(tmp / "base.nfm", "object Base: Form\n  width = 300\n  height = 200\nend\n")
    let desc = "inherited D: D\n  ancestor = 'base.nfm'\nend\n"
    let f = loadNfm(desc, nil, nil, tmp / "d.nfm")
    check f.width == 300
    check formToNfm(f) == desc                     # parsed once, cached
    check formToNfm(f) == desc
    writeFile(tmp / "base.nfm", "object Base: Form\n  width = 640\n  height = 200\nend\n")
    check "width = 300" in formToNfm(f)            # the form is 300 now, the ancestor says 640
    check loadNfm(desc, nil, nil, tmp / "d.nfm").width == 640

suite "designer and inspector with inherited components":
  test "inherited components cannot be deleted or renamed; new ones can":
    Application.init()
    let f = loadNfmFile(dir / "derived.nfm")
    f.show()
    discard f.paintIfDirty()
    let d = newFormDesigner(f)
    let ok = Button(f.named("okButton"))
    let extra = Button(f.named("extraButton"))
    d.select(ok)
    check not d.deleteSelection()
    check f.named("okButton") != nil and ok.parent != nil
    d.select([Control(ok), Control(extra)])        # one inherited in the selection: all stay
    check not d.deleteSelection()
    # inherited ones can still be moved/resized and edited
    ok.setBounds(7, 8, 90, 30)
    check ok.left == 7
    d.select(extra)
    check d.deleteSelection()
    check f.named("extraButton") == nil or extra.parent == nil

    let ins = newObjectInspector(f, 10, 10, 340, 600)
    ins.inspect(ok)
    ins.setValue("name", pvString("renamed"))
    check ok.name == "okButton"
    check "ancestor" in ins.lastError
    ins.setValue("caption", pvString("Changed"))
    check ok.caption == "Changed"
    f.freeWindow()

suite "inherited objects keep their place":
  test "an inherited block under a new container is an error; the class must match":
    expect NfmError:
      discard loadNfm("inherited F: F\n  ancestor = 'base.nfm'\n  object box: Panel\n" &
                      "    inherited okButton: Button\n    end\n  end\nend\n", nil, nil, dir / "x.nfm")
    expect NfmError:
      discard loadNfm("inherited F: F\n  ancestor = 'base.nfm'\n  inherited panel1: Control\n" &
                      "  end\nend\n", nil, nil, dir / "x.nfm")
    check loadNfm("inherited F: F\n  ancestor = 'base.nfm'\n  inherited panel1: Panel\n" &
                  "  end\nend\n", nil, nil, dir / "x.nfm") != nil

  test "the designer does not move an inherited control into another container":
    Application.init()
    let f = loadNfmFile(dir / "derived.nfm")
    f.show()
    discard f.paintIfDirty()
    let d = newFormDesigner(f)
    d.grid = 0
    let ok = Button(f.named("okButton"))
    let panel = Panel(f.named("panel1"))
    let o = ok.formOrigin
    let x0 = o.x + ok.width / 2
    let y0 = o.y + ok.height / 2
    proc feed(kind: EventKind, x, y: float32, shift: ShiftState = {}) =
      Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                         button: mbLeft, clicks: 1, shift: shift))
    feed(ekMouseDown, x0, y0)
    feed(ekMouseMove, x0 + 30, y0 + 100, {ssLeft})
    feed(ekMouseMove, x0 + 60, y0 + 200, {ssLeft})
    feed(ekMouseUp, x0 + 60, y0 + 200)
    check ok.parent == Container(panel)
    f.freeWindow()
