## Pictures and image lists in form files: `picture = 'images/x.png'` read from
## disk by `loadNfm`, embedded by `loadForm`, written back by `formToNfm`, and
## the property editor dialogs (headless, driven through their procs).

import std/[unittest, os, osproc, strutils, tables]
import nimvcl
import nimvcl/dsl/[props, props_std, nfm]
import nimvcl/controls/[inspector, propeditors, dialogs]
import nimvcl/platform/dialogs as platdialogs

const
  here = currentSourcePath().parentDir
  root = here.parentDir
  nfmDir = here / "nfm"

# the whole file is embedded at compile time: no image is read at run time
loadForm Pics, "nfm/pictures.nfm"
loadForm Lists, "nfm/listdata.nfm"
loadForm Refs, "nfm/refs.nfm"

proc ctx(): string = getTempDir() / ("nvpic-" & $getCurrentProcessId())

suite "picture property (registry)":
  Application.init()

  test "Image has a picture property of the image kind, ImageList an images list":
    let ci = classByName("Image")
    check ci.findProp("picture").kind == pkImage
    check classByName("ImageList").findProp("images").kind == pkImages
    check classByName("ToolButton").findProp("image").kind == pkImage

  test "a picture without a path cannot be written but does not break saving":
    let f = newForm(nil, 100, 100)
    let im = newImageControl(f)
    im.name = "im1"
    im.picture = newImage(4, 4)          # made in memory: no source
    check "picture" notin formToNfm(f, "F")
    im.picture.source = "images/x.png"
    check "picture = 'images/x.png'" in formToNfm(f, "F")

suite "loadNfm: pictures from disk":
  Application.init()

  test "paths are relative to the form file":
    let f = loadNfmFile(nfmDir / "pictures.nfm")
    let logo = ImageControl(f.findComponent("logo"))
    check logo.picture != nil
    check logo.picture.width == 4 and logo.picture.height == 3
    check logo.picture.source == "images/red.png"
    check logo.picture.getPixel(0, 0) == Color(r: 255, g: 0, b: 0, a: 255)
    let il = ImageList(f.findComponent("icons"))
    check il.count == 2
    check il.image(0).width == 8 and il.image(1).width == 16
    check il.width == 24 and il.height == 24
    let bar = ToolBar(f.findComponent("bar"))
    check bar.images == il                    # the link resolved by name

  test "text without a file name uses baseDir or the current folder":
    let src = readFile(nfmDir / "pictures.nfm")
    let f = loadNfm(src, nil, NfmOptions(strict: true, baseDir: nfmDir))
    check ImageControl(f.findComponent("logo")).picture.width == 4
    let saved = getCurrentDir()
    setCurrentDir nfmDir
    defer: setCurrentDir saved
    check ImageControl(loadNfm(src).findComponent("logo")).picture.width == 4

  test "a missing image does not raise: a stand-in keeps the path, a warning is listed":
    let src = "object F: Form\n  object p: ImageControl\n    picture = 'nope/gone.png'\n  end\nend\n"
    let opt = newNfmOptions(strict = true)
    let f = loadNfm(src, nil, opt)
    let p = ImageControl(f.findComponent("p"))
    check p.picture != nil and p.picture.source == "nope/gone.png"
    check opt.warnings.len == 1 and "gone.png" in opt.warnings[0]
    check "picture = 'nope/gone.png'" in formToNfm(f)     # nothing is lost on save

  test "a non-string picture value is an error":
    expect NfmError:
      discard loadNfm("object F: Form\n  object p: ImageControl\n    picture = 3\n  end\nend\n")

  test "round trip through formToNfm":
    let f = loadNfmFile(nfmDir / "pictures.nfm")
    let text = formToNfm(f)
    check "picture = 'images/red.png'" in text
    check "'images/blue.png'" in text and "'images/green.png'" in text
    let g = loadNfm(text, nil, NfmOptions(strict: true, baseDir: nfmDir))
    check ImageControl(g.findComponent("logo")).picture.width == 4
    check ImageList(g.findComponent("icons")).count == 2
    check formToNfm(g) == text

