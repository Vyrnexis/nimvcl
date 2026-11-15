# Phase 6 demo: an Explorer-like window. TreeView (lazy folders, icons drawn in
# code) on the left, Splitter, ListView (virtual mode, report / list / icon
# views, sortable columns, check boxes, label editing) on the right.
#
# Keys: arrows / Home / End / type-ahead in both views, F2 renames, Space
#       toggles a check box, `*` expands a whole tree branch, D toggles
#       dark/light. Click a column header to sort (folders under 50,000 rows;
#       "Archive" has 250,000 rows).
#
# Env:
#   NIMVCL_SCREENSHOT   lay out, render one frame to this file and exit (BMP;
#                       .png when ImageMagick `magick` is available)
#   NIMVCL_SCALE        force the display scale
#   NIMVCL_DARK=1       start with the dark theme
#   NIMVCL_VIEW         report | list | small | icon (default report)
#
# Build: nim c --outdir:build examples/views_demo.nim

import std/[os, strutils, algorithm, osproc, sugar]
import nimvcl
import nimvcl/controls/[treeview, listview, imagelist]

type
  Folder = ref object of RootObj
    path: string
    seed: uint32
    rows: int

  FileRec = object
    name, typ: string
    size: int          # -1 for folders
    mtime: int         # minutes since 2023-01-01
    icon: int

const
  IcFolder = 0
  IcDoc = 1
  IcImage = 2
  IcAudio = 3
  IcCode = 4
  IcArchive = 5
  IcComputer = 6
  Words = ["report", "budget", "holiday", "notes", "invoice", "design", "draft",
           "backup", "meeting", "photo", "song", "readme", "main", "config",
           "summary", "plan", "sketch", "album", "letter", "data"]
  Exts = [("", "File folder", IcFolder), (".docx", "Text document", IcDoc),
          (".png", "PNG image", IcImage), (".mp3", "MP3 audio", IcAudio),
          (".nim", "Nim source", IcCode), (".zip", "ZIP archive", IcArchive),
          (".txt", "Text document", IcDoc)]
  Names = ["Documents", "Pictures", "Music", "Projects", "Downloads", "Archive",
           "Work", "Personal", "Shared", "Backups", "Photos", "Reports", "Old",
           "Drafts", "Misc"]

var
  tree: TreeView
  list: ListView
  status: StatusBar
  smallIcons, largeIcons: ImageList
  current: Folder
  order: seq[int]          # row -> file index (sorted views)
  sortCol = -1
  sortAsc = true

# ------------------------------------------------------------------ icons

type Pix = array[16, array[16, Color]]

proc mixh(a, b: uint32): uint32 =
  var h = a * 2654435761'u32 + b * 40503'u32 + 0x9e3779b9'u32
  h = h xor (h shr 15)
  h = h * 2246822519'u32
  h = h xor (h shr 13)
  h

proc fillBox(p: var Pix, x0, y0, x1, y1: int, c: Color) =
  for y in max(y0, 0) .. min(y1, 15):
    for x in max(x0, 0) .. min(x1, 15): p[y][x] = c

proc design(kind: int): Pix =
  let line = rgb(60, 66, 80)
  case kind
  of IcFolder:
    let back = rgb(214, 160, 40)
    let front = rgb(246, 200, 80)
    let edge = rgb(150, 105, 20)
    result.fillBox(1, 3, 6, 5, edge)
    result.fillBox(2, 4, 6, 5, back)
    result.fillBox(1, 5, 14, 13, edge)
    result.fillBox(2, 6, 13, 12, front)
    result.fillBox(2, 6, 13, 7, rgb(255, 222, 130))
    result.fillBox(2, 6, 13, 6, rgb(255, 235, 170))
  of IcComputer:
    result.fillBox(1, 2, 14, 11, line)
    result.fillBox(2, 3, 13, 10, rgb(90, 160, 235))
    result.fillBox(2, 3, 13, 5, rgb(140, 200, 250))
    result.fillBox(6, 12, 9, 13, line)
    result.fillBox(3, 14, 12, 14, line)
  else:
    var band = rgb(80, 130, 210)
    case kind
    of IcImage: band = rgb(70, 170, 110)
    of IcAudio: band = rgb(190, 90, 170)
    of IcCode: band = rgb(70, 70, 90)
    of IcArchive: band = rgb(200, 140, 60)
    else: discard
    result.fillBox(3, 1, 12, 14, rgb(150, 156, 170))
    result.fillBox(4, 2, 11, 13, rgb(250, 251, 253))
    result.fillBox(9, 1, 12, 4, Color())          # folded corner
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

# ---------------------------------------------------------------- the "files"

