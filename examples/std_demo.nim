# Phase 5 demo: the standard controls on the pages of one PageControl, with a
# ToolBar on top, a StatusBar at the bottom and a Splitter between the left
# panel and the pages. Buttons on the last page open every dialog.
#
# Env (headless screenshots):
#   NIMVCL_SCREENSHOT=file.bmp   lay out, render one frame and exit
#   NIMVCL_PAGE=n                active page (0-3)
#   NIMVCL_SCALE=1.5  NIMVCL_DARK=1
#   NIMVCL_DIALOG=info|warning|error|confirm|input  render that dialog instead
#
# Build: nim c --outdir:build examples/std_demo.nim

import std/[os, strutils]
import nimvcl

var
  status: StatusBar
  pc: PageControl
  results: Label

proc say(s: string) =
  if status != nil and status.panels.len > 1: status.panels[1].text = s

proc glyph(kind: string): GlyphProc =
  ## Tiny icons drawn with the canvas.
  result = proc(c: Canvas, r: RectF, col: Color) =
    case kind
    of "new":
      c.strokeRoundRect(r.inflate(-2), 2, col, 1.5)
      c.line(r.x + 6, r.y + 8, r.right - 6, r.y + 8, col, 1.5)
    of "open":
      c.strokeRoundRect(rectF(r.x + 1, r.y + 4, r.w - 2, r.h - 7), 2, col, 1.5)
      c.line(r.x + 1, r.y + 4, r.x + 6, r.y + 2, col, 1.5)
    of "save":
      c.strokeRoundRect(r.inflate(-2), 2, col, 1.5)
      c.fillRect(rectF(r.x + 5, r.y + 3, r.w - 10, 4), col)
    of "bold":
      c.textRect("B", font(size = 14, style = {fsBold}), r, col, taCenter, vaCenter)
    of "italic":
      c.textRect("I", font(size = 14, style = {fsItalic}), r, col, taCenter, vaCenter)
    of "left", "center", "right":
      for i in 0 ..< 4:
        let w = if i mod 2 == 0: r.w - 4 else: r.w - 8
        let x = case kind
                of "left": r.x + 2
                of "center": r.x + (r.w - w) / 2
                else: r.right - 2 - w
        c.line(x, r.y + 3 + float32(i) * 3.5, x + w, r.y + 3 + float32(i) * 3.5, col, 1.5)
    else: discard

proc buildToolBar(f: Form) =
  let tb = newToolBar(f)
  tb.name = "toolbar"
  for (cap, g) in [("New", "new"), ("Open", "open"), ("Save", "save")]:
    let b = newToolButton(tb, cap, tbsButton, glyph(g))
    b.hint = cap & " file"
    b.onClick = proc(s: Control) = say s.caption & " clicked"
  discard newToolButton(tb, "", tbsDivider)
  let bold = newToolButton(tb, "", tbsCheck, glyph("bold"))
  let ital = newToolButton(tb, "", tbsCheck, glyph("italic"))
  bold.hint = "Bold"; ital.hint = "Italic"
  bold.down = true
  discard newToolButton(tb, "", tbsDivider)
  for (g, down) in [("left", true), ("center", false), ("right", false)]:
    let b = newToolButton(tb, "", tbsCheck, glyph(g))
    b.groupIndex = 1
    b.down = down
    b.hint = "Align " & g
    b.onClick = proc(s: Control) = say "align " & g
  let dis = newToolButton(tb, "Disabled")
  dis.enabled = false

