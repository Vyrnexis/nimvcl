# Phase 5 demo: menus, context menu and hints.
#
# Keys: Alt+F / Alt+E / Alt+V or F10 open the menus, arrows navigate, Enter
#       activates, Esc closes. Ctrl+N/O/S/Z, Ctrl+Shift+Z, Ctrl+X/C/V/A, F11
#       fire from anywhere. Right click (or Shift+F10 / Menu key) on the grey
#       panel opens a context menu. Hover a button for its hint.
#
# Env (headless screenshots; popups are drawn over the form in the image):
#   NIMVCL_SCREENSHOT=path.bmp   lay out, render one frame and exit
#   NIMVCL_OPEN_MENU=File        open a top menu (File, Edit, View)
#   NIMVCL_OPEN_SUB=Recent       with it: open that submenu (hot item of the menu)
#   NIMVCL_CONTEXT=1             open the panel's context menu
#   NIMVCL_HINT=name             show the hint of this control (okBtn, helpBtn)
#   NIMVCL_DARK=1                dark theme
#   NIMVCL_SCALE                 force the display scale
#
# Build: nim c --outdir:build examples/menu_demo.nim

import std/[os, strutils, monotimes, times]
import nimvcl
import nimvcl/controls/[menus, hint]

var
  status: Label
  form: Form
  count = 0

proc say(s: string) =
  inc count
  if status != nil: status.caption = "#" & $count & "  " & s

proc act(name: string): MenuItemEvent =
  result = proc(s: MenuItem) =
    var t = name
    if s.checked: t.add " (checked)"
    say t

proc setTheme(dark: bool) =
  Application.theme = if dark: themeDark() else: themeLight()

proc buildMenus(f: Form): MainMenu =
  let mm = newMainMenu(f)
  let file = mm.addItem("&File")
  file.addItem("&New", act("New"), shortcut("Ctrl+N"))
  file.addItem("&Open...", act("Open"), shortcut("Ctrl+O"))
  let recent = file.addItem("Open &recent")
  for n in ["notes.txt", "todo.md", "report.pdf"]: recent.addItem(n, act("Recent " & n))
  file.addSeparator()
  file.addItem("&Save", act("Save"), shortcut("Ctrl+S"))
  file.addItem("Save &as...", act("Save as"), shortcut("Ctrl+Shift+S")).enabled = false
  file.addSeparator()
  file.addItem("E&xit", proc(s: MenuItem) = f.close(), shortcut("Ctrl+Q"))

  let edit = mm.addItem("&Edit")
  edit.addItem("&Undo", act("Undo"), shortcut("Ctrl+Z"))
  edit.addItem("&Redo", act("Redo"), shortcut("Ctrl+Shift+Z"))
  edit.addSeparator()
  edit.addItem("Cu&t", act("Cut"), shortcut("Ctrl+X"))
  edit.addItem("&Copy", act("Copy"), shortcut("Ctrl+C"))
  edit.addItem("&Paste", act("Paste"), shortcut("Ctrl+V"))
  edit.addSeparator()
  edit.addItem("Select &all", act("Select all"), shortcut("Ctrl+A"))

  let view = mm.addItem("&View")
  let bar = view.addItem("&Status bar", act("Status bar"))
  bar.autoCheck = true
  bar.checked = true
  let grid = view.addItem("&Grid", act("Grid"), shortcut("F11"))
  grid.autoCheck = true
  view.addSeparator()
  let light = view.addItem("&Light theme", proc(s: MenuItem) = setTheme(false))
  let dark = view.addItem("&Dark theme", proc(s: MenuItem) = setTheme(true))
  for t in [light, dark]:
    t.radioItem = true
    t.groupIndex = 1
  light.checked = true
  let zoom = view.addItem("&Zoom")
  for z in ["50%", "100%", "150%", "200%"]:
    let it = zoom.addItem(z, act("Zoom " & z))
    it.radioItem = true
    it.groupIndex = 2
    it.checked = z == "100%"
  mm

