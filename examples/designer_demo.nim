# Design mode demo: a palette on the left, a form being designed in the centre
# (a Panel with a FormDesigner attached) and a plain property list on the right.
#
#   * pick a class in the palette, then click or drag on the form to create it
#   * click selects, Shift+click adds, drag on the empty form draws a rubber band
#   * drag moves (grid snapping, guide lines; Alt turns snapping off), drop on
#     a panel or group box reparents
#   * handles resize; arrows move, Shift+arrows resize, Ctrl for grid steps
#   * Delete deletes, Ctrl+Z / Ctrl+Y undo and redo, Tab walks the siblings
#
# Screenshot mode (headless):
#   SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software \
#     nim c -r examples/designer_demo.nim --shots build/designer_shots
#
# Build: nim c --outdir:build examples/designer_demo.nim

import std/os
import nimvcl

const Classes = ["Button", "Edit", "Label", "CheckBox", "Panel", "GroupBox",
                 "ListBox", "ProgressBar", "TrackBar", "Memo"]

type
  Demo = ref object of Form
    palette: ListBox
    surface: Panel
    designer: FormDesigner
    status: StatusBar
    props: array[5, Label]
    gridBox, linesBox, darkBox: CheckBox
    centre: Panel

proc createControl(cls: string): Control =
  case cls
  of "Button": newButton(nil, "Button")
  of "Edit": newEdit(nil, "Edit")
  of "Label": newLabel(nil, "Label")
  of "CheckBox": newCheckBox(nil, "CheckBox")
  of "Panel": newPanel(nil, "")
  of "GroupBox": newGroupBox(nil, "GroupBox")
  of "ListBox": newListBox(nil)
  of "ProgressBar":
    let p = newProgressBar(nil)
    p.max = 100
    p.position = 40
    p
  of "TrackBar": newTrackBar(nil)
  of "Memo": newMemo(nil, "Memo")
  else: nil

proc classOf(c: Control): string =
  if c of Button: "Button"
  elif c of Edit: "Edit"
  elif c of Label: "Label"
  elif c of CheckBox: "CheckBox"
  elif c of GroupBox: "GroupBox"
  elif c of Panel: "Panel"
  elif c of ListBox: "ListBox"
  elif c of ProgressBar: "ProgressBar"
  elif c of TrackBar: "TrackBar"
  elif c of Memo: "Memo"
  else: "Control"

proc describe(c: Control): string =
  if c == nil: "" else: c.name & ": " & $int(c.left) & ", " & $int(c.top) & ", " &
                        $int(c.width) & " x " & $int(c.height)

proc updateProps(d: Demo) =
  let sel = d.designer.selection
  let c = d.designer.primary
  const names = ["Name", "Left", "Top", "Width", "Height"]
  for i in 0 .. 4:
    var v = ""
    if c != nil:
      v = case i
          of 0: (if c == Control(d.surface): "(form)" else: c.name)
          of 1: $int(c.left)
          of 2: $int(c.top)
          of 3: $int(c.width)
          else: $int(c.height)
    d.props[i].caption = names[i] & ":  " & v
  d.status.simpleText =
    if sel.len == 0: "Nothing selected"
    elif sel.len == 1: describe(sel[0]) & "     (" & $d.designer.nonVisuals.len & " non-visual)"
    else: $sel.len & " controls selected"

proc setDark(d: Demo, on: bool) =
  Application.theme = if on: themeDark() else: themeLight()
  d.centre.color = d.theme.window
  d.darkBox.checked = on