proc fileRec(f: Folder, idx: int): FileRec =
  let h = mixh(f.seed, uint32(idx))
  let k = int(h mod 7)
  let (ext, typ, ic) = Exts[k]
  result.icon = ic
  result.typ = typ
  result.name = Words[int((h shr 5) mod uint32(Words.len))]
  if k == 0:
    result.name &= " folder " & $idx
    result.size = -1
  else:
    result.name &= "_" & align($idx, 3, '0') & ext
    result.size = int((h shr 9) mod 4_000_000) + 120
  result.mtime = int((h shr 3) mod 900_000)

proc formatSize(n: int): string =
  if n < 0: return ""
  let kb = (n + 1023) div 1024
  var s = $kb
  var o = ""
  for i, ch in s:
    if i > 0 and (s.len - i) mod 3 == 0: o.add ','
    o.add ch
  o & " KB"

proc formatDate(m: int): string =
  let day = m div 1440
  let mon = (day div 30) mod 12 + 1
  let d = day mod 28 + 1
  let yr = 2023 + day div 360
  align($yr, 4) & "-" & align($mon, 2, '0') & "-" & align($d, 2, '0') & " " &
    align($((m mod 1440) div 60), 2, '0') & ":" & align($(m mod 60), 2, '0')

# ----------------------------------------------------------------- the views

proc updateStatus() =
  if status == nil or list == nil: return
  status.panels[0].text = (if current != nil: current.path else: "")
  status.panels[1].text = $list.count & " items" &
    (if list.selCount > 0: ", " & $list.selCount & " selected" else: "")

proc resetOrder() =
  order.setLen(0)
  sortCol = -1
  list.sortColumn = -1
  list.sortOrder = soNone

proc showFolder(n: TreeNode) =
  if n == nil or n.data == nil: return
  current = Folder(n.data)
  list.itemsCount = 0
  resetOrder()
  list.itemsCount = current.rows
  list.scrollTo(0, 0)
  updateStatus()

proc rowFile(i: int): int =
  if order.len == current.rows: order[i] else: i

proc sortBy(col: int) =
  if current == nil or current.rows > 50_000 or current.rows == 0: return
  if col == sortCol: sortAsc = not sortAsc
  else:
    sortCol = col
    sortAsc = true
  var recs = newSeq[FileRec](current.rows)
  for i in 0 ..< recs.len: recs[i] = fileRec(current, i)
  order = newSeq[int](current.rows)
  for i in 0 ..< order.len: order[i] = i
  let asc = sortAsc
  order.sort(proc(a, b: int): int =
    let x = recs[a]
    let y = recs[b]
    result = case col
             of 0: cmpIgnoreCase(x.name, y.name)
             of 1: cmp(x.size, y.size)
             of 2: cmpIgnoreCase(x.typ, y.typ)
             else: cmp(x.mtime, y.mtime)
    if result == 0: result = cmp(a, b)
    if not asc: result = -result)
  list.sortColumn = col
  list.sortOrder = if asc: soAscending else: soDescending
  list.clearSelection()
  list.refreshData()

proc buildImages() =
  smallIcons = newImageList(16, 16)
  largeIcons = newImageList(32, 32)
  for k in 0 .. IcComputer:
    smallIcons.add makeIcon(k, 16)
    largeIcons.add makeIcon(k, 32)

proc populate(n: TreeNode) =
  ## Creates the subfolders of `n` (called lazily when it is first expanded).
  let f = Folder(n.data)
  if f.path == "Computer":
    for name in ["Local Disk (C:)", "Data (D:)"]:
      let c = n.addChild(name)
      c.data = Folder(path: name, seed: mixh(1, uint32(name.len)), rows: 24)
      c.imageIndex = IcComputer
      c.hasChildren = true
    return
  let cnt = 3 + int(mixh(f.seed, 7) mod 4)
  for i in 0 ..< cnt:
    let name = Names[int(mixh(f.seed, uint32(i + 11)) mod uint32(Names.len))] &
               (if i > 3: " " & $i else: "")
    let seed = mixh(f.seed, uint32(i + 100))
    let rows = if name == "Archive": 250_000 else: 25 + int(seed mod 400)
    let c = n.addChild(name)
    c.data = Folder(path: f.path & "\\" & name, seed: seed, rows: rows)
    c.imageIndex = IcFolder
    c.hasChildren = f.path.count('\\') < 3

