# Object inspector demo: a small form on the left, the ObjectInspector on the
# right. Click a control to inspect it; edits apply to it live. "Save .nfm"
# writes the form to build/inspector_demo.nfm, "Reload from .nfm" rebuilds the
# form from that file.
#
#   * Properties tab: grouped by category (or A-Z), bold = not the default;
#     font, margins and anchors expand into their parts
#   * Events tab: double click an empty row to create a handler name
#   * Shift+click on the form adds a control to the selection (the inspector
#     then shows the properties they share)
#
# Screenshot mode (headless):
#   SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software \
#     nim c -r examples/inspector_demo.nim --shots build/inspector_shots
#
# Build: nim c --outdir:build examples/inspector_demo.nim

import std/os
import nimvcl
import nimvcl/dsl/nfm
import nimvcl/controls/inspector

const
  SaveFile = "build/inspector_demo.nfm"
  SampleNfm = """object sample: Panel
  align = alClient
  padding.left = 12
  padding.top = 12
  padding.right = 12
  padding.bottom = 12
  object title: Label
    left = 16
    top = 14
    width = 260
    caption = 'Sign in'
    font.size = 22
    font.style = [fsBold]
  end
  object userLabel: Label
    left = 16
    top = 64
    caption = 'User name'
    focusControl = userEdit
  end
  object userEdit: Edit
    left = 16
    top = 86
    width = 260
    anchors = [akLeft, akTop, akRight]
    placeholder = 'you@example.com'
  end
  object roleLabel: Label
    left = 16
    top = 124
    caption = 'Role'
  end
  object roleCombo: ComboBox
    left = 16
    top = 146
    width = 260
    items = (
      'Viewer'
      'Editor'
      'Admin'
    )
    itemIndex = 1
  end
  object remember: CheckBox
    left = 16
    top = 188
    width = 200
    caption = 'Remember me'
    state = cbChecked
    onChange = rememberChange
  end
  object volume: TrackBar
    left = 16
    top = 224
    width = 260
    max = 100
    position = 40
  end
  object okButton: Button
    left = 16
    top = 268
    width = 120
    caption = 'OK'
    isDefault = true
    color = #2563eb
    onClick = okClick
  end
  object cancelButton: Button
    left = 150
    top = 268
    width = 120
    caption = 'Cancel'
    isCancel = true
  end
end
"""

type
  Demo = ref object of Form
    stage: Panel
    sample: Panel
    ins: ObjectInspector
    status: Label
    selection: seq[Control]

proc walkControls(c: Control, found: var seq[Control]) =
  found.add c
  if c of Container:
    for k in kidsOf(Obj(c)):
      walkControls(Control(k), found)

proc select(d: Demo, c: Control, add = false) =
  if add and c notin d.selection:
    d.selection.add c
  elif not add:
    d.selection = @[c]
  var objs: seq[Obj]
  for s in d.selection: objs.add Obj(s)
  d.ins.inspect(objs)

proc hook(d: Demo) =
  ## Clicking a control of the sample selects it.
  var all: seq[Control]
  walkControls(d.sample, all)
  for c in all:
    let ctl = c
    let old = ctl.onMouseDown
    ctl.onMouseDown = proc(s: Control, b: MouseButton, sh: ShiftState, x, y: float32) =
      if old != nil: old(s, b, sh, x, y)
      if b == mbLeft: d.select(ctl, ssShift in sh)

proc buildSample(d: Demo, text: string) =
  if d.sample != nil:
    d.stage.removeControl d.sample
  let o = buildNfm(parseNfm(text, "sample.nfm"), d.stage, newNfmOptions(strict = false))
  d.sample = Panel(o)
  d.stage.insertControl d.sample
  d.selection = @[]
  d.hook()

proc say(d: Demo, s: string) = d.status.caption = s

