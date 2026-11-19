## Property editor dialogs for the Object Inspector: the dialogs behind the
## "..." button of a string list, a picture, an image list or a collection
## (columns, status panels, menu items, pages, tool buttons).
##
## ```nim
## let host = newPropEditorHost(baseDir = "/my/project", imagesDir = "/my/project/images")
## host.onChanged = proc(target: Obj, prop: string) = markModified()
## attachEditors(inspector, host)         # sets inspector.onEditExtra
## ```
##
## * **String list** (`seq[string]`: `ListBox.items`, `ComboBox.items`,
##   `Memo.lines`, `TabControl.tabs`): `StringListDlgForm`, a memo with one
##   entry per line. `editStringList` runs it.
## * **Picture** (`Image`: `ImageControl.picture`, `ToolButton.image`):
##   `PictureDlgForm`, like Delphi's Picture Editor: a preview, "Load..." (a
##   file dialog for PNG/JPG/BMP...), "Clear", OK and Cancel. The picked file
##   goes through `host.importFile`, which returns the path that is stored in
##   the form file (see below), when the dialog is accepted (`commit`): a
##   cancelled dialog leaves the project untouched.
## * **Image list** (`ImageList.images`): `ImageListDlgForm`, a list with
##   thumbnails and Add (several files at once) / Delete / Up / Down; the
##   added files are imported on OK (`commit`).
## * **String grid cells** (`StringGrid.cells`): `StringGridDlgForm`, an
##   editable grid of the cells (type into it, Tab / arrows move, Ctrl+V pastes
##   a block) with Add / Delete row and column; OK also applies the new
##   `colCount` / `rowCount`.
## * **List and tree items** (`ListView.items`, `TreeView.items`):
##   `ItemsDlgForm`, like Delphi's Items Editor: the items with Add, Add child
##   (tree), Delete, Up, Down, Indent / Outdent (tree), and for the selected
##   item its caption, sub-items (list), image index, selected image index
##   (tree) and check state. OK applies `items`, `itemImages`,
##   `itemSelectedImages` and `checkedItems` together.
## * **Collection** (`pkCollection`): `CollectionDlgForm`, the list of items
##   with Add / Delete / Up / Down and an Object Inspector for the selected
##   item (which itself offers these editors, so a menu item's sub-items
##   work). It edits the live objects; `host.onItemAdded` lets the application
##   name a new item, `host.onChanged` reports every change.
##
## ## Where pictures live
##
## A form file stores `picture = 'images/logo.png'`: a path relative to
## `host.baseDir` (the folder of the `.nfm`). `importFile` turns a picked file
## into such a path: a file inside `baseDir` is just made relative; any other
## file is copied into `host.imagesDir` (default `baseDir/images`, a number is
## appended when the name is taken) first. An application can replace
## `importFile`.
##
## ## Testing
##
## The dialogs are plain forms: tests build one (`newPictureDlg`, ...), call its
## procs (`loadFile`, `addFiles`, `clearPicture`, `commit`, ...) and read the
## result (`picked`, `result`) without showing anything. `host.runModal` is what
## `attachEditors` uses to run a dialog (default `showModal`); a test replaces
## it to drive the dialog.
##
## Not part of the `import nimvcl` umbrella: `import nimvcl/controls/propeditors`.

import std/[os, strutils, sequtils]
import ../graphics/[color, geometry, canvas, image]
import ../core/[types, component, control, form, theme]
import ../dsl/[formmacro, props_std]
import ./[common, label, button, edit, memo, listbox, imagectl, dialogs, inspector,
          grids, listview, treeview, spinedit, checkbox, viewsupport]
export props_std

type
  PropEditorHost* = ref object
    ## What the editors need from the application.
    baseDir*: string
      ## Image paths of the form are relative to this folder (the `.nfm`'s).
    imagesDir*: string
      ## Where a picked file from outside `baseDir` is copied (default
      ## `baseDir/images`).
    importFile*: proc(path: string): string {.closure.}
      ## A picked file -> the path stored in the form (raises on failure).
      ## Default: `importPicture(host, path)`.
    onChanged*: proc(target: Obj, prop: string) {.closure.}
      ## A value was changed by an editor (`prop` is the property name; for a
      ## collection item the edited property of the item, or the collection's
      ## name when items were added, removed or moved).
    onItemAdded*: proc(parent, item: Obj) {.closure.}
      ## A collection editor created `item`: name it, make it known.
    onItemRemoved*: proc(parent, item: Obj) {.closure.}
      ## Called before a collection editor removes `item`.
    runModal*: proc(d: Form): ModalResult {.closure.}
      ## Runs a dialog (default `showModal` + `freeWindow`).

const
  ImageFilters* = @[("Images", "png;jpg;jpeg;bmp;gif"), ("All files", "*")]
  Pad = 14'f32
  Gap = 8'f32
  BtnH = 28'f32
  BtnW = 88'f32

# ------------------------------------------------------------------- host

proc fullPath(host: PropEditorHost, path: string): string =
  if path.isAbsolute: path
  elif host != nil and host.baseDir.len > 0: host.baseDir / path
  else: path

proc importPicture*(host: PropEditorHost, path: string): string =
  ## The default `importFile`; see the module comment. Raises `IOError` when
  ## the file cannot be copied.
  let abs = absolutePath(path).normalizedPath
  if host == nil or host.baseDir.len == 0: return path
  let base = absolutePath(host.baseDir).normalizedPath
  # `isRelativeTo` says yes for a file on another drive (Windows), where
  # `relativePath` just returns the absolute path back
  let rel = relativePath(abs, base, '/')
  if not rel.isAbsolute and rel != ".." and not rel.startsWith("../"):
    return rel
  let dir = if host.imagesDir.len > 0: host.imagesDir else: base / "images"
  createDir dir
  let (_, name, ext) = splitFile(abs)
  var dest = dir / (name & ext)
  var n = 1
  while fileExists(dest):
    if readFile(dest) == readFile(abs): break      # the same picture is already there
    dest = dir / (name & "_" & $n & ext)
    inc n
  if not fileExists(dest): copyFile(abs, dest)
  relativePath(absolutePath(dest).normalizedPath, base, '/')

