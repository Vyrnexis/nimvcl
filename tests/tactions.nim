## ActionList / Action: clients stay in sync, clicks, shortcuts and idle updates
## reach the action, radio groups, unlinking, and ImageList icons in toolbars
## and menus. Headless (offscreen SDL).

import std/[unittest, os]
import sdl3 except Color, Cursor
import nimvcl

proc ev(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, k = Key(0),
        shift: ShiftState = {}): PlatformEvent =
  PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y, key: k, shift: shift,
                button: mbLeft, clicks: 1)

proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(f.ev(ekKeyDown, k = k, shift = shift))
  Application.dispatch(f.ev(ekKeyUp, k = k, shift = shift))
proc tap(f: Form, c: char, shift: ShiftState = {}) = f.tap(key(c), shift)

proc clickAt(f: Form, p: PointF) =
  let s = f.win.scale
  for k in [ekMouseMove, ekMouseDown, ekMouseUp]:
    Application.dispatch(f.ev(k, p.x * s, p.y * s))
proc click(f: Form, c: Control) =
  discard f.paintIfDirty()
  f.clickAt(c.clientToForm(pointF(c.width / 2, c.height / 2)))

proc clickItem(f: Form, it: MenuItem) =
  let p = topPopup(f)
  doAssert p != nil, "no open menu"
  let r = menuItemRect(p, it)
  let s = p.ui.win.scale
  for k in [ekMouseMove, ekMouseDown, ekMouseUp]:
    Application.dispatch(PlatformEvent(kind: k, windowId: p.ui.win.id,
      x: (r.x + r.w / 2) * s, y: (r.y + r.h / 2) * s, button: mbLeft, clicks: 1))

proc shot(f: Form, popups: bool): tuple[w, h: int, px: seq[byte]] =
  let path = getTempDir() / "nimvcl_tactions.bmp"
  doAssert (if popups: f.screenshotWithPopups(path) else: f.screenshot(path))
  let raw = sdl3.loadBMP(path.cstring)
  doAssert raw != nil
  let s = convertSurface(raw, PIXELFORMAT_RGBA32)
  destroySurface raw
  result.w = s.w
  result.h = s.h
  result.px = newSeq[byte](s.pitch * s.h)
  copyMem(addr result.px[0], s.pixels, result.px.len)
  destroySurface s
  removeFile path

proc isRed(img: tuple[w, h: int, px: seq[byte]], x, y: int): bool =
  let o = (y * img.w + x) * 4
  img.px[o] > 200 and img.px[o + 1] < 60 and img.px[o + 2] < 60

proc redImage(): Image = newImage(16, 16, rgb(255, 0, 0))

type Fx = object
  f: Form
  acts: ActionList
  mm: MainMenu
  file: MenuItem
  bar: ToolBar

proc fixture(): Fx =
  result.f = newForm(nil, 480, 300)
  result.f.show()
  result.acts = newActionList(result.f)
  result.mm = newMainMenu(result.f)
  result.file = result.mm.addItem("&File")
  result.bar = newToolBar(result.f)

