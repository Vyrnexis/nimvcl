# The nimvcl showcase: a gallery of (nearly) every control, one page per topic.
#
#   nim c -r examples/showcase.nim
#
# Left: a TreeView of categories. Right: the selected page. The menu, the
# toolbar and the keyboard shortcuts share one ActionList. View > Dark theme
# (Ctrl+D) switches the whole application live.
#
# Keys: Alt+Left / Alt+Right previous / next page, Ctrl+O open a file, Ctrl+D
#       dark theme, F1 about, Ctrl+Q exit, Alt+letter mnemonics.
#
# Screenshot mode (headless, no window needs to be visible):
#   SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software \
#     nim c -r examples/showcase.nim --shots build/showcase_shots
# renders every page at 1100x720 in the light theme (and some in dark) and
# saves PNGs, then exits.
#
# The code is split in modules: showcase_common (icons, helpers),
# showcase_pages_a / _b (the nine pages), showcase_frame (a `frame`).

import std/[os, strutils]
import nimvcl
import ./showcase_common, ./showcase_pages_a, ./showcase_pages_b

const
  PageIcons = [icButton, icText, icSlider, icList, icData, icLayout, icPaint, icDialog, icCode]
  PageSubtitles = [
    "Push buttons, check boxes, radio groups and toggle tool buttons. Hold Alt to see the & mnemonics.",
    "Edit, SpinEdit, ComboBox and a Memo with multilingual text.",
    "TrackBar, ProgressBar, ScrollBar and a Timer-driven animation.",
    "ListBox, TreeView and ListView, in a PageControl.",
    "A virtual ListView over up to a million rows: sorted, filtered and timed.",
    "FlowPanel, GridPanel, anchors and a Splitter.",
    "A PaintBox: shapes, gradients, text and animation on the Canvas.",
    "Message and file dialogs, a PopupMenu, hints and a modal Form.",
    "A reusable `frame` in a few lines of the form macro. The main window and the About box are `form`s too."]

var gShotMode = false                    ## set by `--shots` before the form is built

# ------------------------------------------------------------ about dialog

form AboutForm:
  caption = "About nimvcl"
  width = 440; height = 280
  borderStyle = bsSingle
  position = poScreenCenter
  PaintBox logo:
    left = 28; top = 28; width = 76; height = 76
    onPaint = proc(s: Control, c: Canvas) =
      let r = s.clientRect
      c.fillRoundRect(r, 18, accentBlue)
      c.fillRoundRect(rectF(r.w * 0.22, r.h * 0.22, r.w * 0.56, r.h * 0.3), 6, rgba(255, 255, 255, 235))
      c.fillRoundRect(rectF(r.w * 0.22, r.h * 0.6, r.w * 0.34, r.h * 0.18), 5, rgba(255, 255, 255, 170))
  Label title:
    caption = "nimvcl"
    left = 124; top = 24
    font = font(size = 30, style = {fsBold})
  Label tagline:
    caption = "A Delphi VCL-style UI library for Nim 2.2,\ndrawn with SDL3."
    left = 126; top = 70
  Label facts:
    caption = "Forms, Align and Anchors, actions, menus, a form macro,\nlight and dark themes, HiDPI. About 30 controls."
    left = 28; top = 128
  Button ok:
    caption = "OK"
    left = 330; top = 204; width = 88; height = 32
    isDefault = true; isCancel = true
    modalResult = mrOk

# ------------------------------------------------------------ main form