suite "loadForm embeds the files":
  Application.init()

  test "the form has its pictures without any file":
    let f = newPics()
    check f.logo.picture != nil and f.logo.picture.width == 4
    check f.logo.picture.source == "images/red.png"
    check f.icons.count == 2 and f.icons.image(1).width == 16
    check f.bar.images == f.icons
    check f.logo.stretch

  test "formToNfm of the typed form writes the paths back":
    let text = formToNfm(newPics())
    check "picture = 'images/red.png'" in text

  test "a compiled program runs after its image files are deleted":
    let dir = ctx() / "embed"
    removeDir dir
    createDir dir / "images"
    for n in ["red.png", "blue.png", "green.png"]:
      copyFile(nfmDir / "images" / n, dir / "images" / n)
    copyFile(nfmDir / "pictures.nfm", dir / "pictures.nfm")
    writeFile(dir / "prog.nim", """
import nimvcl
import nimvcl/dsl/nfm
loadForm Pics, "pictures.nfm"
Application.init()
let f = newPics()
doAssert f.logo.picture.width == 4
doAssert f.icons.count == 2
echo "embedded ok"
""")
    let nimOut = dir / "prog"
    # the program sits outside the repo, so it does not see nim.cfg: link SDL
    # the way nim.cfg does on macOS
    const sdlLink = when defined(macosx):
      " --dynlibOverride:SDL3 --dynlibOverride:SDL3_ttf --dynlibOverride:SDL3_image" &
      " --passL:\"-L/opt/homebrew/lib -L/usr/local/lib -lSDL3 -lSDL3_ttf -lSDL3_image\""
    else: ""
    let (o1, c1) = execCmdEx("nim c --hints:off --warnings:off" & sdlLink & " --path:" & quoteShell(root / "src") &
      " --nimcache:" & quoteShell(dir / "cache") & " -o:" & quoteShell(nimOut) & " " &
      quoteShell(dir / "prog.nim"))
    if c1 != 0: echo o1
    check c1 == 0
    removeDir dir / "images"
    removeFile dir / "pictures.nfm"
    if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
    if not existsEnv("SDL_RENDER_DRIVER"): putEnv("SDL_RENDER_DRIVER", "software")
    let (o2, c2) = execCmdEx(quoteShell(nimOut.addFileExt(ExeExt)))
    check c2 == 0
    check "embedded ok" in o2
    removeDir ctx()

# --------------------------------------------------------------- the editors

suite "picture dialog":
  Application.init()

  setup:
    removeDir ctx()
    createDir ctx() / "proj"
  teardown:
    removeDir ctx()

  test "a file inside the base folder is stored relative":
    createDir ctx() / "proj" / "img"
    copyFile(nfmDir / "images" / "red.png", ctx() / "proj" / "img" / "r.png")
    let host = newPropEditorHost(ctx() / "proj")
    let d = newPictureDlg(host, nil)
    check d.loadFile(ctx() / "proj" / "img" / "r.png")
    check d.preview.picture == d.picked
    check d.commit.source == "img/r.png"
    check d.pathLbl.caption == "img/r.png"

  test "a file outside is copied into images/":
    let host = newPropEditorHost(ctx() / "proj")
    let d = newPictureDlg(host, nil)
    check d.loadFile(nfmDir / "images" / "blue.png")
    # nothing is copied while the dialog is open (Cancel leaves the project alone)
    check not fileExists(ctx() / "proj" / "images" / "blue.png")
    check d.commit.source == "images/blue.png"
    check fileExists(ctx() / "proj" / "images" / "blue.png")
    # the same file again: no second copy; a different file of that name: a new one
    check d.loadFile(nfmDir / "images" / "blue.png")
    check d.commit.source == "images/blue.png"
    writeFile(ctx() / "other.png", readFile(nfmDir / "images" / "red.png"))
    copyFile(ctx() / "other.png", ctx() / "blue.png")
    check d.loadFile(ctx() / "blue.png")
    check d.commit.source == "images/blue_1.png"

  test "imagesDir chooses the copy target":
    let host = newPropEditorHost(ctx() / "proj", ctx() / "proj" / "art")
    let d = newPictureDlg(host, nil)
    check d.loadFile(nfmDir / "images" / "yellow.bmp")
    check d.commit.source == "art/yellow.bmp"

  test "a bad file keeps the old picture and shows an error":
    let host = newPropEditorHost(ctx() / "proj")
    let d = newPictureDlg(host, nil)
    d.loadFile(nfmDir / "images" / "red.png")
    let was = d.picked
    writeFile(ctx() / "bad.png", "not an image")
    check not d.loadFile(ctx() / "bad.png")
    check d.picked == was
    check d.pathLbl.caption.startsWith("cannot load")

  test "Clear":
    let host = newPropEditorHost(ctx() / "proj")
    let d = newPictureDlg(host, nil)
    d.loadFile(nfmDir / "images" / "red.png")
    d.clearPicture()
    check d.picked == nil and d.preview.picture == nil
    check d.pathLbl.caption == "(none)"

  test "Load... runs the file dialog and loads the chosen file":
    let host = newPropEditorHost(ctx() / "proj")
    let d = newPictureDlg(host, nil)
    var req: FileDialogRequest
    let real = showFileDialogImpl
    defer: showFileDialogImpl = real
    showFileDialogImpl = proc(r: FileDialogRequest, token: int, done: FileDialogDone) =
      req = r
      done(token, true, @[nfmDir / "images" / "green.png"])
    d.loadBtn.click()
    for _ in 0 ..< 20:
      Application.processMessages(10)
      if d.picked != nil: break
    check d.picked != nil and d.commit.source == "images/green.png"
    check req.kind == fdkOpen
    check ("Images", "png;jpg;jpeg;bmp;gif") in req.filters