proc showAndFree(d: Form): ModalResult =
  ## Runs a dialog modally and releases its window.
  result = d.showModal()
  d.freeWindow()

proc newPropEditorHost*(baseDir = "", imagesDir = ""): PropEditorHost =
  result = PropEditorHost(baseDir: baseDir, imagesDir: imagesDir)
  let h = result
  result.importFile = proc(path: string): string = importPicture(h, path)
  result.runModal = showAndFree

proc readPicture(host: PropEditorHost, path: string): Image =
  ## Loads the picture at `path` without storing it in the project: its `source`
  ## is `path` until `importPicked` moves it.
  result = loadImage(host.fullPath(path))
  result.source = path

proc importPicked(host: PropEditorHost, img: Image) =
  ## Stores the file of a picture read by `readPicture` (see `importFile`) and
  ## makes the stored path its `source`. Raises `IOError`.
  if host != nil and host.importFile != nil: img.source = host.importFile(img.source)

proc loadPicture*(host: PropEditorHost, path: string): Image =
  ## Imports `path` (see `importFile`) and loads it; the image's `source` is
  ## the stored path. Raises `ImageError` / `IOError`.
  let stored = if host != nil and host.importFile != nil: host.importFile(path) else: path
  result = readPicture(host, stored)

proc changed(host: PropEditorHost, target: Obj, prop: string) =
  if host != nil and host.onChanged != nil: host.onChanged(target, prop)

# ------------------------------------------------------------ string list

form StringListDlgForm:
  borderStyle = bsSingle
  position = poScreenCenter
  Label hintLbl:
    caption = "One entry per line"
    muted = true
  Memo memo:
    wantReturns = true
    wantTabs = false
  Button okBtn:
    caption = "OK"
    modalResult = mrOk
  Button cancelBtn:
    caption = "Cancel"
    isCancel = true
    modalResult = mrCancel
  proc fit(self: StringListDlgForm) =
    let w = 380'f32
    let h = 360'f32
    self.hintLbl.setBounds(Pad, Pad, w - 2 * Pad, 18)
    self.memo.setBounds(Pad, Pad + 24, w - 2 * Pad, h - 2 * Pad - 24 - BtnH - Gap * 2)
    let by = h - Pad - BtnH
    self.cancelBtn.setBounds(w - Pad - BtnW, by, BtnW, BtnH)
    self.okBtn.setBounds(w - Pad - 2 * BtnW - Gap, by, BtnW, BtnH)
    self.setBounds(self.left, self.top, w, h)

proc linesOf*(d: StringListDlgForm): seq[string] =
  ## The entries as typed: one per line (a final line break adds nothing).
  var t = d.memo.text
  if t.len == 0: return @[]
  if t.endsWith("\n"): t.setLen(t.len - 1)
  t.splitLines

proc newStringListDlg*(title: string, lines: seq[string]): StringListDlgForm =
  ## The dialog without showing it.
  result = newStringListDlgForm()
  result.caption = title
  result.memo.text = lines.join("\n")
  result.fit()

proc editStringList*(title: string, lines: var seq[string],
                     run: proc(d: Form): ModalResult = nil): bool =
  ## Runs the dialog; true (and `lines` replaced) when OK was pressed.
  let d = newStringListDlg(title, lines)
  let r = if run != nil: run(d) else: showAndFree(d)
  if r == mrOk:
    lines = d.linesOf
    result = true

# ---------------------------------------------------------------- picture

form PictureDlgForm:
  borderStyle = bsSingle
  position = poScreenCenter
  var peHost: PropEditorHost
  var picked: Image
  var pickedNew = false         ## `picked` was read from a file that is not in the project yet
  var fileDlg: OpenDialog
  var error = ""
  ImageControl preview:
    proportional = true
    center = true
    transparent = false
  Label pathLbl:
    caption = "(none)"
    muted = true
  Button loadBtn:
    caption = "Load..."
  Button clearBtn:
    caption = "Clear"
  Button okBtn:
    caption = "OK"
    isDefault = true
    modalResult = mrOk
  Button cancelBtn:
    caption = "Cancel"
    isCancel = true
    modalResult = mrCancel
  proc fit(self: PictureDlgForm) =
    let w = 420'f32
    let h = 400'f32
    self.preview.setBounds(Pad, Pad, w - 2 * Pad, h - Pad * 2 - BtnH * 2 - Gap * 3 - 18)
    self.pathLbl.setBounds(Pad, self.preview.top + self.preview.height + Gap, w - 2 * Pad, 18)
    let by = h - Pad - BtnH
    self.loadBtn.setBounds(Pad, by, BtnW, BtnH)
    self.clearBtn.setBounds(Pad + BtnW + Gap, by, BtnW, BtnH)
    self.cancelBtn.setBounds(w - Pad - BtnW, by, BtnW, BtnH)
    self.okBtn.setBounds(w - Pad - 2 * BtnW - Gap, by, BtnW, BtnH)
    self.setBounds(self.left, self.top, w, h)

proc refreshView(d: PictureDlgForm) =
  d.preview.picture = d.picked
  d.pathLbl.caption =
    if d.error.len > 0: d.error
    elif d.picked == nil: "(none)"
    elif d.picked.source.len > 0: d.picked.source
    else: "(image)"

proc loadFile*(d: PictureDlgForm, path: string): bool {.discardable.} =
  ## Picks `path`; false, with `error` set, when it cannot be loaded as an
  ## image. The file is stored in the project by `commit`, not yet.
  try:
    d.picked = readPicture(d.peHost, path)
    d.pickedNew = true
    d.error = ""
    result = true
  except CatchableError as e:
    d.error = "cannot load: " & e.msg
  d.refreshView()