form ShowcaseForm:
  caption = "nimvcl showcase"
  width = 1100; height = 720
  position = poScreenCenter
  constraints = constraints(minWidth = 860, minHeight = 600)
  var ctx: Showcase
  var current: int = -1
  var pages: seq[Panel]
  var navNodes: seq[TreeNode]
  var actions: ActionList
  var openAct, darkAct, prevAct, nextAct, aboutAct, exitAct: Action
  var toolbarItem, statusItem: MenuItem
  ToolBar toolbar:
    margins = spacing(0)
  StatusBar statusBar:
    height = 26
  Panel navPanel:
    align = alLeft; width = 236
    borderStyle = pbNone
    PaintBox brand:
      align = alTop; height = 76
    TreeView nav:
      align = alClient
      margins = spacing(10, 0, 4, 10)
      hint = "Pick a page"
  Splitter splitter:
    align = alLeft
  Panel content:
    align = alClient
    borderStyle = pbNone

  proc say*(self: ShowcaseForm, text: string) =
    self.statusBar.panels[0].text = text

  proc setDark*(self: ShowcaseForm, on: bool) =
    self.ctx.dark = on
    Application.theme = if on: themeDark() else: themeLight()
    self.darkAct.checked = on
    self.statusBar.panels[2].text = if on: "Dark theme" else: "Light theme"
    self.brand.invalidate()

  proc showPage*(self: ShowcaseForm, i: int) =
    ## Shows page `i` (0 .. 8) and tells the pages that came and went.
    if i < 0 or i >= self.pages.len or i == self.current: return
    let old = self.current
    self.current = i
    for k, p in self.pages: p.visible = k == i
    for h in self.ctx.hooks:
      if h.page == old: h.activate(false)
    for h in self.ctx.hooks:
      if h.page == i: h.activate(true)
    if self.nav.selected != self.navNodes[i]: self.nav.selected = self.navNodes[i]
    self.statusBar.panels[1].text = "Page " & $(i + 1) & " of " & $self.pages.len
    self.prevAct.enabled = i > 0
    self.nextAct.enabled = i < self.pages.high
    self.say PageNames[i]

  proc buildActions(self: ShowcaseForm) =
    let ctx = self.ctx
    self.actions = newActionList(self)
    self.actions.images = ctx.icons
    self.openAct = newAction(self.actions, "&Open files...", shortcut = shortcut("Ctrl+O"))
    self.openAct.hint = "Open files with the native dialog"
    self.openAct.imageIndex = icOpen
    self.openAct.onExecute = proc(a: Action) =
      self.showPage(7)
      if ctx.pickFile != nil: ctx.pickFile()
    self.darkAct = newAction(self.actions, "&Dark theme", shortcut = shortcut("Ctrl+D"))
    self.darkAct.hint = "Switch the whole application between the light and dark theme"
    self.darkAct.imageIndex = icMoon
    self.darkAct.autoCheck = true
    self.darkAct.onExecute = proc(a: Action) = self.setDark(a.checked)
    self.prevAct = newAction(self.actions, "&Previous page", shortcut = shortcut("Alt+Left"))
    self.prevAct.hint = "Go to the previous page"
    self.prevAct.imageIndex = icPrev
    self.prevAct.onExecute = proc(a: Action) = self.showPage(self.current - 1)
    self.nextAct = newAction(self.actions, "&Next page", shortcut = shortcut("Alt+Right"))
    self.nextAct.hint = "Go to the next page"
    self.nextAct.imageIndex = icNext
    self.nextAct.onExecute = proc(a: Action) = self.showPage(self.current + 1)
    self.aboutAct = newAction(self.actions, "&About nimvcl", shortcut = shortcut("F1"))
    self.aboutAct.hint = "About this showcase"
    self.aboutAct.imageIndex = icInfo
    self.aboutAct.onExecute = proc(a: Action) =
      let d = newAboutForm()
      discard d.showModal()
      d.freeWindow()
    self.exitAct = newAction(self.actions, "E&xit", shortcut = shortcut("Ctrl+Q"))
    self.exitAct.hint = "Close the showcase"
    self.exitAct.imageIndex = icExit
    self.exitAct.onExecute = proc(a: Action) = self.close()

  proc buildMenusAndToolbar(self: ShowcaseForm) =
    let mm = newMainMenu(self)
    mm.images = self.ctx.icons
    let file = mm.addItem("&File")
    file.add(newMenuItem()).action = self.openAct
    file.addSeparator()
    file.add(newMenuItem()).action = self.exitAct
    let view = mm.addItem("&View")
    view.add(newMenuItem()).action = self.darkAct
    view.addSeparator()
    view.add(newMenuItem()).action = self.prevAct
    view.add(newMenuItem()).action = self.nextAct
    view.addSeparator()
    self.toolbarItem = view.addItem("Show &toolbar", proc(s: MenuItem) =
      self.toolbar.visible = s.checked)
    self.toolbarItem.autoCheck = true
    self.toolbarItem.checked = true
    self.statusItem = view.addItem("Show &status bar", proc(s: MenuItem) =
      self.statusBar.visible = s.checked)
    self.statusItem.autoCheck = true
    self.statusItem.checked = true
    let help = mm.addItem("&Help")
    help.add(newMenuItem()).action = self.aboutAct

    let bar = self.toolbar
    bar.images = self.ctx.icons
    for (a, sepAfter) in [(self.openAct, true), (self.darkAct, true), (self.prevAct, false),
                          (self.nextAct, true), (self.aboutAct, false), (self.exitAct, false)]:
      let b = newToolButton(bar, "")
      b.action = a
      b.onMouseEnter = proc(s: Control) = self.say s.hint
      b.onMouseLeave = proc(s: Control) = self.say PageNames[max(self.current, 0)]
      if sepAfter: discard newToolButton(bar, kind = tbsDivider)

  proc buildNav(self: ShowcaseForm) =
    let tree = self.nav
    tree.images = self.ctx.icons
    tree.showLines = false
    tree.itemHeight = 28
    let groups = @[("Controls", @[0, 1, 2]), ("Data", @[3, 4]),
                   ("Layout and graphics", @[5, 6]), ("Application", @[7, 8])]
    self.navNodes.setLen(PageNames.len)
    for (g, idx) in groups:
      let gn = tree.items.addChild(nil, g)
      gn.imageIndex = icFolder
      gn.selectedIndex = icOpen
      gn.tag = -1
      for i in idx:
        let n = gn.addChild(PageNames[i])
        n.imageIndex = PageIcons[i]
        n.selectedIndex = PageIcons[i]
        n.tag = i
        self.navNodes[i] = n
      gn.expand()
    tree.onChange = proc(s: Control, n: TreeNode) =
      if n == nil: return
      if n.tag >= 0: self.showPage(n.tag)
      elif n.childCount > 0: tree.selected = n.children[0]
    self.brand.onPaint = proc(s: Control, c: Canvas) =
      let t = s.theme
      let r = s.clientRect
      let logo = rectF(18, 18, 38, 38)
      c.fillRoundRect(logo, 9, accentBlue)
      c.fillRoundRect(rectF(logo.x + 8, logo.y + 8, 22, 11), 3, rgba(255, 255, 255, 235))
      c.fillRoundRect(rectF(logo.x + 8, logo.y + 23, 13, 7), 3, rgba(255, 255, 255, 170))
      c.drawText("nimvcl", font(size = 20, style = {fsBold}), 68, 14, t.text)
      c.drawText("component showcase", font(size = 12), 69, 40, t.textMuted)
      c.line(r.x + 10, r.bottom - 1, r.right - 4, r.bottom - 1, t.border, 1)

  proc buildPages(self: ShowcaseForm) =
    let ctx = self.ctx
    type Builder = proc(ctx: Showcase, body: Container) {.nimcall.}
    let builders: array[9, Builder] = [buildButtons, buildText, buildRanges, buildLists,
                                       buildBigData, buildLayout, buildPainting,
                                       buildDialogs, buildFormMacro]
    for i, b in builders:
      let (page, body) = ctx.newPage(self.content, PageNames[i], PageSubtitles[i])
      self.pages.add page
      b(ctx, body)

  init:
    self.ctx = newShowcase()
    self.ctx.shotMode = gShotMode
    self.ctx.say = proc(text: string) = self.say(text)
    self.statusBar.addPanel("Ready", 640)
    self.statusBar.addPanel("", 130, taCenter)
    let theme = self.statusBar.addPanel("Light theme", 120, taRight)
    discard theme
    self.statusBar.sizeGrip = true
    self.buildActions()
    self.buildMenusAndToolbar()
    self.buildNav()
    self.buildPages()
    self.showPage(0)