suite "editors through the inspector":
  Application.init()

  setup:
    removeDir ctx()
    createDir ctx() / "proj"
  teardown:
    removeDir ctx()

  test "the ... button of a picture opens the dialog; OK sets it, Cancel does not":
    let f = newForm(nil, 400, 300)
    let im = newImageControl(f)
    let ins = newObjectInspector(f)
    var changed: seq[string]
    ins.onPropertyChanged = proc(s: Control, t: Obj, p: string) = changed.add p
    let host = newPropEditorHost(ctx() / "proj")
    attachEditors(ins, host)
    ins.inspect(im)
    check ins.valueTextOf("picture") == "(none)"
    host.runModal = proc(d: Form): ModalResult =
      PictureDlgForm(d).loadFile(nfmDir / "images" / "red.png")
      mrOk
    ins.beginEdit("picture")
    check im.picture != nil and im.picture.source == "images/red.png"
    check ins.valueTextOf("picture") == "images/red.png"
    check "picture" in changed
    host.runModal = proc(d: Form): ModalResult =
      PictureDlgForm(d).clearPicture()
      mrCancel
    ins.beginEdit("picture")
    check im.picture != nil                      # cancelled
    host.runModal = proc(d: Form): ModalResult =
      PictureDlgForm(d).clearPicture()
      mrOk
    ins.beginEdit("picture")
    check im.picture == nil

  test "Delete clears a picture in the inspector":
    let f = newForm(nil, 400, 300)
    let im = newImageControl(f)
    im.picture = newImage(2, 2)
    let ins = newObjectInspector(f)
    ins.inspect(im)
    check ins.selectProp("picture")
    f.show()
    f.syncMetrics()
    Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: keyDelete))
    ins.setFocus()
    Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: keyDelete))
    check im.picture == nil
    f.freeWindow()

  test "string lists: ListBox items, Memo lines, TabControl tabs":
    let f = newForm(nil, 400, 300)
    let lb = newListBox(f)
    let ins = newObjectInspector(f)
    let host = newPropEditorHost(ctx() / "proj")
    attachEditors(ins, host)
    ins.inspect(lb)
    var seen: seq[string]
    host.runModal = proc(d: Form): ModalResult =
      let dd = StringListDlgForm(d)
      seen = dd.linesOf
      dd.memo.text = "one\ntwo\n\nthree\n"
      mrOk
    ins.beginEdit("items")
    check seen.len == 0
    check lb.items.len == 4
    check lb.items[0] == "one" and lb.items[2] == "" and lb.items[3] == "three"
    check ins.valueTextOf("items") == "(4 lines)"
    host.runModal = proc(d: Form): ModalResult = mrCancel
    ins.beginEdit("items")
    check lb.items.len == 4

  test "ImageList: add several files, delete, move; the list is set on OK":
    let f = newForm(nil, 400, 300)
    let il = newImageList(24, 24, f)
    il.name = "il"
    let ins = newObjectInspector(f)
    let host = newPropEditorHost(ctx() / "proj")
    attachEditors(ins, host)
    ins.inspect(il)
    host.runModal = proc(d: Form): ModalResult =
      let dd = ImageListDlgForm(d)
      check dd.addFiles([nfmDir / "images" / "red.png", nfmDir / "images" / "blue.png",
                         nfmDir / "images" / "green.png"]) == 3
      dd.list.itemIndex = 2
      dd.moveSelected(-1)                    # green before blue
      dd.list.itemIndex = 0
      dd.deleteSelected()                    # drop red
      check dd.addFiles([ctx() / "missing.png"]) == 0
      check dd.errors.len == 1
      mrOk
    ins.beginEdit("images")
    check il.count == 2
    check il.image(0).source == "images/green.png"
    check il.image(1).source == "images/blue.png"
    check not fileExists(ctx() / "proj" / "images" / "red.png")   # dropped before OK: never copied
    check fileExists(ctx() / "proj" / "images" / "blue.png")
    check ins.valueTextOf("images") == "(2 images)"
    check "images = (" in objectToNfm(Obj(il))

  test "ImageList dialog: Add... uses the file dialog with several files":
    let host = newPropEditorHost(ctx() / "proj")
    let d = newImageListDlg(host, @[], 16, 16)
    var req: FileDialogRequest
    let real = showFileDialogImpl
    defer: showFileDialogImpl = real
    showFileDialogImpl = proc(r: FileDialogRequest, token: int, done: FileDialogDone) =
      req = r
      done(token, true, @[nfmDir / "images" / "red.png", nfmDir / "images" / "blue.png"])
    d.addBtn.click()
    for _ in 0 ..< 20:
      Application.processMessages(10)
      if d.imgs.len == 2: break
    check d.imgs.len == 2
    check req.multiSelect
    check d.list.count == 2 and d.list.itemIndex == 1

  test "ToolBar / TreeView / ListView / menus link an ImageList by name":
    let f = newForm(nil, 400, 300)
    let il = newImageList(16, 16, f)
    il.name = "images1"
    let tb = newToolBar(f)
    tb.name = "tb"
    let ins = newObjectInspector(newForm(nil, 400, 300))
    ins.inspect(tb)
    check ins.beginEdit("images")
    let cb = ins.editCombo
    check cb.items.len == 2 and cb.items[0] == "(none)" and cb.items[1] == "images1"
    cb.itemIndex = 1
    check ins.commitEdit()
    check tb.images == il
    check "images = images1" in formToNfm(f, "F")
    let g = loadNfm(formToNfm(f, "F"))
    check ToolBar(g.findComponent("tb")).images == ImageList(g.findComponent("images1"))
    for cls in ["TreeView", "ListView", "MainMenu", "PopupMenu", "ActionList"]:
      var any = false
      for p in classByName(cls).propsOf:
        if p.typeName == "ImageList": any = true
      check any

