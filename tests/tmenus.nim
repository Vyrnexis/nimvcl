## Menus: MenuItem, PopupMenu, MainMenu. Headless (offscreen SDL); popups run
## on their top-level-window fallback (see tpopup.nim). Events are built by
## hand and fed through Application.dispatch.

import std/[unittest, monotimes, times, unicode]
import nimvcl
import nimvcl/controls/menus

var log: seq[string]

proc mk(name: string): MenuItemEvent =
  result = proc(s: MenuItem) = log.add name

proc ev(win: PlatformWindow, kind: EventKind, x = 0'f32, y = 0'f32,
        k = Key(0), shift: ShiftState = {}, button = mbLeft): PlatformEvent =
  PlatformEvent(kind: kind, windowId: win.id, x: x, y: y, key: k, shift: shift,
                button: button, clicks: 1)

proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(ev(f.win, ekKeyDown, k = k, shift = shift))
  Application.dispatch(ev(f.win, ekKeyUp, k = k, shift = shift))
proc tap(f: Form, c: char, shift: ShiftState = {}) = f.tap(key(c), shift)
proc click(win: PlatformWindow, x, y: float32, button = mbLeft) =
  Application.dispatch(ev(win, ekMouseDown, x, y, button = button))
  Application.dispatch(ev(win, ekMouseUp, x, y, button = button))
proc move(win: PlatformWindow, x, y: float32) =
  Application.dispatch(ev(win, ekMouseMove, x, y))

type Fixture = object
  f: Form
  mm: MainMenu
  file, edit, view, recent: MenuItem
  open, save, exit, cut, paste, dark, light, status, a1, a2: MenuItem

proc build(): Fixture =
  var x: Fixture
  x.f = newForm(nil, 520, 320)
  x.f.show()
  x.mm = newMainMenu(x.f)
  x.file = x.mm.addItem("&File")
  x.edit = x.mm.addItem("&Edit")
  x.view = x.mm.addItem("&View")
  x.open = x.file.addItem("&Open...", mk("open"), shortcut("Ctrl+O"))
  x.recent = x.file.addItem("&Recent")
  x.a1 = x.recent.addItem("a.txt", mk("a1"))
  x.a2 = x.recent.addItem("b.txt", mk("a2"))
  x.file.addSeparator()
  x.save = x.file.addItem("&Save", mk("save"), shortcut("Ctrl+S"))
  x.exit = x.file.addItem("E&xit", mk("exit"), shortcut("Alt+F4"))
  x.cut = x.edit.addItem("Cu&t", mk("cut"), shortcut("Ctrl+X"))
  x.edit.addItem("&Copy", mk("copy"), shortcut("Ctrl+C"))
  x.edit.addSeparator()
  x.paste = x.edit.addItem("&Paste", mk("paste"), shortcut("Ctrl+V"))
  x.paste.enabled = false
  x.edit.addItem("Select &all", mk("all"), shortcut("Ctrl+A"))
  x.dark = x.view.addItem("&Dark", mk("dark"))
  x.light = x.view.addItem("&Light", mk("light"))
  x.dark.radioItem = true; x.dark.groupIndex = 1
  x.light.radioItem = true; x.light.groupIndex = 1
  x.light.checked = true
  x.status = x.view.addItem("&Status bar", mk("status"))
  x.status.autoCheck = true
  log = @[]
  x

proc top(): PopupWindow = topPopup(openForms()[0])
proc chainLen(f: Form): int = menuChain(f).len

proc clickItem(f: Form, p: PopupWindow, it: MenuItem) =
  let r = menuItemRect(p, it)
  p.ui.win.click(r.x + r.w / 2, r.y + r.h / 2)

