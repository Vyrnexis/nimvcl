# Phase 7a demo: a small text editor built from the stock controls and the
# `CodeEdit` control. A TreeView file tree on the left (lazy folders), a
# PageControl of CodeEdit tabs in the middle (a "•" in the caption marks a
# modified file; closing asks to save), a MainMenu, an ActionList with shortcuts
# shared by the menu and the ToolBar, and a StatusBar (line:column, INS/OVR,
# encoding and line ending, language).
#
# Keys: Ctrl+N new, Ctrl+O open, Ctrl+S save, Ctrl+Shift+S save as, Ctrl+W close
#       tab, Ctrl+F find, Ctrl+H replace, F3 / Shift+F3 next / previous match,
#       Ctrl+G go to line, Ctrl+/ comment, Ctrl+Shift+[ / ] fold / unfold,
#       Ctrl+K Ctrl+0 / Ctrl+K Ctrl+J fold / unfold all, Alt+Up / Alt+Down move
#       lines, Ctrl+D duplicate line, Insert overwrite. Click the gutter (left of
#       the numbers) to toggle a breakpoint.
#
# Usage: editor_demo [folder-or-file ...]      (default folder: the repo's src/)
#        editor_demo --shots dir               headless screenshots (PNG)
#
# Build: nim c --outdir:build examples/editor_demo.nim

import std/[os, strutils, algorithm]
import nimvcl

type
  FolderInfo = ref object of RootObj
    path: string
    isDir: bool

  EditorTab = ref object
    sheet: TabSheet
    code: CodeEdit
    untitled: int

var
  form: Form
  tabs: PageControl
  tree: TreeView
  status: StatusBar
  acts: ActionList
  icons: ImageList
  editors: seq[EditorTab]
  allActions: seq[Action]
  untitledCount = 0
  folderRoot: string
  shotMode = false
  actUndo, actRedo, actCut, actCopy, actPaste, actSave, actSaveAs, actClose: Action
  actFind, actReplace, actGoto, actFoldAll, actUnfoldAll, actComment: Action
  actWhitespace, actNumbers, actDark: Action

const
  IcFolder = 0
  IcFile = 1
  IcNim = 2

# ------------------------------------------------------------------ icons

type Pix = array[16, array[16, Color]]

proc fillBox(p: var Pix, x0, y0, x1, y1: int, c: Color) =
  for y in max(y0, 0) .. min(y1, 15):
    for x in max(x0, 0) .. min(x1, 15): p[y][x] = c

proc design(kind: int): Pix =
  if kind == IcFolder:
    let back = rgb(214, 160, 40)
    let front = rgb(246, 200, 80)
    let edge = rgb(150, 105, 20)
    result.fillBox(1, 3, 6, 5, edge)
    result.fillBox(2, 4, 6, 5, back)
    result.fillBox(1, 5, 14, 13, edge)
    result.fillBox(2, 6, 13, 12, front)
    result.fillBox(2, 6, 13, 6, rgb(255, 235, 170))
  else:
    let band = if kind == IcNim: rgb(240, 190, 40) else: rgb(80, 130, 210)
    result.fillBox(3, 1, 12, 14, rgb(150, 156, 170))
    result.fillBox(4, 2, 11, 13, rgb(250, 251, 253))
    result.fillBox(9, 1, 12, 4, Color())
    result.fillBox(9, 2, 11, 4, rgb(210, 214, 224))
    result.fillBox(8, 1, 8, 3, rgb(150, 156, 170))
    result.fillBox(4, 9, 11, 13, band)
    for y in [5, 7]: result.fillBox(5, y, 9, y, rgb(190, 196, 210))

proc makeIcon(kind, size: int): Image =
  let d = design(kind)
  let u = size div 16
  result = newImage(size, size)
  for y in 0 ..< 16:
    for x in 0 ..< 16:
      if d[y][x].a == 0: continue
      for dy in 0 ..< u:
        for dx in 0 ..< u: result.setPixel(x * u + dx, y * u + dy, d[y][x])

proc buildIcons() =
  icons = newImageList(16, 16)
  for k in [IcFolder, IcFile, IcNim]: icons.add makeIcon(k, 32)

