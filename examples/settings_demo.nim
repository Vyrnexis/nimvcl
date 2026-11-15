# Phase 5 exit criterion: a settings application that uses (nearly) every
# control, written with the `form` macro and `import nimvcl` only.
#
# Menus (Alt+F/E/V/H), toolbar, a category list that drives a PageControl (and
# the other way round: click a tab or press Ctrl+Tab), a Splitter between them,
# status bar panels, context menu on the list, OK / Cancel / Apply, file
# dialogs (settings are saved as a small key=value text file).
#
# Keys: Ctrl+O open settings, Ctrl+S save as, Ctrl+Q exit, Ctrl+Tab next page,
#       F1 about, F9 toolbar, Alt+letter mnemonics, Enter = OK, Esc = Cancel.
#
# Env (headless screenshot mode):
#   NIMVCL_SCREENSHOT=path.bmp   lay out, render one frame and exit
#   NIMVCL_SIZE=640x480          resize the window first
#   NIMVCL_PAGE=n                show page n (0 General .. 3 Advanced)
#   NIMVCL_OPEN_MENU=View        render with that top menu open
#   NIMVCL_COMBO=language        render with that combo (field name) dropped down
#   NIMVCL_FOCUS=name            focus the control with this field name
#   NIMVCL_ALT=1                 draw as if Alt were held (mnemonic underlines)
#   NIMVCL_DARK=1                dark theme
#   NIMVCL_SCALE=1.5             force the display scale
#
# Build: nim c --outdir:build examples/settings_demo.nim

import std/[os, strutils, tables, math]
import nimvcl

const
  Categories = ["General", "Appearance", "Editor", "Advanced"]
  Swatches = [0xe03131, 0xf08c00, 0x2f9e44, 0x1c7ed6, 0x7048e8, 0xd6336c,
              0x0c8599, 0x495057]
  SwatchNames = ["Red", "Orange", "Green", "Blue", "Violet", "Pink", "Teal", "Slate"]
  SampleText = "Settings are saved as key=value lines.\nThe quick brown fox jumps over the lazy dog.\n" &
               "Toggle word wrap to see this long line wrap around at the edge of the editor, " &
               "which has no horizontal scroll bar while wrapping."

proc swatchColor(i: int): Color =
  let v = Swatches[clamp(i, 0, Swatches.high)]
  rgb((v shr 16) and 0xff, (v shr 8) and 0xff, v and 0xff)

proc makeIcon(inside: proc(u, v: float): bool): Image =
  ## A 16x16 logical icon drawn at 2x (32 px), 3x3 supersampled, in a mid blue
  ## that reads on both themes.
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

proc inRect(u, v, x0, y0, x1, y1: float): bool = u >= x0 and u <= x1 and v >= y0 and v <= y1
proc ring(u, v, r, w: float): bool =
  let d = sqrt((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5))
  d <= r and d >= r - w

proc iconOpen(u, v: float): bool =
  inRect(u, v, 0.08, 0.32, 0.92, 0.84) or inRect(u, v, 0.08, 0.18, 0.42, 0.34)
proc iconSave(u, v: float): bool =
  inRect(u, v, 0.1, 0.1, 0.9, 0.9) and not inRect(u, v, 0.28, 0.1, 0.72, 0.38) and
    not inRect(u, v, 0.26, 0.56, 0.74, 0.9)
proc iconWrap(u, v: float): bool =
  inRect(u, v, 0.1, 0.2, 0.9, 0.3) or inRect(u, v, 0.1, 0.45, 0.75, 0.55) or
    inRect(u, v, 0.1, 0.7, 0.45, 0.8)
proc iconMoon(u, v: float): bool =
  ring(u, v, 0.42, 0.07) or (u < 0.5 and ring(u, v, 0.42, 0.42))
proc iconExit(u, v: float): bool =
  inRect(u, v, 0.1, 0.12, 0.2, 0.88) or inRect(u, v, 0.1, 0.12, 0.5, 0.22) or
    inRect(u, v, 0.1, 0.78, 0.5, 0.88) or inRect(u, v, 0.3, 0.45, 0.68, 0.55) or
    (u >= 0.62 and u <= 0.92 and abs(v - 0.5) <= (0.92 - u) * 0.95)
proc iconAbout(u, v: float): bool =
  ring(u, v, 0.44, 0.07) or inRect(u, v, 0.45, 0.44, 0.55, 0.74) or
    ((u - 0.5) * (u - 0.5) + (v - 0.29) * (v - 0.29) <= 0.0049)