proc newDemo(): Demo =
  new result
  result.initForm()
  let d = result
  d.caption = "Object inspector"
  d.setBounds(0, 0, 900, 620)
  # buttons on top
  let bar = newPanel(d)
  bar.align = alTop
  bar.height = 44
  bar.padding = spacing(8, 8)
  let saveBtn = newButton(bar, "Save .nfm", 8, 8, 110, 28)
  let loadBtn = newButton(bar, "Reload from .nfm", 126, 8, 150, 28)
  d.status = newLabel(d, "Click a control to inspect it.")
  d.status.align = alBottom
  d.status.margins = spacing(10, 6)
  d.status.muted = true
  # the inspector
  d.ins = newObjectInspector(d)
  d.ins.align = alRight
  d.ins.width = 330
  d.ins.margins = spacing(0, 6, 8, 6)
  d.ins.knownHandlers = @["okClick", "cancelClick", "rememberChange"]
  let sp = newSplitter(d, alRight)
  sp.minSize = 240
  # the stage
  d.stage = newPanel(d)
  d.stage.align = alClient
  d.stage.margins = spacing(8, 6, 0, 6)
  d.buildSample(SampleNfm)
  d.ins.onPropertyChanged = proc(s: Control, t: Obj, prop: string) =
    d.say objectName(t) & "." & prop & " changed"
  d.ins.onCreateHandler = proc(s: Control, t: Obj, event: string): string =
    result = objectName(t) & event[2 .. ^1]
    d.say "created handler " & result
  d.ins.onEditExtra = proc(s: Control, t: Obj, prop: string) =
    d.say "\"...\" pressed for " & prop & " (an application dialog would open here)"
  saveBtn.onClick = proc(s: Control) =
    createDir SaveFile.parentDir
    let text = objectToNfm(Obj(d.sample))
    writeFile(SaveFile, text)
    echo text
    d.say "saved " & SaveFile
  loadBtn.onClick = proc(s: Control) =
    if not fileExists(SaveFile):
      d.say "nothing saved yet: press Save .nfm first"
      return
    d.buildSample(readFile(SaveFile))
    d.ins.inspect(newSeq[Obj]())
    d.say "reloaded from " & SaveFile
  d.select(Control(d.sample.findComponent("okButton")))

# ------------------------------------------------------------ screenshots

proc shoot(f: Form, dir, name: string) =
  discard f.paintIfDirty()
  Application.paintForms()
  if not screenshotWithPopups(f, dir / (name & ".png")): quit "screenshot failed for " & name
  echo "wrote ", dir / (name & ".png")

proc ev(f: Form, kind: EventKind, p: PointF, clicks = 1) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: p.x, y: p.y,
                                     button: mbLeft, clicks: clicks))

proc resetWindow(d: Demo) =
  ## Closing a drop-down resizes an offscreen window; put it back.
  d.win.setLogicalSize(900, 620)
  d.syncMetrics()
  d.ui.invalidateAll()

proc clickValue(d: Demo, name: string) =
  let i = d.ins.indexOfProp(name)
  let r = d.ins.valueRect(i)
  let p = d.ins.clientToForm(pointF(r.x + 20, r.y + r.h / 2))
  d.ev(ekMouseDown, p)
  d.ev(ekMouseUp, p)

proc shots(dir: string) =
  createDir dir
  Application.init()
  let d = newDemo()
  d.show()
  d.win.setLogicalSize(900, 620)
  d.syncMetrics()
  d.shoot(dir, "1-properties-light")
  
  d.ui.invalidateAll()
  d.shoot(dir, "1c")
  d.ins.setExpanded("font", true)
  d.ins.setExpanded("anchors", true)
  d.ins.selectProp("anchors")
  d.shoot(dir, "2-expanded-light")
  d.ins.tab = itEvents
  d.shoot(dir, "3-events-light")
  d.ins.tab = itProperties
  d.ins.selectProp("modalResult")
  d.clickValue("modalResult")
  d.shoot(dir, "4-enum-dropdown-light")
  d.ins.cancelEdit()
  d.ins.editCombo.closeUp()
  d.resetWindow()
  d.select(Control(d.sample.findComponent("userEdit")))
  d.ins.sortedFlat = true
  d.shoot(dir, "5-flat-light")
  Application.theme = themeDark()
  d.ins.sortedFlat = false
  d.select(Control(d.sample.findComponent("okButton")))
  d.ins.beginEdit("color")
  d.shoot(dir, "6-color-dark")
  d.ins.cancelEdit()
  d.ins.editCombo.closeUp()
  d.resetWindow()
  d.select(Control(d.sample.findComponent("cancelButton")), add = true)
  d.shoot(dir, "7-multi-dark")

proc main() =
  let args = commandLineParams()
  if args.len >= 1 and args[0] == "--shots":
    shots(if args.len >= 2: args[1] else: "build/inspector_shots")
  else:
    Application.init()
    Application.run(newDemo())

when isMainModule:
  main()