proc glyph(kind: string): GlyphProc =
  result = proc(c: Canvas, r: RectF, col: Color) =
    let cx = r.x + r.w / 2
    let cy = r.y + r.h / 2
    case kind
    of "new":
      c.strokeRoundRect(rectF(cx - 6, cy - 8, 12, 16), 2, col, 1.5)
      c.line(cx - 3, cy - 1, cx + 3, cy - 1, col, 1.5)
      c.line(cx - 3, cy + 3, cx + 3, cy + 3, col, 1.5)
    of "open":
      c.strokeRoundRect(rectF(cx - 8, cy - 4, 16, 11), 2, col, 1.5)
      c.line(cx - 8, cy - 4, cx - 3, cy - 7, col, 1.5)
      c.line(cx - 3, cy - 7, cx + 1, cy - 7, col, 1.5)
    of "save":
      c.strokeRoundRect(rectF(cx - 7, cy - 7, 14, 14), 2, col, 1.5)
      c.fillRect(rectF(cx - 4, cy - 7, 8, 5), col)
      c.strokeRoundRect(rectF(cx - 4, cy + 1, 8, 5), 1, col, 1.2)
    of "undo", "redo":
      let s = if kind == "undo": 1'f32 else: -1'f32
      c.line(cx - 6 * s, cy - 2, cx - 6 * s + 4 * s, cy - 6, col, 1.5)
      c.line(cx - 6 * s, cy - 2, cx - 6 * s + 4 * s, cy + 2, col, 1.5)
      c.line(cx - 6 * s, cy - 2, cx + 3 * s, cy - 2, col, 1.5)
      c.line(cx + 3 * s, cy - 2, cx + 6 * s, cy + 1, col, 1.5)
      c.line(cx + 6 * s, cy + 1, cx + 3 * s, cy + 5, col, 1.5)
      c.line(cx + 3 * s, cy + 5, cx - 2 * s, cy + 5, col, 1.5)
    of "find":
      c.strokeEllipse(rectF(cx - 6, cy - 6, 10, 10), col, 1.6)
      c.line(cx + 2, cy + 2, cx + 7, cy + 7, col, 2)
    of "fold":
      c.line(cx - 6, cy - 5, cx + 6, cy - 5, col, 1.5)
      c.line(cx - 6, cy + 5, cx + 6, cy + 5, col, 1.5)
      c.line(cx - 3, cy - 1, cx, cy + 2, col, 1.5)
      c.line(cx, cy + 2, cx + 3, cy - 1, col, 1.5)
    else: discard

# ----------------------------------------------------------------- helpers

func isNimFile(path: string): bool = splitFile(path).ext.toLowerAscii in [".nim", ".nims", ".nimble"]

proc current(): EditorTab =
  let sh = if tabs == nil: nil else: tabs.activePage
  for e in editors:
    if e.sheet == sh: return e

proc displayName(e: EditorTab): string =
  if e.code.fileName.len > 0: e.code.fileName.extractFilename
  else: "Untitled-" & $e.untitled

proc refreshCaption(e: EditorTab) =
  e.sheet.caption = e.displayName & (if e.code.modified: " •" else: "")
  if e == current():
    let f = if e.code.fileName.len > 0: e.code.fileName else: e.displayName
    form.caption = f & (if e.code.modified: " •" else: "") & " - nimvcl editor"

proc updateStatus() =
  let e = current()
  if e == nil:
    for p in status.panels: p.text = ""
    return
  let c = e.code
  status.panels[0].text = if c.fileName.len > 0: c.fileName else: "Untitled"
  status.panels[1].text = "Ln " & $(c.caretLine + 1) & ", Col " &
    $(visualCol(c.lineAt(c.caretLine), c.caretCol, c.tabWidth) + 1)
  status.panels[2].text = if c.overwrite: "OVR" else: "INS"
  status.panels[3].text = c.encoding & "  " & (if c.lineEnding == leCRLF: "CRLF" else: "LF")
  status.panels[4].text = case c.language
                          of "nim": "Nim"
                          else: "Plain text"

proc applyViewOptions(c: CodeEdit) =
  c.showWhitespace = actWhitespace != nil and actWhitespace.checked
  c.showLineNumbers = actNumbers == nil or actNumbers.checked