proc clearPicture*(d: PictureDlgForm) =
  ## "Clear": the picture becomes empty.
  d.picked = nil
  d.pickedNew = false
  d.error = ""
  d.refreshView()

proc commit*(d: PictureDlgForm): Image =
  ## After OK: stores a newly picked file in the project (the host's
  ## `importFile`) and returns the picture to assign. Raises `IOError`.
  if d.pickedNew:
    d.peHost.importPicked(d.picked)
    d.pickedNew = false
    d.refreshView()
  d.picked

proc pickFile*(d: PictureDlgForm) =
  ## "Load...": the file dialog; the chosen file is loaded when it reports.
  if d.fileDlg == nil:
    d.fileDlg = newOpenDialog(d)
    d.fileDlg.title = "Load picture"
    d.fileDlg.filters = ImageFilters
  if d.peHost != nil and d.peHost.baseDir.len > 0 and d.fileDlg.initialDir.len == 0:
    d.fileDlg.initialDir = d.peHost.baseDir
  d.fileDlg.execute(proc(ok: bool, files: seq[string]) =
    if ok and files.len > 0: d.loadFile(files[0]))

proc newPictureDlg*(host: PropEditorHost, current: Image,
                    title = "Picture"): PictureDlgForm =
  ## The dialog without showing it; `picked` is the current picture until
  ## changed.
  result = newPictureDlgForm()
  let d = result
  d.caption = title
  d.peHost = host
  d.picked = current
  d.fit()
  d.loadBtn.onClick = proc(s: Control) = d.pickFile()
  d.clearBtn.onClick = proc(s: Control) = d.clearPicture()
  d.refreshView()

# -------------------------------------------------------------- image list

const ThumbRow = 44'f32

form ImageListDlgForm:
  borderStyle = bsSingle
  position = poScreenCenter
  var peHost: PropEditorHost
  var imgs: seq[Image]
  var added: seq[Image]         ## pictures in `imgs` read from files that are not in the project yet
  var iw = 16'f32
  var ih = 16'f32
  var fileDlg: OpenDialog
  var errors: seq[string]
  Label infoLbl:
    muted = true
  ListBox list:
    style = lbOwnerDraw
    itemHeight = ThumbRow
  Button addBtn:
    caption = "Add..."
  Button delBtn:
    caption = "Delete"
  Button upBtn:
    caption = "Up"
  Button downBtn:
    caption = "Down"
  Button okBtn:
    caption = "OK"
    modalResult = mrOk
  Button cancelBtn:
    caption = "Cancel"
    isCancel = true
    modalResult = mrCancel
  proc fit(self: ImageListDlgForm) =
    let w = 460'f32
    let h = 420'f32
    self.infoLbl.setBounds(Pad, Pad, w - 2 * Pad, 18)
    let bx = w - Pad - BtnW
    self.list.setBounds(Pad, Pad + 24, bx - Pad - Gap, h - Pad * 2 - 24 - BtnH - Gap * 2)
    var y = Pad + 24
    for b in [self.addBtn, self.delBtn, self.upBtn, self.downBtn]:
      b.setBounds(bx, y, BtnW, BtnH)
      y += BtnH + Gap
    let by = h - Pad - BtnH
    self.cancelBtn.setBounds(w - Pad - BtnW, by, BtnW, BtnH)
    self.okBtn.setBounds(w - Pad - 2 * BtnW - Gap, by, BtnW, BtnH)
    self.setBounds(self.left, self.top, w, h)

proc nameOf(d: ImageListDlgForm, i: int): string =
  let img = d.imgs[i]
  $i & ": " & (if img != nil and img.source.len > 0: img.source else: "(image)")

proc syncButtons(d: ImageListDlgForm) =
  d.delBtn.enabled = d.list.itemIndex >= 0
  d.upBtn.enabled = d.list.itemIndex > 0
  d.downBtn.enabled = d.list.itemIndex in 0 ..< d.imgs.high

proc syncList(d: ImageListDlgForm, select = -2) =
  let keep = if select == -2: d.list.itemIndex else: select
  var names: seq[string]
  for i in 0 ..< d.imgs.len: names.add d.nameOf(i)
  d.list.items = names
  d.list.itemIndex = if d.imgs.len == 0: -1 else: clamp(keep, 0, d.imgs.high)
  d.infoLbl.caption = $d.imgs.len & " image(s), shown at " & $int(d.iw) & " x " & $int(d.ih)
  d.syncButtons()
  d.list.invalidate()

proc addFiles*(d: ImageListDlgForm, paths: openArray[string]): int {.discardable.} =
  ## Appends the images of `paths` (stored in the project by `commit`); files
  ## that cannot be loaded are skipped and listed in `errors`. Returns how many
  ## were added.
  for p in paths:
    try:
      let img = readPicture(d.peHost, p)
      d.imgs.add img
      d.added.add img
      inc result
    except CatchableError as e:
      d.errors.add p & ": " & e.msg
  d.syncList(if result > 0: d.imgs.high else: -2)

proc deleteSelected*(d: ImageListDlgForm) =
  let i = d.list.itemIndex
  if i in 0 ..< d.imgs.len:
    d.imgs.delete(i)
    d.syncList(i)

proc moveSelected*(d: ImageListDlgForm, delta: int) =
  ## Moves the selected image up (-1) or down (+1).
  let i = d.list.itemIndex
  let j = i + delta
  if i in 0 ..< d.imgs.len and j in 0 ..< d.imgs.len:
    swap(d.imgs[i], d.imgs[j])
    d.syncList(j)

