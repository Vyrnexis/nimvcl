# Phase 2 demo: Form, layout, input routing, timer, modal form, theme switch.
# No stock widgets yet (phase 3), so Box / Readout / Pad are defined here.
#
# Keys: Tab / Shift+Tab move focus, Space or Enter toggles the focused box,
#       D toggles dark/light, M opens a modal dialog, Esc closes the window.
#
# Env:
#   NIMVCL_SCREENSHOT   lay out, render one frame to this BMP and exit
#   NIMVCL_SCALE        force the display scale (headless testing of 1.5x etc.)
#   NIMVCL_DARK=1       start with the dark theme
#
# Build: nim c --outdir:build examples/core_demo.nim

import std/[os, strutils, times]
import nimvcl

type
  Panel = ref object of Container
    ## Surface-coloured container with an optional bottom/top edge line.
    edge: Align            # which edge gets a border line (alNone: none)

  Box = ref object of Container
    ## A focusable toggle: hover colour, pressed state, focus ring.
    label: string
    on, down: bool

  Readout = ref object of Control
    ## One line of text.
    bold: bool

  Pad = ref object of Container
    ## Drawing area: drag with the left button (mouse capture keeps strokes
    ## going outside the pad); shows the pointer position.
    strokes: seq[seq[PointF]]
    mouse: PointF
    inside: bool

var
  status: Readout
  hoverName = "-"
  lastEvent = "-"
  clock = ""

proc refreshStatus() =
  status.caption = "hover: " & hoverName & "   |   last: " & lastEvent &
                   "   |   " & clock

proc noteHover(c: Control) =
  c.onMouseEnter = proc(s: Control) =
    hoverName = s.name
    refreshStatus()
  c.onMouseLeave = proc(s: Control) =
    if hoverName == s.name:
      hoverName = "-"
      refreshStatus()

# ------------------------------------------------------------------ Panel

method paint(p: Panel, c: Canvas) =
  let t = p.theme
  c.fillRect(p.clientRect, t.surface)
  case p.edge
  of alBottom: c.fillRect(rectF(0, p.height - 1, p.width, 1), t.border)
  of alTop: c.fillRect(rectF(0, 0, p.width, 1), t.border)
  of alRight: c.fillRect(rectF(p.width - 1, 0, 1, p.height), t.border)
  else: discard

proc newPanel(parent: Container, name: string, align: Align, size: float32,
              edge = alNone): Panel =
  result = Panel(edge: edge)
  result.initContainer()
  result.name = name
  result.align = align
  if align in {alTop, alBottom}: result.height = size
  else: result.width = size
  parent.insertControl result
  result.noteHover

# -------------------------------------------------------------------- Box

method canFocus(b: Box): bool = b.isVisible and b.isEnabled

method paint(b: Box, c: Canvas) =
  let t = b.theme
  let r = b.clientRect.inflate(-2)
  var fill = if b.on: t.accent else: t.surfaceAlt
  if not b.on and b.down: fill = t.pressed
  elif not b.on and b.name == hoverName: fill = t.hover
  c.fillRoundRect(r, t.radius, fill)
  c.strokeRoundRect(r, t.radius, t.borderStrong, t.borderWidth)
  if b.focused:
    c.strokeRoundRect(b.clientRect, t.radius + 1, t.focusRing, t.focusRingWidth)
  c.textRect(b.label, b.font, r.inflate(-6), (if b.on: t.accentText else: t.text),
             taCenter, vaCenter)

method doMouseEnter(b: Box) =
  procCall doMouseEnter(Container(b))
  b.invalidate()
method doMouseLeave(b: Box) =
  procCall doMouseLeave(Container(b))
  b.invalidate()
method doMouseDown(b: Box, btn: MouseButton, s: ShiftState, x, y: float32) =
  b.down = true
  b.invalidate()
  procCall doMouseDown(Container(b), btn, s, x, y)
method doMouseUp(b: Box, btn: MouseButton, s: ShiftState, x, y: float32) =
  b.down = false
  b.invalidate()
  procCall doMouseUp(Container(b), btn, s, x, y)
method doClick(b: Box) =
  b.on = not b.on
  b.invalidate()
  lastEvent = "click " & b.name & (if b.on: " (on)" else: " (off)")
  refreshStatus()
  procCall doClick(Container(b))
method doKeyDown(b: Box, key: var Key, s: ShiftState) =
  procCall doKeyDown(Container(b), key, s)
  if key == keySpace or key == keyEnter:
    key = Key(0)
    b.doClick()
method doEnter(b: Box) =
  procCall doEnter(Container(b))
  lastEvent = "focus " & b.name
  refreshStatus()

proc newBox(parent: Container, name, label: string, x, y, w, h: float32): Box =
  result = Box(label: label)
  result.initContainer()
  result.name = name
  result.setBounds(x, y, w, h)
  result.tabStop = true
  result.cursor = crHand
  parent.insertControl result
  result.noteHover

# ---------------------------------------------------------------- Readout

method paint(r: Readout, c: Canvas) =
  let t = r.theme
  let f = if r.bold: r.font.bold else: r.font
  c.textRect(r.caption, f, r.clientRect, t.text, taLeft, vaCenter)