proc newEditor(path = ""): EditorTab =
  result = EditorTab()
  let e = result
  e.sheet = newTabSheet(tabs, "")
  e.code = newCodeEdit(e.sheet)
  e.code.align = alClient
  e.code.markerColumn = true
  e.code.applyViewOptions()
  if path.len == 0:
    inc untitledCount
    e.untitled = untitledCount
    e.code.language = "nim"
  else:
    discard e.code.loadFromFile(path)
  if e.code.language == "nim": e.code.tabWidth = 2     # Nim code is indented by two
  e.code.onModifiedChanged = proc(s: Control) = e.refreshCaption()
  e.code.onCaretMove = proc(s: Control, l, c: int) = updateStatus()
  e.code.onOverwriteChange = proc(s: Control) = updateStatus()
  e.code.onChange = proc(s: Control) = updateStatus()
  e.code.onGutterClick = proc(s: Control, line: int, area: GutterArea, b: MouseButton,
                              handled: var bool) =
    if area == gaMarkers:
      e.code.toggleMarker(line, mkBreakpoint)
      handled = true
  editors.add e
  tabs.activePage = e.sheet
  e.refreshCaption()
  e.code.setFocus()
  updateStatus()

proc openFile(path: string) =
  if not fileExists(path): return
  let full = path.absolutePath
  for e in editors:
    if e.code.fileName == full:
      tabs.activePage = e.sheet
      e.code.setFocus()
      return
  # an untouched "Untitled" tab is reused
  let cur = current()
  if cur != nil and cur.code.fileName.len == 0 and not cur.code.modified and cur.code.lineCount == 1 and
     cur.code.lineAt(0).len == 0:
    discard cur.code.loadFromFile(full)
    if cur.code.language == "nim": cur.code.tabWidth = 2
    cur.refreshCaption()
    updateStatus()
    return
  try: discard newEditor(full)
  except IOError as ex: showMessage("Cannot open " & full & ":\n" & ex.msg)

proc saveAs(e: EditorTab): bool

proc save(e: EditorTab): bool =
  if e.code.fileName.len == 0: return e.saveAs()
  try:
    e.code.saveToFile()
    e.refreshCaption()
    updateStatus()
    true
  except IOError as ex:
    showMessage("Cannot save " & e.code.fileName & ":\n" & ex.msg)
    false

proc saveAs(e: EditorTab): bool =
  let d = newSaveDialog(form)
  d.title = "Save as"
  d.filters = @[("Nim files", "nim"), ("All files", "*")]
  if e.code.fileName.len > 0: d.initialDir = e.code.fileName.parentDir
  elif folderRoot.len > 0: d.initialDir = folderRoot
  if not d.executeModal(): return false
  e.code.fileName = d.fileName
  e.save()

proc confirmClose(e: EditorTab): bool =
  ## True when the tab may be closed (saved, or discarded on request).
  if not e.code.modified: return true
  tabs.activePage = e.sheet
  case messageDlg("Save changes to " & e.displayName & "?", mtConfirmation,
                  {mbYes, mbNo, mbCancel})
  of mrYes: e.save()
  of mrNo: true
  else: false

proc closeEditor(e: EditorTab): bool =
  if not e.confirmClose(): return false
  editors.delete editors.find(e)
  e.sheet.free()
  if editors.len == 0: discard newEditor()
  updateStatus()
  true

# --------------------------------------------------------------- file tree

proc populate(n: TreeNode) =
  let info = FolderInfo(n.data)
  var dirs, files: seq[string]
  for kind, p in walkDir(info.path):
    let name = p.extractFilename
    if name.startsWith(".") or name in ["nimcache", "build"]: continue
    if kind in {pcDir, pcLinkToDir}: dirs.add name
    else: files.add name
  dirs.sort(cmpIgnoreCase)
  files.sort(cmpIgnoreCase)
  for name in dirs:
    let c = n.addChild(name)
    c.data = FolderInfo(path: info.path / name, isDir: true)
    c.imageIndex = IcFolder
    c.hasChildren = true
  for name in files:
    let c = n.addChild(name)
    c.data = FolderInfo(path: info.path / name, isDir: false)
    c.imageIndex = if isNimFile(name): IcNim else: IcFile

