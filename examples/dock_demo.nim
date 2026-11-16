# Docking demo: an IDE-like arrangement of dock panels.
#
#   left:    "Palette" and "Structure" as tabs
#   centre:  three editor panels (tabs of one group), "Messages" below them
#   right:   "Inspector"
#
# Drag a tab by its title: guides appear over the group under the pointer and at
# the edges of the site; drop on one to dock there, outside the window to float
# the panel. Double click a tab to float or dock it, right click for a menu,
# Ctrl+Tab / Ctrl+Shift+Tab switch tabs, Ctrl+F4 closes the active panel.
# The View menu shows and hides panels; File saves, loads and resets the layout.
#
# Screenshot mode (headless, no window needs to be visible):
#   SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software \
#     nim c -r examples/dock_demo.nim --shots build/dock_shots
# renders the initial layout, a drag in progress, the result of the drop, a
# floating window and the dark theme, saves PNGs, then exits.
#
# Build: nim c --outdir:build examples/dock_demo.nim

import std/os
import nimvcl

const
  LayoutFile = "dock_layout.json"
  icPalette = 0
  icStructure = 1
  icEditor = 2
  icInspector = 3
  icMessages = 4

const Sample = """import std/strutils

type
  Shape = ref object of RootObj
    name: string

method area(s: Shape): float {.base.} = 0.0

proc describe(s: Shape): string =
  s.name & " has an area of " & formatFloat(s.area, ffDecimal, 2)

when isMainModule:
  echo describe(Shape(name: "empty"))
"""

# ------------------------------------------------------------------ icons

proc makeIcon(inside: proc(u, v: float): bool): Image =
  ## A 16x16 logical icon drawn at 2x, 3x3 supersampled.
  const N = 32
  result = newImage(N, N)
  for y in 0 ..< N:
    for x in 0 ..< N:
      var hit = 0
      for sy in 0 .. 2:
        for sx in 0 .. 2:
          if inside((x.float + (sx.float + 0.5) / 3) / N, (y.float + (sy.float + 0.5) / 3) / N):
            inc hit
      if hit > 0: result.setPixel(x, y, rgba(0x4c, 0x8b, 0xe8, hit * 255 div 9))

proc box(u, v, x0, y0, x1, y1: float): bool = u >= x0 and u <= x1 and v >= y0 and v <= y1

proc makeIcons(): ImageList =
  result = newImageList(16, 16)
  # palette: a 2x2 grid of tiles
  result.add makeIcon(proc(u, v: float): bool =
    box(u, v, 0.12, 0.12, 0.46, 0.46) or box(u, v, 0.54, 0.12, 0.88, 0.46) or
    box(u, v, 0.12, 0.54, 0.46, 0.88) or box(u, v, 0.54, 0.54, 0.88, 0.88))
  # structure: an indented tree
  result.add makeIcon(proc(u, v: float): bool =
    box(u, v, 0.1, 0.14, 0.5, 0.26) or box(u, v, 0.3, 0.44, 0.9, 0.56) or
    box(u, v, 0.3, 0.74, 0.9, 0.86) or box(u, v, 0.18, 0.26, 0.26, 0.8) or
    box(u, v, 0.18, 0.48, 0.3, 0.52) or box(u, v, 0.18, 0.78, 0.3, 0.82))
  # editor: a page with lines
  result.add makeIcon(proc(u, v: float): bool =
    (box(u, v, 0.2, 0.08, 0.8, 0.92) and not box(u, v, 0.28, 0.16, 0.72, 0.84)) or
    box(u, v, 0.34, 0.3, 0.66, 0.38) or box(u, v, 0.34, 0.5, 0.66, 0.58) or
    box(u, v, 0.34, 0.7, 0.54, 0.78))
  # inspector: sliders
  result.add makeIcon(proc(u, v: float): bool =
    box(u, v, 0.1, 0.22, 0.9, 0.3) or box(u, v, 0.1, 0.46, 0.9, 0.54) or
    box(u, v, 0.1, 0.7, 0.9, 0.78) or box(u, v, 0.55, 0.14, 0.65, 0.38) or
    box(u, v, 0.28, 0.38, 0.38, 0.62) or box(u, v, 0.68, 0.62, 0.78, 0.86))
  # messages: a speech bubble
  result.add makeIcon(proc(u, v: float): bool =
    (box(u, v, 0.1, 0.14, 0.9, 0.7) and not box(u, v, 0.18, 0.22, 0.82, 0.62)) or
    box(u, v, 0.24, 0.7, 0.4, 0.88) or box(u, v, 0.3, 0.34, 0.7, 0.42) or
    box(u, v, 0.3, 0.46, 0.56, 0.54))