proc newDemo(): Demo =
  let d = Demo()
  d.initForm()
  d.caption = "nimvcl designer demo"
  d.setBounds(0, 0, 940, 600)

  d.status = newStatusBar(d, "")

  let left = newPanel(d, "", 0, 0, 170, 0)
  left.align = alLeft
  left.padding = spacing(10)
  let pal = newLabel(left, "Palette", 10, 10)
  pal.font = font(pal.font.family, pal.font.size, {fsBold})
  d.palette = newListBox(left, 10, 36, 150, 290)
  for c in Classes: d.palette.add c
  d.gridBox = newCheckBox(left, "Grid", true, 10, 330)
  d.linesBox = newCheckBox(left, "Snap lines", true, 10, 358)
  d.darkBox = newCheckBox(left, "Dark theme", false, 10, 386)

  let right = newPanel(d, "", 0, 0, 220, 0)
  right.align = alRight
  let ph = newLabel(right, "Selection", 14, 10)
  ph.font = font(ph.font.family, ph.font.size, {fsBold})
  for i in 0 .. 4: d.props[i] = newLabel(right, "", 14, float32(40 + i * 26))
  newLabel(right, "Delete: remove     Ctrl+Z: undo", 14, 200)
  newLabel(right, "Arrows: nudge     Tab: next", 14, 224)

  let centre = newPanel(d, "", 0, 0, 0, 0)
  centre.align = alClient
  centre.color = d.theme.window
  d.centre = centre
  d.surface = newPanel(centre, "", 24, 24, 520, 440)
  d.surface.borderStyle = pbSingle

  # the form being designed
  let s = d.surface
  newLabel(s, "Name:", 24, 28)
  newEdit(s, "Edit1", 80, 24, 160, 26)
  newButton(s, "OK", 280, 24, 90, 28)
  newButton(s, "Cancel", 380, 24, 90, 28)
  let box = newGroupBox(s, "Options", 24, 80, 220, 140)
  newCheckBox(box, "Enabled", true, 12, 30)
  newCheckBox(box, "Visible", false, 12, 58)
  let pan = newPanel(s, "", 272, 96, 200, 120)
  pan.borderStyle = pbRaised
  newButton(pan, "Inside", 16, 40, 100, 28)
  let list = newListBox(s, 24, 248, 220, 120)
  list.add "alpha"
  list.add "beta"
  list.add "gamma"
  newProgressBar(s, 272, 248, 200, 18).max = 100
  newTrackBar(s, 272, 288, 200, 32)
  newButton(s, "Close", 380, 392, 90, 28)

  # names: Button1, Edit1, ... as the designer would hand out
  var counts: seq[(string, int)]
  proc nameAll(c: Container) =
    for ch in c.children:
      let cls = classOf(ch)
      var n = 1
      for (k, v) in counts.mitems:
        if k == cls:
          inc v
          n = v
      if n == 1: counts.add (cls, 1)
      ch.name = cls & $n
      if ch of Container and not (ch of ListBox): nameAll(Container(ch))
  nameAll(s)

  let fd = newFormDesigner(s, attachNow = false)
  d.designer = fd
  let timer = newComponent(s)
  timer.name = "Timer1"
  fd.addNonVisual(timer, 40, 380, "Timer")
  let images = newComponent(s)
  images.name = "ImageList1"
  fd.addNonVisual(images, 120, 380, "ImageList")
  fd.createControl = createControl
  fd.onSelectionChanged = proc(f: FormDesigner, sel: seq[Control]) = d.updateProps()
  fd.onModified = proc(f: FormDesigner) = d.updateProps()
  fd.onCreated = proc(f: FormDesigner, c: Control) =
    d.palette.itemIndex = -1
  fd.onDoubleClick = proc(f: FormDesigner, c: Control) =
    d.status.simpleText = "Double click on " & c.name & ": the IDE would add its default handler"
  d.palette.onChange = proc(sender: Control) =
    let i = d.palette.itemIndex
    if i >= 0: fd.beginCreate Classes[i]
  d.gridBox.onClick = proc(sender: Control) = fd.showGrid = d.gridBox.checked
  d.linesBox.onClick = proc(sender: Control) = fd.snapLines = d.linesBox.checked
  d.darkBox.onClick = proc(sender: Control) = d.setDark(d.darkBox.checked)
  d

proc attach(d: Demo) =
  d.designer.attach()
  d.designer.select(d.surface)
  d.updateProps()

# ------------------------------------------------------------ screenshots