proc setFolder(path: string) =
  folderRoot = path.absolutePath
  tree.items.clear()
  let root = tree.items.addChild(nil, folderRoot.extractFilename)
  root.data = FolderInfo(path: folderRoot, isDir: true)
  root.imageIndex = IcFolder
  root.hasChildren = true
  root.expand()
  tree.selected = root

proc openSelectedNode() =
  let n = tree.selected
  if n != nil and n.data != nil:
    let info = FolderInfo(n.data)
    if not info.isDir: openFile(info.path)

# ----------------------------------------------------------------- actions

proc act(caption: string, key = "", run: ActionEvent = nil): Action =
  result = newAction(acts, caption, run, if key.len > 0: shortcut(key) else: noShortcut)
  allActions.add result

proc withEditor(run: proc(c: CodeEdit)): ActionEvent =
  result = proc(a: Action) =
    let e = current()
    if e != nil: run(e.code)

proc setTheme(dark: bool) =
  Application.theme = if dark: themeDark() else: themeLight()
  if actDark != nil: actDark.checked = dark

proc openFilesDialog() =
  let d = newOpenDialog(form)
  d.title = "Open files"
  d.multiSelect = true
  d.filters = @[("Nim files", "nim"), ("All files", "*")]
  if folderRoot.len > 0: d.initialDir = folderRoot
  d.execute(proc(ok: bool, files: seq[string]) =
    if ok:
      for f in files: openFile(f))

proc openFolderDialog() =
  let d = newSelectFolderDialog(form)
  d.title = "Open folder"
  if folderRoot.len > 0: d.initialDir = folderRoot
  d.execute(proc(ok: bool, files: seq[string]) =
    if ok and files.len > 0: setFolder(files[0]))

proc buildActions() =
  acts = newActionList(form)
  discard act("&New", "Ctrl+N", proc(a: Action) = discard newEditor())
  discard act("&Open...", "Ctrl+O", proc(a: Action) = openFilesDialog())
  discard act("Open &folder...", "Ctrl+Shift+O", proc(a: Action) = openFolderDialog())
  actSave = act("&Save", "Ctrl+S", proc(a: Action) =
    let e = current()
    if e != nil: discard e.save())
  actSaveAs = act("Save &as...", "Ctrl+Shift+S", proc(a: Action) =
    let e = current()
    if e != nil: discard e.saveAs())
  actClose = act("&Close tab", "Ctrl+W", proc(a: Action) =
    let e = current()
    if e != nil: discard e.closeEditor())
  actUndo = act("&Undo", "Ctrl+Z", withEditor(proc(c: CodeEdit) = c.undo()))
  actRedo = act("&Redo", "Ctrl+Y", withEditor(proc(c: CodeEdit) = c.redo()))
  actCut = act("Cu&t", "Ctrl+X", withEditor(proc(c: CodeEdit) = c.cutToClipboard()))
  actCopy = act("&Copy", "Ctrl+C", withEditor(proc(c: CodeEdit) = c.copyToClipboard()))
  actPaste = act("&Paste", "Ctrl+V", withEditor(proc(c: CodeEdit) = c.pasteFromClipboard()))
  actFind = act("&Find...", "Ctrl+F", withEditor(proc(c: CodeEdit) = c.showFindBar(false)))
  actReplace = act("&Replace...", "Ctrl+H", withEditor(proc(c: CodeEdit) = c.showFindBar(true)))
  actGoto = act("&Go to line...", "Ctrl+G", withEditor(proc(c: CodeEdit) = c.gotoLineDialog(c)))
  actComment = act("Toggle c&omment", "Ctrl+/", withEditor(proc(c: CodeEdit) = c.toggleComment()))
  actFoldAll = act("&Fold all", "", withEditor(proc(c: CodeEdit) = c.foldAll()))
  actUnfoldAll = act("&Unfold all", "", withEditor(proc(c: CodeEdit) = c.unfoldAll()))
  actWhitespace = act("Show &whitespace", "", proc(a: Action) =
    for e in editors: e.code.showWhitespace = a.checked)
  actWhitespace.autoCheck = true
  actNumbers = act("Line &numbers", "", proc(a: Action) =
    for e in editors: e.code.showLineNumbers = a.checked)
  actNumbers.autoCheck = true
  actNumbers.checked = true
  actDark = act("&Dark theme", "", proc(a: Action) = setTheme(a.checked))
  actDark.autoCheck = true
  # enable / disable from the state of the current editor
  actUndo.onUpdate = proc(a: Action) =
    let e = current()
    a.enabled = e != nil and e.code.canUndo
  actRedo.onUpdate = proc(a: Action) =
    let e = current()
    a.enabled = e != nil and e.code.canRedo
  actCut.onUpdate = proc(a: Action) =
    let e = current()
    a.enabled = e != nil and not e.code.readOnly
  actSave.onUpdate = proc(a: Action) =
    let e = current()
    a.enabled = e != nil and (e.code.modified or e.code.fileName.len == 0)

