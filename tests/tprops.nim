## Property registry (dsl/props, dsl/props_std). Headless (offscreen SDL).

import std/[unittest, tables]
import nimvcl
import nimvcl/dsl/props_std
from nimvcl/dsl/nfmsyntax import isReservedFieldName

const Expected = [
  "Form", "Label", "Button", "CheckBox", "RadioButton", "Panel", "GroupBox",
  "Frame", "Bevel", "PaintBox", "ImageControl", "ScrollBox", "Splitter",
  "FlowPanel", "GridPanel", "StatusBar", "StatusPanel", "ToolBar", "ToolButton",
  "TabControl", "PageControl", "TabSheet", "Edit", "Memo", "SpinEdit",
  "ComboBox", "ListBox", "TrackBar", "ProgressBar", "ScrollBar", "TreeView",
  "ListView", "ListColumn", "DrawGrid", "StringGrid", "CodeEdit", "Timer",
  "ImageList", "MainMenu", "PopupMenu", "MenuItem", "ActionList", "Action"]

proc make(ci: ClassInfo): Obj =
  ## An instance; classes that need a parent get one.
  let parent: Obj =
    case ci.name
    of "StatusPanel": Obj(newStatusBar(nil))
    of "ListColumn": Obj(newListView(nil))
    of "MenuItem": Obj(newMainMenu(nil))
    else: nil
  ci.createObject(nil, parent)

# a class registered from outside, with its own factory
type Badge = ref object of Panel
  fLevel: int
proc level(b: Badge): int = b.fLevel
proc `level=`(b: Badge, v: int) = b.fLevel = v
proc newBadge(parent: Container = nil): Badge =
  new result
  result.initPanel(parent)
  if parent != nil: parent.insertControl result

registerClass(Badge, parent = Panel):
  category Data:
    level: int