# --------------------------------------------------------------- the form

type
  DockDemo = ref object of Form
    site: DockSite
    status: StatusBar
    palette, structure, ed1, ed2, ed3, inspector, messages: DockPanel
    viewItems: seq[MenuItem]
    defaultLayout: string
    dark: MenuItem

proc say(d: DockDemo, text: string) =
  d.status.panels[0].text = text

proc newEditor(text: string): Memo =
  result = newMemo(nil, text)
  result.font = currentTheme().monoFont

proc buildPalette(): ListBox =
  result = newListBox(nil)
  for n in ["Button", "CheckBox", "ComboBox", "Edit", "Label", "ListBox", "Memo",
            "Panel", "PageControl", "RadioButton", "ScrollBox", "Splitter",
            "StatusBar", "TrackBar", "TreeView"]:
    result.add n

proc buildStructure(): TreeView =
  result = newTreeView(nil)
  let root = result.items.addChild(nil, "MainForm")
  let top = root.addChild("TopPanel")
  top.addChild("OkButton")
  top.addChild("CancelButton")
  let body = root.addChild("PageControl1")
  body.addChild("TabSheet1")
  body.addChild("TabSheet2")
  root.addChild("StatusBar1")
  result.expandAll()

proc buildInspector(): ListView =
  result = newListView(nil)
  result.viewStyle = vsReport
  result.columns.add("Property", 110)
  result.columns.add("Value", 120)
  for (k, v) in [("Caption", "MainForm"), ("Align", "alClient"), ("Width", "640"),
                 ("Height", "480"), ("Color", "clWindow"), ("Enabled", "true"),
                 ("Visible", "true"), ("TabStop", "false")]:
    result.items.add(k, v)

proc buildMessages(): ListBox =
  result = newListBox(nil)
  for n in ["Hint: [nimvcl] build started", "Hint: 412 lines; 0.31s; 31MiB",
            "Warning: unused import: strutils", "Success: build finished"]:
    result.add n

proc updateViewChecks(d: DockDemo) =
  for i, p in d.site.panels:
    if i < d.viewItems.len: d.viewItems[i].checked = p.state != dpHidden

proc buildLayout(d: DockDemo) =
  let s = d.site
  s.dock(d.ed1)
  s.dock(d.ed2, d.ed1, dsCenter)
  s.dock(d.ed3, d.ed1, dsCenter)
  s.dock(d.inspector, nil, dsRight, 0.2)
  s.dock(d.palette, nil, dsLeft, 0.2)
  s.dock(d.structure, d.palette, dsCenter)
  s.dock(d.messages, d.ed1, dsBottom, 0.27)
  d.ed1.activate()
  d.palette.activate()

proc setDark(d: DockDemo, on: bool) =
  Application.theme = if on: themeDark() else: themeLight()
  d.dark.checked = on

proc newDockDemo(): DockDemo =
  let d = DockDemo()
  d.initForm()
  d.caption = "nimvcl dock demo"
  d.setBounds(0, 0, 1180, 720)
  let icons = makeIcons()

  let menu = newMainMenu(d)
  let file = menu.addItem("&File")
  let view = menu.addItem("&View")

  d.status = newStatusBar(d)
  d.status.addPanel("Drag a tab by its title to rearrange the panels", 520)
  d.status.addPanel("", 200, taRight)

  let site = newDockSite(d)
  site.align = alClient
  d.site = site

  proc panel(name, caption: string, content: Control, icon: int, closable = true): DockPanel =
    result = newDockPanel(site, name, caption, content, closable)
    result.images = icons
    result.imageIndex = icon
  d.palette = panel("palette", "Palette", buildPalette(), icPalette)
  d.structure = panel("structure", "Structure", buildStructure(), icStructure)
  d.ed1 = panel("main", "main.nim", newEditor(Sample), icEditor)
  d.ed2 = panel("util", "util.nim", newEditor("# helpers\nproc twice(x: int): int = 2 * x\n"), icEditor)
  d.ed3 = panel("notes", "notes.md", newEditor("# Notes\n\n- docking panels\n- floating windows\n"), icEditor)
  d.inspector = panel("inspector", "Inspector", buildInspector(), icInspector)
  d.messages = panel("messages", "Messages", buildMessages(), icMessages, closable = false)
  d.buildLayout()
  d.defaultLayout = site.saveLayout()

  # the View menu mirrors the panels
  for p in site.panels:
    let nm = p.name                     # captured by the closure below
    let item = view.addItem(p.caption, proc(sender: MenuItem) =
      let q = site.findPanel(nm)
      if q.state == dpHidden: q.show() else: q.close())
    d.viewItems.add item
  view.addSeparator()
  d.dark = view.addItem("&Dark theme", proc(sender: MenuItem) = d.setDark(not d.dark.checked))
  d.updateViewChecks()
  site.onDock = proc(s: DockSite, p: DockPanel) = d.updateViewChecks()
  site.onUndock = proc(s: DockSite, p: DockPanel) = d.updateViewChecks()
  site.onActivate = proc(s: DockSite, p: DockPanel) = d.say("Active: " & p.caption)

  file.addItem("&Save layout", proc(sender: MenuItem) =
    writeFile(LayoutFile, site.saveLayout())
    d.say("Layout saved to " & LayoutFile), shortcut("Ctrl+S"))
  file.addItem("&Load layout", proc(sender: MenuItem) =
    if fileExists(LayoutFile) and site.loadLayout(readFile(LayoutFile)):
      d.say("Layout loaded from " & LayoutFile)
    else:
      d.say("No saved layout"), shortcut("Ctrl+L"))
  file.addItem("&Reset layout", proc(sender: MenuItem) =
    discard site.loadLayout(d.defaultLayout)
    d.say("Layout reset"), shortcut("Ctrl+R"))
  file.addSeparator()
  file.addItem("E&xit", proc(sender: MenuItem) = d.close(), shortcut("Alt+F4"))
  d