proc actionByCaption(caption: string): Action =
  for a in allActions:
    if a.caption == caption: return a

proc buildMenus() =
  let mm = newMainMenu(form)
  let file = mm.addItem("&File")
  for (cap, sep) in [("&New", false), ("&Open...", false), ("Open &folder...", true),
                     ("&Save", false), ("Save &as...", true), ("&Close tab", false)]:
    file.addItem(cap).action = actionByCaption(cap)
    if sep: file.addSeparator()
  file.addSeparator()
  file.addItem("E&xit", proc(s: MenuItem) = form.close(), shortcut("Ctrl+Q"))
  let edit = mm.addItem("&Edit")
  for (cap, sep) in [("&Undo", false), ("&Redo", true), ("Cu&t", false), ("&Copy", false),
                     ("&Paste", true), ("&Find...", false), ("&Replace...", false),
                     ("&Go to line...", true), ("Toggle c&omment", false)]:
    edit.addItem(cap).action = actionByCaption(cap)
    if sep: edit.addSeparator()
  let view = mm.addItem("&View")
  for cap in ["&Dark theme", "Show &whitespace", "Line &numbers"]:
    view.addItem(cap).action = actionByCaption(cap)
  view.addSeparator()
  for cap in ["&Fold all", "&Unfold all"]:
    view.addItem(cap).action = actionByCaption(cap)

proc buildToolBar() =
  let tb = newToolBar(form)
  tb.name = "toolbar"
  tb.images = nil
  template tool(cap, g: string) =
    let b = newToolButton(tb, "", tbsButton, glyph(g))
    b.action = actionByCaption(cap)
    b.showCaption = false
  tool("&New", "new")
  tool("&Open...", "open")
  tool("&Save", "save")
  discard newToolButton(tb, "", tbsDivider)
  tool("&Undo", "undo")
  tool("&Redo", "redo")
  discard newToolButton(tb, "", tbsDivider)
  tool("&Find...", "find")
  tool("&Fold all", "fold")

# ------------------------------------------------------------------- build

proc buildForm() =
  form = newForm(nil, 1180, 740)
  form.caption = "nimvcl editor"
  buildIcons()
  buildActions()
  buildMenus()
  buildToolBar()
  status = newStatusBar(form)
  status.addPanel("", 420)
  status.addPanel("", 110)
  status.addPanel("", 60)
  status.addPanel("", 130)
  status.addPanel("", 100, taRight)
  status.sizeGrip = true

  tree = newTreeView(form)
  tree.name = "tree"
  tree.align = alLeft
  tree.width = 250
  tree.margins = spacing(6, 6, 0, 6)
  tree.images = icons
  tree.showLines = false
  tree.onExpanding = proc(s: Control, n: TreeNode, allow: var bool) =
    if n.childCount == 0 and n.data != nil and FolderInfo(n.data).isDir: populate(n)
  tree.onDblClick = proc(s: Control) = openSelectedNode()
  tree.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
    if k == keyEnter and sh == {}:
      openSelectedNode()
      k = Key(0)
  let sp = newSplitter(form)
  sp.minSize = 120

  tabs = newPageControl(form)
  tabs.name = "tabs"
  tabs.align = alClient
  tabs.margins = spacing(0, 6, 6, 6)
  tabs.onChange = proc(s: Control) =
    let e = current()
    if e != nil:
      e.refreshCaption()
      e.code.setFocus()
    updateStatus()
  form.onCloseQuery = proc(f: Form, canClose: var bool) =
    for e in editors:
      if not e.confirmClose():
        canClose = false
        return