proc actionKids2(l: ActionList): seq[Obj] =
  for a in l.components:
    if a of Action: result.add Obj(a)

suite "collection editor":
  Application.init()

  test "ListView columns: add, rename through the inspector, move, delete":
    let f = newForm(nil, 400, 300)
    let lv = newListView(f)
    let ci = classByName("ListView")
    let info = ci.findProp("columns")
    check info.kind == pkCollection
    var added: seq[Obj]
    var changes: seq[string]
    let host = newPropEditorHost()
    host.onItemAdded = proc(p, it: Obj) = added.add it
    host.onChanged = proc(t: Obj, prop: string) = changes.add prop
    let d = newCollectionDlg(host, lv, info)
    d.addItem()
    d.addItem()
    check lv.columns.len == 2 and added.len == 2
    check d.list.count == 2 and d.list.itemIndex == 1
    # edit the selected item in the embedded inspector
    d.insp.setValue("caption", pvString("Name"))
    check lv.columns[1].caption == "Name"
    check d.list.items[1] == "Name"
    d.moveItem(-1)
    check lv.columns[0].caption == "Name" and d.list.itemIndex == 0
    d.deleteItem()
    check lv.columns.len == 1
    check "columns" in changes and "caption" in changes

  test "StatusBar panels, PageControl pages, ToolBar buttons, menu items":
    let f = newForm(nil, 400, 300)
    let host = newPropEditorHost()
    # status bar
    let sb = newStatusBar(f)
    var d = newCollectionDlg(host, sb, classByName("StatusBar").findProp("panels"))
    d.addItem(); d.addItem(); d.addItem()
    check sb.panels.len == 3
    d.list.itemIndex = 0
    d.moveItem(1)
    d.deleteItem()
    check sb.panels.len == 2
    # pages
    let pc = newPageControl(f)
    d = newCollectionDlg(host, pc, classByName("PageControl").findProp("pages"))
    d.addItem(); d.addItem()
    check pc.sheets.len == 2
    d.insp.setValue("caption", pvString("Second"))
    check pc.sheets[1].caption == "Second"
    d.moveItem(-1)
    check pc.sheets[0].caption == "Second"
    check d.itemsOf[0] == Obj(pc.sheets[0])
    d.deleteItem()
    check pc.sheets.len == 1
    # tool buttons
    let tb = newToolBar(f)
    d = newCollectionDlg(host, tb, classByName("ToolBar").findProp("buttons"))
    d.addItem(); d.addItem()
    check tb.children.len == 2
    d.list.itemIndex = 1
    d.moveItem(-1)
    d.deleteItem()
    check tb.children.len == 1
    # actions (no reordering)
    let al = newActionList(f)
    d = newCollectionDlg(host, al, classByName("ActionList").findProp("actions"))
    d.addItem(); d.addItem()
    check actionKids2(al).len == 2
    d.moveItem(-1)                       # not reorderable: nothing happens
    d.deleteItem()
    check actionKids2(al).len == 1
    # menus: items and sub-items
    let mm = newMainMenu(f)
    d = newCollectionDlg(host, mm, classByName("MainMenu").findProp("items"))
    d.addItem()
    d.insp.setValue("caption", pvString("File"))
    check mm.items.count == 1 and mm.items[0].caption == "File"
    let sub = newCollectionDlg(host, Obj(mm.items[0]), classByName("MenuItem").findProp("items"))
    sub.addItem(); sub.addItem()
    check mm.items[0].count == 2
    sub.list.itemIndex = 1
    sub.moveItem(-1)
    sub.deleteItem()
    check mm.items[0].count == 1

  test "the collection is edited from the inspector's ... button; the result is saved":
    let f = newForm(nil, 400, 300)
    f.name = "F"
    let lv = newListView(f)
    lv.name = "lv"
    let ins = newObjectInspector(newForm(nil, 400, 300))
    let host = newPropEditorHost()
    attachEditors(ins, host)
    ins.inspect(lv)
    check ins.valueTextOf("columns") == "(empty)"
    host.runModal = proc(d: Form): ModalResult =
      let c = CollectionDlgForm(d)
      c.addItem()
      c.insp.setValue("caption", pvString("Size"))
      c.insp.setValue("width", pvFloat(77))
      mrOk
    ins.beginEdit("columns")
    check lv.columns.len == 1
    check ins.valueTextOf("columns") == "(1 item)"
    let text = formToNfm(f)
    check "object: ListColumn" in text and "caption = 'Size'" in text
    let g = loadNfm(text)
    check ListView(g.findComponent("lv")).columns[0].width == 77

