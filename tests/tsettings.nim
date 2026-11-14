## The settings demo (phase 5 exit criterion) driven through dispatched events:
## keyboard + mouse, menus, dialogs, focus traversal and a paint smoke test.
## Headless (offscreen SDL).

import std/[unittest, os, strutils, sequtils, monotimes, times]
import sdl3 except Color, Cursor
import nimvcl
import nimvcl/platform/dialogs as pdialogs
import ../examples/settings_demo

# ------------------------------------------------------------------ helpers

proc ev(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, k = Key(0),
        shift: ShiftState = {}, button = mbLeft): PlatformEvent =
  PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y, key: k, shift: shift,
                button: button, clicks: 1)

proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(f.ev(ekKeyDown, k = k, shift = shift))
  Application.dispatch(f.ev(ekKeyUp, k = k, shift = shift))
proc tap(f: Form, c: char, shift: ShiftState = {}) = f.tap(key(c), shift)
proc typeText(f: Form, s: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id, text: s))

proc scaleOf(f: Form): float32 = f.win.scale
proc center(c: Control): PointF =
  discard Form(c.root).paintIfDirty()           # like the loop: layout before input
  c.clientToForm(pointF(c.width / 2, c.height / 2))

proc mouse(f: Form, kind: EventKind, p: PointF, shift: ShiftState = {}) =
  let s = f.scaleOf
  Application.dispatch(f.ev(kind, p.x * s, p.y * s, shift = shift))
proc clickAt(f: Form, p: PointF) =
  f.mouse(ekMouseMove, p)
  f.mouse(ekMouseDown, p)
  f.mouse(ekMouseUp, p)
proc click(f: Form, c: Control) = f.clickAt(c.center)
proc clickRow(f: Form, lb: ListBox, i: int) =
  discard f.paintIfDirty()
  f.clickAt(lb.clientToForm(pointF(lb.width / 2, lb.itemRect(i).y + lb.itemHeight / 2)))
proc clickTab(f: Form, pc: PageControl, i: int) =
  discard f.paintIfDirty()
  let r = pc.tabRect(i)
  f.clickAt(pc.clientToForm(pointF(r.x + r.w / 2, r.y + r.h / 2)))

template whileModal(body: untyped) =
  ## Runs `body` on the UI thread once the modal loop runs; `dlg` is the modal form.
  Application.queue(proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let dlg {.inject.} = modalForm()
      body)

proc buttonCaption(f: Form, caption: string): Button =
  for c in f.children:
    if c of Button and c.caption == caption: return Button(c)

proc newShown(w = 0'f32, h = 0'f32): SettingsForm =
  result = newSettingsForm()
  if w > 0: result.width = w
  if h > 0: result.height = h
  result.show()
  result.syncMetrics()
  discard result.paintIfDirty()

proc finish(f: SettingsForm) =
  ## Closes without the "discard changes?" question.
  f.modified = false
  f.close()
  Application.init()                    # closing the main form terminated the app

proc focusName(f: SettingsForm): string =
  let c = f.activeControl
  if c == nil: "-" else: c.name

proc statusText(f: SettingsForm, i: int): string = f.statusBar.panels[i].text

proc openMenu(f: SettingsForm, ch: char) =
  f.tap(ch, {ssAlt})

proc clickMenuItem(f: Form, it: MenuItem) =
  let p = topPopup(f)
  doAssert p != nil, "no open menu"
  let r = menuItemRect(p, it)
  let s = p.ui.win.scale
  for k in [ekMouseMove, ekMouseDown, ekMouseUp]:
    Application.dispatch(PlatformEvent(kind: k, windowId: p.ui.win.id,
      x: (r.x + r.w / 2) * s, y: (r.y + r.h / 2) * s, button: mbLeft, clicks: 1))

proc itemByName(f: SettingsForm, top: int, text: string): MenuItem =
  let t = f.menu.items[top]
  for i in 0 ..< t.count:
    if parseMnemonic(t[i].caption).text == text: return t[i]

proc pixel(f: Form, x, y: int): tuple[r, g, b: int] =
  ## Colour of a pixel of the rendered form (through a BMP screenshot).
  let path = getTempDir() / "nimvcl_tsettings.bmp"
  doAssert f.screenshot(path)
  let raw = sdl3.loadBMP(path.cstring)
  doAssert raw != nil
  let s = convertSurface(raw, PIXELFORMAT_RGBA32)
  destroySurface raw
  let o = y * s.pitch + x * 4
  result = (int(s.pixels[o]), int(s.pixels[o + 1]), int(s.pixels[o + 2]))
  destroySurface s
  removeFile path