# ------------------------------------------------------------ screenshots

proc shoot(f: ShowcaseForm, dir, name: string) =
  discard f.paintIfDirty()
  Application.paintForms()
  if not screenshotWithPopups(f, dir / (name & ".png")): quit "screenshot failed for " & name
  echo "wrote ", dir / (name & ".png")

const ShotNames = ["buttons", "text", "ranges", "lists", "bigdata", "layout", "painting",
                   "dialogs", "formmacro"]

proc shots(dir: string) =
  createDir dir
  gShotMode = true
  Application.init()
  let f = newShowcaseForm()
  f.show()
  f.syncMetrics()
  f.win.setLogicalSize(1100, 720)
  f.syncMetrics()
  for i in 0 ..< ShotNames.len:
    f.showPage(i)
    f.shoot(dir, "page" & $(i + 1) & "-" & ShotNames[i] & "-light")
  f.showPage(3)
  f.ctx.listPages.tabIndex = 1
  f.shoot(dir, "page4b-tree-light")
  f.ctx.listPages.tabIndex = 2
  f.shoot(dir, "page4c-listview-light")
  f.ctx.listPages.tabIndex = 0
  f.showPage(7)
  f.ctx.popupMenu.popup(f, 360, 470)
  f.shoot(dir, "popupmenu-light")
  f.ctx.popupMenu.close()
  f.setDark(true)
  f.showPage(3)
  f.ctx.listPages.tabIndex = 2
  f.shoot(dir, "page4c-listview-dark")
  f.ctx.listPages.tabIndex = 0
  for i in [0, 2, 3, 4, 6, 8]:
    f.showPage(i)
    f.shoot(dir, "page" & $(i + 1) & "-" & ShotNames[i] & "-dark")
  f.setDark(false)
  f.showPage(0)
  discard f.paintIfDirty()
  f.menu.openDropdown(1, selectFirst = true)      # the View menu
  Application.paintForms()
  f.shoot(dir, "menu-view-light")
  Application.shutdown()

proc main() =
  let args = commandLineParams()
  if args.len >= 1 and args[0] == "--shots":
    shots(if args.len >= 2: args[1] else: "build/showcase_shots")
  else:
    Application.init()
    Application.run(newShowcaseForm())

when isMainModule:
  main()