suite "list and tree data as text":
  Application.init()

  test "TreeView items are an outline, ListView items tab-separated cells":
    let f = newForm(nil, 300, 300)
    f.name = "F"
    let tv = newTreeView(f)
    tv.name = "tv"
    tv.nodeLines = @["Root", "  Child A", "    Leaf", "  Child B", "Second"]
    check tv.items.count == 5
    check tv.nodeLines == @["Root", "  Child A", "    Leaf", "  Child B", "Second"]
    let lv = newListView(f)
    lv.name = "lv"
    lv.columns.add("Name"); lv.columns.add("Size")
    lv.itemLines = @["a.txt\t10", "b.txt\t20", "c"]
    check lv.items.count == 3 and lv.items[1].subItems == @["20"]
    let text = formToNfm(f)
    check "items = (" in text
    let g = loadNfm(text)
    check TreeView(g.findComponent("tv")).nodeLines == tv.nodeLines
    check ListView(g.findComponent("lv")).itemLines == lv.itemLines
    check formToNfm(g) == text

  test "loadForm builds the same data":
    Application.init()
    let f = newLists()
    check f.tv.nodeLines == @["Root", "  Child", "Second"]
    check f.lv.itemLines == @["a\t1", "b\t2"]
    let r = loadNfmFile(here / "nfm" / "listdata.nfm")
    check TreeView(r.findComponent("tv")).nodeLines == f.tv.nodeLines

  test "Label/Panel font.color is stored (and the old textColor name still loads)":
    let f = newForm(nil, 100, 100)
    f.name = "F"
    let l = newLabel(f, "x")
    l.name = "l"
    l.fontColor = Color(r: 255, g: 0, b: 0, a: 255)
    check "font.color = #ff0000" in formToNfm(f).replace("#FF0000", "#ff0000")
    check "textColor" notin formToNfm(f)
    check Label(loadNfm(formToNfm(f)).findComponent("l")).fontColor == l.fontColor
    let old = loadNfm("object F: Form\n  object l: Label\n    textColor = #00ff00\n  end\nend\n")
    check Label(old.findComponent("l")).fontColor == hex"#00ff00"

