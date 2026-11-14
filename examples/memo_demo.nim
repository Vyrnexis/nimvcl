# Phase 5 demo: Memo (multi-line edit with word wrap) and ComboBox (editable
# csDropDown with autocomplete, and csDropDownList).
#
# Keys: type in the memo (Tab inserts a tab when "Tab key" is checked), the
#       wrap checkbox toggles word wrap; in the combos Alt+Down / F4 open the
#       list, Up/Down change the selection, type to autocomplete.
#
# Env:
#   NIMVCL_SCREENSHOT   lay out, render one frame to this BMP and exit
#   NIMVCL_SCALE        force the display scale (headless testing of 1.5x etc.)
#   NIMVCL_DARK=1       start with the dark theme
#   NIMVCL_OPEN_COMBO=1 with NIMVCL_SCREENSHOT: render with the editable combo's
#                       drop-down open (popup.screenshotWithPopups)
#
# Build: nim c --outdir:build examples/memo_demo.nim

import std/[os, strutils]
import nimvcl
import nimvcl/core/popup
import nimvcl/controls/[memo, combobox]

const Sample = """Memo: a multi-line text editor.

It wraps long lines at the width of the control when "Word wrap" is on, and scrolls horizontally when it is off. The caret keeps its pixel column on Up and Down, Home and End work on the visual line, and Ctrl+Z / Ctrl+Y undo and redo whole words.

	A line that starts with a tab.
Unicode works too: héllo wörld, Привет мир, γειά σου, ñandú.

Double click selects a word, triple click a line; drag outside the control to scroll while selecting."""

const Cities = ["Amsterdam", "Athens", "Berlin", "Bern", "Brussels", "Budapest",
                "Cairo", "Copenhagen", "Dublin", "Edinburgh", "Helsinki",
                "Istanbul", "Lisbon", "London", "Madrid", "Oslo", "Paris",
                "Prague", "Rome", "Stockholm", "Vienna", "Warsaw", "Zurich"]

const Fonts = ["Sans", "Sans Bold", "Serif", "Mono", "Mono Bold", "Condensed"]

var
  status: Label
  cityCombo: ComboBox

proc say(s: string) =
  if status != nil: status.caption = s

proc heading(f: Form, text: string, x, y: float32) =
  let l = newLabel(f, text, x, y)
  l.font = l.font.bold

proc buildMain(): Form =
  let f = newForm(nil, 760, 420)
  f.caption = "nimvcl memo demo"

  f.heading("Memo", 16, 12)
  let m = newMemo(f, Sample, 16, 34, 440, 300)
  m.name = "memo"
  m.wordWrap = true
  m.placeholder = "Type something..."
  m.onChange = proc(s: Control) =
    say $Memo(s).lines.count & " lines, caret " & $(Memo(s).caretPos.line + 1) &
        ":" & $(Memo(s).caretPos.col + 1)

  let wrap = newCheckBox(f, "Word wrap", true, 16, 344)
  wrap.onChange = proc(s: Control) = m.wordWrap = CheckBox(s).checked
  let tabs = newCheckBox(f, "Tab key inserts a tab", false, 130, 344)
  tabs.onChange = proc(s: Control) = m.wantTabs = CheckBox(s).checked
  let ro = newCheckBox(f, "Read only", false, 330, 344)
  ro.onChange = proc(s: Control) = m.readOnly = CheckBox(s).checked
  let dark = newCheckBox(f, "Dark theme", currentTheme().name == "dark", 16, 372)
  dark.onChange = proc(s: Control) =
    Application.theme = if CheckBox(s).checked: themeDark() else: themeLight()

  f.heading("City (csDropDown, autocomplete)", 484, 12)
  cityCombo = newComboBox(f, csDropDown, 484, 34, 250)
  cityCombo.name = "city"
  for s in Cities: cityCombo.add s
  cityCombo.dropDownCount = 8
  cityCombo.onChange = proc(s: Control) = say "city text: " & ComboBox(s).text
  cityCombo.onSelect = proc(s: Control) = say "city picked: " & ComboBox(s).text

  f.heading("Font (csDropDownList)", 484, 84)
  let fonts = newComboBox(f, csDropDownList, 484, 106, 250)
  fonts.name = "font"
  for s in Fonts: fonts.add s
  fonts.itemIndex = 0
  fonts.onSelect = proc(s: Control) =
    let c = ComboBox(s)
    m.font = case c.itemIndex
      of 1: font("sans", 14).bold
      of 2: font("serif", 14)
      of 3: font("mono", 14)
      of 4: font("mono", 14).bold
      of 5: font("sans", 12)
      else: font("sans", 14)
    say "font: " & c.text

  f.heading("Disabled", 484, 156)
  let dis = newComboBox(f, csDropDownList, 484, 178, 250)
  dis.add "Disabled"
  dis.itemIndex = 0
  dis.enabled = false

  status = newLabel(f, "", 16, 396)
  status.autoSize = false
  status.setBounds(16, 396, 720, 20)
  status.caption = "Ready"
  f

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
    for c in f.children:
      if c.name == "memo": f.activeControl = c
    var ok: bool
    if getEnv("NIMVCL_OPEN_COMBO") == "1":
      cityCombo.text = "B"
      cityCombo.itemIndex = 3
      cityCombo.dropDown()
      ok = screenshotWithPopups(f, shot)
    else:
      ok = f.screenshot(shot)
    if not ok: quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    Application.run(f)

main()