suite "registry":
  test "every public control is registered and creatable":
    for n in Expected:
      let ci = classByName(n)
      check ci != nil
      if ci == nil: continue
      let o = make(ci)
      check o != nil
      check classOf(o) == ci
    check classByName("Image") == classByName("ImageControl")
    # every property of the base classes is a reserved field name (N25)
    for cn in ["Component", "Control", "Container", "Form"]:
      let ci = classByName(cn)
      if ci == nil: continue
      for p in ci.propsOf:
        check isReservedFieldName(p.name)
    check isReservedFieldName("icon") and isReservedFieldName("menu")
    check not isReservedFieldName("Button1") and not isReservedFieldName("")
    check classByName("NoSuchThing") == nil

  test "inheritance and property lists":
    let b = classByName("Button")
    check b.parent == classByName("Control")
    var names: seq[string]
    for p in b.propsOf: names.add p.name
    for n in ["name", "left", "top", "width", "height", "align", "anchors", "margins",
              "constraints", "visible", "enabled", "hint", "tabOrder", "tabStop",
              "font", "color", "parentFont", "parentColor", "autoSize", "cursor",
              "caption", "isDefault", "modalResult", "onClick"]:
      check n in names
    check "padding" notin names                       # Container only
    var panelNames: seq[string]
    for p in classByName("Panel").propsOf: panelNames.add p.name
    check "padding" in panelNames
    check classByName("Button").findProp("nope") == nil
    check classByName("Button").findProp("font.size") != nil
    check classByName("Button").findProp("font.style.fsBold") != nil
    check classByName("Button").findProp("anchors.akLeft") != nil
    check classByName("Form").findProp("windowState") != nil
    check classByName("Form").findProp("onCreate") != nil
    check classByName("Form").findProp("onCreate").kind == pkEvent

  test "default values are those of a fresh instance":
    for ci in allClasses():
      if ci.abstract: continue
      let o = make(ci)
      for p in ci.propsOf:
        if not isDefault(o, p): echo ci.name, ".", p.name, " is not default when fresh"
        check isDefault(o, p)

  test "get and set round-trip for every property of every class":
    for ci in allClasses():
      if ci.abstract or ci.name in ["Timer"]: continue
      let o = make(ci)
      for p in ci.propsOf:
        if p.kind in {pkEvent, pkImage}: continue
        let v = p.get(o)
        p.set(o, v)
        check p.get(o) == v

  test "a collection property reports its item count and ignores a set":
    let sb = newStatusBar(nil)
    sb.addPanel("a")
    let p = classByName("StatusBar").findProp("panels")
    check p.kind == pkCollection and not p.stored
    check p.get(sb) == PropValue(kind: pkCollection, i: 1)
    p.set(sb, p.get(sb))
    check sb.panels.len == 1
    expect PropError:
      p.set(sb, pvInt(3))

  test "kinds: bool int float string":
    let b = newButton(nil, "x")
    setProp(b, "isDefault", pvBool(true))
    check b.isDefault
    check getProp(b, "isDefault") == pvBool(true)
    setProp(b, "tabOrder", pvInt(7))
    check b.tabOrder == 7
    setProp(b, "left", pvFloat(12.5))
    check b.left == 12.5
    setProp(b, "left", pvInt(3))                  # a whole number is fine for a float
    check b.left == 3
    setProp(b, "caption", pvString("hello"))
    check b.caption == "hello"
    check not isDefault(b, "caption")

  test "kinds: enum and set, names and values":
    let b = newButton(nil)
    let a = classByName("Button").findProp("align")
    check a.kind == pkEnum
    check a.enumNames == @["alNone", "alTop", "alBottom", "alLeft", "alRight", "alClient", "alCustom"]
    check a.enumValue("alClient") == 5
    check a.enumValue("alBogus") == -1
    check a.enumName(1) == "alTop"
    setProp(b, "align", pvEnum(a.enumValue("alBottom")))
    check b.align == alBottom
    let an = classByName("Button").findProp("anchors")
    check an.kind == pkSet
    check an.enumNames == @["akLeft", "akTop", "akRight", "akBottom"]
    setProp(b, "anchors", pvSet(0b0110))
    check b.anchors == {akTop, akRight}
    setProp(b, "anchors.akBottom", pvBool(true))
    check b.anchors == {akTop, akRight, akBottom}
    check getProp(b, "anchors.akLeft") == pvBool(false)
    check getProp(b, "anchors.akTop") == pvBool(true)

  test "kinds: colour, font, spacing, constraints":
    let p = newPanel(nil)
    setProp(p, "color", pvColor(hex"#336699"))
    check p.color == hex"#336699"
    check not p.parentColor
    check not isDefault(p, "color")
    check isDefault(newPanel(nil), "color")       # inherited colour is the default
    setProp(p, "font.size", pvFloat(18))
    check p.font.size == 18
    check not p.parentFont
    setProp(p, "font.style", pvSet(1))
    check p.font.style == {fsBold}
    setProp(p, "font.style.fsItalic", pvBool(true))
    check p.font.style == {fsBold, fsItalic}
    check not isDefault(p, "font.size")
    check isDefault(p, "font.color")
    check classByName("Label").findProp("font.color") != nil
    check classByName("Label").findProp("font.color").kind == pkColor
    check classByName("Label").findProp("textColor") == nil      # replaced by font.color
    setProp(p, "font.color", pvColor(hex"#336699"))
    check p.font.color == hex"#336699"
    check getProp(p, "font.color") == pvColor(hex"#336699")
    check not isDefault(p, "font.color")
    setProp(p, "margins.left", pvFloat(4))
    setProp(p, "margins.bottom", pvInt(9))
    check p.margins == spacing(4, 0, 0, 9)
    setProp(p, "padding", pvSpacing(spacing(2)))
    check p.padding == spacing(2)
    setProp(p, "constraints.minWidth", pvFloat(50))
    check p.constraints.minWidth == 50
    check getProp(p, "constraints.maxHeight") == pvFloat(0)

  test "kinds: object references, strings, events":
    let f = newForm(nil)
    let e = newEdit(f, "x")
    e.name = "userEdit"
    let l = newLabel(f)
    setProp(l, "focusControl", pvObject(e))
    check l.focusControl == Control(e)
    check getProp(l, "focusControl").objName == "userEdit"
    setProp(l, "focusControl", pvObject(nil))
    check l.focusControl == nil
    expect PropError: setProp(l, "focusControl", pvObject(Obj(newTimer(f))))
    let cb = newComboBox(f)
    setProp(cb, "items", pvStrings(@["a", "b", "c"]))
    check cb.items.len == 3
    check getProp(cb, "items").strs == @["a", "b", "c"]
    let btn = newButton(f)
    let click = classByName("Button").findProp("onClick")
    check click.kind == pkEvent
    check click.typeName == "NotifyEvent"
    check getProp(btn, "onClick") == pvEvent("")
    setProp(btn, "onClick", pvEvent("go"))
    check getProp(btn, "onClick") == pvEvent("go")
    check handlerNameOf(btn, "onClick") == "go"
    check not click.isAssigned(btn)               # a name alone binds nothing
    var hit = 0
    let box = HandlerBox[NotifyEvent](fn: proc(s: Control) = inc hit)
    check click.bindHandler(btn, box)
    check click.isAssigned(btn)
    btn.onClick(btn)
    check hit == 1
    check not click.bindHandler(btn, HandlerBox[MenuItemEvent]())   # wrong event type
    setProp(btn, "onClick", pvEvent(""))
    check btn.onClick == nil
    check isDefault(btn, "onClick")

  test "images and image lists":
    let ic = newImageControl(nil)
    let img = newImage(4, 4)
    setProp(ic, "picture", PropValue(kind: pkImage, image: img))
    check ic.picture == img
    let il = newImageList(16, 16)
    il.name = "icons"
    let tb = newToolBar(nil)
    setProp(tb, "images", pvObject(il))
    check tb.images == il

  test "errors":
    let b = newButton(nil)
    expect PropError: setProp(b, "nope", pvInt(1))
    expect PropError: discard getProp(b, "nope")
    expect PropError: setProp(b, "isDefault", pvInt(1))
    expect PropError: setProp(b, "align", pvEnum(99))
    expect PropError: setProp(b, "font.bogus", pvFloat(1))

  test "collections: kids and creation":
    let f = newForm(nil)
    let mm = newMainMenu(f)
    let it = mm.addItem("File")
    it.addItem("Open")
    let kids = kidsOf(Obj(mm))
    check kids.len == 1
    check kidsOf(kids[0]).len == 1
    check kidsOf(Obj(f)).len == 1                 # the menu bar
    let sb = newStatusBar(f)
    sb.addPanel("a")
    check kidsOf(Obj(sb)).len == 1
    check classOf(kidsOf(Obj(sb))[0]).name == "StatusPanel"
    let lv = newListView(f)
    lv.columns.add("Name")
    check classOf(kidsOf(Obj(lv))[0]).name == "ListColumn"
    # a ScrollBox does not list its own scroll bars
    let sc = newScrollBox(f)
    check kidsOf(Obj(sc)).len == 0
    newLabel(sc)
    check kidsOf(Obj(sc)).len == 1

  test "a class registered from outside":
    let ci = classByName("Badge")
    check ci != nil
    check ci.parent == classByName("Panel")
    let o = ci.createObject(nil, nil)
    check o of Badge
    setProp(o, "level", pvInt(3))
    check Badge(o).level == 3
    check not isDefault(o, "level")
    check classOf(o) == ci
    # a user subclass of a registered class answers its nearest registered class
    type Fancy = ref object of Button
    let fz = Fancy()
    fz.initButton()
    check classOf(fz) == classByName("Button")
    expect PropError: discard classByName("Control").createObject(nil, nil)