proc newReadout(parent: Container, name, text: string, align: Align,
                bold = false): Readout =
  result = Readout(bold: bold)
  result.initControl()
  result.name = name
  result.caption = text
  result.align = align
  parent.insertControl result

# -------------------------------------------------------------------- Pad

method paint(p: Pad, c: Canvas) =
  let t = p.theme
  c.fillRoundRect(p.clientRect, t.radius, t.surface)
  c.strokeRoundRect(p.clientRect, t.radius, t.border, t.borderWidth)
  c.pushClip(p.clientRect.inflate(-1))
  for s in p.strokes:
    for i in 1 ..< s.len:
      c.line(s[i - 1].x, s[i - 1].y, s[i].x, s[i].y, t.accent, 2)
  c.popClip()
  let msg = if p.inside:
              "pad  x=" & $int(p.mouse.x) & "  y=" & $int(p.mouse.y)
            else: "pad  (drag to draw, strokes follow the pointer outside too)"
  c.textRect(msg, p.font, rectF(10, 6, p.width - 20, 20), t.textMuted)

method doMouseDown(p: Pad, btn: MouseButton, s: ShiftState, x, y: float32) =
  procCall doMouseDown(Container(p), btn, s, x, y)
  if btn == mbLeft:
    p.strokes.add @[pointF(x, y)]
    p.invalidate()
method doMouseMove(p: Pad, s: ShiftState, x, y: float32) =
  procCall doMouseMove(Container(p), s, x, y)
  p.mouse = pointF(x, y)
  p.inside = true
  if ssLeft in s and p.strokes.len > 0: p.strokes[^1].add pointF(x, y)
  p.invalidate()
method doMouseLeave(p: Pad) =
  procCall doMouseLeave(Container(p))
  p.inside = false
  p.invalidate()

# --------------------------------------------------------------- dialogs

proc runDialog(owner: Form) =
  let d = newForm(nil, 340, 190)
  d.caption = "Dialog"
  d.position = poMainFormCenter
  d.borderStyle = bsSingle
  d.keyPreview = true
  discard d.newBox("d1", "Option A", 16, 16, 140, 40)
  discard d.newBox("d2", "Option B", 180, 16, 140, 40)
  let ok = d.newBox("ok", "OK", 120, 130, 90, 40)
  let cancel = d.newBox("cancel", "Cancel", 230, 130, 90, 40)
  ok.onClick = proc(s: Control) = d.modalResult = mrOk
  cancel.onClick = proc(s: Control) = d.modalResult = mrCancel
  d.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
    if k == keyEscape: d.modalResult = mrCancel
  let r = d.showModal()
  lastEvent = "dialog result: " & $r
  refreshStatus()

# ------------------------------------------------------------------ main

proc buildMain(): Form =
  let f = newForm(nil, 900, 600)
  f.caption = "nimvcl core demo"
  f.keyPreview = true

  let header = f.newPanel("header", alTop, 48, alBottom)
  let title = header.newReadout("title", "nimvcl core demo", alClient, bold = true)
  title.margins = spacing(16, 0, 0, 0)
  title.font = font(size = 18, style = {fsBold})

  let bar = f.newPanel("status", alBottom, 28, alTop)
  status = bar.newReadout("statusText", "", alClient)
  status.margins = spacing(12, 0, 0, 0)

  let side = f.newPanel("sidebar", alLeft, 180, alRight)
  side.padding = spacing(8)
  for i in 1 .. 4:
    let b = side.newBox("side" & $i, "Sidebar " & $i, 0, 0, 100, 40)
    b.align = alTop
    b.margins = spacing(0, 0, 0, 8)

  let area = newContainer()
  area.name = "area"
  area.align = alClient
  f.insertControl area

  # form 900x600 -> area 720x524 at first layout
  let anch = area.newBox("anchored", "Anchored R+B", 590, 470, 120, 44)
  anch.anchors = {akRight, akBottom}
  let wide = area.newBox("stretch", "Stretched L+R", 16, 16, 688, 44)
  wide.anchors = {akLeft, akRight, akTop}
  let pad = Pad()
  pad.initContainer()
  pad.name = "pad"
  pad.setBounds(16, 76, 688, 380)
  pad.anchors = {akLeft, akTop, akRight, akBottom}
  pad.cursor = crCross
  area.insertControl pad
  pad.noteHover

  let clk = newTimer(f, 1000)
  clk.onTimer = proc(t: Timer) =
    clock = now().format("HH:mm:ss")
    refreshStatus()
  clock = now().format("HH:mm:ss")
  clk.enabled = true
  refreshStatus()

  f.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
    if sh * {ssCtrl, ssAlt} != {}: return
    if k == 'd'.key:
      Application.theme = if currentTheme().name == "dark": themeLight() else: themeDark()
      lastEvent = "theme " & currentTheme().name
      refreshStatus()
      k = Key(0)
    elif k == 'm'.key:
      k = Key(0)
      runDialog(f)
    elif k == keyEscape:
      k = Key(0)
      f.close()
  f

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let f = buildMain()
  if shot.len > 0:
    if not f.screenshot(shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    Application.run(f)

main()