suite "component references: action and popupMenu":
  Application.init()

  test "loadForm and loadNfm resolve them by name; formToNfm writes the names":
    let f = newRefs()
    check f.btn.popupMenu == f.pm
    check f.btn.action == f.doIt
    check f.miA.action == f.doIt
    let text = formToNfm(f)
    check "popupMenu = pm" in text and "action = doIt" in text
    check text.find("onClick") < 0
    let g = loadNfmFile(here / "nfm" / "refs.nfm")
    let b = Button(g.findComponent("btn"))
    check b.popupMenu == PopupMenu(g.findComponent("pm"))
    check b.action != nil and b.action == Action(g.findComponent("acts").findComponent("doIt"))
    check formToNfm(g) == text

  test "popupMenu plus a real onMouseUp handler: only the handler is a form event":
    let f = newForm(nil, 200, 200)
    f.name = "F"
    let pm = newPopupMenu(f)
    pm.name = "pm"
    let p = newPanel(f)
    p.name = "p"
    p.popupMenu = pm
    check p.onMouseUp == nil and p.onMouseDown == nil and p.onKeyDown == nil and p.onEnter == nil
    p.onMouseUp = proc(s: Control, b: MouseButton, sh: ShiftState, x, y: float32) = discard
    setHandlerName(Obj(p), "onMouseUp", "pUp")
    let text = formToNfm(f)
    check "popupMenu = pm" in text and "onMouseUp = pUp" in text
    for ev in ["onMouseDown", "onKeyDown", "onEnter"]:
      check ev notin text
    let g = loadNfm(text)
    check Panel(g.findComponent("p")).popupMenu == PopupMenu(g.findComponent("pm"))
    check formToNfm(g) == text

  test "the popupMenu property can be cleared":
    let f = newRefs()
    f.btn.popupMenu = nil
    check f.btn.popupMenu == nil
    check "popupMenu" notin formToNfm(f)
    check popupMenuOf(f.btn) == nil

suite "inspector: where object references come from":
  Application.init()

  test "onGetChoices overrides the walk up from the target":
    let f = newForm(nil, 300, 300)
    let il = newImageList(16, 16, f)
    il.name = "mine"
    let other = newImageList(16, 16, nil)
    other.name = "elsewhere"
    let tb = newToolBar(f)
    tb.name = "tb"
    let ins = newObjectInspector(newForm(nil, 300, 300))
    ins.onGetChoices = proc(s: Control, t: Obj, prop: string): seq[Obj] = @[Obj(other), Obj(tb)]
    ins.inspect(tb)
    check ins.beginEdit("images")
    check ins.editCombo.items.len == 2           # (none) + the ImageList; the ToolBar is filtered out
    check ins.editCombo.items[1] == "elsewhere"