proc buildToolBar(f: Form) =
  let tb = newToolBar(f)
  tb.name = "toolbar"
  let styles = [("Report", vsReport), ("List", vsList),
                ("Small icons", vsSmallIcon), ("Icons", vsIcon)]
  for (cap, st) in styles:
    let b = newToolButton(tb, cap, tbsCheck)
    b.groupIndex = 1
    b.down = st == vsReport
    b.name = "view_" & cap
    capture st:
      b.onClick = proc(s: Control) = list.viewStyle = st
  discard newToolButton(tb, "", tbsDivider)
  let chk = newToolButton(tb, "Check boxes", tbsCheck)
  chk.onClick = proc(s: Control) = list.checkboxes = not list.checkboxes
  let grid = newToolButton(tb, "Grid lines", tbsCheck)
  grid.onClick = proc(s: Control) = list.gridLines = not list.gridLines
  let multi = newToolButton(tb, "Multi-select", tbsCheck)
  multi.down = true
  multi.onClick = proc(s: Control) = list.multiSelect = not list.multiSelect

proc buildMain(): Form =
  let f = newForm(nil, 960, 560)
  f.caption = "nimvcl views demo"
  buildImages()
  buildToolBar(f)
  status = newStatusBar(f)
  status.addPanel("", 360)
  status.addPanel("", 200)
  status.addPanel("TreeView + ListView", 100, taRight)
  status.sizeGrip = true

  tree = newTreeView(f)
  tree.name = "tree"
  tree.align = alLeft
  tree.width = 260
  tree.margins = spacing(8, 8, 0, 8)
  tree.images = smallIcons
  tree.showLines = true
  tree.hideSelection = false
  let sp = newSplitter(f)
  sp.minSize = 140

  list = newListView(f)
  list.name = "list"
  list.align = alClient
  list.margins = spacing(0, 8, 8, 8)
  list.smallImages = smallIcons
  list.largeImages = largeIcons
  list.multiSelect = true
  list.columns.add("Name", 250)
  list.columns.add("Size", 100, taRight)
  list.columns.add("Type", 130)
  list.columns.add("Modified", 140)
  list.ownerData = true
  list.onData = proc(s: Control, it: ListItem) =
    let fi = rowFile(it.index)
    let r = fileRec(current, fi)
    it.caption = r.name
    it.subItems = @[formatSize(r.size), r.typ, formatDate(r.mtime)]
    it.imageIndex = r.icon
  list.onColumnClick = proc(s: Control, c: ListColumn) = sortBy(c.index)
  list.onChange = proc(s: Control) = updateStatus()
  list.onDblClick = proc(s: Control) =
    if list.itemIndex >= 0: status.panels[2].text = list.getItem(list.itemIndex).caption
  list.onEdited = proc(s: Control, it: ListItem, text: var string) =
    status.panels[2].text = "renamed to " & text

  tree.onExpanding = proc(s: Control, n: TreeNode, allow: var bool) =
    if n.childCount == 0 and n.data != nil: populate(n)
  tree.onChange = proc(s: Control, n: TreeNode) = showFolder(n)

  let root = tree.items.addChild(nil, "Computer")
  root.data = Folder(path: "Computer", seed: 1, rows: 12)
  root.imageIndex = IcComputer
  root.hasChildren = true

  f.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
    if k == 'd'.key and sh * {ssCtrl, ssAlt} == {} and
       not (f.activeControl of TreeView or f.activeControl of ListView or
            f.activeControl of Edit):
      Application.theme = if currentTheme().name == "dark": themeLight() else: themeDark()
      k = Key(0)
  f

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let f = buildMain()
  case getEnv("NIMVCL_VIEW").toLowerAscii
  of "list": list.viewStyle = vsList
  of "small": list.viewStyle = vsSmallIcon
  of "icon": list.viewStyle = vsIcon
  else: discard
  for c in f.children:               # sync the toolbar with NIMVCL_VIEW
    if c of ToolBar:
      for b in ToolBar(c).children:
        if b.name.startsWith("view_"):
          ToolButton(b).down = b.name == "view_" & (case list.viewStyle
            of vsReport: "Report"
            of vsList: "List"
            of vsSmallIcon: "Small icons"
            of vsIcon: "Icons")
  # start in a folder with some depth
  let first = tree.items.top(0)
  first.expand()
  var target = first
  for c in first.children:
    if c.text.startsWith("Local"): target = c
  target.expand()
  if target.childCount > 0: target = target.child(1)
  tree.selected = target
  if shot.len > 0:
    f.show()
    f.syncMetrics()
    discard f.paintIfDirty()
    f.layoutIfNeeded()
    # a few rows selected and sorted, to show the header arrow and highlights
    sortBy(0)
    list.itemIndex = 2
    list.setSelected(3, true)
    list.setSelected(4, true)
    list.setFocus()
    discard f.paintIfDirty()
    let bmp = if shot.endsWith(".png"): shot.changeFileExt("bmp") else: shot
    if not f.screenshot(bmp): quit "screenshot failed: " & sdlError()
    if shot.endsWith(".png"):
      if execCmd("magick " & quoteShell(bmp) & " " & quoteShell(shot)) == 0:
        removeFile bmp
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    tree.setFocus()
    Application.run(f)

main()