suite "actions":
  setup:
    Application.init()
    Application.forceScale = 0
    Application.theme = themeLight()
  teardown:
    for f in openForms(): f.freeWindow()

  test "action properties reach every client immediately":
    let x = fixture()
    let a = newAction(x.acts, "&Save", nil, shortcut("Ctrl+S"))
    a.hint = "Save it"
    a.imageIndex = 3
    let mi = x.file.addItem("x")
    let tb = newToolButton(x.bar, "x")
    let btn = newButton(x.f, "x")
    let cb = newCheckBox(x.f, "x")
    mi.action = a; tb.action = a; btn.action = a; cb.action = a
    check mi.caption == "&Save" and btn.caption == "&Save" and cb.caption == "&Save"
    check tb.caption == "Save"                       # no mnemonic on tool buttons
    check mi.shortcut == shortcut("Ctrl+S")
    check tb.hint == "Save it" and btn.hint == "Save it" and cb.hint == "Save it"
    check mi.imageIndex == 3 and tb.imageIndex == 3
    check a.clientCount == 4 and mi.action == a and btn.action == a
    a.enabled = false
    check not mi.enabled and not tb.enabled and not btn.enabled and not cb.enabled
    a.visible = false
    check not mi.visible and not tb.visible and not btn.visible and not cb.visible
    a.visible = true; a.enabled = true
    a.checked = true
    check mi.checked and cb.checked
    check tb.kind == tbsButton and not tb.down      # plain action: no check state
    a.autoCheck = true
    check tb.kind == tbsCheck and tb.down and mi.autoCheck
    a.caption = "&Store"
    a.hint = "Store it"
    a.imageIndex = 1
    check mi.caption == "&Store" and tb.caption == "Store" and btn.caption == "&Store"
    check cb.hint == "Store it" and tb.imageIndex == 1
    a.checked = false
    check not mi.checked and not cb.checked and not tb.down
    # the action wins over a hand-set client property on its next change
    btn.caption = "mine"
    a.caption = "Action"
    check btn.caption == "Action"

  test "linking replaces the old action; nil unlinks":
    let x = fixture()
    let a = newAction(x.acts, "A")
    let b = newAction(x.acts, "B")
    let btn = newButton(x.f, "x")
    btn.action = a
    btn.action = b
    check a.clientCount == 0 and b.clientCount == 1 and btn.caption == "B"
    a.caption = "A2"
    check btn.caption == "B"
    btn.action = nil
    check b.clientCount == 0 and btn.action == nil
    b.caption = "B2"
    check btn.caption == "B"

  test "executing from a button, a tool button, a menu item and a shortcut":
    let x = fixture()
    var n = 0
    var last: Action
    let a = newAction(x.acts, "Go", proc(s: Action) = (inc n; last = s), shortcut("Ctrl+G"))
    let btn = newButton(x.f, "x", 10, 100)
    let tb = newToolButton(x.bar, "x")
    let mi = x.file.addItem("x")
    btn.action = a; tb.action = a; mi.action = a
    x.f.click(btn)
    check n == 1 and last == a
    x.f.click(tb)
    check n == 2
    x.mm.openDropdown(0)
    x.f.clickItem(mi)
    check n == 3
    x.f.tap('g', {ssCtrl})                    # menu shows it, the list fires it
    check n == 4
    a.enabled = false
    x.f.tap('g', {ssCtrl})
    x.f.click(btn)
    check n == 4
    check not a.execute()
    a.enabled = true
    check a.execute() and n == 5

  test "shortcuts work without any menu item, once per list":
    let x = fixture()
    var n = 0
    let a = newAction(x.acts, "Go", proc(s: Action) = (inc n), shortcut("F6"))
    x.f.tap(keyF6)
    check n == 1
    x.f.tap(keyF6, {ssShift})
    check n == 1
    let l2 = newActionList(x.f)
    discard newAction(l2, "Other", proc(s: Action) = (inc n), shortcut("F7"))
    x.f.tap(keyF7)
    check n == 2
    a.visible = false
    x.f.tap(keyF6)
    check n == 2

  test "list level onExecute sees the action first and can handle it":
    let x = fixture()
    var seen, own = 0
    let a = newAction(x.acts, "Go", proc(s: Action) = inc own)
    x.acts.onExecute = proc(s: Action, handled: var bool) =
      inc seen
      handled = seen == 1
    check a.execute()
    check seen == 1 and own == 0
    check a.execute()
    check seen == 2 and own == 1

  test "check boxes, check tool buttons and auto-check items sync through the action":
    let x = fixture()
    let a = newAction(x.acts, "Wrap")
    a.autoCheck = true
    var execs = 0
    a.onExecute = proc(s: Action) = inc execs
    let cb = newCheckBox(x.f, "x", false, 10, 100)
    let tb = newToolButton(x.bar, "x")
    let mi = x.file.addItem("x")
    cb.action = a; tb.action = a; mi.action = a
    x.f.click(cb)
    check a.checked and tb.down and mi.checked and execs == 1
    x.f.click(tb)
    check not a.checked and not cb.checked and not mi.checked and execs == 2
    x.mm.openDropdown(0)
    x.f.clickItem(mi)
    check a.checked and cb.checked and tb.down and execs == 3
    a.checked = false
    check not cb.checked and not tb.down and not mi.checked and execs == 3

  test "radio groups: executing one unchecks the others of its list":
    let x = fixture()
    let a1 = newAction(x.acts, "Left")
    let a2 = newAction(x.acts, "Right")
    let a3 = newAction(x.acts, "Other")
    for a in [a1, a2]:
      a.groupIndex = 1
      a.autoCheck = true
    a3.groupIndex = 2
    a3.checked = true
    a1.checked = true
    let t1 = newToolButton(x.bar, "x")
    let t2 = newToolButton(x.bar, "x")
    t1.action = a1; t2.action = a2
    check t1.kind == tbsCheck and t1.groupIndex == 1 and t1.down and not t2.down
    discard a2.execute()
    check a2.checked and not a1.checked and a3.checked
    check t2.down and not t1.down
    x.f.click(t1)
    check a1.checked and not a2.checked and t1.down and not t2.down
    let m1 = x.file.addItem("x")
    m1.action = a2
    check m1.radioItem and m1.groupIndex == 1 and not m1.checked
    a2.checked = true
    check m1.checked and not t1.down

  test "autoCheck toggles on execute":
    let x = fixture()
    let a = newAction(x.acts, "T")
    a.autoCheck = true
    a.execute()
    check a.checked
    a.execute()
    check not a.checked

  test "onUpdate runs when the application goes idle, not while painting":
    let x = fixture()
    var n = 0
    let a = newAction(x.acts, "U")
    a.onUpdate = proc(s: Action) =
      inc n
      s.enabled = n mod 2 == 0
    let btn = newButton(x.f, "x")
    btn.action = a
    var listN = 0
    x.acts.onUpdate = proc(s: Action, handled: var bool) = inc listN
    Application.processMessages(0)
    check n == 1 and listN == 1 and not btn.enabled
    for i in 1 .. 50:                     # a busy loop that only paints
      x.f.invalidate()
      discard x.f.paintIfDirty()
    check n == 1
    Application.processMessages(0)
    check n == 2 and btn.enabled
    updateActions()
    check n == 3
    Application.queue(proc() {.closure, gcsafe.} = discard)
    Application.processMessages(0)
    check n == 4

  test "a menu refreshes its actions right before it opens":
    let x = fixture()
    let a = newAction(x.acts, "U")
    let mi = x.file.addItem("x")
    mi.action = a
    a.onUpdate = proc(s: Action) = s.enabled = false
    check mi.enabled
    x.mm.openDropdown(0)
    check not mi.enabled

  test "unlinking: free of action, of list, and re-linking after":
    let x = fixture()
    let a = newAction(x.acts, "A")
    let btn = newButton(x.f, "x")
    let mi = x.file.addItem("x")
    btn.action = a; mi.action = a
    check x.acts.count == 1
    a.free()
    check x.acts.count == 0 and a.clientCount == 0
    check btn.action == nil and mi.action == nil
    a.caption = "changed"
    check btn.caption == "A"
    btn.click()                               # no crash, no action
    let b = newAction(x.acts, "B")
    let c = newAction(x.acts, "C")
    btn.action = b; mi.action = c
    x.acts.free()
    check btn.action == nil and mi.action == nil and x.acts.count == 0
    x.f.tap(keyF6)                            # list key handler removed
    btn.click()

  test "a menu item linked to an action in a list without a form still has its shortcut":
    let x = fixture()
    var n = 0
    let a = newAction(Component(nil), "Go", proc(s: Action) = (inc n), shortcut("F8"))
    x.file.addItem("x").action = a
    x.f.tap(keyF8)
    check n == 1

  test "ToolBar.images draws the action's icon, disabled faded":
    let x = fixture()
    let il = newImageList(16, 16)
    il.add newImage(16, 16, rgb(0, 0, 0))
    il.add redImage()
    let a = newAction(x.acts, "Red")
    a.imageIndex = 1
    let tb = newToolButton(x.bar, "")
    tb.showCaption = false
    tb.action = a
    x.acts.images = il
    check x.bar.images == il
    discard x.f.paintIfDirty()
    let c = tb.clientToForm(pointF(tb.width / 2, tb.height / 2))
    let s = x.f.win.scale
    check x.f.shot(false).isRed(int(c.x * s), int(c.y * s))
    a.enabled = false
    discard x.f.paintIfDirty()
    check not x.f.shot(false).isRed(int(c.x * s), int(c.y * s))

  test "ToolBar.images works by hand, and glyphs still win":
    let x = fixture()
    let il = newImageList(16, 16)
    il.add redImage()
    x.bar.images = il
    let tb = newToolButton(x.bar, "")
    tb.showCaption = false
    tb.imageIndex = 0
    discard x.f.paintIfDirty()
    let c = tb.clientToForm(pointF(tb.width / 2, tb.height / 2))
    let s = x.f.win.scale
    check x.f.shot(false).isRed(int(c.x * s), int(c.y * s))
    let w0 = tb.width
    tb.glyph = proc(cv: Canvas, r: RectF, col: Color) = cv.fillRect(r, rgb(0, 0, 255))
    discard x.f.paintIfDirty()
    check not x.f.shot(false).isRed(int(c.x * s), int(c.y * s))
    check tb.width == w0

  test "menu icons: an icon column in the dropdown, disabled ones faded":
    let x = fixture()
    let il = newImageList(16, 16)
    il.add redImage()
    x.mm.images = il
    let withIcon = x.file.addItem("With icon")
    withIcon.imageIndex = 0
    let plain = x.file.addItem("Plain")
    discard plain
    x.mm.openDropdown(0)
    let p = topPopup(x.f)
    let r = menuItemRect(p, withIcon)
    let s = x.f.win.scale
    let b = p.bounds
    let cx = int((b.x + r.x + 15) * s)
    let cy = int((b.y + r.y + r.h / 2) * s)
    check x.f.shot(true).isRed(cx, cy)
    # the text starts to the right of the icon column
    withIcon.enabled = false
    p.content.invalidate()
    check not x.f.shot(true).isRed(cx, cy)

  test "menu items: action images come from the list, popup menus too":
    let x = fixture()
    let il = newImageList(16, 16)
    il.add redImage()
    x.acts.images = il
    let a = newAction(x.acts, "Go")
    a.imageIndex = 0
    let pm = newPopupMenu(x.f)
    let it = pm.addItem("x")
    it.action = a
    check pm.images == il
    let pm2 = newPopupMenu(x.f)
    pm2.images = il
    check pm2.items.images == il

  test "shortcuts: plain printable keys do not fire while typing in an Edit":
    let x = fixture()
    let ed = newEdit(x.f, "", 10, 100, 200)
    var plain, shifted, ctrlK, fkey = 0
    discard newAction(x.acts, "p", proc(a: Action) = (inc plain), shortcut("A"))
    discard newAction(x.acts, "s", proc(a: Action) = (inc shifted), shortcut("Shift+B"))
    discard newAction(x.acts, "c", proc(a: Action) = (inc ctrlK), shortcut("Ctrl+K"))
    discard newAction(x.acts, "f", proc(a: Action) = (inc fkey), shortcut("F5"))
    x.f.tap('a')
    x.f.tap('b', {ssShift})
    check plain == 1 and shifted == 1              # no Edit focused: they fire
    ed.setFocus()
    x.f.tap('a')
    x.f.tap('b', {ssShift})
    check plain == 1 and shifted == 1              # typing in the Edit: they do not
    x.f.tap('k', {ssCtrl})
    x.f.tap(keyF5)
    check ctrlK == 1 and fkey == 1                 # Ctrl+key and F-keys still do
    ed.readOnly = true                             # not a text target any more
    x.f.tap('a')
    check plain == 2

  test "a CheckBox linked to a grouped action cannot uncheck it":
    let x = fixture()
    let a = newAction(x.acts, "g")
    a.groupIndex = 1
    let b = newAction(x.acts, "h")
    b.groupIndex = 1
    let cb = newCheckBox(x.f, "x", false, 10, 10)
    cb.action = a
    x.f.click(cb)
    check a.checked and cb.checked
    x.f.click(cb)                                  # clicking again keeps it checked
    check a.checked and cb.checked
    b.checked = true
    check not a.checked and not cb.checked

  test "executing a grouped action that is not autoCheck checks it":
    let x = fixture()
    let a = newAction(x.acts, "a")
    a.groupIndex = 2
    let b = newAction(x.acts, "b")
    b.groupIndex = 2
    a.checked = true
    check not a.autoCheck
    b.execute()
    check b.checked and not a.checked

  test "an action callback may unlink clients while it notifies":
    let x = fixture()
    let a = newAction(x.acts, "a")
    let b1 = newButton(x.f, "1", 10, 10)
    let b2 = newButton(x.f, "2", 10, 50)
    let b3 = newButton(x.f, "3", 10, 90)
    b1.autoSize = true
    b1.onResize = proc(s: Control) = b1.action = nil     # unlinks itself mid-notify
    b1.action = a; b2.action = a; b3.action = a
    check a.clientCount == 3 or a.clientCount == 2
    a.caption = "a much longer caption than before"
    check b2.caption == "a much longer caption than before"
    check b3.caption == "a much longer caption than before"

  test "a ToolButton upgraded to check reverts when the action stops needing it":
    let x = fixture()
    let a = newAction(x.acts, "a")
    let tb = newToolButton(x.bar, "x")
    tb.action = a
    check tb.kind == tbsButton
    a.autoCheck = true
    check tb.kind == tbsCheck
    a.autoCheck = false
    check tb.kind == tbsButton
    a.groupIndex = 1
    check tb.kind == tbsCheck
    tb.action = nil                                # unlinking reverts too
    check tb.kind == tbsButton
    let own = newToolButton(x.bar, "y", tbsCheck)  # an explicit check button stays
    own.action = a
    a.groupIndex = 0
    check own.kind == tbsCheck
