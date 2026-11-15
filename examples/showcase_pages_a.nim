## Showcase pages 1 to 4: buttons and choices, text input, ranges, lists and trees.
## Each `buildXxx` fills the body panel of one page with plain constructors.

import std/[strutils, sequtils, unicode]
import nimvcl
import ./showcase_common

# ============================================================ 1. buttons

proc buildButtons*(ctx: Showcase, body: Container) =
  # ---- push buttons
  let gb = card(body, "Push buttons", 0, 0, 396, 150, {akLeft, akTop, akRight})
  var clicks = 0
  let counter = newLabel(gb, "Nothing clicked yet", 16, 112)
  counter.textColor = currentTheme().textMuted
  ctx.muted.add counter
  proc hit(what: string) =
    inc clicks
    counter.caption = what & " clicked (" & $clicks & " in total)"
    ctx.say what & " button clicked"
  let def = newButton(gb, "&Default", 16, 32, 110, 32)
  def.isDefault = true
  def.hint = "The default button: Enter clicks it from anywhere in the form"
  def.onClick = proc(s: Control) = hit("Default")
  let cancel = newButton(gb, "&Cancel", 136, 32, 110, 32)
  cancel.isCancel = true
  cancel.hint = "The cancel button: Esc clicks it"
  cancel.onClick = proc(s: Control) = hit("Cancel")
  let flat = newButton(gb, "Fla&t", 256, 32, 110, 32)
  flat.flat = true
  flat.hint = "A flat button has no face until hovered"
  flat.onClick = proc(s: Control) = hit("Flat")
  let off = newButton(gb, "Disabled", 16, 72, 110, 32)
  off.enabled = false
  let tog = newButton(gb, "&Enable it", 136, 72, 110, 32)
  tog.hint = "Enables and disables the button next to it"
  tog.onClick = proc(s: Control) =
    off.enabled = not off.enabled
    tog.caption = if off.enabled: "&Disable it" else: "&Enable it"
  let wide = newButton(gb, "Auto size", 256, 72)
  wide.autoSize = true
  wide.onClick = proc(s: Control) = hit("Auto-sized")

  # ---- check boxes
  let cb = card(body, "Check boxes", 414, 0, 396, 150, {akTop, akRight})
  let rem = newCheckBox(cb, "&Remember me", true, 16, 32)
  let note = newCheckBox(cb, "&Notifications", false, 16, 60)
  let dis = newCheckBox(cb, "Disabled, checked", true, 16, 88)
  dis.enabled = false
  let tri = newCheckBox(cb, "Tri-state", false, 210, 32)
  tri.allowGrayed = true
  tri.state = cbGrayed
  let summary = newLabel(cb, "", 210, 70, 170, 60)
  summary.wordWrap = true
  summary.autoSize = false
  ctx.muted.add summary
  summary.textColor = currentTheme().textMuted
  proc refresh(s: Control) =
    let st = case tri.state
             of cbUnchecked: "off"
             of cbChecked: "on"
             else: "grayed"
    summary.caption = "Tri-state is " & st & ".\nRemember: " &
                      (if rem.checked: "yes" else: "no") & ", notify: " &
                      (if note.checked: "yes" else: "no")
  for c in [rem, note, tri]: c.onChange = refresh
  refresh(nil)

  # ---- radio groups with a live preview
  let sizes = card(body, "Size", 0, 166, 190, 150)
  let colours = card(body, "Colour", 206, 166, 190, 150)
  var size = 1
  var colour = 0
  let preview = card(body, "Preview", 414, 166, 396, 150, {akTop, akRight})
  let pb = newPaintBox(preview, 12, 30, 372, 108)
  pb.anchors = {akLeft, akTop, akRight}
  const
    names = ["Small", "Medium", "Large"]
    colNames = ["Blue", "Green", "Amber", "Pink"]
    cols = [rgb(0x3b, 0x82, 0xf6), rgb(0x22, 0xa5, 0x5e), rgb(0xf5, 0x9e, 0x0b), rgb(0xe1, 0x4d, 0x8a)]
  pb.onPaint = proc(s: Control, c: Canvas) =
    let r = s.clientRect
    let h = [34'f32, 58, 82][size]
    let w = [120'f32, 190, 260][size]
    let box = rectF((r.w - w) / 2, (r.h - h) / 2, w, h)
    c.fillRoundRect(box.inflate(4), 14, rgba(cols[colour].r.int, cols[colour].g.int, cols[colour].b.int, 50))
    c.fillRoundRect(box, 10, cols[colour])
    c.textRect(names[size] & " " & colNames[colour].toLowerAscii, font(size = 14, style = {fsBold}),
               box, clWhite, taCenter, vaCenter)
  for i, n in names:
    let rb = newRadioButton(sizes, n, i == size, 16, 32 + i.float32 * 28)
    rb.tag = i
    rb.onChange = proc(s: Control) =
      if RadioButton(s).checked:
        size = s.tag
        pb.invalidate()
        ctx.say "Size: " & names[size]
  for i, n in colNames:
    let rb = newRadioButton(colours, n, i == colour, 16, 32 + i.float32 * 26)
    rb.tag = i
    rb.onChange = proc(s: Control) =
      if RadioButton(s).checked:
        colour = s.tag
        pb.invalidate()
        ctx.say "Colour: " & colNames[colour]

  # ---- toggle tool buttons
  let tb = card(body, "Toggle tool buttons", 0, 332, 810, 180, {akLeft, akTop, akRight, akBottom})
  let bar = newToolBar(tb)
  bar.margins = spacing(10, 4, 10, 4)
  let bold = newToolButton(bar, "Bold", tbsCheck)
  let ital = newToolButton(bar, "Italic", tbsCheck)
  let underl = newToolButton(bar, "Underline", tbsCheck)
  discard newToolButton(bar, kind = tbsDivider)
  let alL = newToolButton(bar, "Left", tbsCheck)
  let alC = newToolButton(bar, "Center", tbsCheck)
  let alR = newToolButton(bar, "Right", tbsCheck)
  for b in [alL, alC, alR]:
    b.groupIndex = 1
  alL.down = true
  bold.hint = "Toggle bold"
  ital.hint = "Toggle italic"
  underl.hint = "Toggle underline"
  alL.hint = "Align left (radio group of tool buttons)"
  alC.hint = "Align centre"
  alR.hint = "Align right"
  let sampleBox = newPanel(tb)
  sampleBox.align = alClient
  sampleBox.margins = spacing(12, 6, 12, 12)
  sampleBox.borderStyle = pbSingle
  sampleBox.padding = spacing(12, 8)
  let sample = newLabel(sampleBox, "Style me with the tool buttons above.\nHold Alt to see the underlined mnemonics.")
  sample.align = alClient
  sample.autoSize = false
  sample.wordWrap = true
  sample.layout = vaCenter
  sample.font = font(size = 18)
  proc restyle(s: Control) =
    var st: set[FontStyle]
    if bold.down: st.incl fsBold
    if ital.down: st.incl fsItalic
    if underl.down: st.incl fsUnderline
    sample.font = font(size = 18, style = st)
    sample.alignment = if alC.down: taCenter elif alR.down: taRight else: taLeft
  for b in [bold, ital, underl, alL, alC, alR]: b.onClick = restyle
  restyle(nil)

# ============================================================ 2. text input

const
  MemoHead = """nimvcl draws Unicode text with SDL3_ttf.

English   The quick brown fox jumps over the lazy dog.
Deutsch   Zwölf Boxkämpfer jagen Viktor quer über den großen Sylter Deich.
Français  Portez ce vieux whisky au juge blond qui fume sur son île.
Español   El veloz murciélago hindú comía feliz cardillo y kiwi.
Русский   Съешь же ещё этих мягких французских булок, да выпей чаю.
Ελληνικά  Ξεσκεπάζω την ψυχοφθόρα βδελυγμία.
"""
  MemoCjk = """日本語     いろはにほへと ちりぬるを わかよたれそ。
中文      敏捷的棕色狐狸跳过了懒狗。
한국어     다람쥐 헌 쳇바퀴에 타고파.
"""
  MemoTail = """

This is a Memo: select text, copy, paste, undo with Ctrl+Z, and toggle word wrap below."""

const Countries = ["Argentina", "Australia", "Austria", "Belgium", "Brazil", "Canada",
                   "Chile", "Denmark", "Finland", "France", "Germany", "Iceland",
                   "Ireland", "Italy", "Japan", "Mexico", "Netherlands", "Norway",
                   "Spain", "Sweden", "Switzerland", "United Kingdom", "United States"]

proc buildText*(ctx: Showcase, body: Container) =
  let left = card(body, "Edit, SpinEdit and ComboBox", 0, 0, 400, 520, {akLeft, akTop, akBottom})
  proc caption(text: string, y: float32, focus: Control = nil, x = 16'f32): Label =
    result = newLabel(left, text, x, y)
    result.focusControl = focus
  let name = newEdit(left, "", 16, 52, 368)
  name.placeholder = "Your full name"
  name.hint = "A plain Edit with a placeholder"
  discard caption("&Name", 32, name)
  let pass = newEdit(left, "", 16, 108, 368)
  pass.placeholder = "Password"
  pass.password = true
  pass.text = "secret123"
  pass.hint = "password = true shows dots"
  discard caption("&Password", 88, pass)
  let age = newEdit(left, "", 16, 164, 170)
  age.placeholder = "Digits only"
  age.numbersOnly = true
  age.text = "36"
  age.hint = "numbersOnly rejects everything but digits"
  discard caption("&Age (numbersOnly)", 144, age)
  let qty = newSpinEdit(left, 3, 214, 164, 170)
  qty.minValue = 0
  qty.maxValue = 99
  qty.hint = "SpinEdit: arrows, wheel, Up and Down keys"
  discard caption("&Quantity (SpinEdit)", 144, qty, 214)
  let country = newComboBox(left, csDropDown, 16, 220, 368)
  country.items = Countries
  country.autoComplete = true
  country.text = "Germany"
  country.hint = "An editable combo that completes while you type"
  discard caption("&Country (dropdown, autocomplete)", 200, country)
  let lang = newComboBox(left, csDropDownList, 16, 276, 368)
  lang.items = ["English", "Deutsch", "Español", "Français", "Italiano", "Português", "Polski"]
  lang.itemIndex = 0
  lang.hint = "A list-style combo: pick from the list"
  discard caption("&Language (list)", 256, lang)
  # a live echo
  let echoBox = newPanel(left, "", 16, 336, 368, 160)
  echoBox.borderStyle = pbSingle
  echoBox.anchors = {akLeft, akTop, akRight, akBottom}
  let greet = newLabel(echoBox, "", 14, 12, 340, 130)
  greet.autoSize = false
  greet.wordWrap = true
  greet.font = font(size = 15)
  proc update(s: Control) =
    var t = "Hello, " & (if name.text.len > 0: name.text else: "stranger") & "!"
    if pass.text.len > 0: t.add "\nPassword length: " & $pass.text.runeLen
    if age.text.len > 0: t.add "\nAge: " & age.text
    t.add "\nQuantity: " & $qty.value
    if country.text.len > 0: t.add "\nCountry: " & country.text
    t.add "\nLanguage: " & lang.text
    greet.caption = t
  name.onChange = update
  pass.onChange = update
  age.onChange = update
  qty.onChange = update
  country.onChange = update
  lang.onChange = update
  update(nil)

  let right = card(body, "Memo", 414, 0, 396, 520, {akLeft, akTop, akRight, akBottom})
  let memo = newMemo(right, MemoHead & (if ctx.cjk: MemoCjk else: "") & MemoTail, 14, 30, 368, 440)
  memo.anchors = {akLeft, akTop, akRight, akBottom}
  memo.wordWrap = true
  memo.font = font(size = 14)
  memo.hint = "A full Memo: selection, clipboard, undo, wheel scrolling"
  let wrap = newCheckBox(right, "&Word wrap", true, 14, 484)
  wrap.anchors = {akLeft, akBottom}
  wrap.onChange = proc(s: Control) = memo.wordWrap = wrap.checked
  let ro = newCheckBox(right, "&Read only", false, 140, 484)
  ro.anchors = {akLeft, akBottom}
  ro.onChange = proc(s: Control) = memo.readOnly = ro.checked
  let pos = newLabel(right, "", 262, 486)
  pos.anchors = {akRight, akBottom}
  ctx.muted.add pos
  pos.textColor = currentTheme().textMuted
  proc count(s: Control) = pos.caption = $memo.lines.count & " lines"
  memo.onChange = count
  count(nil)

# ============================================================ 3. ranges

proc buildRanges*(ctx: Showcase, body: Container) =
  # ---- TrackBar -> ProgressBar
  let a = card(body, "TrackBar drives a ProgressBar", 0, 0, 810, 140, {akLeft, akTop, akRight})
  let tr = newTrackBar(a, 16, 34, 640, 36)
  tr.anchors = {akLeft, akTop, akRight}
  tr.min = 0
  tr.max = 100
  tr.frequency = 10
  tr.position = 64
  tr.hint = "Drag me, or use the arrow keys, Page Up/Down, Home and End"
  let pr = newProgressBar(a, 16, 84, 640, 22)
  pr.anchors = {akLeft, akTop, akRight}
  let val = newLabel(a, "", 676, 34, 120, 70)
  val.anchors = {akTop, akRight}
  val.autoSize = false
  val.font = font(size = 36, style = {fsBold})
  val.alignment = taRight
  val.layout = vaCenter
  proc sync(s: Control) =
    pr.position = tr.position
    val.caption = $tr.position & "%"
    ctx.say "Position " & $tr.position
  tr.onChange = sync
  sync(nil)

  # ---- vertical
  let v = card(body, "Vertical", 0, 156, 250, 356, {akLeft, akTop, akBottom})
  let vt = newTrackBar(v, 36, 34, 50, 300)
  vt.anchors = {akLeft, akTop, akBottom}
  vt.orientation = orVertical
  vt.min = 0
  vt.max = 10
  vt.frequency = 1
  vt.position = 4
  let vp = newProgressBar(v, 130, 40, 22, 290)
  vp.anchors = {akLeft, akTop, akBottom}
  vp.orientation = orVertical
  vp.max = 10
  let vl = newLabel(v, "", 170, 40)
  vl.anchors = {akLeft, akTop}
  vl.font = font(size = 22, style = {fsBold})
  proc vsync(s: Control) =
    vp.position = 10 - vt.position       # the track's minimum is at the top
    vl.caption = $(10 - vt.position)
  vt.onChange = vsync
  vsync(nil)

  # ---- animated
  let t = card(body, "Timer animation", 266, 156, 544, 214, {akLeft, akTop, akRight})
  let bar = newProgressBar(t, 16, 56, 514, 22)
  bar.anchors = {akLeft, akTop, akRight}
  bar.max = 100
  let busy = newProgressBar(t, 16, 114, 514, 22)
  busy.anchors = {akLeft, akTop, akRight}
  busy.style = pbsMarquee
  discard newLabel(t, "Determinate", 16, 32)
  discard newLabel(t, "Marquee (indeterminate)", 16, 90)
  let tick = newTimer(t, 40)
  tick.onTimer = proc(s: Timer) =
    bar.position = if bar.position >= bar.max: 0 else: bar.position + 1
  let run = newCheckBox(t, "&Running", false, 16, 154)
  run.hint = "The Timer fires onTimer every 40 ms"
  run.onChange = proc(s: Control) = tick.enabled = run.checked
  let reset = newButton(t, "Re&set", 140, 148, 90, 32)
  reset.onClick = proc(s: Control) = bar.position = 0
  let step = newButton(t, "&Step", 240, 148, 90, 32)
  step.onClick = proc(s: Control) = bar.stepBy(10)
  ctx.addHook(2, proc(on: bool) =
    # the animation runs only while this page is visible
    if on and not ctx.shotMode:
      run.checked = true
    elif not on:
      run.checked = false
    tick.enabled = run.checked)
  if ctx.shotMode: bar.position = 62

  # ---- scrollbar
  let sc = card(body, "ScrollBar", 266, 386, 544, 126, {akLeft, akTop, akRight})
  let sb = newScrollBar(sc, sbHorizontal, 16, 40, 514, 20)
  sb.anchors = {akLeft, akTop, akRight}
  sb.min = 0
  sb.max = 200
  sb.pageSize = 40
  sb.position = 60
  let sl = newLabel(sc, "", 16, 80)
  proc ssync(s: Control) = sl.caption = "Position " & $int(sb.position) & " of 0 .. 200 (page size 40)"
  sb.onChange = ssync
  ssync(nil)

# ============================================================ 4. lists and trees

type FileInfo = tuple[name, kind: string, size: int, date: string, icon: int]

const Files: array[14, FileInfo] = [
  ("src", "Folder", 0, "2026-11-02", icFolder),
  ("docs", "Folder", 0, "2026-11-09", icFolder),
  ("examples", "Folder", 0, "2026-11-14", icFolder),
  ("nimvcl.nimble", "Package", 1210, "2026-10-21", icFile),
  ("README.md", "Markdown", 5320, "2026-11-12", icFile),
  ("main.nim", "Nim source", 14280, "2026-11-14", icCode),
  ("canvas.nim", "Nim source", 48310, "2026-11-10", icCode),
  ("logo.png", "PNG image", 20480, "2026-09-30", icImage),
  ("screenshot.png", "PNG image", 188200, "2026-11-13", icImage),
  ("build.tar.gz", "Archive", 3204110, "2026-11-01", icArchive),
  ("LICENSE", "Text", 1066, "2026-08-05", icFile),
  ("theme.nim", "Nim source", 9410, "2026-11-06", icCode),
  ("icons.zip", "Archive", 802311, "2026-10-17", icArchive),
  ("notes.txt", "Text", 640, "2026-11-11", icFile)]

proc sizeText(n: int): string =
  if n == 0: "" elif n < 1024: $n & " B" elif n < 1024 * 1024: $(n div 1024) & " KB"
  else: formatFloat(n / (1024 * 1024), ffDecimal, 1) & " MB"

proc buildLists*(ctx: Showcase, body: Container) =
  let pages = newPageControl(body, 0, 0, BodyW, BodyH)
  pages.align = alClient
  ctx.listPages = pages
  # ------------------------------------------------ ListBox
  let lbSheet = newTabSheet(pages, "&ListBox")
  lbSheet.setBounds(0, 0, 808, 508)
  let fruit = ["Apple", "Apricot", "Banana", "Blackberry", "Blueberry", "Cherry",
               "Coconut", "Cranberry", "Date", "Fig", "Grape", "Grapefruit", "Guava",
               "Kiwi", "Lemon", "Lime", "Lychee", "Mango", "Melon", "Nectarine",
               "Orange", "Papaya", "Peach", "Pear", "Pineapple", "Plum", "Pomegranate",
               "Raspberry", "Strawberry", "Watermelon"]
  let lb = newListBox(lbSheet, 16, 40, 260, 440)
  lb.anchors = {akLeft, akTop, akBottom}
  lb.items = fruit
  lb.multiSelect = true
  lb.setSelection([1, 4, 5])
  lb.hint = "Ctrl+click and Shift+click select several"
  discard newLabel(lbSheet, "All fruit (multi-select)", 16, 14)
  discard newLabel(lbSheet, "Your basket", 300, 14)
  let basket = newListBox(lbSheet, 300, 40, 240, 440)
  basket.anchors = {akLeft, akTop, akBottom}
  let cnt = newLabel(lbSheet, "", 566, 44)
  cnt.font = font(size = 32, style = {fsBold})
  let cnt2 = ctx.mutedLabel(lbSheet, "selected", 566, 90)
  proc basketSync(s: Control) =
    basket.items.clear()
    for i in lb.selectedIndices: basket.add fruit[i]
    cnt.caption = $lb.selCount
    cnt2.caption = if lb.selCount == 1: "fruit selected" else: "fruits selected"
    ctx.say $lb.selCount & " selected"
  lb.onChange = basketSync
  basketSync(nil)
  let selAll = newButton(lbSheet, "Select &all", 566, 140, 130, 32)
  selAll.onClick = proc(s: Control) = lb.selectAll(); basketSync(nil)
  let clearB = newButton(lbSheet, "&Clear", 566, 180, 130, 32)
  clearB.onClick = proc(s: Control) = lb.clearSelection(); basketSync(nil)
  let invert = newButton(lbSheet, "&Invert", 566, 220, 130, 32)
  invert.onClick = proc(s: Control) =
    var keep: seq[int]
    for i in 0 ..< fruit.len:
      if not lb.selected(i): keep.add i
    lb.setSelection(keep)
    basketSync(nil)
  let srt = newCheckBox(lbSheet, "Sorted", false, 566, 270)
  srt.onChange = proc(s: Control) =
    lb.sorted = srt.checked
    basketSync(nil)

  # ------------------------------------------------ TreeView
  let trSheet = newTabSheet(pages, "&TreeView")
  trSheet.setBounds(0, 0, 808, 508)
  let tree = newTreeView(trSheet, 16, 16, 320, 470)
  tree.anchors = {akLeft, akTop, akBottom}
  tree.images = ctx.icons
  let root = tree.items.addChild(nil, "nimvcl")
  root.imageIndex = icFolder
  root.selectedIndex = icOpen
  proc dir(parent: TreeNode, text: string): TreeNode =
    result = parent.addChild(text)
    result.imageIndex = icFolder
    result.selectedIndex = icOpen
  proc leaf(parent: TreeNode, text: string) =
    let n = parent.addChild(text)
    n.imageIndex = if text.endsWith(".nim"): icCode elif text.endsWith(".png"): icImage
                   elif text.endsWith(".zip"): icArchive else: icFile
    n.selectedIndex = n.imageIndex
  let src = root.dir("src")
  let core = src.dir("core")
  for f in ["application.nim", "control.nim", "form.nim", "layout.nim", "theme.nim"]: core.leaf f
  let ctl = src.dir("controls")
  for f in ["button.nim", "listview.nim", "treeview.nim", "grids.nim", "memo.nim"]: ctl.leaf f
  let gfx = src.dir("graphics")
  for f in ["canvas.nim", "color.nim", "font.nim"]: gfx.leaf f
  let docs = root.dir("docs")
  for f in ["README.md", "forms.md", "getting-started.md"]: docs.leaf f
  let ex = root.dir("examples")
  for f in ["showcase.nim", "settings_demo.nim", "crud_demo.nim"]: ex.leaf f
  # a folder whose children are created when it is expanded
  let lazy = root.dir("tests (loaded on expand)")
  lazy.hasChildren = true
  tree.onExpanding = proc(s: Control, n: TreeNode, allow: var bool) =
    if n == lazy and n.childCount == 0:
      for f in ["tcore.nim", "tlistview.nim", "ttreeview.nim", "tgrids.nim", "tshowcase.nim"]:
        n.leaf f
  root.leaf "nimvcl.nimble"
  root.leaf "README.md"
  root.expand()
  src.expand()
  core.expand()
  discard newLabel(trSheet, "Selected node", 360, 16)
  let path = newLabel(trSheet, "", 360, 40, 440, 24)
  path.font = font(size = 16, style = {fsBold})
  let info = ctx.mutedLabel(trSheet, "", 360, 70, 440, 24)
  tree.onChange = proc(s: Control, n: TreeNode) =
    if n == nil: return
    var parts: seq[string]
    var c = n
    while c != nil and c.text.len > 0:
      parts.insert c.text, 0
      c = c.parent
    path.caption = parts.join("/")
    info.caption = "level " & $n.level & ", " & $n.childCount & " children"
    ctx.say "Tree: " & path.caption
  tree.selected = core.children[1]
  let lines = newCheckBox(trSheet, "Show &lines", true, 360, 120)
  lines.onChange = proc(s: Control) = tree.showLines = lines.checked
  let chk = newCheckBox(trSheet, "Check &boxes", false, 360, 150)
  chk.onChange = proc(s: Control) = tree.checkboxes = chk.checked
  let expandB = newButton(trSheet, "&Expand all", 360, 196, 130, 32)
  expandB.onClick = proc(s: Control) = tree.expandAll()
  let collapseB = newButton(trSheet, "Colla&pse all", 500, 196, 130, 32)
  collapseB.onClick = proc(s: Control) =
    tree.collapseAll()
    root.expand()
  let hintL = ctx.mutedLabel(trSheet, "Arrow keys move, Left and Right collapse and expand.\nF2 renames a node. The last folder loads its children lazily.",
                             360, 250, 440, 60)
  hintL.autoSize = false
  hintL.wordWrap = true

  # ------------------------------------------------ ListView
  let lvSheet = newTabSheet(pages, "List&View")
  lvSheet.setBounds(0, 0, 808, 508)
  let lv = newListView(lvSheet, 16, 56, 790, 436)
  lv.anchors = {akLeft, akTop, akRight, akBottom}
  lv.smallImages = ctx.icons
  lv.largeImages = ctx.bigIcons
  lv.viewStyle = vsReport
  lv.multiSelect = true
  lv.readOnly = true
  lv.columns.add("Name", 220)
  lv.columns.add("Type", 130)
  lv.columns.add("Size", 110, taRight)
  lv.columns.add("Modified", 120)
  for i, f in Files:
    let it = lv.items.add(f.name, f.kind, sizeText(f.size), f.date)
    it.imageIndex = f.icon
    it.tag = f.size
  var sortCol = -1
  var sortAsc = true
  lv.onColumnClick = proc(s: Control, col: ListColumn) =
    let c = col.index
    sortAsc = if c == sortCol: not sortAsc else: true
    sortCol = c
    lv.sortColumn = c
    lv.sortOrder = if sortAsc: soAscending else: soDescending
    lv.sortItems(proc(a, b: ListItem): int =
      let r = if c == 2: cmp(a.tag, b.tag)
              else: cmp(a.columnText(c).toLowerAscii, b.columnText(c).toLowerAscii)
      if sortAsc: r else: -r)
    ctx.say "Sorted by " & col.caption & (if sortAsc: " (ascending)" else: " (descending)")
  discard newLabel(lvSheet, "View:", 16, 20)
  let style = newComboBox(lvSheet, csDropDownList, 62, 14, 150)
  style.items = ["Report", "List", "Small icons", "Large icons"]
  style.itemIndex = 0
  style.onChange = proc(s: Control) =
    lv.viewStyle = [vsReport, vsList, vsSmallIcon, vsIcon][style.itemIndex]
    ctx.say "ListView style: " & style.text
  let checks = newCheckBox(lvSheet, "Check&boxes", false, 240, 18)
  checks.onChange = proc(s: Control) = lv.checkboxes = checks.checked
  let grid = newCheckBox(lvSheet, "&Grid lines", false, 360, 18)
  grid.onChange = proc(s: Control) = lv.gridLines = grid.checked
  let hl = ctx.mutedLabel(lvSheet, "Click a column header to sort.", 520, 20)
  lv.itemIndex = 4