proc commit*(d: ImageListDlgForm): seq[Image] =
  ## After OK: stores the added files that are still in the list in the project
  ## (the host's `importFile`) and returns the images to assign. Raises `IOError`.
  for img in d.imgs:
    if img in d.added: d.peHost.importPicked(img)
  d.added.setLen 0
  d.imgs

proc pickFiles*(d: ImageListDlgForm) =
  ## "Add...": the file dialog (several files); they are added when it reports.
  if d.fileDlg == nil:
    d.fileDlg = newOpenDialog(d)
    d.fileDlg.title = "Add images"
    d.fileDlg.filters = ImageFilters
    d.fileDlg.multiSelect = true
  if d.peHost != nil and d.peHost.baseDir.len > 0 and d.fileDlg.initialDir.len == 0:
    d.fileDlg.initialDir = d.peHost.baseDir
  d.fileDlg.execute(proc(ok: bool, files: seq[string]) =
    if ok: d.addFiles(files))

proc drawRow(d: ImageListDlgForm, cv: Canvas, index: int, rect: RectF,
             state: ItemStates) =
  let t = d.theme
  if isSelected in state: cv.fillRect(rect, t.selection)
  elif isHot in state: cv.fillRect(rect, t.hover)
  if index notin 0 ..< d.imgs.len: return
  let img = d.imgs[index]
  # the thumbnail: the image shown into the list's icon size, kept in the row
  let box = rectF(rect.x + 6, rect.y + 4, ThumbRow - 8, ThumbRow - 8)
  cv.fillRect(box, t.surface)
  if img != nil:
    let s = min(box.w / max(d.iw, 1), box.h / max(d.ih, 1))
    let w = d.iw * s
    let h = d.ih * s
    cv.drawImage(img, rectF(box.x + (box.w - w) / 2, box.y + (box.h - h) / 2, w, h))
  cv.strokeRoundRect(box, 0, t.border, 1)
  cv.textRect(d.nameOf(index), d.font,
              rectF(box.right + 8, rect.y, rect.w - box.w - 20, rect.h),
              if isSelected in state: t.selectionText else: t.text, taLeft, vaCenter)

proc newImageListDlg*(host: PropEditorHost, images: seq[Image], width, height: float32,
                      title = "Image list"): ImageListDlgForm =
  ## The dialog without showing it; `imgs` is a working copy of `images`.
  result = newImageListDlgForm()
  let d = result
  d.caption = title
  d.peHost = host
  d.imgs = images
  d.iw = width
  d.ih = height
  d.fit()
  d.list.onDrawItem = proc(s: Control, cv: Canvas, index: int, rect: RectF,
                           state: ItemStates) = d.drawRow(cv, index, rect, state)
  d.list.onChange = proc(s: Control) = d.syncButtons()
  d.addBtn.onClick = proc(s: Control) = d.pickFiles()
  d.delBtn.onClick = proc(s: Control) = d.deleteSelected()
  d.upBtn.onClick = proc(s: Control) = d.moveSelected(-1)
  d.downBtn.onClick = proc(s: Control) = d.moveSelected(1)
  d.syncList(0)


# ------------------------------------------------------------ grid cells

form StringGridDlgForm:
  borderStyle = bsSizeable
  position = poScreenCenter
  Label hintLbl:
    caption = "Type into the cells"
    muted = true
  StringGrid grid:
    options = {goColSizing, goRangeSelect, goEditing, goTabs}
  Button addRowBtn:
    caption = "Add row"
  Button delRowBtn:
    caption = "Delete row"
  Button addColBtn:
    caption = "Add column"
  Button delColBtn:
    caption = "Delete column"
  Button okBtn:
    caption = "OK"
    modalResult = mrOk
  Button cancelBtn:
    caption = "Cancel"
    isCancel = true
    modalResult = mrCancel
  proc fit(self: StringGridDlgForm) =
    let w = 640'f32
    let h = 440'f32
    self.hintLbl.setBounds(Pad, Pad, w - 2 * Pad, 18)
    let bx = w - Pad - BtnW - 20
    self.grid.setBounds(Pad, Pad + 24, bx - Pad - Gap, h - Pad * 2 - 24 - BtnH - Gap * 2)
    var y = Pad + 24
    for b in [self.addRowBtn, self.delRowBtn, self.addColBtn, self.delColBtn]:
      b.setBounds(bx, y, BtnW + 20, BtnH)
      y += BtnH + Gap
    let by = h - Pad - BtnH
    self.cancelBtn.setBounds(w - Pad - BtnW, by, BtnW, BtnH)
    self.okBtn.setBounds(w - Pad - 2 * BtnW - Gap, by, BtnW, BtnH)
    self.setBounds(self.left, self.top, w, h)

proc cellsOf*(d: StringGridDlgForm): seq[string] =
  ## The cells as typed, in the form `StringGrid.cells` stores them (an edit in
  ## progress is committed first).
  d.grid.endEdit(true)
  d.grid.cellLines

proc colCountOf*(d: StringGridDlgForm): int = d.grid.colCount
proc rowCountOf*(d: StringGridDlgForm): int = d.grid.rowCount

proc addRow*(d: StringGridDlgForm) =
  ## Appends an empty row (below the current one when it is not the last).
  d.grid.endEdit(true)
  let at = if d.grid.row >= d.grid.fixedRows and d.grid.row < d.grid.rowCount - 1:
             d.grid.row + 1 else: d.grid.rowCount
  d.grid.insertRow(at)
  d.grid.row = min(at, d.grid.rowCount - 1)

proc deleteRow*(d: StringGridDlgForm) =
  ## Removes the current row (a fixed row cannot be removed).
  d.grid.endEdit(false)
  d.grid.deleteRow(d.grid.row)

proc addColumn*(d: StringGridDlgForm) =
  d.grid.endEdit(true)
  d.grid.colCount = d.grid.colCount + 1

