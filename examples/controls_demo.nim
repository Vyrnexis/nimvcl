# Phase 3 demo: every stock control (Edit comes with its own demo).
#
# Keys: Tab / Shift+Tab move focus, Space / Enter activate, arrows move inside
#       a radio group, Enter = default button, Esc = cancel button (closes).
#       D toggles dark/light.
#
# Env:
#   NIMVCL_SCREENSHOT   lay out, render one frame to this BMP and exit
#   NIMVCL_SCALE        force the display scale (headless testing of 1.5x etc.)
#   NIMVCL_DARK=1       start with the dark theme
#   NIMVCL_FOCUS=name   (screenshot) focus the control with this name
#   NIMVCL_HOVER=name   (screenshot) put the mouse over this control
#   NIMVCL_PRESS=1      (screenshot) with NIMVCL_HOVER: hold the left button
#
# Build: nim c --outdir:build examples/controls_demo.nim

import std/[os, strutils]
import nimvcl

var status: Label

proc say(s: string) =
  if status != nil: status.caption = s

proc makeImage(): Image =
  ## A small gradient with a diagonal, 48x32.
  result = newImage(48, 32)
  for y in 0 ..< 32:
    for x in 0 ..< 48:
      var c = rgb(40 + x * 4, 110 + y * 3, 220 - x * 2)
      if abs(x * 2 div 3 - y) < 2: c = rgb(255, 255, 255)
      result.setPixel(x, y, c)