# ------------------------------------------------------------ screenshots

proc shoot(f: Form, dir, name: string) =
  discard f.paintIfDirty()
  Application.paintForms()
  if not screenshotWithPopups(f, dir / (name & ".png")): quit "screenshot failed for " & name
  echo "wrote ", dir / (name & ".png")

proc ev(f: Form, kind: EventKind, p: PointF, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: p.x, y: p.y,
                                     button: mbLeft, clicks: 1, shift: shift))

proc tabPoint(p: DockPanel): PointF =
  let g = p.group
  let r = g.tabRects[g.panels.find(p)]
  g.clientToForm(pointF(r.x + 18, r.h / 2))

proc center(r: RectF): PointF = pointF(r.x + r.w / 2, r.y + r.h / 2)

proc guidePoint(d: DockDemo, g: DockTabs, side: DockSide): PointF =
  d.site.clientToForm(d.site.guideRect(g, side).center)

proc shots(dir: string) =
  createDir dir
  Application.init()
  let d = newDockDemo()
  d.show()
  d.syncMetrics()
  d.win.setLogicalSize(1180, 720)
  d.syncMetrics()
  d.shoot(dir, "1-initial-light")

  # a drag in progress: the Inspector over the left guide of the editors
  let a = d.inspector.tabPoint
  d.ev(ekMouseDown, a)
  d.ev(ekMouseMove, pointF(a.x - 40, a.y + 60), {ssLeft})
  d.ev(ekMouseMove, d.guidePoint(d.ed1.group, dsLeft), {ssLeft})
  d.shoot(dir, "2-drag-light")
  d.ev(ekMouseMove, d.guidePoint(d.ed1.group, dsCenter), {ssLeft})
  d.shoot(dir, "2b-drag-centre-light")
  d.ev(ekMouseMove, d.guidePoint(nil, dsBottom), {ssLeft})
  d.shoot(dir, "2c-drag-edge-light")
  d.ev(ekMouseMove, d.guidePoint(d.ed1.group, dsLeft), {ssLeft})
  d.ev(ekMouseUp, d.guidePoint(d.ed1.group, dsLeft))
  d.shoot(dir, "3-after-drop-light")

  # a floating panel in its own window
  d.messages.makeFloating(rectF(300, 200, 420, 220))
  d.shoot(dir, "4-main-with-float-light")
  d.messages.floatForm.shoot(dir, "4b-floating-window-light")
  d.messages.dockBack()
  discard d.site.loadLayout(d.defaultLayout)

  d.setDark(true)
  d.shoot(dir, "5-initial-dark")
  let b = d.ed2.tabPoint
  d.ev(ekMouseDown, b)
  d.ev(ekMouseMove, pointF(b.x + 20, b.y + 50), {ssLeft})
  d.ev(ekMouseMove, d.guidePoint(d.palette.group, dsRight), {ssLeft})
  d.shoot(dir, "6-drag-dark")
  d.ev(ekMouseMove, d.guidePoint(d.palette.group, dsRight), {ssLeft})
  d.ev(ekMouseUp, d.guidePoint(d.palette.group, dsRight))
  d.shoot(dir, "7-after-drop-dark")
  Application.shutdown()

proc main() =
  let args = commandLineParams()
  if args.len >= 1 and args[0] == "--shots":
    shots(if args.len >= 2: args[1] else: "build/dock_shots")
  else:
    Application.init()
    Application.run(newDockDemo())

when isMainModule:
  main()