proc deleteColumn*(d: StringGridDlgForm) =
  ## Removes the current column (cells to its right move left).
  d.grid.endEdit(false)
  let c = d.grid.col
  if c < d.grid.fixedCols or c >= d.grid.colCount: return
  for r in 0 ..< d.grid.rowCount:
    for k in c ..< d.grid.colCount - 1:
      d.grid.cells[k, r] = d.grid.cells[k + 1, r]
  d.grid.colCount = d.grid.colCount - 1

proc newStringGridDlg*(colCount, rowCount, fixedCols, fixedRows: int, cells: seq[string],
                       colWidths = "", title = "String grid"): StringGridDlgForm =
  ## The dialog without showing it; the grid is a working copy.
  result = newStringGridDlgForm()
  let d = result
  d.caption = title
  d.fit()
  d.grid.colCount = colCount
  d.grid.rowCount = rowCount
  d.grid.fixedCols = fixedCols
  d.grid.fixedRows = fixedRows
  d.grid.colWidthsText = colWidths
  d.grid.cellLines = cells
  d.addRowBtn.onClick = proc(s: Control) = d.addRow()
  d.delRowBtn.onClick = proc(s: Control) = d.deleteRow()
  d.addColBtn.onClick = proc(s: Control) = d.addColumn()
  d.delColBtn.onClick = proc(s: Control) = d.deleteColumn()

# ------------------------------------------------------------ item lists

type
  ItemRec* = object
    ## One item of the items editor.
    text*: string
    subs*: seq[string]          ## ListView sub-items
    image*, selImage*: int      ## -1: none
    checked*: bool
    level*: int                 ## TreeView nesting (0: top level)

proc parseItemRecs*(tree: bool, lines, images, selImages, checked: seq[string]): seq[ItemRec] =
  ## The items of a ListView (`tree` false) or TreeView from the property
  ## values `items`, `itemImages`, `itemSelectedImages` and `checkedItems`.
  for l in lines:
    var r = ItemRec(image: -1, selImage: -1)
    if tree:
      var depth = 0
      while depth * 2 + 1 < l.len and l[depth * 2] == ' ' and l[depth * 2 + 1] == ' ': inc depth
      r.level = min(depth, if result.len == 0: 0 else: result[^1].level + 1)
      r.text = l[depth * 2 .. ^1]
    else:
      let p = l.split('\t')
      r.text = p[0]
      r.subs = p[1 .. ^1]
    result.add r
  let img = parseImageIndexLines(images, result.len)
  let sel = parseImageIndexLines(selImages, result.len)
  let chk = parseIndexLines(checked, result.len)
  for i in 0 ..< result.len:
    result[i].image = img[i]
    result[i].selImage = sel[i]
    result[i].checked = i in chk

func itemLinesOf*(tree: bool, recs: seq[ItemRec]): seq[string] =
  for r in recs:
    result.add (if tree: repeat("  ", r.level) & r.text else: r.text & r.subs.mapIt('\t' & it).join)

func imagesOf*(recs: seq[ItemRec], selected = false): seq[string] =
  imageIndexLines(recs.mapIt(if selected: it.selImage else: it.image))

func checkedOf*(recs: seq[ItemRec]): seq[string] =
  var v: seq[int]
  for i, r in recs:
    if r.checked: v.add i
  indexLines(v)

form ItemsDlgForm:
  borderStyle = bsSingle
  position = poScreenCenter
  var tree = false
  var recs: seq[ItemRec]
  var syncing = false           ## the controls are being refilled: their change events are ignored
  ListBox list:
    multiSelect = false
  Button addBtn:
    caption = "Add"
  Button childBtn:
    caption = "Add child"
  Button delBtn:
    caption = "Delete"
  Button upBtn:
    caption = "Up"
  Button downBtn:
    caption = "Down"
  Button inBtn:
    caption = "Indent"
  Button outBtn:
    caption = "Outdent"
  Label capLbl:
    caption = "Caption"
  Edit capEdit:
    discard
  Label subLbl:
    caption = "Sub-items (one per line)"
  Memo subMemo:
    wantReturns = true
  Label imgLbl:
    caption = "Image index"
  SpinEdit imgSpin:
    minValue = -1
    maxValue = 9999
  Label selLbl:
    caption = "Selected image index"
  SpinEdit selSpin:
    minValue = -1
    maxValue = 9999
  CheckBox chkBox:
    caption = "Checked"
  Button okBtn:
    caption = "OK"
    modalResult = mrOk
  Button cancelBtn:
    caption = "Cancel"
    isCancel = true
    modalResult = mrCancel
  proc fit(self: ItemsDlgForm) =
    let w = 640'f32
    let h = 440'f32
    let lw = 250'f32
    let bw = (lw - Gap * 2) / 3
    self.list.setBounds(Pad, Pad, lw, h - Pad * 3 - BtnH * 3 - Gap * 3)
    var y = Pad + self.list.height + Gap
    var x = Pad
    for b in [self.addBtn, self.childBtn, self.delBtn]:
      b.setBounds(x, y, bw, BtnH)
      x += bw + Gap
    y += BtnH + Gap
    x = Pad
    for b in [self.upBtn, self.downBtn, self.inBtn, self.outBtn]:
      b.setBounds(x, y, (lw - Gap * 3) / 4, BtnH)
      x += (lw - Gap * 3) / 4 + Gap
    let rx = Pad * 2 + lw
    let rw = w - rx - Pad
    y = Pad
    self.capLbl.setBounds(rx, y, rw, 18)
    self.capEdit.setBounds(rx, y + 20, rw, 26)
    y += 56
    if self.tree:
      self.subLbl.visible = false
      self.subMemo.visible = false
    else:
      self.subLbl.setBounds(rx, y, rw, 18)
      self.subMemo.setBounds(rx, y + 20, rw, 120)
      y += 150
    self.imgLbl.setBounds(rx, y, rw / 2, 18)
    self.imgSpin.setBounds(rx, y + 20, 100, 26)
    if self.tree:
      self.selLbl.setBounds(rx + 120, y, rw - 120, 18)
      self.selSpin.setBounds(rx + 120, y + 20, 100, 26)
      y += 56
    else:
      self.selLbl.visible = false
      self.selSpin.visible = false
      y += 56
    self.chkBox.setBounds(rx, y, 160, 24)
    let by = h - Pad - BtnH
    self.cancelBtn.setBounds(w - Pad - BtnW, by, BtnW, BtnH)
    self.okBtn.setBounds(w - Pad - 2 * BtnW - Gap, by, BtnW, BtnH)
    self.setBounds(self.left, self.top, w, h)