proc buildMain(): Form =
  let f = newForm(nil, 560, 380)
  f.caption = "Menus and hints"
  form = f
  discard buildMenus(f)
  status = newLabel(f, "Ready")
  status.align = alBottom
  status.margins = spacing(10, 8)
  let pnl = newPanel(f, "Right click here for a context menu", 0, 0)
  pnl.name = "ctx"
  pnl.align = alClient
  pnl.margins = spacing(12)
  let ok = newButton(f, "OK", 20, 60, 100, 30)
  ok.name = "okBtn"
  ok.hint = "Accept the changes"
  ok.isDefault = true
  ok.onClick = proc(s: Control) = say "OK clicked"
  let help = newButton(f, "Help", 130, 60, 100, 30)
  help.name = "helpBtn"
  help.hint = "Open the help.\nF1 also works."
  help.onClick = proc(s: Control) = say "Help clicked"
  for b in [ok, help]: pnl.insertControl b
  let pm = newPopupMenu(f)
  pm.addItem("&Copy", act("Context: Copy"), shortcut("Ctrl+Shift+C"))
  pm.addItem("&Paste", act("Context: Paste"))
  pm.addSeparator()
  let sub = pm.addItem("&Align")
  for a in ["Left", "Center", "Right"]: sub.addItem(a, act("Align " & a))
  pm.addItem("&Delete", act("Context: Delete")).enabled = false
  attachPopupMenu(pnl, pm)
  f

proc findByName(c: Control, name: string): Control =
  if c.name == name: return c
  if c of Container:
    for ch in Container(c).children:
      result = findByName(ch, name)
      if result != nil: return

proc topItemIndex(f: Form, name: string): int =
  let mm = f.menu
  for i in 0 ..< mm.items.count:
    if parseMnemonic(mm.items[i].caption).text.toLowerAscii == name.toLowerAscii: return i
  -1

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let f = buildMain()
  if shot.len > 0:
    f.show()
    f.syncMetrics()
    discard f.paintIfDirty()
    let s = f.win.scale
    let openMenu = getEnv("NIMVCL_OPEN_MENU")
    if openMenu.len > 0:
      let i = topItemIndex(f, openMenu)
      if i >= 0:
        f.menu.openDropdown(i, selectFirst = true)
        let sub = getEnv("NIMVCL_OPEN_SUB")
        if sub.len > 0:
          # walk down to the item, then Right opens it
          var guard = 0
          while guard < 20:
            inc guard
            let h = hotMenuItem(topPopup(f))
            if h != nil and parseMnemonic(h.caption).text.toLowerAscii.startsWith(sub.toLowerAscii): break
            Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id,
                                               key: keyDown))
          Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id,
                                             key: keyRight))
    if getEnv("NIMVCL_CONTEXT") == "1":
      let pnl = findByName(f, "ctx")
      let p = pnl.clientToForm(pointF(40, 120))
      let pm = popupMenuOf(pnl)
      discard pm.popup(f, p.x, p.y)
      let al = getEnv("NIMVCL_OPEN_SUB")
      if al.len > 0:
        Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: keyDown))
        Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: keyDown))
        Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: keyDown))
        Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: keyRight))
    let hintName = getEnv("NIMVCL_HINT")
    if hintName.len > 0:
      let c = findByName(f, hintName)
      if c != nil:
        Application.hintPause = 50
        let o = c.clientToForm(pointF(c.width / 2, c.height / 2))
        Application.dispatch(PlatformEvent(kind: ekMouseMove, windowId: f.win.id,
                                           x: o.x * s, y: o.y * s))
        let t0 = getMonoTime()
        while not hintVisible() and (getMonoTime() - t0).inMilliseconds < 2000:
          Application.processMessages(20)
    Application.paintForms()
    if not screenshotWithPopups(f, shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    Application.run(f)

main()