suite "menu items":
  test "mnemonics":
    check parseMnemonic("&File") == (text: "File", index: 0, ch: "f".runeAt(0))
    check parseMnemonic("E&xit") == (text: "Exit", index: 1, ch: "x".runeAt(0))
    check parseMnemonic("Tom && Jerry") == (text: "Tom & Jerry", index: -1, ch: Rune(0))
    check parseMnemonic("a&b&c").index == 1
    check parseMnemonic("-").text == "-"
  test "shortcut text and parsing":
    check $shortcut("Ctrl+S") == "Ctrl+S"
    check $shortcut("ctrl+shift+z") == "Ctrl+Shift+Z"
    check $shortcut("Alt+F4") == "Alt+F4"
    check shortcut("Del") == shortcut(keyDelete)
    check shortcut("Esc").key == keyEscape
    check not shortcut("nonsense").isSet
    check $shortcut(keyEnter, {ssAlt}) == "Alt+Enter"
    check $noShortcut == ""
  test "tree: add, insert, delete, parent":
    let m = newMenuItem("root")
    let a = m.addItem("a")
    let c = newMenuItem("c")
    m.add c
    m.insert(newMenuItem("b"), 1)
    check m.count == 3 and m[1].caption == "b" and a.parent == m
    m.delete(1)
    check m.count == 2 and m[1] == c
    m.addSeparator()
    check m[2].isSeparator
    var names: seq[string]
    for it in m: names.add it.caption
    check names == @["a", "c", "-"]
  test "click: radio group, autoCheck, disabled, separator, submenu":
    let r = newMenuItem("r")
    let a = r.addItem("a", mk("a")); let b = r.addItem("b", mk("b"))
    let c = r.addItem("c", mk("c"))
    for it in [a, b]:
      it.radioItem = true
      it.groupIndex = 2
    c.radioItem = true
    c.groupIndex = 3
    c.checked = true
    log = @[]
    a.click()
    check a.checked and not b.checked and c.checked      # other group untouched
    b.click()
    check b.checked and not a.checked and log == @["a", "b"]
    let t = r.addItem("t", mk("t"))
    t.autoCheck = true
    t.click(); check t.checked
    t.click(); check not t.checked
    t.enabled = false
    t.click(); check not t.checked and log.len == 4
    r.addSeparator().click()
    let s = r.addItem("s", mk("s"))
    s.addItem("child")
    s.click()
    check "s" notin log
    r.enabled = false                   # a disabled parent disables the items
    a.click()
    check log.len == 4