func blockEnd(d: ItemsDlgForm, i: int): int =
  ## One past the last row of the subtree of row `i`.
  result = i + 1
  while result < d.recs.len and d.recs[result].level > d.recs[i].level: inc result

proc itemLabel(d: ItemsDlgForm, r: ItemRec): string =
  repeat("  ", r.level) & (if r.text.len > 0: r.text else: "(empty)")

proc selectedIndex*(d: ItemsDlgForm): int =
  ## The selected row (-1: none).
  if d.list.itemIndex in 0 ..< d.recs.len: d.list.itemIndex else: -1

proc syncDetails(d: ItemsDlgForm) =
  let i = d.selectedIndex
  d.syncing = true
  for c in [Control(d.capEdit), d.subMemo, d.imgSpin, d.selSpin, d.chkBox, d.delBtn]:
    c.enabled = i >= 0
  d.childBtn.enabled = d.tree
  if i >= 0:
    let r = d.recs[i]
    d.capEdit.text = r.text
    d.subMemo.text = r.subs.join("\n")
    d.imgSpin.value = r.image
    d.selSpin.value = r.selImage
    d.chkBox.checked = r.checked
  else:
    d.capEdit.text = ""
    d.subMemo.text = ""
    d.imgSpin.value = -1
    d.selSpin.value = -1
    d.chkBox.checked = false
  d.upBtn.enabled = i > 0
  d.downBtn.enabled = i >= 0 and i < d.recs.high
  d.inBtn.enabled = d.tree and i > 0 and d.recs[i].level <= d.recs[i - 1].level
  d.outBtn.enabled = d.tree and i >= 0 and d.recs[i].level > 0
  d.syncing = false

proc syncList*(d: ItemsDlgForm, select = -2) =
  ## Re-reads the rows into the list box.
  let keep = if select == -2: d.list.itemIndex else: select
  var names: seq[string]
  for r in d.recs: names.add d.itemLabel(r)
  d.syncing = true
  d.list.items = names
  d.list.itemIndex = if d.recs.len == 0: -1 else: clamp(keep, 0, d.recs.high)
  d.syncing = false
  d.syncDetails()

proc addItem*(d: ItemsDlgForm, child = false): int {.discardable.} =
  ## "Add" (a sibling after the selected item and its sub-items) or "Add child"
  ## (the last child of the selected item); selects the new item.
  let sel = d.selectedIndex
  var at = d.recs.len
  var level = 0
  if sel >= 0:
    at = d.blockEnd(sel)
    level = if child and d.tree: d.recs[sel].level + 1 else: d.recs[sel].level
  d.recs.insert(ItemRec(text: "Item " & $(d.recs.len + 1), image: -1, selImage: -1,
                        level: level), at)
  d.syncList(at)
  at

proc deleteItem*(d: ItemsDlgForm) =
  ## Removes the selected item with its sub-items.
  let i = d.selectedIndex
  if i < 0: return
  d.recs.delete(i ..< d.blockEnd(i))
  d.syncList(i)

proc moveItem*(d: ItemsDlgForm, delta: int) =
  ## "Up" (-1) / "Down" (+1): past the previous / next item of the same level
  ## (with its sub-items).
  let i = d.selectedIndex
  if i < 0: return
  let e = d.blockEnd(i)
  let block0 = d.recs[i ..< e]
  let lvl = d.recs[i].level
  if delta < 0:
    var p = i - 1
    while p >= 0 and d.recs[p].level > lvl: dec p
    if p < 0 or d.recs[p].level < lvl: return
    d.recs.delete(i ..< e)
    d.recs.insert(block0, p)
    d.syncList(p)
  else:
    if e >= d.recs.len or d.recs[e].level < lvl: return
    let n = d.blockEnd(e)
    d.recs.delete(i ..< e)
    d.recs.insert(block0, n - block0.len)
    d.syncList(n - block0.len)

proc indentItem*(d: ItemsDlgForm, delta: int) =
  ## "Indent" (+1: becomes a child of the item above) / "Outdent" (-1) for the
  ## selected item with its sub-items; tree only.
  let i = d.selectedIndex
  if not d.tree or i < 0: return
  if delta > 0 and (i == 0 or d.recs[i].level > d.recs[i - 1].level): return
  if delta < 0 and d.recs[i].level == 0: return
  for k in i ..< d.blockEnd(i): d.recs[k].level += (if delta > 0: 1 else: -1)
  d.syncList(i)

proc commitText(d: ItemsDlgForm) =
  let i = d.selectedIndex
  if d.syncing or i < 0: return
  d.recs[i].text = d.capEdit.text
  d.syncing = true
  d.list.items[i] = d.itemLabel(d.recs[i])
  d.syncing = false

proc itemLines*(d: ItemsDlgForm): seq[string] = itemLinesOf(d.tree, d.recs)
  ## The edited `items` value.
proc itemImages*(d: ItemsDlgForm): seq[string] = imagesOf(d.recs)
proc itemSelectedImages*(d: ItemsDlgForm): seq[string] = imagesOf(d.recs, true)
proc checkedItems*(d: ItemsDlgForm): seq[string] = checkedOf(d.recs)