const
  iOpen = 0
  iSave = 1
  iWrap = 2
  iDark = 3
  iExit = 4
  iAbout = 5

proc makeIcons(): ImageList =
  result = newImageList(16, 16)
  for f in [iconOpen, iconSave, iconWrap, iconMoon, iconExit, iconAbout]:
    result.add makeIcon(f)

type
  Swatch = ref object of PaintBox
    ## A colour swatch: a PaintBox that can take the focus (one tab stop for the
    ## group, the selected swatch) and moves the selection with the arrow keys.
    selected: bool
    pick: proc(index: int)

method canFocus(s: Swatch): bool = s.isVisible and s.isEnabled
method isTabStop(s: Swatch): bool = s.selected

method doKeyDown(s: Swatch, key: var Key, shift: ShiftState) =
  procCall doKeyDown(PaintBox(s), key, shift)
  if key == Key(0) or shift * {ssCtrl, ssAlt, ssSuper} != {}: return
  var step = 0
  if key == keyLeft or key == keyUp: step = -1
  elif key == keyRight or key == keyDown: step = 1
  elif key == keySpace or key == keyEnter:
    if s.pick != nil: s.pick(s.tag)
    key = Key(0)
    return
  if step != 0:
    key = Key(0)
    let n = s.tag + step
    if n >= 0 and n < Swatches.len and s.pick != nil: s.pick(n)

method doClick(s: Swatch) =
  procCall doClick(PaintBox(s))

proc newSwatch(parent: Container, index: int): Swatch =
  new result
  result.initPaintBox(parent)
  result.setBounds(0, 0, 28, 28)
  result.tag = index
  parent.insertControl result