proc ev(f: Form, kind: EventKind, x, y: float32, shift: ShiftState = {},
        button = mbLeft, clicks = 1) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))

proc shoot(f: Form, dir, name: string) =
  discard f.paintIfDirty()
  if not f.screenshot(dir / (name & ".png")): quit "screenshot failed for " & name
  echo "wrote ", dir / (name & ".png")

proc center(c: Control): PointF =
  pointF(c.formOrigin.x + c.width / 2, c.formOrigin.y + c.height / 2)

proc byName(d: Demo, name: string): Control =
  proc find(c: Container): Control =
    for ch in c.children:
      if ch.name == name: return ch
      if ch of Container:
        let r = find(Container(ch))
        if r != nil: return r
  find(d.surface)

proc shots(dir: string) =
  createDir dir
  Application.init()
  let d = newDemo()
  d.show()
  d.syncMetrics()
  d.attach()
  d.shoot(dir, "0-initial")

  let ok = d.byName("Button1")
  let cancel = d.byName("Button2")
  let c1 = ok.center
  d.ev(ekMouseDown, c1.x, c1.y)
  d.ev(ekMouseUp, c1.x, c1.y)
  d.shoot(dir, "1-single")

  let c2 = cancel.center
  d.ev(ekMouseDown, c2.x, c2.y, {ssShift})
  d.ev(ekMouseUp, c2.x, c2.y, {ssShift})
  d.shoot(dir, "2-multi")

  # rubber band over the list box and the progress bar area
  let so = d.surface.formOrigin
  d.ev(ekMouseDown, so.x + 5, so.y + 232)
  d.ev(ekMouseMove, so.x + 150, so.y + 300, {ssLeft})
  d.ev(ekMouseMove, so.x + 330, so.y + 330, {ssLeft})
  d.shoot(dir, "3-rubber-band")
  d.ev(ekMouseUp, so.x + 330, so.y + 330)

  # a drag with guide lines: Close button towards the OK button's right edge
  let close = d.byName("Button4")
  let cc = close.center
  d.ev(ekMouseDown, cc.x, cc.y)
  d.ev(ekMouseMove, cc.x - 1, cc.y - 50, {ssLeft})
  d.ev(ekMouseMove, cc.x - 2, cc.y - 120, {ssLeft})
  d.ev(ekMouseMove, cc.x - 3, cc.y - 170, {ssLeft})
  d.shoot(dir, "4-snap-lines")
  let pc = d.byName("Panel1").center
  d.ev(ekMouseMove, pc.x, pc.y + 20, {ssLeft})
  d.shoot(dir, "4b-drop-target")
  d.ev(ekMouseUp, pc.x, pc.y + 20)

  # creating a control: pick Edit in the palette, drag a rectangle
  d.palette.itemIndex = 1
  d.ev(ekMouseMove, so.x + 290, so.y + 340)
  d.ev(ekMouseDown, so.x + 290, so.y + 340)
  d.ev(ekMouseMove, so.x + 380, so.y + 360, {ssLeft})
  d.ev(ekMouseMove, so.x + 450, so.y + 372, {ssLeft})
  d.shoot(dir, "5-creating")
  d.ev(ekMouseUp, so.x + 450, so.y + 372)
  d.shoot(dir, "5b-created")

  d.setDark(true)
  let e = d.byName("Edit1")
  d.ev(ekMouseDown, e.center.x, e.center.y)
  d.ev(ekMouseUp, e.center.x, e.center.y)
  d.ev(ekMouseDown, c1.x, c1.y, {ssShift})
  d.ev(ekMouseUp, c1.x, c1.y, {ssShift})
  d.shoot(dir, "6-dark")
  Application.shutdown()

proc main() =
  let args = commandLineParams()
  if args.len >= 1 and args[0] == "--shots":
    shots(if args.len >= 2: args[1] else: "build/designer_shots")
  else:
    Application.init()
    let d = newDemo()
    d.show()
    d.attach()
    Application.run(d)

main()