proc lum(c: tuple[r, g, b: int]): int = (c.r * 3 + c.g * 6 + c.b) div 10

func near(a: tuple[r, g, b: int], c: Color, tol = 6): bool =
  abs(a.r - int(c.r)) <= tol and abs(a.g - int(c.g)) <= tol and abs(a.b - int(c.b)) <= tol

proc visibleStops(f: SettingsForm): seq[Control] = tabStops(f)

suite "settings demo":
  setup:
    Application.init()
    Application.forceScale = 0
    Application.theme = themeLight()
  teardown:
    for f in openForms(): f.freeWindow()
    Application.theme = themeLight()

  # ------------------------------------------------------------ pages
  test "starts on General with the status bar filled in and Apply disabled":
    let f = newShown()
    check f.cats.count == 4 and f.pages.pageCount == 4
    check f.cats.itemIndex == 0 and f.pages.tabIndex == 0
    check f.statusText(1) == "Saved" and f.statusText(2) == "General"
    check not f.applyBtn.enabled
    check f.okBtn.isDefault and f.cancelBtn.isCancel
    f.finish()

  test "clicking the list switches the page, clicking a tab switches the list":
    let f = newShown()
    f.clickRow(f.cats, 2)
    check f.pages.tabIndex == 2 and f.statusText(2) == "Editor"
    check f.editorPage.isShowing and not f.generalPage.isShowing
    f.clickTab(f.pages, 1)
    check f.cats.itemIndex == 1 and f.statusText(2) == "Appearance"
    f.cats.setFocus()
    f.tap(keyDown)                      # arrows in the list move the page too
    check f.pages.tabIndex == 2
    f.tap(keyEnd)
    check f.pages.tabIndex == 3
    f.finish()

  test "Ctrl+Tab / Ctrl+Shift+Tab cycle the pages and the list follows":
    let f = newShown()
    f.nameEdit.setFocus()
    f.tap(keyTab, {ssCtrl})
    check f.pages.tabIndex == 1 and f.cats.itemIndex == 1
    f.tap(keyTab, {ssCtrl, ssShift})
    check f.pages.tabIndex == 0 and f.cats.itemIndex == 0
    f.tap(keyTab, {ssCtrl, ssShift})
    check f.pages.tabIndex == 3 and f.cats.itemIndex == 3     # wraps
    f.tap(keyTab, {ssCtrl})
    check f.pages.tabIndex == 0
    f.finish()

  # ------------------------------------------------------------ keyboard
  test "Alt mnemonics: labels focus, check boxes toggle, buttons click, tabs select":
    let f = newShown()
    f.tap('n', {ssAlt})
    check f.focusName == "nameEdit"
    f.tap('m', {ssAlt})
    check f.focusName == "emailEdit"
    f.tap('l', {ssAlt})
    check f.focusName == "language"
    f.tap('o', {ssAlt})
    check f.country.edit.focused
    check f.updates.checked
    f.tap('u', {ssAlt})
    check not f.updates.checked and f.updates.focused
    check f.modified and f.statusText(1) == "Modified" and f.applyBtn.enabled
    f.tap('w', {ssAlt})
    check f.startWelcome.checked and not f.startLast.checked
    f.tap('d', {ssAlt})
    check f.startLast.checked
    f.tap('r', {ssAlt})                 # "Catego&ries" focuses the list
    check f.focusName == "cats"
    f.tap('p', {ssAlt})                 # tab "A&ppearance"
    check f.pages.tabIndex == 1 and f.cats.itemIndex == 1
    f.tap('s', {ssAlt})                 # "Font &size" -> the track bar
    check f.focusName == "fontSize"
    f.tap('i', {ssAlt})                 # tab "Ed&itor"
    check f.pages.tabIndex == 2
    f.tap('c', {ssAlt})                 # tab "Advan&ced"
    check f.pages.tabIndex == 3
    f.tap('g', {ssAlt})                 # tab "&General"
    check f.pages.tabIndex == 0
    f.tap('v', {ssAlt})                 # the menu bar takes Alt+V
    check f.menu.openIndex == 2
    f.tap(keyEscape)
    check f.menu.openIndex == -1
    f.tap('a', {ssAlt})                 # &Apply
    check f.applied == 1 and not f.modified and not f.applyBtn.enabled
    f.tap('a', {ssAlt})                 # disabled now: nothing happens
    check f.applied == 1
    f.finish()

  test "menu shortcuts work from any focus: F9 toolbar, F2 preferences":
    let f = newShown()
    f.clickRow(f.cats, 2)
    f.sample.setFocus()
    f.tap(keyF9)
    check not f.toolbar.visible and not f.toolbarItem.checked
    f.tap(keyF9)
    check f.toolbar.visible and f.toolbarItem.checked
    f.tap(keyF2)
    check f.pages.tabIndex == 0 and f.focusName == "nameEdit"
    f.finish()

  test "Edit > Undo/Redo act on the focused edit":
    let f = newShown()
    f.nameEdit.setFocus()
    f.typeText "Ann"
    check f.nameEdit.text == "Ann"
    f.openMenu('e')
    f.clickMenuItem(f.undoItem)
    check f.nameEdit.text == ""
    f.openMenu('e')
    f.clickMenuItem(f.redoItem)
    check f.nameEdit.text == "Ann"
    f.finish()

  test "Tab order never visits the disabled Apply button; Enter is OK, Esc is Cancel":
    let f = newShown()
    check Control(f.applyBtn) notin f.visibleStops
    f.nameEdit.setFocus()
    f.typeText "Bob"
    check f.applyBtn.enabled and Control(f.applyBtn) in f.visibleStops
    f.tap(keyEnter)                     # edit leaves Enter alone -> OK
    check f.applied == 1 and not f.visible

  # ------------------------------------------------------------ menus
  test "View menu: dark theme repaints the whole UI, the check items follow":
    let f = newShown()
    let bg = currentTheme().surface
    check f.pixel(600, 520).near(bg)
    f.openMenu('v')
    check f.menu.openIndex == 2
    f.clickMenuItem(f.themeDarkItem)
    check f.menu.openIndex == -1
    check Application.theme.surface != bg
    check f.themeDarkItem.checked and f.darkAct.checked
    check f.darkTool.down and f.themeCombo.itemIndex == 1
    discard f.paintIfDirty()
    let dk = currentTheme()
    check f.pixel(600, 520).near(dk.surface)
    # one blank spot per big area must be dark (nothing kept its light colour)
    for c in [Control(f.statusBar), f.toolbar, f.footer, f.catPanel, f.cats, f.pages.activePage, f.nameEdit]:
      let o = c.clientToForm(pointF(c.width - 6, c.height - 6))
      check f.pixel(int(o.x), int(o.y)).lum < 110
    # back to light through the toolbar toggle
    f.click(f.darkTool)
    check not f.darkTool.down and not f.themeDarkItem.checked and not f.darkAct.checked
    check Application.theme.surface == bg
    discard f.paintIfDirty()
    check f.pixel(600, 520).near(bg)
    f.finish()

  test "theme combo and View menu stay in sync, Show toolbar toggles":
    let f = newShown()
    f.clickTab(f.pages, 1)
    f.themeCombo.itemIndex = 1
    check f.themeDarkItem.checked and Application.theme.surface != themeLight().surface
    f.openMenu('v')
    f.clickMenuItem(f.themeDarkItem)       # toggles dark off
    check f.themeCombo.itemIndex == 0 and not f.darkTool.down
    f.openMenu('v')
    f.clickMenuItem(f.toolbarItem)
    check not f.toolbar.visible
    discard f.paintIfDirty()
    check f.cats.clientToForm(pointF(0, 0)).y < 70   # the content moved up into the freed space
    f.finish()

  test "Help > About is a modal dialog and closes with Enter":
    let f = newShown()
    var seen = false
    whileModal:
      seen = dlg != nil and dlg != Form(f) and dlg.caption == "About"
      dlg.tap(keyEnter)
    f.tap(keyF1)
    check seen and modalForm() == nil
    f.finish()

  test "category context menu selects pages":
    let f = newShown()
    let pm = popupMenuOf(f.cats)
    check pm != nil
    let p = f.cats.clientToForm(pointF(40, 40))
    discard pm.popup(f, p.x, p.y)
    var pick: MenuItem
    for i in 0 ..< pm.items.count:
      if parseMnemonic(pm.items[i].caption).text == "Editor": pick = pm.items[i]
    f.clickMenuItem(pick)
    check f.pages.tabIndex == 2
    f.finish()

  # ------------------------------------------------------------ toolbar
  test "toolbar check buttons drive word wrap and the theme, plain ones open dialogs":
    let f = newShown()
    f.clickRow(f.cats, 2)
    check not f.sample.wordWrap
    f.click(f.wrapTool)
    check f.sample.wordWrap and f.wrap.checked and f.wrapTool.down
    f.click(f.wrapTool)
    check not f.sample.wordWrap and not f.wrap.checked
    f.wrap.checked = true                 # the check box drives the tool button
    check f.sample.wordWrap and f.wrapTool.down
    f.click(f.darkTool)
    check f.darkTool.down and f.themeDarkItem.checked
    f.finish()

  test "Wrap and Dark are one Action: menu item, tool button, check box and shortcut share it":
    let f = newShown()
    check f.wrapAct.clientCount == 3 and f.darkAct.clientCount == 2
    f.tap('w', {ssCtrl})                  # the shortcut belongs to the action list
    check f.sample.wordWrap and f.wrapAct.checked and f.wrapTool.down and f.wrap.checked
    f.openMenu('v')
    check f.menu.items[2][1].checked      # View > Word wrap
    f.clickMenuItem(f.menu.items[2][1])
    check not f.sample.wordWrap and not f.wrapTool.down and not f.wrap.checked
    f.wrapAct.enabled = false             # one switch disables every client
    check not f.wrapTool.enabled and not f.wrap.enabled
    f.wrapAct.enabled = true
    f.tap('d', {ssCtrl})
    check f.darkTool.down and f.themeDarkItem.checked and f.themeCombo.itemIndex == 1
    f.finish()

  # ------------------------------------------------------------ splitter
  test "splitter drag resizes the category panel and the page follows":
    let f = newShown()
    let w0 = f.catPanel.width
    let pw0 = f.pages.width
    let sp = f.splitter.center
    f.mouse(ekMouseMove, sp)
    f.mouse(ekMouseDown, sp)
    f.mouse(ekMouseMove, pointF(sp.x + 60, sp.y))
    check f.splitter.isDragging
    f.mouse(ekMouseUp, pointF(sp.x + 60, sp.y))
    discard f.paintIfDirty()
    check f.catPanel.width == w0 + 60
    check f.pages.width == pw0 - 60
    f.mouse(ekMouseDown, f.splitter.center)
    f.mouse(ekMouseMove, pointF(0, f.splitter.center.y))
    f.mouse(ekMouseUp, pointF(0, f.splitter.center.y))
    discard f.paintIfDirty()
    check f.catPanel.width == f.splitter.minSize
    check f.pages.width > pw0
    f.finish()

  # ------------------------------------------------------------ controls
  test "controls update the status bar and the dirty state":
    let f = newShown()
    f.clickTab(f.pages, 1)
    f.fontSize.setFocus()
    f.tap(keyRight)
    check f.fontSize.position == 15 and f.fontValue.caption == "15 pt"
    check f.statusText(0) == "Font size 15 pt" and f.modified
    check f.preview.font.size == 15
    f.click(f.swatchBoxes[5])
    check f.accentIndex == 5 and f.statusText(0) == "Accent: Pink"
    f.clickTab(f.pages, 0)
    f.autosave.edit.setFocus()
    f.tap(keyUp)
    check f.autosave.value == 11 and f.statusText(0) == "Auto-save 11 min"
    f.click(f.startEmpty)
    check f.startEmpty.checked and f.statusText(0).startsWith("Startup")
    f.language.setFocus()
    f.tap(keyDown)
    check f.language.text == "Deutsch" and f.statusText(0) == "Language: Deutsch"
    f.country.edit.setFocus()
    f.typeText "Ger"
    check f.country.text == "Germany" and f.country.edit.selLength == 4
    check f.statusText(0) == "Country: Germany"
    f.finish()

  test "Apply shows the marquee 'applying...' and disables itself":
    let f = newShown()
    f.clickTab(f.pages, 1)
    check not f.applying.visible
    f.click(f.fontSize)
    f.nameEdit.text = "x"
    check f.applyBtn.enabled
    f.click(f.applyBtn)
    check f.applied == 1 and f.applying.visible and f.applyingLabel.visible
    check not f.applyBtn.enabled and f.statusText(1) == "Saved"
    check f.applying.runsMarquee
    f.finish()

  test "OK applies and closes, Cancel asks when there are changes":
    let f = newShown()
    f.click(f.cancelBtn)                 # nothing changed: closes silently
    check not f.visible
    Application.init()                   # (the first form is the main form)
    let g = newShown()
    g.nameEdit.text = "dirty"
    var asked = ""
    whileModal:
      asked = dlg.caption
      dlg.tap(keyEnter)                  # the default button is "No"
    g.tap(keyEscape)
    check asked == "Preferences" and g.visible
    whileModal:
      for c in dlg.children:
        if c of Button and c.tag == ord(mbYes): Button(c).click()
    g.tap(keyEscape)
    check not g.visible
    let h = newShown()
    h.nameEdit.text = "dirty"
    h.click(h.okBtn)
    check h.applied == 1 and not h.visible

  # ------------------------------------------------------------ modal round trips
  test "Advanced page: input query changes the name, reset asks Yes/No":
    let f = newShown()
    f.clickRow(f.cats, 3)
    f.nameEdit.text = "old"
    whileModal:
      let d = InputDlgForm(dlg)
      check d.input.text == "old"
      d.input.text = "new"
      dlg.tap(keyEnter)
    f.click(f.askBtn)
    check f.nameEdit.text == "new"
    whileModal:
      dlg.tap(keyEscape)
    f.click(f.askBtn)
    check f.nameEdit.text == "new"
    whileModal:
      dlg.tap(keyEnter)                             # the first button, Yes, is the default
    f.warnBtn.click()
    check f.statusText(0) == "Options reset"
    f.finish()

  # ------------------------------------------------------------ files
  test "settings round trip through a key=value file and the file dialogs":
    let path = getTempDir() / "nimvcl_settings_test.conf"
    removeFile path
    let f = newShown()
    f.nameEdit.text = "Ada"
    f.emailEdit.text = "ada@example.com"
    f.language.itemIndex = 3
    f.country.text = "Norway"
    f.minimised.checked = true
    f.autosave.value = 25
    f.startEmpty.checked = true
    f.fontSize.position = 20
    f.accentIndex = 6
    f.setWrap(true)
    f.setDark(true)
    check f.saveSettings(path)
    check "name=Ada" in readFile(path) and "theme=1" in readFile(path)
    # a fresh form in the default state loads it all back
    Application.theme = themeLight()
    f.finish()
    let g = newShown()
    check g.nameEdit.text == ""
    check g.loadSettings(path)
    check g.nameEdit.text == "Ada" and g.emailEdit.text == "ada@example.com"
    check g.language.text == "Français" and g.country.text == "Norway"
    check g.minimised.checked and g.autosave.value == 25 and g.startEmpty.checked
    check g.fontSize.position == 20 and g.accentIndex == 6
    check g.sample.wordWrap and g.themeDarkItem.checked
    check not g.modified and g.statusText(1) == "Saved"
    g.finish()
    # through the dialogs (fake platform call answering at once)
    let real = pdialogs.showFileDialogImpl
    var asked: seq[FileDialogKind]
    pdialogs.showFileDialogImpl = proc(req: FileDialogRequest, token: int,
                                       done: FileDialogDone) =
      asked.add req.kind
      done(token, true, @[path])
    defer: pdialogs.showFileDialogImpl = real
    Application.theme = themeLight()
    let h = newShown()
    h.tap('o', {ssCtrl})                 # File > Open settings...
    check asked == @[fdkOpen] and h.nameEdit.text == "Ada"
    removeFile path
    h.nameEdit.text = "Grace"
    h.tap('s', {ssCtrl})                 # File > Save as...
    check asked == @[fdkOpen, fdkSave] and fileExists(path)
    check "name=Grace" in readFile(path)
    check h.statusText(0).startsWith("Saved ")
    removeFile path
    h.finish()

  test "bad numbers and unknown keys in a settings file are tolerated":
    let f = newShown()
    f.loadSettingsText "autosave=abc\nfontsize=999\nfoo=bar\nnoequals\ntheme=0\n"
    check f.autosave.value == 10
    check f.fontSize.position == f.fontSize.max
    f.finish()

  # ------------------------------------------------------------ focus traversal
  test "Tab walks every focusable control of each page exactly once (no traps)":
    let f = newShown()
    for page in 0 .. 3:
      f.cats.itemIndex = page
      discard f.paintIfDirty()
      let stops = f.visibleStops
      check stops.len > 4
      for c in stops:
        check c.isShowing and c.isEnabled and c.canFocus
      # hidden pages contribute nothing
      for other in 0 .. 3:
        if other != page:
          for c in f.pages.sheets[other].children:
            check Control(c) notin stops
      f.activeControl = stops[0]
      var seen: seq[Control]
      for i in 0 ..< stops.len:
        check f.activeControl != nil
        check f.activeControl in stops
        check f.activeControl notin seen
        seen.add f.activeControl
        f.tap(keyTab)
      check f.activeControl == stops[0]          # wrapped after exactly stops.len steps
      check seen.len == stops.len
      # and backwards
      for i in 0 ..< stops.len: f.tap(keyTab, {ssShift})
      check f.activeControl == stops[0]
      # the focused control is always visible (the Advanced page scrolls to it)
      for c in stops:
        f.activeControl = c
        discard f.paintIfDirty()
        let r = f.clientToForm(f.clientRect)
        let cr = c.clientToForm(c.clientRect)
        check cr.x >= r.x - 0.5 and cr.right <= r.right + 0.5
        check cr.y >= r.y - 0.5 and cr.bottom <= r.bottom + 0.5
        var p = c.parent
        while p != nil:
          if p of ScrollBox:
            let vp = p.clientToForm(ScrollBox(p).viewportRect)
            check cr.y >= vp.y - 0.5 and cr.bottom <= vp.bottom + 0.5
          p = p.parent
    f.finish()

  test "every control sharing a row uses the theme's control height":
    let f = newShown()
    let h = currentTheme().controlHeight
    for c in [Control(f.nameEdit), f.emailEdit, f.language, f.country, f.autosave,
              f.themeCombo, f.tabSize, f.okBtn, f.cancelBtn, f.applyBtn]:
      check c.height == h
    f.finish()

  test "tab order: list, tabs, the page, then OK / Cancel; every stop has a hint":
    let f = newShown()
    for page in 0 .. 3:
      f.cats.itemIndex = page
      discard f.paintIfDirty()
      let stops = f.visibleStops
      check stops[0] == Control(f.cats) and stops[1] == Control(f.pages)
      check stops[^2] == Control(f.okBtn) or stops[^2] == Control(f.cancelBtn)
      check stops[^1] == Control(f.cancelBtn) or stops[^1] == Control(f.applyBtn)
      let iOk = stops.find(f.okBtn)
      check iOk > 1 and stops.find(f.cancelBtn) == iOk + 1
      for c in stops:
        let owner = if c.parent of ComboBox or c.parent of SpinEdit: c.parent else: c
        check owner.hint.len > 0
    f.finish()

  test "hovering a control shows its hint":
    let f = newShown()
    f.clickRow(f.cats, 3)
    Application.hintPause = 30
    f.mouse(ekMouseMove, f.folderBtn.center)
    let t0 = getMonoTime()
    while not hintVisible() and (getMonoTime() - t0).inMilliseconds < 2000:
      Application.processMessages(20)
    check hintVisible()
    f.mouse(ekMouseMove, pointF(5, 5))
    check not hintVisible()
    Application.hintPause = 600
    f.finish()

  test "Shift+F10 and the Menu key open the list's context menu; Esc closes it":
    let f = newShown()
    f.cats.setFocus()
    f.tap(keyF10, {ssShift})
    check topPopup(f) != nil
    f.tap(keyEscape)
    check topPopup(f) == nil
    f.finish()

  test "combo keyboard: Alt+Down opens, arrows move, Enter picks, Esc closes":
    let f = newShown()
    f.language.setFocus()
    f.tap(keyDown, {ssAlt})
    check f.language.droppedDown
    f.tap(keyDown)
    f.tap(keyDown)
    check f.language.text == "English"           # the text stays until the pick
    f.tap(keyEnter)
    check not f.language.droppedDown and f.language.text == "Español"
    check f.statusText(0) == "Language: Español" and f.visible
    f.tap(keyDown, {ssAlt})
    f.tap(keyEscape)
    check not f.language.droppedDown and f.language.text == "Español" and f.visible
    f.finish()

  test "combo mouse: arrow opens, a row picks; click outside closes":
    let f = newShown()
    discard f.paintIfDirty()
    f.clickAt(f.language.clientToForm(pointF(f.language.width - 10, f.language.height / 2)))
    check f.language.droppedDown
    let lb = f.language.dropList
    let p = f.language.popupWindow
    let r = lb.itemRect(4)
    let s = p.ui.win.scale
    for k in [ekMouseMove, ekMouseDown, ekMouseUp]:
      Application.dispatch(PlatformEvent(kind: k, windowId: p.ui.win.id,
        x: (r.x + r.w / 2) * s, y: (r.y + r.h / 2) * s, button: mbLeft, clicks: 1))
    check not f.language.droppedDown and f.language.text == "Italiano"
    f.finish()

  test "colour swatches are reachable with the keyboard (one stop, arrows move)":
    let f = newShown()
    f.clickTab(f.pages, 1)
    discard f.paintIfDirty()
    var swatchStops = 0
    for c in f.visibleStops:
      if c in f.swatchBoxes.mapIt(Control(it)): inc swatchStops
    check swatchStops == 1
    f.activeControl = f.swatchBoxes[f.accentIndex]
    check f.activeControl == Control(f.swatchBoxes[3])
    f.tap(keyRight)
    check f.accentIndex == 4 and f.activeControl == Control(f.swatchBoxes[4])
    f.tap(keyLeft); f.tap(keyLeft)
    check f.accentIndex == 2 and f.statusText(0) == "Accent: Green"
    f.tap(keyHome)                       # not a swatch key: stays
    f.activeControl = f.swatchBoxes[0]
    f.tap(keyLeft)
    check f.accentIndex == 2                # no wrap, nothing changes
    f.finish()

  test "a window the WM sized differently still gets the buttons at the right edge":
    let f = newSettingsForm()
    f.width = 640; f.height = 480        # before the first layout
    f.show()
    f.syncMetrics()
    discard f.paintIfDirty()
    check f.applyBtn.left + f.applyBtn.width <= f.footer.width
    check f.footer.width - (f.applyBtn.left + f.applyBtn.width) == 10
    check f.okBtn.left > 0
    f.finish()

  test "resizing keeps the buttons at the right edge and the page filling the window":
    let f = newShown()
    let gap = f.footer.width - (f.applyBtn.left + f.applyBtn.width)
    for (w, h) in [(640'f32, 480'f32), (1200'f32, 800'f32)]:
      f.setBounds(f.left, f.top, w, h)
      f.syncMetrics()
      discard f.paintIfDirty()
      check f.footer.width == w
      check abs(f.footer.width - (f.applyBtn.left + f.applyBtn.width) - gap) < 0.5
      check f.okBtn.left + f.okBtn.width <= f.cancelBtn.left
      check f.pages.width + f.catPanel.width + f.splitter.width <= w
      check f.pages.left + f.pages.width + 10 == w
      check f.statusBar.top + f.statusBar.height == f.height
    f.finish()

  test "track bar: mouse drag and keys change the font size live":
    let f = newShown()
    f.clickTab(f.pages, 1)
    discard f.paintIfDirty()
    let t = f.fontSize
    let th = t.thumbRect
    let start = t.clientToForm(pointF(th.x + th.w / 2, th.y + th.h / 2))
    f.mouse(ekMouseMove, start)
    f.mouse(ekMouseDown, start)
    f.mouse(ekMouseMove, pointF(start.x + 60, start.y))
    check t.isDragging and t.position > 14
    check f.fontValue.caption == $t.position & " pt"
    f.mouse(ekMouseUp, pointF(start.x + 60, start.y))
    check f.preview.font.size == float32(t.position)
    f.tap(keyHome)
    check t.position == 8 and f.sample.font.size == 8
    f.tap(keyEnd)
    check t.position == 32
    f.finish()

  test "memo: typing marks the page modified, Tab leaves the memo, wrap toggles scroll bars":
    let f = newShown()
    f.clickRow(f.cats, 2)
    f.sample.setFocus()
    check not f.modified
    f.typeText "Hello "
    check f.modified and f.statusText(0) == "Sample text edited"
    check f.sample.text.startsWith("Hello Settings")
    f.tap(keyTab)
    check f.activeControl == Control(f.wrap)
    check f.sample.hScrollBar.visible
    f.wrap.checked = true
    discard f.paintIfDirty()
    check not f.sample.hScrollBar.visible
    f.finish()

  test "wheel scrolls the Advanced page; clicks then hit the right check box":
    let f = newShown()
    f.clickRow(f.cats, 3)
    discard f.paintIfDirty()
    let box = f.advanced
    check box.vScrollBar.visible and box.scrollPos.y == 0
    let c = box.center
    f.mouse(ekMouseMove, c)
    Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: f.win.id,
                                       x: c.x, y: c.y, dy: -3, button: mbLeft))
    check box.scrollPos.y > 0
    discard f.paintIfDirty()
    var target: CheckBox
    for ch in box.children:
      if ch of CheckBox and ch.caption == "Experimental option 8": target = CheckBox(ch)
    check target != nil
    let before = target.checked
    f.click(target)
    check target.checked != before
    check f.statusText(0) == "Option changed"
    f.finish()

  test "modal dialogs give the focus back; the main form ignores input meanwhile":
    let f = newShown()
    f.nameEdit.setFocus()
    var ignored = true
    whileModal:
      f.tap('x')                         # the main form is gated
      f.typeText "zzz"
      ignored = f.nameEdit.text == ""
      dlg.tap(keyEnter)
    f.tap(keyF1)
    check ignored
    check f.activeControl == Control(f.nameEdit)
    f.typeText "ok"
    check f.nameEdit.text == "ok"
    f.finish()

  test "list type-ahead switches pages; radio arrows and Space work":
    let f = newShown()
    f.cats.setFocus()
    f.typeText "e"
    f.tap('e')
    check f.pages.tabIndex == 2          # "Editor"
    f.clickTab(f.pages, 0)
    f.startLast.setFocus()
    f.tap(keyDown)
    check f.startWelcome.checked and f.startWelcome.focused
    check f.statusText(0) == "Startup: Show the welcome page"
    f.tap(keyDown)
    check f.startEmpty.checked
    f.tap(keyUp)
    check f.startWelcome.checked
    f.updates.setFocus()
    f.tap(keySpace)
    check not f.updates.checked
    f.finish()

  test "spin edit: typed numbers are clamped when focus leaves, status follows":
    let f = newShown()
    f.autosave.edit.setFocus()
    f.autosave.edit.selectAll()
    f.typeText "999"
    f.tap(keyTab)
    check f.autosave.value == 120 and f.autosave.edit.text == "120"
    check f.statusText(0) == "Auto-save 120 min"
    f.autosave.edit.setFocus()
    f.autosave.edit.selectAll()
    f.typeText "12x"                      # letters are filtered
    check f.autosave.edit.text == "12"
    f.tap(keyEnter)                       # commits; Enter is left to the default button -> OK
    check f.applied == 1
    check f.autosave.value == 12

  test "Enter in the memo is a new line, not OK; Esc in a closed combo is Cancel":
    let f = newShown()
    f.clickRow(f.cats, 2)
    f.sample.setFocus()
    let lines = f.sample.lineCount
    f.tap(keyEnter)
    check f.sample.lineCount == lines + 1 and f.visible and f.applied == 0
    f.finish()
    let g = newShown()
    g.language.setFocus()
    g.tap(keyEscape)                      # nothing changed: Cancel closes
    check not g.visible

  test "closing the window with changes asks first":
    let f = newShown()
    f.nameEdit.text = "x"
    var asked = false
    whileModal:
      asked = dlg != nil and dlg.caption == "Preferences"
      dlg.tap(keyEnter)                   # default "No"
    Application.dispatch(PlatformEvent(kind: ekWindowClose, windowId: f.win.id))
    check asked and f.visible
    f.finish()

  # ------------------------------------------------------------ paint smoke
  test "paints every page at 1x, 1.5x and 2x in both themes (also tiny and wide)":
    for scale in [1'f32, 1.5, 2]:
      Application.forceScale = scale
      for dark in [false, true]:
        Application.theme = if dark: themeDark() else: themeLight()
        let f = newShown()
        for page in 0 .. 3:
          f.cats.itemIndex = page
          check f.paintIfDirty() or true
          f.activeControl = f.visibleStops[0]
          discard f.paintIfDirty()
        # menus and combos open
        for m in 0 .. 3:
          f.menu.openDropdown(m, selectFirst = true)
          Application.paintForms()
          f.menu.closeMenus()
        f.cats.itemIndex = 0
        f.language.dropDown()
        Application.paintForms()
        f.language.closeUp()
        f.country.dropDown()
        Application.paintForms()
        f.country.closeUp()
        for (w, h) in [(640'f32, 480'f32), (1200'f32, 800'f32)]:
          f.setBounds(f.left, f.top, w, h)
          f.syncMetrics()
          for page in 0 .. 3:
            f.cats.itemIndex = page
            discard f.paintIfDirty()
        f.finish()
        check not f.visible
    Application.forceScale = 0
