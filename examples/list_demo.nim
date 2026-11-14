# Phase 5 demo: ListBox (standard, multi-select, owner-draw, virtual with
# 1,000,000 items) and a ScrollBox full of controls.
#
# Keys: Tab moves focus (the ScrollBox scrolls to the focused control), wheel
#       scrolls (Shift+wheel horizontally), type letters in a list to jump,
#       Shift/Ctrl+click or Shift+arrows in the multi-select list.
#       D toggles dark/light.
#
# Env:
#   NIMVCL_SCREENSHOT   lay out, render one frame to this BMP and exit
#   NIMVCL_SCALE        force the display scale (headless testing of 1.5x etc.)
#   NIMVCL_DARK=1       start with the dark theme
#
# Build: nim c --outdir:build examples/list_demo.nim

import std/[os, strutils]
import nimvcl
import nimvcl/controls/[scrollbar, scrolling, scrollbox, listbox]

var status: Label

const Fruits = ["Apple", "Apricot", "Banana", "Blackberry", "Blueberry",
                "Cherry", "Coconut", "Cranberry", "Date", "Elderberry", "Fig",
                "Grape", "Grapefruit", "Guava", "Kiwi", "Lemon", "Lime",
                "Mango", "Melon", "Nectarine", "Orange", "Papaya", "Peach",
                "Pear", "Pineapple", "Plum", "Pomegranate", "Quince",
                "Raspberry", "Strawberry", "Tangerine", "Watermelon"]

proc say(s: string) =
  if status != nil: status.caption = s

proc caption(f: Form, text: string, x, y: float32) =
  let l = newLabel(f, text, x, y)
  l.font = l.font.bold

proc swatchColor(i: int): Color =
  let h = float32(i * 37 mod 360)
  # cheap HSV-ish palette
  let r = 0.5 + 0.5 * cos((h) * 0.0174533)
  let g = 0.5 + 0.5 * cos((h - 120) * 0.0174533)
  let b = 0.5 + 0.5 * cos((h + 120) * 0.0174533)
  rgb(int(60 + r * 170), int(60 + g * 170), int(60 + b * 170))

proc buildMain(): Form =
  let f = newForm(nil, 940, 560)
  f.caption = "nimvcl list demo"

  # --- standard
  f.caption("Standard", 16, 12)
  let std = newListBox(f, 16, 34, 210, 230)
  std.name = "std"
  for s in Fruits: std.add s
  std.itemIndex = 3
  std.onChange = proc(s: Control) =
    say "standard: " & ListBox(s)[ListBox(s).itemIndex]

  # --- multi-select
  f.caption("Multi-select", 242, 12)
  let multi = newListBox(f, 242, 34, 210, 230)
  multi.name = "multi"
  multi.multiSelect = true
  for s in Fruits: multi.add s
  multi.setSelected(1, true)
  multi.setSelected(2, true)
  multi.setSelected(5, true)
  multi.onChange = proc(s: Control) =
    say $ListBox(s).selCount & " selected"

  # --- owner-draw
  f.caption("Owner-draw", 468, 12)
  let od = newListBox(f, 468, 34, 210, 230)
  od.name = "owner"
  od.style = lbOwnerDraw
  od.itemHeight = 28
  for i in 0 ..< 60: od.add "Colour #" & $(i + 1)
  od.itemIndex = 2
  od.onDrawItem = proc(s: Control, c: Canvas, i: int, r: RectF, st: ItemStates) =
    let lb = ListBox(s)
    let sw = rectF(r.x + 8, r.y + 5, 28, r.h - 10)
    c.fillRoundRect(sw, 4, swatchColor(i))
    c.strokeRoundRect(sw, 4, lb.theme.borderStrong, 1)
    lb.drawItemText(c, rectF(r.x + 36, r.y, r.w - 36, r.h), lb[i], st)

  # --- virtual
  f.caption("Virtual: 1,000,000 items", 694, 12)
  let virt = newListBox(f, 694, 34, 230, 230)
  virt.name = "virtual"
  virt.itemHeight = 24
  virt.onData = proc(s: Control, i: int): string = "Item number " & $(i + 1)
  virt.count = 1_000_000
  virt.itemIndex = 499_999
  virt.onChange = proc(s: Control) =
    say "virtual: row " & $ListBox(s).itemIndex

  # --- scroll box
  f.caption("ScrollBox (Tab scrolls to the focused control)", 16, 280)
  let sb = newScrollBox(f, 16, 302, 520, 220)
  sb.name = "box"
  for i in 0 ..< 14:
    let y = 8 + float32(i) * 34
    discard newLabel(sb, "Option " & $(i + 1), 8, y + 4)
    discard newCheckBox(sb, "Enable feature " & $(i + 1), i mod 3 == 0, 110, y + 3)
    let b = newButton(sb, "Run " & $(i + 1), 300, y, 90, 28)
    b.onClick = proc(s: Control) = say s.caption & " clicked"
    if i mod 2 == 0:
      discard newEdit(sb, "text " & $(i + 1), 400, y, 220, 28)

  status = newLabel(f, "", 560, 310)
  status.autoSize = false
  status.setBounds(560, 310, 360, 24)
  status.caption = "Select something"

  f.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
    if k == 'd'.key and sh * {ssCtrl, ssAlt} == {} and
       not (f.activeControl of ListBox):
      Application.theme = if currentTheme().name == "dark": themeLight() else: themeDark()
      k = Key(0)
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
    # hover a row of the standard list and focus the multi-select one
    for c in f.children:
      if c.name == "multi": f.activeControl = c
    if not f.screenshot(shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    Application.run(f)

main()