proc buildProgressPage(s: TabSheet) =
  let l1 = newLabel(s, "ProgressBar", 16, 14)
  l1.font = font(size = 14, style = {fsBold})
  let p1 = newProgressBar(s, 16, 44, 300, 18)
  p1.position = 62
  let p2 = newProgressBar(s, 16, 76, 300, 18)
  p2.style = pbsMarquee
  let p3 = newProgressBar(s, 16, 108, 300, 18)
  p3.position = 25
  p3.enabled = false
  let pv = newProgressBar(s, 340, 14, 18, 112)
  pv.orientation = orVertical
  pv.position = 70
  let step = newButton(s, "Step +10", 16, 140, 100)
  step.onClick = proc(c: Control) =
    p1.step = 10
    p1.stepIt()
    if p1.position >= 100: p1.position = 0
    say "progress " & $p1.position

  let l2 = newLabel(s, "TrackBar", 16, 196)
  l2.font = font(size = 14, style = {fsBold})
  let val = newLabel(s, "position: 4", 240, 238)
  let tb = newTrackBar(s, 16, 228, 210, 36)
  tb.max = 10
  tb.position = 4
  tb.onChange = proc(c: Control) = val.caption = "position: " & $TrackBar(c).position
  let tb2 = newTrackBar(s, 340, 160, 36, 130)
  tb2.orientation = orVertical
  tb2.max = 10
  tb2.position = 7
  tb2.frequency = 2
  let tb3 = newTrackBar(s, 16, 270, 210, 32)
  tb3.max = 100
  tb3.frequency = 0
  tb3.position = 30
  tb3.enabled = false

  let l3 = newLabel(s, "SpinEdit", 420, 14)
  l3.font = font(size = 14, style = {fsBold})
  let sp = newSpinEdit(s, 25, 420, 44, 110)
  sp.minValue = -50
  sp.maxValue = 200
  sp.increment = 5
  sp.onChange = proc(c: Control) = say "spin = " & $SpinEdit(c).value
  discard newLabel(s, "-50 .. 200 step 5", 420, 80)
  let sp2 = newSpinEdit(s, 3, 420, 110, 110)
  sp2.enabled = false

proc buildLayoutPage(s: TabSheet) =
  let l1 = newLabel(s, "FlowPanel (wraps)", 16, 14)
  l1.font = font(size = 14, style = {fsBold})
  let fp = newFlowPanel(s, 16, 40, 360, 120)
  fp.borderStyle = pbSingle
  fp.padding = spacing(6)
  for i in 1 .. 8:
    let b = newButton(fp, "Item " & $i)
    b.width = 70 + float32(i mod 3) * 14
    b.margins = spacing(3)
  let l2 = newLabel(s, "GridPanel (abs, auto, percent; spans)", 16, 176)
  l2.font = font(size = 14, style = {fsBold})
  let g = newGridPanel(s, 16, 202, 460, 150)
  g.borderStyle = pbSingle
  g.padding = spacing(6)
  g.columns = @[gsAbsolute(100), gsAuto(), gsPercent(50), gsPercent(50)]
  g.rows = @[gsAbsolute(30), gsPercent(50), gsPercent(50)]
  let head = newButton(g, "Header spans all columns")
  g.setCell(head, 0, 0, 1, 4)
  head.margins = spacing(2)
  for (cap, r, c) in [("abs 100", 1, 0), ("auto", 1, 1), ("50%", 1, 2), ("50%", 1, 3),
                      ("row 2", 2, 0)]:
    let b = newButton(g, cap)
    g.setCell(b, r, c)
    b.margins = spacing(2)
  let wide = newButton(g, "span 2 x 3")
  g.setCell(wide, 2, 1, 1, 3)
  wide.margins = spacing(2)

proc buildTabsPage(s: TabSheet) =
  let l1 = newLabel(s, "TabControl (tabs only)", 16, 14)
  l1.font = font(size = 14, style = {fsBold})
  let tc = newTabControl(s, @["General", "Network", "Display", "Advanced"], 16, 40, 420, 120)
  let info = newLabel(tc, "Selected tab: General", 16, 44)
  tc.onChange = proc(c: Control) =
    info.caption = "Selected tab: " & tc.tabs[tc.tabIndex]
  let l2 = newLabel(s, "Nested PageControl with overflowing tabs", 16, 180)
  l2.font = font(size = 14, style = {fsBold})
  let inner = newPageControl(s, 16, 206, 300, 130)
  for i in 1 .. 7:
    let sh = newTabSheet(inner, "Sheet " & $i)
    discard newLabel(sh, "Content of sheet " & $i, 12, 12)
  inner.activePageIndex = 5
  let hintLbl = newLabel(s, "Ctrl+Tab and Ctrl+PageUp/Down switch the pages of the PageControl that has focus.", 340, 206, 220, 60)
  hintLbl.wordWrap = true