form SettingsForm:
  caption = "Preferences"
  width = 900; height = 640
  position = poScreenCenter
  var modified: bool                       ## unsaved changes since the last Apply
  var loading: bool                        ## true while settings are applied by code
  var applied: int                         ## how many times Apply took effect
  var accentIndex: int = 3
  var lastFile: string
  var swatchBoxes: seq[PaintBox]          ## `Swatch`es
  var applyTimer: Timer
  var mainMenu: MainMenu
  var catMenu: PopupMenu
  var themeDarkItem, toolbarItem: MenuItem
  var undoItem, redoItem: MenuItem
  var actions: ActionList                  ## shared by the menu, toolbar and shortcuts
  var openAct, saveAct, wrapAct, darkAct, exitAct, aboutAct: Action
  var icons: ImageList

  ToolBar toolbar:
    ToolButton openTool:
      caption = "Open"
    ToolButton saveTool:
      caption = "Save"
    ToolButton:
      kind = tbsDivider
    ToolButton wrapTool:
      caption = "Wrap"
    ToolButton darkTool:
      caption = "Dark"
  StatusBar statusBar:
    height = 26
  Panel footer:
    align = alBottom; height = 52
    borderStyle = pbNone
    tabOrder = 9                          # after the page controls
    # alRight stacks from the right edge (first declared = rightmost), so the
    # row follows any window size; tabOrder gives OK, Cancel, Apply.
    Button applyBtn:
      caption = "&Apply"; width = 92; align = alRight
      margins = spacing(0, 12, 10, 12); tabOrder = 2
      hint = "Apply the changes now"
    Button cancelBtn:
      caption = "Cancel"; width = 92; align = alRight
      margins = spacing(0, 12, 8, 12); tabOrder = 1
      isCancel = true
      hint = "Close without applying"
    Button okBtn:
      caption = "OK"; width = 92; align = alRight
      margins = spacing(0, 12, 8, 12); tabOrder = 0
      isDefault = true
      hint = "Apply the changes and close"
  Panel catPanel:
    align = alLeft; width = 190
    borderStyle = pbNone
    padding = spacing(10, 4, 0, 10)
    Label catLabel:
      caption = "Catego&ries"; align = alTop
      focusControl = self.cats
      margins = spacing(2, 2, 0, 6)
    ListBox cats:
      align = alClient
      hint = "Pick a settings category"
  Splitter splitter:
    align = alLeft
  PageControl pages:
    align = alClient
    hint = "Ctrl+Tab switches the page"
    margins = spacing(0, 4, 10, 10)
    TabSheet generalPage:
      caption = "&General"
      # Small windows scroll the page instead of clipping it: the canvas follows
      # the page size down to a minimum, below which the ScrollBox scrolls.
      ScrollBox generalScroll:
        align = alClient
        width = 692; height = 457       # the size the canvas below was drawn for
        hScrollMode = sbmNever          # the canvas shrinks to its minimum width instead
        Panel generalCanvas:
          borderStyle = pbNone
          left = 0; top = 0; width = 692; height = 457
          anchors = {akLeft, akTop, akRight, akBottom}
          constraints = constraints(minWidth = 340, minHeight = 390)
          GridPanel identGrid:
            left = 16; top = 14; width = 660; height = 112
            anchors = {akLeft, akTop, akRight}
            borderStyle = pbNone
            Label nameLabel:
              caption = "&Name"; autoSize = false; layout = vaBottom
              margins = spacing(0, 0, 0, 3)
              focusControl = self.nameEdit
            Label emailLabel:
              caption = "E&mail"; autoSize = false; layout = vaBottom
              margins = spacing(12, 0, 0, 3)
              focusControl = self.emailEdit
            Edit nameEdit:
              placeholder = "Your full name"
              margins = spacing(0, 0, 0, 0)
              hint = "The name shown in documents"
            Edit emailEdit:
              placeholder = "name@example.com"
              margins = spacing(12, 0, 0, 0)
              hint = "Used for notifications"
            Label langLabel:
              caption = "&Language"; autoSize = false; layout = vaBottom
              margins = spacing(0, 0, 0, 3)
              focusControl = self.language
            Label countryLabel:
              caption = "C&ountry"; autoSize = false; layout = vaBottom
              margins = spacing(12, 0, 0, 3)
              focusControl = self.country
            ComboBox language:
              style = csDropDownList
              hint = "User interface language"
            ComboBox country:
              margins = spacing(12, 0, 0, 0)
              hint = "Type to complete the country name"
          CheckBox updates:
            caption = "Check for &updates"; checked = true; left = 16; top = 152
            hint = "Look for new versions at startup"
          CheckBox minimised:
            caption = "Start minimi&sed"; left = 16; top = 180
            hint = "Start in the system tray"
          CheckBox usage:
            caption = "Send usage s&tatistics"; left = 16; top = 208
            hint = "Anonymous, never shared"
          Label autosaveLabel:
            caption = "Auto-save ever&y (min)"; left = 240; top = 152
            focusControl = self.autosave
          SpinEdit autosave:
            left = 240; top = 174; width = 120
            minValue = 0; maxValue = 120; value = 10
            hint = "0 turns auto-save off"
          GroupBox startupGroup:
            caption = "On startup"; left = 16; top = 252; width = 660; height = 120
            anchors = {akLeft, akTop, akRight}
            RadioButton startLast:
              caption = "Open the last &document"; checked = true; left = 16; top = 32
              hint = "Restore the previous session"
            RadioButton startWelcome:
              caption = "Show the &welcome page"; left = 16; top = 58
              hint = "A short tour"
            RadioButton startEmpty:
              caption = "Start with an empty wor&kspace"; left = 16; top = 84
              hint = "Nothing is opened"
    TabSheet appearancePage:
      caption = "A&ppearance"
      # Small windows scroll the page instead of clipping it: the canvas follows
      # the page size down to a minimum, below which the ScrollBox scrolls.
      ScrollBox appearanceScroll:
        align = alClient
        width = 692; height = 457       # the size the canvas below was drawn for
        hScrollMode = sbmNever          # the canvas shrinks to its minimum width instead
        Panel appearanceCanvas:
          borderStyle = pbNone
          left = 0; top = 0; width = 692; height = 457
          anchors = {akLeft, akTop, akRight, akBottom}
          constraints = constraints(minWidth = 340, minHeight = 330)
          Label fontLabel:
            caption = "Font &size"; left = 16; top = 14
            focusControl = self.fontSize
          TrackBar fontSize:
            left = 16; top = 36; width = 560
            anchors = {akLeft, akTop, akRight}
            min = 8; max = 32; position = 14; frequency = 4
            hint = "Editor font size"
          Label fontValue:
            caption = "14 pt"; left = 600; top = 40
            anchors = {akTop, akRight}
          GroupBox previewGroup:
            caption = "Preview"; left = 16; top = 84; width = 660; height = 84
            anchors = {akLeft, akTop, akRight}
            Label preview:
              caption = "The quick brown fox jumps over the lazy dog"
              left = 16; top = 34
          Label themeLabel:
            caption = "&Theme"; left = 16; top = 184
            focusControl = self.themeCombo
          ComboBox themeCombo:
            style = csDropDownList
            left = 16; top = 206; width = 200
            hint = "Colour theme"
          Label accentLabel:
            caption = "Accent colour"; left = 240; top = 184
          FlowPanel swatchPanel:
            left = 240; top = 206; width = 436; height = 36
            anchors = {akLeft, akTop, akRight}
            hGap = 6
          Label applyingLabel:
            caption = "Applying..."; left = 16; top = 268
            visible = false
          ProgressBar applying:
            left = 16; top = 290; width = 300
            anchors = {akLeft, akTop, akRight}
            style = pbsMarquee; visible = false
            hint = "Applying the settings"
    TabSheet editorPage:
      caption = "Ed&itor"
      # Small windows scroll the page instead of clipping it: the canvas follows
      # the page size down to a minimum, below which the ScrollBox scrolls.
      ScrollBox editorScroll:
        align = alClient
        width = 692; height = 457       # the size the canvas below was drawn for
        hScrollMode = sbmNever          # the canvas shrinks to its minimum width instead
        Panel editorCanvas:
          borderStyle = pbNone
          left = 0; top = 0; width = 692; height = 457
          anchors = {akLeft, akTop, akRight, akBottom}
          constraints = constraints(minWidth = 340, minHeight = 380)
          Memo sample:
            left = 16; top = 14; width = 660; height = 250
            anchors = {akLeft, akTop, akRight, akBottom}
            hint = "A sample document"
          CheckBox wrap:
            caption = "&Word wrap"; left = 16; top = 276
            anchors = {akLeft, akBottom}
            hint = "Wrap long lines in the editor"
          GridPanel optionsGrid:
            left = 16; top = 312; width = 660; height = 96
            anchors = {akLeft, akRight, akBottom}
            Label tabLabel:
              caption = "T&ab width"; autoSize = false; layout = vaCenter
              margins = spacing(0, 2)
              focusControl = self.tabSize
            SpinEdit tabSize:
              minValue = 1; maxValue = 16; value = 4; margins = spacing(0, 2)
              hint = "Spaces per tab"
            CheckBox lineNumbers:
              caption = "Line &numbers"; checked = true; margins = spacing(0, 2)
              hint = "Show line numbers"
            CheckBox highlightLine:
              caption = "Highlight the current &line"; margins = spacing(0, 2)
              hint = "Tint the line with the caret"
            CheckBox trimSpaces:
              caption = "&Trim trailing spaces"; margins = spacing(0, 2)
              hint = "Remove trailing blanks on save"
            CheckBox finalNewline:
              caption = "En&d files with a newline"; margins = spacing(0, 2)
              hint = "Add a final line break on save"
    TabSheet advancedPage:
      caption = "Advan&ced"
      ScrollBox advanced:
        align = alClient
        autoContentSize = true
        padding = spacing(12)
        Button askBtn:
          caption = "Ask name..."; left = 12; top = 12; width = 120
          hint = "inputQuery dialog"
        Button warnBtn:
          caption = "Reset..."; left = 140; top = 12; width = 120
          hint = "messageDlg with Yes/No"
        Button openBtn:
          caption = "Open file..."; left = 268; top = 12; width = 120
          hint = "OpenDialog"
        Button saveBtn:
          caption = "Save file..."; left = 396; top = 12; width = 120
          hint = "SaveDialog"
        Button folderBtn:
          caption = "Folder..."; left = 524; top = 12; width = 120
          hint = "SelectFolderDialog"

  # ---------------------------------------------------------------- logic

  proc say(self: SettingsForm, text: string) =
    self.statusBar.panels[0].text = text

  proc refreshStatus(self: SettingsForm) =
    self.statusBar.panels[1].text = if self.modified: "Modified" else: "Saved"
    self.statusBar.panels[2].text = Categories[clamp(self.pages.tabIndex, 0, Categories.high)]
    self.applyBtn.enabled = self.modified

  proc touch(self: SettingsForm, what: string) =
    if self.loading: return
    self.modified = true
    self.say what
    self.refreshStatus()

  proc setDark*(self: SettingsForm, dark: bool) =
    let was = self.loading
    self.loading = true
    Application.theme = if dark: themeDark() else: themeLight()
    self.darkAct.checked = dark          # menu item and tool button follow
    self.themeCombo.itemIndex = ord(dark)
    self.loading = was
    self.touch "Theme: " & (if dark: "dark" else: "light")

  proc applyFont(self: SettingsForm) =
    let n = self.fontSize.position
    self.fontValue.caption = $n & " pt"
    self.preview.font = font(size = float32(n))
    self.sample.font = font(size = float32(n))
    self.touch "Font size " & $n & " pt"

  proc selectAccent(self: SettingsForm, i: int) =
    self.accentIndex = i
    for b in self.swatchBoxes:
      Swatch(b).selected = b.tag == i
      b.invalidate()
    self.touch "Accent: " & SwatchNames[i]

  proc setWrap*(self: SettingsForm, on: bool) =
    self.sample.wordWrap = on
    self.wrap.checked = on
    self.wrapAct.checked = on            # View menu item and tool button follow
    self.touch "Word wrap " & (if on: "on" else: "off")

  proc applyNow(self: SettingsForm) =
    ## Pretend to apply for a moment: the marquee shows "applying...".
    inc self.applied
    self.modified = false
    self.applyingLabel.visible = true
    self.applying.visible = true
    self.applyTimer.enabled = false           # restart the 900 ms delay
    self.applyTimer.enabled = true
    self.say "Settings applied (" & $self.applied & ")"
    self.refreshStatus()

  proc settingsText*(self: SettingsForm): string =
    ## The current settings as `key=value` lines.
    var t = initOrderedTable[string, string]()
    t["name"] = self.nameEdit.text
    t["email"] = self.emailEdit.text
    t["language"] = self.language.text
    t["country"] = self.country.text
    t["updates"] = $self.updates.checked
    t["minimised"] = $self.minimised.checked
    t["usage"] = $self.usage.checked
    t["autosave"] = $self.autosave.value
    t["startup"] = $(if self.startWelcome.checked: 1 elif self.startEmpty.checked: 2 else: 0)
    t["fontsize"] = $self.fontSize.position
    t["theme"] = $self.themeCombo.itemIndex
    t["accent"] = $self.accentIndex
    t["wrap"] = $self.wrap.checked
    t["tabsize"] = $self.tabSize.value
    t["linenumbers"] = $self.lineNumbers.checked
    for k, v in t: result.add k & "=" & v & "\n"

  proc loadSettingsText*(self: SettingsForm, text: string) =
    var t = initTable[string, string]()
    for line in text.splitLines:
      let i = line.find('=')
      if i > 0: t[line[0 ..< i].strip()] = line[i + 1 .. ^1].strip()
    let was = self.loading
    self.loading = true
    proc b(k: string, d: bool): bool = (if k in t: t[k] == "true" else: d)
    proc n(k: string, d: int): int =
      try: (if k in t: parseInt(t[k]) else: d)
      except ValueError: d
    self.nameEdit.text = t.getOrDefault("name", "")
    self.emailEdit.text = t.getOrDefault("email", "")
    self.language.text = t.getOrDefault("language", self.language.text)
    self.country.text = t.getOrDefault("country", "")
    self.updates.checked = b("updates", true)
    self.minimised.checked = b("minimised", false)
    self.usage.checked = b("usage", false)
    self.autosave.value = n("autosave", 10)
    let st = n("startup", 0)
    self.startLast.checked = st == 0
    self.startWelcome.checked = st == 1
    self.startEmpty.checked = st == 2
    self.fontSize.position = n("fontsize", 14)
    self.accentIndex = clamp(n("accent", 3), 0, Swatches.high)
    self.setWrap(b("wrap", false))
    self.tabSize.value = n("tabsize", 4)
    self.lineNumbers.checked = b("linenumbers", true)
    self.loading = was
    self.setDark(n("theme", 0) == 1)
    self.loading = was
    self.selectAccent(self.accentIndex)
    self.modified = false
    self.refreshStatus()

  proc saveSettings*(self: SettingsForm, path: string): bool =
    try:
      writeFile(path, self.settingsText)
      self.lastFile = path
      self.say "Saved " & extractFilename(path)
      true
    except IOError:
      messageDlg("Cannot write " & path, mtError)
      false

  proc loadSettings*(self: SettingsForm, path: string): bool =
    try:
      self.loadSettingsText readFile(path)
      self.lastFile = path
      self.say "Loaded " & extractFilename(path)
      true
    except IOError:
      messageDlg("Cannot read " & path, mtError)
      false

  proc openSettings*(self: SettingsForm) =
    let d = newOpenDialog(self)
    d.title = "Open settings"
    d.filters = @[("Settings", "conf;ini;txt"), ("All files", "*")]
    if d.executeModal() and d.fileName.len > 0: discard self.loadSettings(d.fileName)

  proc saveSettingsAs*(self: SettingsForm) =
    let d = newSaveDialog(self)
    d.title = "Save settings as"
    d.filters = @[("Settings", "conf"), ("All files", "*")]
    if d.executeModal() and d.fileName.len > 0: discard self.saveSettings(d.fileName)

  proc showAbout*(self: SettingsForm) =
    messageDlg("Preferences demo\nBuilt with nimvcl: every control, one form.",
               mtInformation, {mbOK}, mbOK, "About")

  proc focusActiveEditable(self: SettingsForm): Control =
    let c = self.activeControl
    if c != nil and (c of Edit or c of Memo): c else: nil

  proc buildActions(self: SettingsForm) =
    ## One Action per command: the menu items, tool buttons, the Wrap check box
    ## and the keyboard shortcuts all share its caption, hint, icon, enabled
    ## and checked state.
    self.icons = makeIcons()
    let al = newActionList(self)
    self.actions = al
    al.images = self.icons
    proc make(caption, hint: string, icon: int, sc = noShortcut,
              autoCheck = false): Action =
      result = newAction(al, caption, nil, sc)
      result.hint = hint
      result.imageIndex = icon
      result.autoCheck = autoCheck
    self.openAct = make("&Open settings...", "Open a settings file (Ctrl+O)", iOpen,
                        shortcut("Ctrl+O"))
    self.saveAct = make("Save &as...", "Save the settings as a file (Ctrl+S)", iSave,
                        shortcut("Ctrl+S"))
    self.wrapAct = make("&Word wrap", "Word wrap in the editor", iWrap,
                        shortcut("Ctrl+W"), true)
    self.darkAct = make("&Dark theme", "Dark theme", iDark, shortcut("Ctrl+D"), true)
    self.exitAct = make("E&xit", "Close the preferences (Ctrl+Q)", iExit, shortcut("Ctrl+Q"))
    self.aboutAct = make("&About", "About this demo (F1)", iAbout, shortcut("F1"))
    self.openAct.onExecute = proc(a: Action) = self.openSettings()
    self.saveAct.onExecute = proc(a: Action) = self.saveSettingsAs()
    self.wrapAct.onExecute = proc(a: Action) = self.setWrap(a.checked)
    self.darkAct.onExecute = proc(a: Action) = self.setDark(a.checked)
    self.exitAct.onExecute = proc(a: Action) = self.close()
    self.aboutAct.onExecute = proc(a: Action) = self.showAbout()
    for (b, a) in [(self.openTool, self.openAct), (self.saveTool, self.saveAct),
                   (self.wrapTool, self.wrapAct), (self.darkTool, self.darkAct)]:
      b.action = a
      b.showCaption = false              # icons only; the hints say the rest
    self.wrap.action = self.wrapAct      # the Editor page's check box shares it too

  proc buildMenus(self: SettingsForm) =
    self.buildActions()
    let mm = newMainMenu(self)
    self.mainMenu = mm
    let file = mm.addItem("&File")
    file.add(newMenuItem()).action = self.openAct
    file.add(newMenuItem()).action = self.saveAct
    file.addSeparator()
    file.add(newMenuItem()).action = self.exitAct
    let edit = mm.addItem("&Edit")
    proc undoRedo(redo: bool) =
      let c = self.focusActiveEditable()
      if c of Edit:
        if redo: Edit(c).redo() else: Edit(c).undo()
      elif c of Memo:
        if redo: Memo(c).redo() else: Memo(c).undo()
    self.undoItem = edit.addItem("&Undo", proc(s: MenuItem) = undoRedo(false))
    self.redoItem = edit.addItem("&Redo", proc(s: MenuItem) = undoRedo(true))
    edit.addSeparator()
    proc preferences(s: MenuItem) =
      self.cats.itemIndex = 0
      setFocus(self.nameEdit)
    edit.addItem("&Preferences", preferences, shortcut("F2"))
    let view = mm.addItem("&View")
    self.themeDarkItem = view.add(newMenuItem())
    self.themeDarkItem.action = self.darkAct
    view.add(newMenuItem()).action = self.wrapAct
    proc toggleToolbar(s: MenuItem) =
      self.toolbar.visible = s.checked
      self.say(if s.checked: "Toolbar shown" else: "Toolbar hidden")
    self.toolbarItem = view.addItem("Show &toolbar", toggleToolbar, shortcut("F9"))
    self.toolbarItem.autoCheck = true
    self.toolbarItem.checked = true
    let help = mm.addItem("&Help")
    help.add(newMenuItem()).action = self.aboutAct

    let pm = newPopupMenu(self)
    self.catMenu = pm
    pm.addItem("&General", proc(s: MenuItem) = self.cats.itemIndex = 0)
    pm.addItem("&Appearance", proc(s: MenuItem) = self.cats.itemIndex = 1)
    pm.addItem("Ed&itor", proc(s: MenuItem) = self.cats.itemIndex = 2)
    pm.addItem("Ad&vanced", proc(s: MenuItem) = self.cats.itemIndex = 3)
    pm.addSeparator()
    pm.addItem("&Reset page", proc(s: MenuItem) = self.say "Reset " & Categories[self.pages.tabIndex])
    attachPopupMenu(self.cats, pm)

  proc buildContent(self: SettingsForm) =
    for c in Categories: self.cats.add c
    self.language.items = ["English", "Deutsch", "Español", "Français", "Italiano", "日本語"]
    self.language.itemIndex = 0
    self.country.items = ["Argentina", "Australia", "Austria", "Belgium", "Brazil",
                          "Canada", "Chile", "Denmark", "Finland", "France", "Germany",
                          "Ireland", "Italy", "Japan", "Mexico", "Netherlands", "Norway",
                          "Spain", "Sweden", "Switzerland", "United Kingdom", "United States"]
    self.themeCombo.items = ["Light", "Dark"]
    self.themeCombo.itemIndex = 0
    self.applyTimer = newTimer(self, 900)
    self.applyTimer.enabled = false
    self.applyTimer.onTimer = proc(t: Timer) =
      t.enabled = false
      self.applyingLabel.visible = false
      self.applying.visible = false
    let sb = self.statusBar
    sb.addPanel("Ready", 420)
    sb.addPanel("Saved", 90, taCenter)
    sb.addPanel("General", 140)
    sb.sizeGrip = true
    # colour swatches
    for i in 0 ..< Swatches.len:
      let p = newSwatch(self.swatchPanel, i)
      p.hint = SwatchNames[i] & " accent"
      p.cursor = crHand
      p.selected = i == self.accentIndex
      p.pick = proc(index: int) =
        self.selectAccent(index)
        setFocus(self.swatchBoxes[index])
      p.onPaint = proc(s: Control, c: Canvas) =
        let r = s.clientRect
        c.fillRoundRect(r.inflate(-4), 4, swatchColor(s.tag))
        if self.accentIndex == s.tag:
          c.strokeRoundRect(r.inflate(-2), 6, s.theme.text, 2)
        if s.focused: drawFocusRing(c, r, s.theme)
      p.onClick = proc(s: Control) = self.selectAccent(s.tag)
      self.swatchBoxes.add p
    self.preview.font = font(size = 14)
    self.sample.text = SampleText
    self.sample.font = font(size = 14)
    # grid of editor options
    let g = self.optionsGrid
    g.columns = @[gsPercent(50), gsPercent(50)]
    g.rows = @[gsAbsolute(32), gsAbsolute(32), gsAbsolute(32)]
    let ig = self.identGrid
    ig.columns = @[gsPercent(50), gsPercent(50)]
    let ch = currentTheme().controlHeight
    ig.rows = @[gsAbsolute(24), gsAbsolute(ch), gsAbsolute(24), gsAbsolute(ch)]
    ig.height = 24 + ch + 24 + ch
    g.setCell(self.tabLabel, 0, 0)
    g.setCell(self.tabSize, 0, 1)
    g.setCell(self.lineNumbers, 1, 0)
    g.setCell(self.highlightLine, 1, 1)
    g.setCell(self.trimSpaces, 2, 0)
    g.setCell(self.finalNewline, 2, 1)
    self.tabSize.width = 110
    # advanced: many options, a hint on each
    var y = 60'f32
    for i in 1 .. 18:
      let cb = newCheckBox(self.advanced, "Experimental option " & $i, i mod 3 == 0, 12, y)
      cb.hint = "Turns experimental option " & $i & " on or off"
      cb.onChange = proc(s: Control) = self.touch("Option changed")
      y += 30

  proc wire(self: SettingsForm) =
    self.cats.onChange = proc(s: Control) =
      let i = self.cats.itemIndex
      if i >= 0 and i != self.pages.tabIndex: self.pages.tabIndex = i
    self.pages.onChange = proc(s: Control) =
      if self.cats.itemIndex != self.pages.tabIndex:
        self.cats.itemIndex = self.pages.tabIndex
      self.refreshStatus()
    for e in [self.nameEdit, self.emailEdit]:
      e.onChange = proc(s: Control) = self.touch("Edited " & Edit(s).placeholder.toLowerAscii)
    self.sample.onChange = proc(s: Control) = self.touch("Sample text edited")
    self.language.onChange = proc(s: Control) = self.touch("Language: " & self.language.text)
    self.country.onChange = proc(s: Control) = self.touch("Country: " & self.country.text)
    for c in [self.updates, self.minimised, self.usage, self.lineNumbers,
              self.highlightLine, self.trimSpaces, self.finalNewline]:
      c.onChange = proc(s: Control) = self.touch(s.caption.replace("&", "") & ": " &
                                                  (if CheckBox(s).checked: "on" else: "off"))
    self.autosave.onChange = proc(s: Control) = self.touch("Auto-save " & $self.autosave.value & " min")
    self.tabSize.onChange = proc(s: Control) = self.touch("Tab width " & $self.tabSize.value)
    for r in [self.startLast, self.startWelcome, self.startEmpty]:
      r.onChange = proc(s: Control) =
        if RadioButton(s).checked: self.touch("Startup: " & s.caption.replace("&", ""))
    self.fontSize.onChange = proc(s: Control) = self.applyFont()
    self.themeCombo.onChange = proc(s: Control) =
      if not self.loading: self.setDark(self.themeCombo.itemIndex == 1)
    self.wrap.onChange = proc(s: Control) =
      if not self.loading and self.sample.wordWrap != self.wrap.checked:
        self.setWrap(self.wrap.checked)
    self.applyBtn.onClick = proc(s: Control) = self.applyNow()
    self.okBtn.onClick = proc(s: Control) =
      self.applyNow()
      self.modified = false
      self.close()
    self.cancelBtn.onClick = proc(s: Control) = self.close()
    self.onCloseQuery = proc(f: Form, canClose: var bool) =
      if self.modified and
         messageDlg("Discard the unsaved changes?", mtConfirmation, {mbYes, mbNo},
                    mbNo, "Preferences") != mrYes:
        canClose = false
    # the Advanced page's buttons
    self.askBtn.onClick = proc(s: Control) =
      var v = self.nameEdit.text
      if inputQuery("Name", "Your name:", v):
        self.nameEdit.text = v
    self.warnBtn.onClick = proc(s: Control) =
      if messageDlg("Reset every option on this page?", mtWarning, {mbYes, mbNo}) == mrYes:
        self.say "Options reset"
    self.openBtn.onClick = proc(s: Control) = self.openSettings()
    self.saveBtn.onClick = proc(s: Control) = self.saveSettingsAs()
    self.folderBtn.onClick = proc(s: Control) =
      let d = newSelectFolderDialog(self)
      d.title = "Choose the backup folder"
      if d.executeModal() and d.fileName.len > 0: self.say "Folder: " & d.fileName

  init:
    self.buildMenus()
    self.buildContent()
    self.wire()
    self.cats.itemIndex = 0
    self.refreshStatus()