suite "design-time properties registered":
  Application.init()

  test "the audited properties exist with the right kinds":
    proc kindOf(cls, prop: string): PropKind =
      let p = classByName(cls).findProp(prop)
      check p != nil
      p.kind
    check kindOf("Edit", "passwordChar") == pkString
    check kindOf("Button", "images") == pkObject
    check kindOf("Button", "imageIndex") == pkInt
    check kindOf("Button", "imageAlignment") == pkEnum
    check kindOf("Form", "icon") == pkImage
    check kindOf("Form", "menu") == pkObject
    check kindOf("StringGrid", "cells") == pkStrings
    check kindOf("StringGrid", "colWidths") == pkString
    check kindOf("StringGrid", "rowHeights") == pkString
    check kindOf("DrawGrid", "colWidths") == pkString
    check kindOf("StringGrid", "fixedRows") == pkInt
    check kindOf("ListView", "itemImages") == pkStrings
    check kindOf("ListView", "checkedItems") == pkStrings
    check kindOf("TreeView", "itemImages") == pkStrings
    check kindOf("TreeView", "itemSelectedImages") == pkStrings
    check kindOf("TreeView", "checkedItems") == pkStrings

  test "hidden properties are stored but not for the inspector":
    for (c, p) in [("ListView", "itemImages"), ("ListView", "checkedItems"),
                   ("TreeView", "itemImages"), ("TreeView", "itemSelectedImages"),
                   ("TreeView", "checkedItems")]:
      let pi = classByName(c).findProp(p)
      check pi.hidden and pi.stored
    check not classByName("ListView").findProp("items").hidden

  test "ordering: dependent properties come after what they depend on":
    proc pos(cls: string): Table[string, int] =
      for i, p in classByName(cls).propsOf: result[p.name] = i
    let sg = pos("StringGrid")
    check sg["cells"] > sg["colCount"] and sg["cells"] > sg["rowCount"]
    check sg["colWidths"] > sg["colCount"] and sg["colWidths"] > sg["defaultColWidth"]
    check sg["rowHeights"] > sg["rowCount"] and sg["rowHeights"] > sg["defaultRowHeight"]
    let lv = pos("ListView")
    check lv["itemImages"] > lv["items"] and lv["checkedItems"] > lv["itemImages"]
    let tv = pos("TreeView")
    check tv["itemImages"] > tv["items"] and tv["itemSelectedImages"] > tv["items"]
    check tv["checkedItems"] > tv["items"] and tv["checkedItems"] > tv["propagateChecks"]

  test "get and set on live objects":
    let g = newStringGrid(nil)
    setProp(Obj(g), "cells", pvStrings(@["a\tb", "c"]))
    check g.cells[1, 0] == "b" and g.cells[0, 1] == "c"
    check getProp(Obj(g), "cells").strs == @["a\tb", "c"]
    setProp(Obj(g), "colWidths", pvString("10, 20"))
    check g.colWidths[1] == 20
    check getProp(Obj(g), "colWidths").s == "10, 20, 64, 64, 64"
    let b = newButton(nil)
    let il = newImageList()
    setProp(Obj(b), "images", pvObject(Obj(il)))
    setProp(Obj(b), "imageIndex", pvInt(2))
    setProp(Obj(b), "imageAlignment", pvEnum(ord(iaBottom)))
    check b.images == il and b.imageIndex == 2 and b.imageAlignment == iaBottom
    let f = newForm(nil, 100, 100)
    let mm = newMainMenu(f)
    f.menu = nil
    setProp(Obj(f), "menu", pvObject(Obj(mm)))
    check f.menu == mm
    setProp(Obj(f), "icon", PropValue(kind: pkImage, image: newImage(2, 2)))
    check f.icon != nil