proc buildDialogPage(s: TabSheet) =
  let l1 = newLabel(s, "Message dialogs", 16, 14)
  l1.font = font(size = 14, style = {fsBold})
  var y = 44'f32
  results = newLabel(s, "(results appear here)", 16, 300, 520, 40)
  for (cap, t, bs) in [("Information", mtInformation, {mbOK}),
                       ("Warning", mtWarning, {mbOK, mbCancel}),
                       ("Error", mtError, {mbAbort, mbRetry, mbIgnore}),
                       ("Confirmation", mtConfirmation, {mbYes, mbNo, mbCancel})]:
    let b = newButton(s, cap & "...", 16, y, 150)
    y += 36
    b.onClick = proc(c: Control) =
      let r = messageDlg("This is a " & cap.toLowerAscii & " message. It wraps when it " &
                         "gets long enough to need a second line.", t, bs)
      results.caption = cap & " -> " & $r
  let sm = newButton(s, "showMessage", 190, 44, 150)
  sm.onClick = proc(c: Control) = showMessage("Plain message without an icon.")
  let iq = newButton(s, "inputQuery", 190, 80, 150)
  iq.onClick = proc(c: Control) =
    var v = "Nim"
    if inputQuery("Language", "Favourite language:", v): results.caption = "input: " & v
    else: results.caption = "input cancelled"
  let l2 = newLabel(s, "File dialogs (native)", 380, 14)
  l2.font = font(size = 14, style = {fsBold})
  proc show(ok: bool, files: seq[string]) =
    results.caption = if ok: "chosen: " & files.join(", ") else: "cancelled"
  let od = newOpenDialog(s)
  od.title = "Open files"
  od.multiSelect = true
  od.filters = @[("Nim files", "nim"), ("All files", "*")]
  let sd = newSaveDialog(s)
  sd.title = "Save as"
  let fd = newSelectFolderDialog(s)
  let b1 = newButton(s, "Open...", 380, 44, 130)
  b1.onClick = proc(c: Control) = od.execute(show)
  let b2 = newButton(s, "Save...", 380, 80, 130)
  b2.onClick = proc(c: Control) = sd.execute(show)
  let b3 = newButton(s, "Folder...", 380, 116, 130)
  b3.onClick = proc(c: Control) = fd.execute(show)

proc buildMain(): Form =
  let f = newForm(nil, 980, 560)
  f.caption = "nimvcl standard controls"
  buildToolBar(f)
  status = newStatusBar(f)
  status.addPanel("Ready", 140)
  status.addPanel("", 220)
  status.addPanel("nimvcl 0.5", 100, taRight)
  status.sizeGrip = true
  let left = newPanel(f, "", 0, 0, 190)
  left.align = alLeft
  left.borderStyle = pbSingle
  left.margins = spacing(8, 8, 0, 8)
  let lh = newLabel(left, "Navigation", 12, 10)
  lh.font = font(size = 14, style = {fsBold})
  for i, n in ["Progress", "Layouts", "Tabs", "Dialogs"]:
    let b = newButton(left, n, 12, 40 + float32(i) * 34, 160)
    b.flat = true
    b.onClick = proc(c: Control) = pc.activePageIndex = i
  let sp = newSplitter(f)
  sp.minSize = 120
  pc = newPageControl(f)
  pc.align = alClient
  pc.margins = spacing(0, 8, 8, 8)
  buildProgressPage(newTabSheet(pc, "Progress && Sliders"))
  buildLayoutPage(newTabSheet(pc, "Layouts"))
  buildTabsPage(newTabSheet(pc, "Tabs"))
  buildDialogPage(newTabSheet(pc, "Dialogs"))
  pc.onChange = proc(c: Control) =
    status.panels[0].text = pc.activePage.caption
  f

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let dlg = getEnv("NIMVCL_DIALOG")
  if dlg.len > 0 and shot.len > 0:
    let text = "Delete the selected item? This is a longer message to show how the " &
               "text wraps inside the dialog."
    let d: Form =
      case dlg
      of "info": newMessageDlg("The file was saved.", mtInformation)
      of "warning": newMessageDlg(text, mtWarning, {mbOK, mbCancel})
      of "error": newMessageDlg("The operation failed.\nCheck the log for details.", mtError,
                                {mbAbort, mbRetry, mbIgnore}, mbRetry)
      of "input": newInputDlg("Language", "Favourite language:", "Nim")
      else: newMessageDlg(text, mtConfirmation, {mbYes, mbNo, mbCancel}, mbNo)
    if not d.screenshot(shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  size ", d.width, "x", d.height
    Application.shutdown()
    return
  let f = buildMain()
  let page = getEnv("NIMVCL_PAGE")
  if page.len > 0: pc.activePageIndex = parseInt(page)
  if shot.len > 0:
    f.show()
    f.syncMetrics()
    discard f.paintIfDirty()
    if not f.screenshot(shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    Application.run(f)

main()