proc findByName(c: Control, name: string): Control =
  if c.name == name: return c
  if c of Container:
    for ch in Container(c).children:
      result = findByName(ch, name)
      if result != nil: return

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  let f = newSettingsForm()
  if getEnv("NIMVCL_DARK") == "1": f.setDark(true)
  if shot.len > 0:
    f.show()
    f.syncMetrics()
    let size = getEnv("NIMVCL_SIZE")          # e.g. 640x480
    if size.len > 0:
      let wh = size.split('x')
      # like a tiling window manager: the window gets its size from outside
      f.win.setLogicalSize(parseFloat(wh[0]).float32, parseFloat(wh[1]).float32)
      f.syncMetrics()
    let page = getEnv("NIMVCL_PAGE")
    if page.len > 0: f.cats.itemIndex = parseInt(page)
    let focusName = getEnv("NIMVCL_FOCUS")
    if focusName.len > 0:
      let c = findByName(f, focusName)
      if c != nil: setFocus(c)
    if getEnv("NIMVCL_ALT") == "1": f.ui.setAlt(true)
    discard f.paintIfDirty()
    let openMenu = getEnv("NIMVCL_OPEN_MENU")
    if openMenu.len > 0:
      for i in 0 ..< f.menu.items.count:
        if parseMnemonic(f.menu.items[i].caption).text.toLowerAscii == openMenu.toLowerAscii:
          f.menu.openDropdown(i, selectFirst = true)
    let combo = getEnv("NIMVCL_COMBO")
    if combo.len > 0:
      case combo
      of "language": f.language.dropDown()
      of "country": f.country.dropDown()
      of "themeCombo": f.themeCombo.dropDown()
      else: discard
    Application.paintForms()
    if not screenshotWithPopups(f, shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    Application.run(f)

when isMainModule:
  main()