proc buildMain(): Form =
  let f = newForm(nil, 800, 640)
  f.caption = "nimvcl controls demo"
  f.keyPreview = false

  # --- status line
  let bar = newPanel(f)
  bar.name = "bar"
  bar.align = alBottom
  bar.height = 32
  bar.borderStyle = pbNone
  status = newLabel(bar, "ready", 12, 0)
  status.name = "status"
  status.autoSize = false
  status.align = alClient
  status.layout = vaCenter
  status.margins = spacing(12, 0, 0, 0)
  let sep = newBevel(f, bsTopLine)
  sep.align = alBottom
  sep.height = 1

  let title = newLabel(f, "Stock controls")
  title.name = "title"
  title.font = font(size = 20, style = {fsBold})
  title.top = 0

  # --- buttons
  let gb = newGroupBox(f, "Buttons", 0, 44, 240, 190)
  gb.name = "gbButtons"
  let ok = newButton(gb, "OK", 16, 34, 100)
  ok.name = "ok"
  ok.isDefault = true
  let cancel = newButton(gb, "Cancel", 124, 34, 100)
  cancel.name = "cancel"
  cancel.isCancel = true
  let flat = newButton(gb, "Flat", 16, 74, 100)
  flat.name = "flat"
  flat.flat = true
  let dis = newButton(gb, "Disabled", 124, 74, 100)
  dis.name = "disabled"
  dis.enabled = false
  let auto = newButton(gb, "Auto-sized button", 16, 114)
  auto.name = "auto"
  auto.autoSize = true
  let closeBtn = newButton(gb, "Close", 16, 150, 100)
  closeBtn.name = "close"
  closeBtn.modalResult = mrClose
  for b in [ok, cancel, flat, auto, closeBtn]:
    b.onClick = proc(s: Control) = say "clicked " & s.caption
  cancel.onClick = proc(s: Control) =
    say "clicked Cancel"
    f.close()

  # --- check boxes
  let gc = newGroupBox(f, "Check boxes", 256, 44, 240, 190)
  gc.name = "gbChecks"
  let c1 = newCheckBox(gc, "Remember me", true, 16, 34)
  c1.name = "check1"
  let c2 = newCheckBox(gc, "Subscribe to updates", false, 16, 62)
  c2.name = "check2"
  let c3 = newCheckBox(gc, "Tri-state (grayed)", false, 16, 90)
  c3.name = "check3"
  c3.allowGrayed = true
  c3.state = cbGrayed
  let c4 = newCheckBox(gc, "Disabled, checked", true, 16, 118)
  c4.name = "check4"
  c4.enabled = false
  let c5 = newCheckBox(gc, "Disabled, off", false, 16, 146)
  c5.name = "check5"
  c5.enabled = false
  for c in [c1, c2, c3]:
    c.onChange = proc(s: Control) =
      let cb = CheckBox(s)
      say s.caption & ": " & $cb.state

  # --- radio buttons
  let gr = newGroupBox(f, "Radio buttons", 512, 44, 256, 190)
  gr.name = "gbRadios"
  let r1 = newRadioButton(gr, "Small", false, 16, 34)
  r1.name = "radio1"
  let r2 = newRadioButton(gr, "Medium", true, 16, 62)
  r2.name = "radio2"
  let r3 = newRadioButton(gr, "Large", false, 16, 90)
  r3.name = "radio3"
  let r4 = newRadioButton(gr, "Extra large (disabled)", false, 16, 118)
  r4.name = "radio4"
  r4.enabled = false
  for r in [r1, r2, r3]:
    r.onChange = proc(s: Control) =
      if RadioButton(s).checked: say "size: " & s.caption

  # --- labels
  let gl = newGroupBox(f, "Labels", 0, 250, 240, 180)
  gl.name = "gbLabels"
  let l1 = newLabel(gl, "Left aligned", 16, 34, 208, 20)
  l1.name = "labLeft"
  let l2 = newLabel(gl, "Centered", 16, 58, 208, 20)
  l2.name = "labCenter"
  l2.alignment = taCenter
  let l3 = newLabel(gl, "Right aligned", 16, 82, 208, 20)
  l3.name = "labRight"
  l3.alignment = taRight
  let l4 = newLabel(gl, "A very long caption that does not fit in the label", 16, 106, 208, 20)
  l4.name = "labEllipsis"
  let l5 = newLabel(gl, "Wrapped text flows over lines and keeps its width.",
                    16, 130, 208, 40)
  l5.name = "labWrap"
  l5.wordWrap = true
  l5.autoSize = true
  l5.fontColor = f.theme.textMuted

  # --- panels and bevels
  let gp = newGroupBox(f, "Panels and bevels", 256, 250, 240, 180)
  gp.name = "gbPanels"
  let p1 = newPanel(gp, "Single", 16, 34, 96, 52)
  p1.name = "panelSingle"
  p1.borderStyle = pbSingle
  let p2 = newPanel(gp, "Raised", 128, 34, 96, 52)
  p2.name = "panelRaised"
  p2.borderStyle = pbRaised
  let b1 = newBevel(gp, bsBox, 16, 100, 96, 28)
  b1.name = "bevelBox"
  let b2 = newBevel(gp, bsFrame, 128, 100, 96, 28)
  b2.name = "bevelFrame"
  let b3 = newBevel(gp, bsTopLine, 16, 142, 208, 2)
  b3.name = "bevelLine"

  # --- image
  let gi = newGroupBox(f, "ImageControl", 512, 250, 256, 180)
  gi.name = "gbImages"
  let img = makeImage()
  let i1 = newImageControl(gi, img, 16, 34, 72, 56)
  i1.name = "imgNatural"
  let i2 = newImageControl(gi, img, 96, 34, 72, 56)
  i2.name = "imgStretch"
  i2.stretch = true
  let i3 = newImageControl(gi, img, 176, 34, 64, 56)
  i3.name = "imgProp"
  i3.stretch = true
  i3.proportional = true
  i3.transparent = false
  i3.color = f.theme.surfaceAlt
  let i4 = newImageControl(gi, img, 16, 100, 72, 56)
  i4.name = "imgCenter"
  i4.center = true
  i4.transparent = false
  i4.color = f.theme.surfaceAlt
  let cap = newLabel(gi, "natural / stretch / proportional / centered", 96, 112, 150, 40)
  cap.name = "imgCaption"
  cap.wordWrap = true
  cap.autoSize = true
  cap.fontColor = f.theme.textMuted

  # --- paint box
  let gx = newGroupBox(f, "PaintBox", 0, 446, 768, 100)
  gx.name = "gbPaint"
  let pb = newPaintBox(gx, 16, 30, 736, 66)
  pb.name = "paintbox"
  pb.onPaint = proc(s: Control, c: Canvas) =
    let t = s.theme
    let w = s.width
    let h = s.height
    c.fillRoundRect(s.clientRect, t.radius, t.surfaceAlt)
    for i in 0 ..< 24:
      let x = 8 + float32(i) * (w - 16) / 24
      let bh = 8 + float32((i * 7) mod 11) * (h - 24) / 11
      c.fillRoundRect(rectF(x, h - 8 - bh, (w - 16) / 24 - 4, bh), 2,
                      if i mod 6 == 0: t.accent else: t.borderStrong)
    c.textRect("PaintBox: drawn by onPaint in client coordinates", s.font,
               rectF(10, 4, w - 20, 18), t.textMuted)

  # --- placement of the top-level pieces (alNone, absolute)
  for c in [Control(gb), gc, gr, gl, gp, gi, gx]:
    c.setBounds(c.left + 16, c.top + 20, c.width, c.height)
  title.setBounds(16, 8, title.width, title.height)

  f.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
    if k == 'd'.key and sh * {ssCtrl, ssAlt} == {}:
      Application.theme = if currentTheme().name == "dark": themeLight() else: themeDark()
      k = Key(0)
  f

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
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let f = buildMain()
  if shot.len > 0:
    f.show()
    f.syncMetrics()
    discard f.paintIfDirty()
    let focus = getEnv("NIMVCL_FOCUS")
    if focus.len > 0:
      let c = findByName(f, focus)
      if c != nil: f.activeControl = c
    let hover = getEnv("NIMVCL_HOVER")
    if hover.len > 0:
      let c = findByName(f, hover)
      if c != nil:
        let o = c.clientToForm(pointF(c.width / 2, c.height / 2))
        let s = f.win.scale
        Application.dispatch(PlatformEvent(kind: ekMouseMove, windowId: f.win.id,
                                           x: o.x * s, y: o.y * s))
        if getEnv("NIMVCL_PRESS") == "1":
          Application.dispatch(PlatformEvent(kind: ekMouseDown, windowId: f.win.id,
                                             x: o.x * s, y: o.y * s,
                                             button: mbLeft, clicks: 1))
    if not f.screenshot(shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    Application.run(f)

main()