proc newItemsDlg*(tree: bool, lines, images, selImages, checked: seq[string],
                  title = "Items"): ItemsDlgForm =
  ## The dialog without showing it (`tree`: a TreeView's nodes, else a
  ## ListView's items).
  result = newItemsDlgForm()
  let d = result
  d.tree = tree
  d.caption = title
  d.recs = parseItemRecs(tree, lines, images, selImages, checked)
  d.fit()
  for b in [Control(d.childBtn), d.inBtn, d.outBtn]: b.visible = tree
  d.list.onChange = proc(s: Control) =
    if not d.syncing: d.syncDetails()
  d.addBtn.onClick = proc(s: Control) = d.addItem()
  d.childBtn.onClick = proc(s: Control) = d.addItem(child = true)
  d.delBtn.onClick = proc(s: Control) = d.deleteItem()
  d.upBtn.onClick = proc(s: Control) = d.moveItem(-1)
  d.downBtn.onClick = proc(s: Control) = d.moveItem(1)
  d.inBtn.onClick = proc(s: Control) = d.indentItem(1)
  d.outBtn.onClick = proc(s: Control) = d.indentItem(-1)
  d.capEdit.onChange = proc(s: Control) = d.commitText()
  d.subMemo.onChange = proc(s: Control) =
    let i = d.selectedIndex
    if d.syncing or i < 0: return
    var t = d.subMemo.text
    d.recs[i].subs = if t.len == 0: @[] else: t.splitLines
  d.imgSpin.onChange = proc(s: Control) =
    let i = d.selectedIndex
    if not d.syncing and i >= 0: d.recs[i].image = d.imgSpin.value
  d.selSpin.onChange = proc(s: Control) =
    let i = d.selectedIndex
    if not d.syncing and i >= 0: d.recs[i].selImage = d.selSpin.value
  d.chkBox.onChange = proc(s: Control) =
    let i = d.selectedIndex
    if not d.syncing and i >= 0: d.recs[i].checked = d.chkBox.checked
  d.syncList(0)

# -------------------------------------------------------------- collection

form CollectionDlgForm:
  borderStyle = bsSizeable
  position = poScreenCenter
  var peHost: PropEditorHost
  var target: Obj
  var coll: PropInfo
  var syncing = false           ## the list is being refilled: its change events are ignored
  ListBox list:
    multiSelect = false
  Button addBtn:
    caption = "Add"
  Button delBtn:
    caption = "Delete"
  Button upBtn:
    caption = "Up"
  Button downBtn:
    caption = "Down"
  ObjectInspector insp:
    tabStop = true
  Button closeBtn:
    caption = "Close"
    isDefault = true
    isCancel = true
    modalResult = mrOk
  proc fit(self: CollectionDlgForm) =
    let w = 640'f32
    let h = 440'f32
    let lw = 230'f32
    self.list.setBounds(Pad, Pad, lw, h - Pad * 3 - BtnH * 2 - Gap * 2)
    let by = Pad + self.list.height + Gap
    let bw = (lw - Gap * 3) / 4
    var x = Pad
    for b in [self.addBtn, self.delBtn, self.upBtn, self.downBtn]:
      b.setBounds(x, by, bw, BtnH)
      x += bw + Gap
    self.insp.setBounds(Pad * 2 + lw, Pad, w - Pad * 3 - lw, h - Pad * 3 - BtnH)
    self.closeBtn.setBounds(w - Pad - BtnW, h - Pad - BtnH, BtnW, BtnH)
    self.setBounds(self.left, self.top, w, h)

proc itemsOf*(d: CollectionDlgForm): seq[Obj] = d.coll.coll.items(d.target)

proc itemLabel(o: Obj): string =
  let ci = classOf(o)
  var txt = ""
  if ci != nil:
    for pn in ["caption", "text"]:
      let p = ci.findProp(pn)
      if p != nil and p.kind == pkString:
        txt = p.get(o).s
        break
  let nm = objectName(o)
  if txt.len > 0 and nm.len > 0: txt & "  [" & nm & "]"
  elif txt.len > 0: txt
  elif nm.len > 0: nm
  else: "(" & (if ci != nil: ci.name else: "item") & ")"

proc selectedItem*(d: CollectionDlgForm): Obj =
  ## The item selected in the list (nil: none).
  let its = d.itemsOf
  if d.list.itemIndex in 0 ..< its.len: its[d.list.itemIndex] else: nil

proc syncEditor(d: CollectionDlgForm) =
  let its = d.itemsOf
  let i = d.list.itemIndex
  d.insp.inspect(if i in 0 ..< its.len: its[i] else: nil)
  d.delBtn.enabled = i in 0 ..< its.len
  d.upBtn.enabled = i > 0
  d.downBtn.enabled = i in 0 ..< its.high

proc syncList*(d: CollectionDlgForm, select = -2) =
  ## Re-reads the items (after anything changed them).
  let its = d.itemsOf
  let keep = if select == -2: d.list.itemIndex else: select
  var names: seq[string]
  for o in its: names.add itemLabel(o)
  d.syncing = true
  d.list.items = names
  d.list.itemIndex = if its.len == 0: -1 else: clamp(keep, 0, its.high)
  d.syncing = false
  d.syncEditor()

proc addItem*(d: CollectionDlgForm): Obj {.discardable.} =
  ## "Add": creates a new item at the end and selects it.
  result = d.coll.coll.add(d.target)
  if d.peHost != nil and d.peHost.onItemAdded != nil: d.peHost.onItemAdded(d.target, result)
  d.syncList(d.itemsOf.high)
  d.peHost.changed(d.target, d.coll.name)