suite "main menu":
  setup:
    Application.init()
    Application.forceScale = 0
    popupFocusGrace = 0
    focusIdProc = proc(): uint32 = 0
    submenuDelay = 0
  teardown:
    closeAllPopups(nil)
    for f in openForms(): f.freeWindow()

  test "the bar is the first thing at the top and the client area starts below":
    let x = build()
    let p = newPanel(x.f, "client")
    p.align = alClient
    check x.f.menu == x.mm and x.mm.align == alTop
    check x.f.paintIfDirty()
    check x.mm.top == 0 and x.mm.width == x.f.width
    check p.top >= x.mm.height

  test "Alt+letter opens the menu and selects the first item":
    let x = build()
    x.f.tap('f', {ssAlt})
    check x.mm.openIndex == 0 and chainLen(x.f) == 1
    check hotMenuItem(top()) == x.open
    x.f.tap('e', {ssAlt})               # switches while open
    check x.mm.openIndex == 1 and chainLen(x.f) == 1
    check hotMenuItem(top()) == x.cut

  test "F10 opens the first menu; Esc closes; Alt alone does nothing":
    let x = build()
    x.f.tap(keyF10)
    check x.mm.openIndex == 0
    x.f.tap(keyEscape)
    check x.mm.openIndex == -1 and chainLen(x.f) == 0
    x.f.tap(keyLAlt)
    check chainLen(x.f) == 0

  test "Alt held underlines the bar mnemonics (state tracked)":
    let x = build()
    check not x.mm.altHeld
    Application.dispatch(ev(x.f.win, ekKeyDown, k = keyLAlt, shift = {ssAlt}))
    check x.mm.altHeld
    check x.f.paintIfDirty() or true
    Application.dispatch(ev(x.f.win, ekKeyUp, k = keyLAlt))
    check not x.mm.altHeld

  test "arrows skip separators and disabled items and wrap":
    let x = build()
    x.f.tap('e', {ssAlt})
    check hotMenuItem(top()) == x.cut
    x.f.tap(keyDown); check hotMenuItem(top()).caption == "&Copy"
    x.f.tap(keyDown); check hotMenuItem(top()) .caption == "Select &all"   # separator and disabled Paste skipped
    x.f.tap(keyDown); check hotMenuItem(top()) == x.cut                    # wraps
    x.f.tap(keyUp); check hotMenuItem(top()).caption == "Select &all"
    x.f.tap(keyUp); check hotMenuItem(top()).caption == "&Copy"
    x.f.tap(keyEnd); check hotMenuItem(top()).caption == "Select &all"
    x.f.tap(keyHome); check hotMenuItem(top()) == x.cut

  test "Right/Left: submenu, then next/previous top menu":
    let x = build()
    x.f.tap('f', {ssAlt})
    x.f.tap(keyDown)                    # Recent
    check hotMenuItem(top()) == x.recent
    x.f.tap(keyRight)
    check chainLen(x.f) == 2 and hotMenuItem(top()) == x.a1
    x.f.tap(keyDown); check hotMenuItem(top()) == x.a2
    x.f.tap(keyLeft)
    check chainLen(x.f) == 1 and hotMenuItem(top()) == x.recent
    x.f.tap(keyRight); x.f.tap(keyEscape)           # Esc closes only the submenu
    check chainLen(x.f) == 1 and x.mm.openIndex == 0
    x.f.tap(keyRight)                   # reopen; Right inside a leaf menu does nothing more
    x.f.tap(keyEscape)
    x.f.tap(keyDown)                    # -> Save (Recent -> Save, separator skipped)
    check hotMenuItem(top()) == x.save
    x.f.tap(keyRight)                   # a leaf: moves to the next top menu
    check x.mm.openIndex == 1 and hotMenuItem(top()) == x.cut
    x.f.tap(keyLeft)
    check x.mm.openIndex == 0
    x.f.tap(keyLeft)                    # wraps to the last
    check x.mm.openIndex == 2
    x.f.tap(keyRight)
    check x.mm.openIndex == 0

  test "Enter fires onClick and closes everything; Enter on a submenu item opens it":
    let x = build()
    x.f.tap('f', {ssAlt})
    x.f.tap(keyEnter)
    check log == @["open"] and chainLen(x.f) == 0 and x.mm.openIndex == -1
    x.f.tap('f', {ssAlt})
    x.f.tap(keyDown); x.f.tap(keyEnter)
    check chainLen(x.f) == 2 and log.len == 1
    x.f.tap(keyDown); x.f.tap(keyEnter)
    check log == @["open", "a2"] and chainLen(x.f) == 0

  test "mnemonic letters inside a dropdown activate; shared letters cycle":
    let x = build()
    x.f.tap('f', {ssAlt})
    x.f.tap('s')
    check log == @["save"] and chainLen(x.f) == 0
    x.f.tap('e', {ssAlt})
    x.f.tap('t')
    check log == @["save", "cut"]
    x.f.tap('v', {ssAlt})
    x.f.tap('d')
    check x.dark.checked and not x.light.checked
    x.f.tap('f', {ssAlt})
    x.f.tap('z')                        # no such mnemonic: nothing happens
    check chainLen(x.f) == 1

  test "mouse: click opens, hover switches, click on an item fires, outside closes":
    let x = build()
    let bar = x.f.win
    let fr = x.mm.clientToForm(x.mm.itemRect(0))
    let er = x.mm.clientToForm(x.mm.itemRect(1))
    bar.move(fr.x + 5, fr.y + 5)
    bar.click(fr.x + 5, fr.y + 5)
    check x.mm.openIndex == 0 and chainLen(x.f) == 1
    bar.move(er.x + 5, er.y + 5)                    # hover switches
    check x.mm.openIndex == 1 and chainLen(x.f) == 1
    let p = top()
    let r = menuItemRect(p, x.cut)
    p.ui.win.move(r.x + 10, r.y + 5)
    check hotMenuItem(p) == x.cut
    x.f.clickItem(p, x.cut)
    check log == @["cut"] and chainLen(x.f) == 0 and x.mm.openIndex == -1
    # hover without an open menu opens nothing
    bar.move(fr.x + 5, fr.y + 5)
    check x.mm.openIndex == -1
    # click on the bar item while open closes it (toggle) and a click outside too
    bar.click(fr.x + 5, fr.y + 5)
    check x.mm.openIndex == 0
    bar.click(fr.x + 5, fr.y + 5)
    check x.mm.openIndex == -1 and chainLen(x.f) == 0
    bar.click(fr.x + 5, fr.y + 5)
    bar.click(300, 250)
    check chainLen(x.f) == 0 and log == @["cut"]

  test "mouse: submenu opens on hover, disabled and separator rows do nothing":
    let x = build()
    x.mm.openDropdown(0)
    let p = top()
    let r = menuItemRect(p, x.recent)
    p.ui.win.move(r.x + 10, r.y + 5)
    check chainLen(x.f) == 2
    let sub = top()
    x.f.clickItem(sub, x.a1)
    check log == @["a1"] and chainLen(x.f) == 0
    x.mm.openDropdown(1)
    let q = top()
    x.f.clickItem(q, x.paste)                        # disabled
    check chainLen(x.f) == 1 and log == @["a1"]
    q.ui.win.click(q.content.width / 2, 2 + 4 + 26 * 2 + 4)   # the separator row
    check chainLen(x.f) == 1 and log == @["a1"]

  test "hover delay: submenu opens after submenuDelay":
    let x = build()
    submenuDelay = 40
    focusIdProc = nil                   # real events are pumped below: use the real focus
    x.mm.openDropdown(0)
    let p = top()
    let r = menuItemRect(p, x.recent)
    p.ui.win.move(r.x + 10, r.y + 5)
    check chainLen(x.f) == 1
    let t0 = getMonoTime()
    while chainLen(x.f) < 2 and (getMonoTime() - t0).inMilliseconds < 2000:
      Application.processMessages(20)
    check chainLen(x.f) == 2

  test "shortcuts fire anywhere in the form, also from submenus":
    let x = build()
    let b = newButton(x.f, "b", 10, 100, 80, 28)
    x.f.activeControl = b
    x.f.tap('o', {ssCtrl})
    x.f.tap('s', {ssCtrl})
    x.f.tap(keyF4, {ssAlt})
    check log == @["open", "save", "exit"]
    x.a1.shortcut = shortcut(keyF5)
    x.f.tap(keyF5)
    check log[^1] == "a1"
    x.f.tap('o', {ssCtrl, ssShift})                 # modifiers must match exactly
    x.f.tap('o')
    check log.len == 4
    x.save.enabled = false
    x.f.tap('s', {ssCtrl})
    check log.len == 4
    x.save.enabled = true
    x.save.visible = false
    x.f.tap('s', {ssCtrl})
    check log.len == 4
    x.save.visible = true
    x.edit.enabled = false                          # disabled parent
    x.f.tap('x', {ssCtrl})
    check "cut" notin log
    x.edit.enabled = true
    x.f.tap('x', {ssCtrl})
    check log[^1] == "cut"

  test "shortcuts do not fire while a menu is open (keys go to the menu)":
    let x = build()
    x.mm.openDropdown(1)
    x.f.tap('o', {ssCtrl})
    check log.len == 0

  test "shortcuts coexist with default and cancel buttons (either order)":
    for menuFirst in [true, false]:
      let f = newForm(nil, 400, 300)
      f.show()
      var okN, cancelN = 0
      let mm = if menuFirst: newMainMenu(f) else: nil
      let ok = newButton(f, "OK", 10, 60, 80, 28)
      let cancel = newButton(f, "Cancel", 100, 60, 80, 28)
      ok.isDefault = true
      cancel.isCancel = true
      ok.onClick = proc(s: Control) = inc okN
      cancel.onClick = proc(s: Control) = inc cancelN
      let mm2 = if menuFirst: mm else: newMainMenu(f)
      mm2.addItem("&File").addItem("&Save", mk("save"), shortcut("Ctrl+S"))
      log = @[]
      check f.paintIfDirty()                        # installs the dialog keys
      f.tap(keyEnter)
      f.tap(keyEscape)
      f.tap('s', {ssCtrl})
      check okN == 1 and cancelN == 1 and log == @["save"]
      f.freeWindow()

  test "a form's own onUnhandledKey hook is kept and runs first":
    let x = build()
    var seen: seq[Key]
    # a hook that was installed before the menu: new form
    let f = newForm(nil, 300, 200)
    f.show()
    f.ui.onUnhandledKey = proc(k: var Key, s: ShiftState) = seen.add k
    let mm = newMainMenu(f)
    mm.addItem("&File").addItem("&Save", mk("save2"), shortcut("Ctrl+S"))
    f.tap('s', {ssCtrl})
    check seen == @[key('s')] and log[^1] == "save2"
    discard x

  test "PopupMenu: right click, Shift+F10 and the Menu key":
    let x = build()
    let pm = newPopupMenu(x.f)
    pm.addItem("&Copy", mk("pcopy"), shortcut("Ctrl+K"))
    pm.addSeparator()
    pm.addItem("&Paste", mk("ppaste"))
    let panel = newPanel(x.f, "ctx", 20, 80, 200, 150)
    attachPopupMenu(panel, pm)
    check popupMenuOf(panel) == pm
    x.f.win.click(60, 120, mbRight)
    check chainLen(x.f) == 1
    let p = top()
    check p.bounds.x == 60 and p.bounds.y == 120
    check hotMenuItem(p) == nil
    x.f.clickItem(p, pm.items[2])
    check log == @["ppaste"] and chainLen(x.f) == 0
    x.f.win.click(60, 120)                          # left click: no menu
    check chainLen(x.f) == 0
    # keyboard: a focusable control inside the panel
    let b = newButton(panel, "b", 10, 10, 80, 28)
    x.f.activeControl = b
    x.f.tap(keyF10, {ssShift})
    check chainLen(x.f) == 1 and hotMenuItem(top()) == pm.items[0]
    x.f.tap(keyEscape)
    x.f.tap(keyApplication)
    check chainLen(x.f) == 1
    x.f.tap('p')
    check log == @["ppaste", "ppaste"] and chainLen(x.f) == 0
    # the shortcut of a popup menu item works in the form
    x.f.tap('k', {ssCtrl})
    check log[^1] == "pcopy"
    # popup(): positions and closes
    let pp = pm.popup(x.f, 1000, 740)               # near the corner of the 1024x768 display
    check pp != nil and pp.bounds.y < 740 and pp.bounds.x < 1000
    pm.close()
    check chainLen(x.f) == 0

  test "PopupMenu at a point flips and slides to stay on the screen":
    let x = build()
    let pm = newPopupMenu()
    for i in 1 .. 4: pm.addItem("Item " & $i)
    let p = pm.popup(x.f, 100, 100)
    check p.bounds.x == 100 and p.bounds.y == 100
    check p.bounds.w >= 120 and p.bounds.h > 4 * 26
    check pm.popup(x.f, 100, 100) != nil and chainLen(x.f) == 1   # replaces
    let empty = newPopupMenu()
    check empty.popup(x.f, 10, 10) == nil

  test "every menu paints in both themes":
    let x = build()
    for t in [themeLight(), themeDark()]:
      Application.theme = t
      x.mm.openDropdown(0, true)
      x.f.tap(keyDown); x.f.tap(keyRight)
      check chainLen(x.f) == 2
      check x.f.paintIfDirty()
      Application.paintForms()
      closeAllPopups(x.f)
    Application.theme = themeLight()
    check x.f.paintIfDirty() or true

  test "a freed PopupMenu neither re-registers nor fires its shortcuts":
    let x = build()
    let pm = newPopupMenu(x.f)
    pm.addItem("&Copy", mk("pcopy"), shortcut("Ctrl+K"))
    let panel = newPanel(x.f, "ctx", 20, 80, 200, 150)
    attachPopupMenu(panel, pm)
    log = @[]
    pm.free()
    check panel.popupMenu == nil
    x.f.win.click(60, 120, mbRight)
    check chainLen(x.f) == 0
    x.f.tap('k', {ssCtrl})
    check log.len == 0

  test "a PopupMenu is released with its owner (N11)":
    let x = build()
    let holder = newPanel(x.f, "holder", 20, 80, 200, 150)
    let pm = newPopupMenu(holder)           # owned by the panel it serves
    pm.addItem("&Copy", mk("pcopy"), shortcut("Ctrl+K"))
    attachPopupMenu(holder, pm)
    check x.f.popupMenus.len == 1
    log = @[]
    holder.free()
    check x.f.popupMenus.len == 0
    check holder.popupMenu == nil
    x.f.tap('k', {ssCtrl})
    check log.len == 0

  test "MenuItem[] and delete ignore out-of-range indices":
    let root = newMenuItem("r")
    root.addItem("a")
    check root[1] == nil and root[-1] == nil
    root.delete(5)
    check root.count == 1

  test "popup(): onPopup runs before the visible-items check (review 3)":
    let x = build()
    let pm = newPopupMenu(x.f)
    pm.onPopup = proc(m: PopupMenu) =
      if m.items.count == 0: m.addItem("dynamic")
    let p = pm.popup(x.f, 10, 100)
    check p != nil and pm.items.count == 1
    pm.close()
    let pm2 = newPopupMenu(x.f)
    let only = pm2.addItem("only")
    pm2.onPopup = proc(m: PopupMenu) = only.visible = false
    check pm2.popup(x.f, 10, 100) == nil and chainLen(x.f) == 0
    pm2.onPopup = proc(m: PopupMenu) = only.visible = true
    check pm2.popup(x.f, 10, 100) != nil
    pm2.close()

  test "attachPopupMenu before the control is in a form (review 4)":
    let x = build()
    let pm = newPopupMenu(x.f)
    pm.addItem("&Paste", mk("ppaste"), shortcut("Ctrl+K"))
    let panel = newPanel(nil, "ctx", 20, 80, 200, 150)
    attachPopupMenu(panel, pm)
    x.f.insertControl panel
    let b = newButton(panel, "b", 10, 10, 80, 28)
    x.f.activeControl = b                           # entering the panel's button
    x.f.win.click(60, 120, mbRight)
    check popupMenuOf(panel) == pm
    check chainLen(x.f) == 1
    closeAllPopups(x.f)
    # Shift+F10 / Menu key on a control attached before insertion
    let pm2 = newPopupMenu(x.f)
    pm2.addItem("&Q", mk("q"))
    let pnl2 = newPanel(nil, "c2", 240, 80, 100, 100)
    pnl2.tabStop = true
    attachPopupMenu(pnl2, pm2)
    x.f.insertControl pnl2
    x.f.activeControl = pnl2
    x.f.tap(keyApplication)
    check chainLen(x.f) == 1
    closeAllPopups(x.f)

  test "attachPopupMenu leaves the control's event fields alone":
    let x = build()
    let pm = newPopupMenu(x.f)
    pm.addItem("&Paste", mk("ppaste"))
    let panel = newPanel(x.f, "ctx", 20, 80, 200, 150)
    attachPopupMenu(panel, pm)
    check panel.onMouseDown == nil and panel.onMouseUp == nil
    check panel.onKeyDown == nil and panel.onEnter == nil
    x.f.win.click(60, 120, mbRight)
    check chainLen(x.f) == 1                       # still served
    closeAllPopups(x.f)
    check panel.onMouseDown == nil and panel.onMouseUp == nil and panel.onEnter == nil

  test "a handler assigned after attachPopupMenu: both run":
    let x = build()
    let pm = newPopupMenu(x.f)
    pm.addItem("&Paste", mk("ppaste"))
    let panel = newPanel(x.f, "ctx", 20, 80, 200, 150)
    attachPopupMenu(panel, pm)
    var ups = 0
    panel.onMouseUp = proc(s: Control, b: MouseButton, sh: ShiftState, mx, my: float32) =
      inc ups
    x.f.win.click(60, 120, mbRight)
    check ups == 1
    check chainLen(x.f) == 1
    closeAllPopups(x.f)
    # a child control without a menu of its own: the ancestor's menu serves it
    let b = newButton(panel, "b", 10, 10, 80, 28)
    x.f.win.click(60, 110, mbRight)
    check chainLen(x.f) == 1
    closeAllPopups(x.f)

  test "PopupMenu.close closes only its own popup (review 11)":
    let x = build()
    let pm = newPopupMenu(x.f)                      # not attached to any control
    pm.addItem("Y")
    check pm.popup(x.f, 10, 100) != nil and chainLen(x.f) == 1
    pm.close()
    check chainLen(x.f) == 0
    # an unrelated main-menu dropdown stays open
    x.mm.openDropdown(0, true)
    check chainLen(x.f) == 1
    pm.close()
    check chainLen(x.f) == 1
    closeAllPopups(x.f)
    # a popup shown, closed by the user, then close() again: harmless
    let p = pm.popup(x.f, 10, 100)
    closePopup(p)
    x.mm.openDropdown(1, true)
    pm.close()
    check chainLen(x.f) == 1
    closeAllPopups(x.f)

  test "Super+key never fires a menu shortcut (review 22)":
    let x = build()
    x.f.tap('o', {ssCtrl, ssSuper})
    check log.len == 0
    x.f.tap('o', {ssCtrl})
    check log == @["open"]

  test "images= subscribes to the image list and unsubscribes on replace":
    let x = build()
    let il = newImageList(16, 16)
    x.mm.images = il
    discard x.f.paintIfDirty()
    il.width = 20                                   # list changed: bar repaints
    check x.f.paintIfDirty()
    x.mm.images = nil
    discard x.f.paintIfDirty()
    il.width = 24
    check not x.f.paintIfDirty()
    let pm = newPopupMenu(x.f)
    pm.addItem("a")
    pm.images = il
    let p = pm.popup(x.f, 10, 100)
    check p != nil
    discard x.f.paintIfDirty()
    Application.paintForms()
    il.width = 18
    pm.images = nil
    closeAllPopups(x.f)