# ---------------------------------------------------------------- shots mode

proc shoot(dir, name: string) =
  discard form.paintIfDirty()
  Application.paintForms()
  let path = dir / (name & ".png")
  if not screenshotWithPopups(form, path): quit "screenshot failed for " & name
  echo "wrote ", path

proc lineOf(c: CodeEdit, prefix: string, from0 = 0): int =
  for i in from0 ..< c.lineCount:
    if c.lineAt(i).startsWith(prefix): return i
  -1

proc shots(dir: string, srcDir: string) =
  createDir dir
  shotMode = true
  Application.init()
  buildForm()
  form.show()
  form.syncMetrics()
  form.win.setLogicalSize(1180, 740)
  form.syncMetrics()
  setFolder(srcDir)
  # expand down to nimvcl/controls
  var n = tree.items.top(0)
  for part in ["nimvcl", "controls"]:
    for c in n.children:
      if c.text == part:
        c.expand()
        n = c
        break
  let path = srcDir / "nimvcl" / "controls" / "codecommands.nim"
  openFile(path)
  openFile(srcDir / "nimvcl" / "controls" / "folding.nim")
  for c in n.children:
    if c.text == "codecommands.nim": tree.selected = c
  tabs.activePageIndex = 0
  let ed = editors[0].code
  ed.gotoLine(lineOf(ed, "proc indentLines"), 0)
  ed.addMarker(lineOf(ed, "proc outdentLines"), mkBreakpoint)
  ed.addMarker(lineOf(ed, "proc toggleLineComment"), mkBookmark)
  ed.setFocus()
  let top = max(lineOf(ed, "proc indentLines") - 3, 0)
  ed.gotoLine(top + 8, 8)
  ed.scrollTo(0, float64(top) * ed.rowHeight)
  shoot(dir, "01-nim-light")
  setTheme(true)
  shoot(dir, "02-nim-dark")
  setTheme(false)
  # find bar with matches highlighted
  ed.showFindBar(false)
  discard ed.find("lines", SearchOptions(ignoreCase: true))
  shoot(dir, "03-find-light")
  setTheme(true)
  shoot(dir, "04-find-dark")
  setTheme(false)
  ed.hideFindBar()
  # find and replace
  ed.showFindBar(true)
  ed.findBar.replaceEdit.text = "rows"
  discard ed.find("first", SearchOptions(ignoreCase: true))
  shoot(dir, "05-replace")
  ed.hideFindBar()
  # folded regions
  ed.gotoLine(0)
  ed.foldAll()
  ed.toggleFold(lineOf(ed, "proc indentLines"))
  ed.toggleFold(lineOf(ed, "proc outdentLines"))
  shoot(dir, "06-folded")
  ed.unfoldAll()
  # a selection and whitespace
  let a = lineOf(ed, "proc toggleLineComment")
  ed.scrollTo(0, float64(a - 2) * ed.rowHeight)
  ed.showWhitespace = true
  ed.select((a + 3, 4), (a + 9, 20))
  shoot(dir, "07-selection-whitespace")
  ed.showWhitespace = false
  # the second tab
  tabs.activePageIndex = 1
  editors[1].code.gotoLine(40, 0)
  editors[1].code.setFocus()
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: form.win.id,
                                     text: "# edited: the tab shows a dot\n"))
  shoot(dir, "08-second-tab-dark".replace("dark", "light"))
  setTheme(true)
  shoot(dir, "09-second-tab-dark")
  Application.shutdown()

# -------------------------------------------------------------------- main

proc repoSrc(): string = currentSourcePath().parentDir.parentDir / "src"

proc main() =
  let args = commandLineParams()
  if args.len >= 1 and args[0] == "--shots":
    shots(if args.len >= 2: args[1] else: "build/editor_shots", repoSrc())
    return
  Application.init()
  buildForm()
  var folder = repoSrc()
  var files: seq[string]
  for a in args:
    if dirExists(a): folder = a
    elif fileExists(a): files.add a
  setFolder(folder)
  for f in files: openFile(f)
  if editors.len == 0: discard newEditor()
  updateStatus()
  Application.run(form)

main()