proc deleteItem*(d: CollectionDlgForm) =
  ## "Delete": removes the selected item.
  let o = d.selectedItem
  if o == nil: return
  let i = d.list.itemIndex
  if d.peHost != nil and d.peHost.onItemRemoved != nil: d.peHost.onItemRemoved(d.target, o)
  d.coll.coll.remove(d.target, o)
  d.syncList(i)
  d.peHost.changed(d.target, d.coll.name)

proc moveItem*(d: CollectionDlgForm, delta: int) =
  ## "Up" (-1) / "Down" (+1).
  let o = d.selectedItem
  let i = d.list.itemIndex
  if o == nil or d.coll.coll.move == nil or i + delta notin 0 ..< d.itemsOf.len: return
  d.coll.coll.move(d.target, o, i + delta)
  d.syncList(i + delta)
  d.peHost.changed(d.target, d.coll.name)

proc attachEditors*(ins: ObjectInspector, host: PropEditorHost)

proc newCollectionDlg*(host: PropEditorHost, target: Obj, collection: PropInfo,
                       title = ""): CollectionDlgForm =
  ## The dialog without showing it. `collection` is a `pkCollection` property
  ## of `target`.
  assert collection.kind == pkCollection
  result = newCollectionDlgForm()
  let d = result
  d.caption = if title.len > 0: title
              else: (let n = objectName(target); (if n.len > 0: n & "." else: "") & collection.name)
  d.peHost = host
  d.target = target
  d.coll = collection
  d.fit()
  attachEditors(d.insp, host)
  # an edit in the item inspector: relabel the list, tell the application
  let inner = d.insp.onPropertyChanged
  d.insp.onPropertyChanged = proc(s: Control, t: Obj, prop: string) =
    if inner != nil: inner(s, t, prop)
    d.syncList()
    d.peHost.changed(t, prop)
  d.list.onChange = proc(s: Control) =
    if not d.syncing: d.syncEditor()
  d.addBtn.onClick = proc(s: Control) = d.addItem()
  d.delBtn.onClick = proc(s: Control) = d.deleteItem()
  d.upBtn.onClick = proc(s: Control) = d.moveItem(-1)
  d.downBtn.onClick = proc(s: Control) = d.moveItem(1)
  d.syncList(0)

# ------------------------------------------------------------------- glue

proc run(host: PropEditorHost, d: Form): ModalResult =
  if host != nil and host.runModal != nil: host.runModal(d) else: showAndFree(d)

proc editExtra*(ins: ObjectInspector, host: PropEditorHost, target: Obj, prop: string) =
  ## What the "..." button of property `prop` of `target` does; see the module
  ## comment. The result is applied with `ins.setValue` (to every target of
  ## the inspector).
  let ci = classOf(target)
  if ci == nil: return
  let info = ci.findProp(prop)
  if info == nil: return
  let v = info.get(target)
  let title = (let n = objectName(target); (if n.len > 0: n & "." else: "") & prop)
  proc strs(name: string): seq[string] =
    let p = ci.findProp(name)
    if p != nil and p.kind == pkStrings: p.get(target).strs else: @[]
  proc intOf(name: string): int =
    let p = ci.findProp(name)
    if p != nil: int(p.get(target).i) else: 0
  if info.kind == pkStrings and prop == "items" and
     (target of ListView or target of TreeView):
    let tree = target of TreeView
    let d = newItemsDlg(tree, v.strs, strs("itemImages"), strs("itemSelectedImages"),
                        strs("checkedItems"), title)
    if host.run(d) == mrOk:
      ins.setValue("items", pvStrings(d.itemLines))
      ins.setValue("itemImages", pvStrings(d.itemImages))
      if tree: ins.setValue("itemSelectedImages", pvStrings(d.itemSelectedImages))
      ins.setValue("checkedItems", pvStrings(d.checkedItems))
    return
  if info.kind == pkStrings and prop == "cells" and target of StringGrid:
    let wp = ci.findProp("colWidths")
    let d = newStringGridDlg(intOf("colCount"), intOf("rowCount"), intOf("fixedCols"),
                             intOf("fixedRows"), v.strs,
                             if wp != nil: wp.get(target).s else: "", title)
    if host.run(d) == mrOk:
      ins.setValue("colCount", pvInt(d.colCountOf))
      ins.setValue("rowCount", pvInt(d.rowCountOf))
      ins.setValue("cells", pvStrings(d.cellsOf))
    return
  case info.kind
  of pkStrings:
    let d = newStringListDlg(title, v.strs)
    if host.run(d) == mrOk:
      ins.setValue(prop, pvStrings(d.linesOf))
  of pkImage:
    let d = newPictureDlg(host, v.image, title)
    if host.run(d) == mrOk:
      try: ins.setValue(prop, PropValue(kind: pkImage, image: d.commit))
      except IOError as e: ins.reportError(e.msg)
  of pkImages:
    var w = 16'f32
    var h = 16'f32
    let wp = ci.findProp("width")
    let hp = ci.findProp("height")
    if wp != nil: w = float32(wp.get(target).f)
    if hp != nil: h = float32(hp.get(target).f)
    let d = newImageListDlg(host, v.imgs, w, h, title)
    if host.run(d) == mrOk:
      try: ins.setValue(prop, PropValue(kind: pkImages, imgs: d.commit))
      except IOError as e: ins.reportError(e.msg)
  of pkCollection:
    let d = newCollectionDlg(host, target, info, title)
    discard host.run(d)
    ins.refresh()
  else: discard

proc attachEditors*(ins: ObjectInspector, host: PropEditorHost) =
  ## Makes the "..." buttons of `ins` open the editors of this module. `host`
  ## (see `newPropEditorHost`) says where pictures live and gets the change
  ## notifications; it is also called after each edit through `ins` itself
  ## (via the inspector's own `onPropertyChanged`, which stays yours).
  ins.onEditExtra = proc(s: Control, target: Obj, prop: string) =
    ins.editExtra(host, target, prop)
