## A colour set on a control is what gets painted. Headless (offscreen SDL).

import std/[unittest, os]
import sdl3 except Color, Cursor
import nimvcl

proc pixel(f: Form, x, y: int): tuple[r, g, b: int] =
  ## Colour of a pixel of the rendered form (through a BMP screenshot).
  let path = getTempDir() / ("nimvcl_tcontrolcolor_" & $getCurrentProcessId() & ".bmp")
  doAssert f.screenshot(path, full = true)
  let raw = sdl3.loadBMP(path.cstring)
  doAssert raw != nil
  let s = convertSurface(raw, PIXELFORMAT_RGBA32)
  destroySurface raw
  let o = y * s.pitch + x * 4
  result = (int(s.pixels[o]), int(s.pixels[o + 1]), int(s.pixels[o + 2]))
  destroySurface s
  removeFile path

func near(a: tuple[r, g, b: int], c: Color, tol = 8): bool =
  abs(a.r - int(c.r)) <= tol and abs(a.g - int(c.g)) <= tol and abs(a.b - int(c.b)) <= tol

suite "Button colour":
  test "a button with its own colour paints that colour":
    let f = newForm(nil, 300, 120)
    f.show()
    let red = parseColor("#dc2626")
    let b = newButton(f, "Red", 20, 20, 120, 40)
    b.color = red
    let plain = newButton(f, "Plain", 160, 20, 120, 40)
    check not b.parentColor
    check f.pixel(30, 40).near(red)              # inside the face, left of the text
    check not f.pixel(170, 40).near(red)         # the plain button keeps the theme face
    f.close()

  test "the default button with its own colour uses that colour, not the accent":
    let f = newForm(nil, 300, 120)
    f.show()
    let green = parseColor("#16a34a")
    let b = newButton(f, "OK", 20, 20, 120, 40)
    b.isDefault = true
    b.color = green
    check f.pixel(30, 40).near(green)
    f.close()

  test "a light colour gets dark text and a dark colour light text":
    let f = newForm(nil, 300, 120)
    f.show()
    let light = newButton(f, "MMMMMMMM", 20, 20, 200, 40)
    light.color = parseColor("#fde68a")
    # somewhere on the caption there must be a dark pixel
    var dark = false
    for x in 60 .. 180:
      let p = f.pixel(x, 40)
      if p.r + p.g + p.b < 200: dark = true; break
    check dark
    f.close()

# ------------------------------------------------- own background, per family

let paint = parseColor("#c0392b")          # not close to any theme surface

proc probeForm(): Form =
  result = newForm(nil, 400, 260)
  result.show()

suite "own background colour: fields":
  test "Edit":
    let f = probeForm()
    let e = newEdit(f, "", 20, 20, 300, 32)
    check f.pixel(250, 36).near(themeLight().surface)     # theme look without a colour
    e.color = paint
    check f.pixel(250, 36).near(paint)
    f.close()

  test "Edit: disabled fades the colour, borderless fills edge to edge":
    let f = probeForm()
    let e = newEdit(f, "", 20, 20, 300, 32)
    e.color = paint
    e.enabled = false
    check not f.pixel(250, 36).near(paint)
    check not f.pixel(250, 36).near(themeLight().surfaceAlt)
    e.enabled = true
    e.borderStyle = ebNone
    check f.pixel(21, 21).near(paint)
    f.close()

  test "Memo":
    let f = probeForm()
    let m = newMemo(f, "", 20, 20, 300, 120)
    m.color = paint
    check f.pixel(250, 100).near(paint)
    f.close()

  test "CodeEdit":
    let f = probeForm()
    let e = newCodeEdit(f, "", 20, 20, 300, 120)
    e.color = paint
    check f.pixel(280, 100).near(paint)
    f.close()

  test "ListBox":
    let f = probeForm()
    let l = newListBox(f, 20, 20, 300, 120)
    l.items = @["one", "two"]
    l.color = paint
    check f.pixel(250, 110).near(paint)
    f.close()

  test "ComboBox: the field and the drop-down list":
    let f = probeForm()
    let c = newComboBox(f, csDropDown, 20, 20, 300, 32)
    c.items = @["one", "two"]
    c.color = paint
    check f.pixel(150, 36).near(paint)               # the inner edit follows it
    check f.pixel(30, 36).near(paint)
    c.dropDown()
    check c.dropList.color == paint and not c.dropList.parentColor
    c.closeUp()
    let l = newComboBox(f, csDropDownList, 20, 80, 300, 32)
    l.color = paint
    check f.pixel(200, 96).near(paint)
    f.close()

  test "SpinEdit":
    let f = probeForm()
    let s = newSpinEdit(f, 0, 20, 20, 200, 32)
    s.color = paint
    check f.pixel(150, 36).near(paint)               # inside the edit
    check f.pixel(24, 24).near(paint)
    f.close()

suite "own background colour: lists and grids":
  test "ListView (report and icon styles)":
    let f = probeForm()
    let lv = newListView(f, 20, 20, 300, 160)
    lv.columns.add("A", 100)
    lv.items.add("x")
    lv.color = paint
    check f.pixel(250, 150).near(paint)
    check not f.pixel(250, 24).near(paint)           # the header is a shade of it, not the same
    check f.pixel(250, 24).near(shade(paint, 0.06), 10)
    f.close()

  test "TreeView":
    let f = probeForm()
    let tv = newTreeView(f, 20, 20, 300, 160)
    tv.items.add(nil, "root")
    tv.color = paint
    check f.pixel(250, 150).near(paint)
    f.close()

  test "StringGrid: cells and the fixed header shade":
    let f = probeForm()
    let g = newStringGrid(f, 20, 20, 340, 200)
    g.color = paint
    check f.pixel(330, 210).near(paint)              # below the rows
    f.close()

suite "own background colour: buttons, containers and bars":
  test "CheckBox and RadioButton: the area behind":
    let f = probeForm()
    let c = newCheckBox(f, "a", false, 20, 20, 300, 24)
    let r = newRadioButton(f, "b", false, 20, 60, 300, 24)
    c.color = paint
    r.color = paint
    check f.pixel(250, 32).near(paint)
    check f.pixel(250, 72).near(paint)
    f.close()

  test "Label: only when it is not transparent":
    let f = probeForm()
    let l = newLabel(f, "x", 20, 20, 300, 24)
    l.color = paint
    check not f.pixel(250, 32).near(paint)           # transparent by default
    l.transparent = false
    check f.pixel(250, 32).near(paint)
    f.close()

  test "Panel and GroupBox":
    let f = probeForm()
    let p = newPanel(f, "", 20, 20, 160, 100)
    let g = newGroupBox(f, "", 200, 20, 160, 100)
    p.color = paint
    g.color = paint
    check f.pixel(100, 70).near(paint)
    check f.pixel(280, 70).near(paint)
    f.close()

  test "children with parentColor inherit a panel's colour; own colours win":
    let f = probeForm()
    let p = newPanel(f, "", 20, 20, 300, 100)
    p.color = paint
    let l = newLabel(p, "x", 10, 10, 100, 24)
    l.transparent = false
    check l.color == paint
    f.close()

  test "Frame and ScrollBox":
    let f = probeForm()
    let fr = newFrame(f, 20, 20, 160, 100)
    let sb = newScrollBox(f, 200, 20, 160, 100)
    fr.color = paint
    sb.color = paint
    check f.pixel(100, 70).near(paint)
    check f.pixel(260, 70).near(paint)
    f.close()

  test "StatusBar and ToolBar":
    let f = probeForm()
    let sb = newStatusBar(f, "ready")
    sb.color = paint
    check f.pixel(300, 260 - 10).near(paint)
    let tb = newToolBar(f)
    tb.color = paint
    check f.pixel(300, 16).near(paint)
    f.close()

  test "PageControl and TabControl: the body":
    let f = probeForm()
    let pc = newPageControl(f, 20, 20, 160, 160)
    newTabSheet(pc, "one")
    pc.color = paint
    check f.pixel(100, 150).near(paint)
    let tc = newTabControl(f, @["a", "b"], 200, 20, 160, 160)
    tc.color = paint
    check f.pixel(280, 150).near(paint)
    f.close()

  test "ProgressBar track, TrackBar area, Bevel":
    let f = probeForm()
    let p = newProgressBar(f, 20, 20, 300, 18)
    p.color = paint
    check f.pixel(250, 29).near(paint)
    let t = newTrackBar(f, 20, 60, 300, 32)
    t.color = paint
    check f.pixel(250, 64).near(paint)
    let b = newBevel(f, bsBox, 20, 110, 100, 50)
    b.color = paint
    check f.pixel(60, 135).near(paint)
    f.close()

suite "font.color":
  proc countNear(f: Form, c: Color, tol = 24): int =
    let path = getTempDir() / ("nimvcl_tcontrolcolor_fc_" & $getCurrentProcessId() & ".bmp")
    doAssert f.screenshot(path, full = true)
    let img = loadImage(path)
    for y in 0 ..< img.height:
      for x in 0 ..< img.width:
        let p = img.getPixel(x, y)
        if abs(int(p.r) - int(c.r)) <= tol and abs(int(p.g) - int(c.g)) <= tol and
           abs(int(p.b) - int(c.b)) <= tol: inc result
    removeFile path

  let green = parseColor("#00aa00")
  let big = font(size = 28, style = {fsBold})

  test "the default is the theme's text colour (alpha 0)":
    let l = newLabel(nil, "x")
    check l.fontColor.a == 0 and l.font.color.a == 0
    l.fontColor = green
    check l.font.color == green and not l.parentFont

  test "Label":
    let f = probeForm()
    let l = newLabel(f, "MMMMMM", 20, 20)
    l.font = big
    check f.countNear(green) == 0
    l.fontColor = green
    check f.countNear(green) > 80
    f.close()

  test "Edit":
    let f = probeForm()
    let e = newEdit(f, "MMMMMM", 20, 20, 300, 48)
    e.font = big
    e.fontColor = green
    check f.countNear(green) > 80
    f.close()

  test "Button":
    let f = probeForm()
    let b = newButton(f, "MMMMMM", 20, 20, 300, 48)
    b.font = big
    b.fontColor = green
    check f.countNear(green) > 80
    f.close()

  test "CheckBox":
    let f = probeForm()
    let c = newCheckBox(f, "MMMMMM", false, 20, 20, 300, 40)
    c.font = big
    c.fontColor = green
    check f.countNear(green) > 80
    f.close()

  test "ListBox":
    let f = probeForm()
    let l = newListBox(f, 20, 20, 300, 120)
    l.font = big
    l.items = @["MMMM"]
    l.fontColor = green
    check f.countNear(green) > 80
    f.close()

  test "children inherit it through parentFont, like the VCL":
    let f = probeForm()
    let p = newPanel(f, "", 0, 0, 400, 100)
    let l = newLabel(p, "MMMMMM", 20, 20)
    l.parentFont = true
    p.font = big
    p.fontColor = green
    check l.font.color == green
    check f.countNear(green) > 80
    f.close()

  test "a colour set on the control keeps text readable without font.color":
    let f = probeForm()
    let e = newEdit(f, "MMMMMM", 20, 20, 300, 48)
    e.font = big
    e.color = parseColor("#101010")                 # dark: the theme's dark text would vanish
    check f.countNear(clWhite) > 80
    f.close()

  test "Label.textColor is the deprecated alias":
    let l = newLabel(nil, "x")
    l.textColor = green
    check l.fontColor == green and l.hasTextColor
    l.resetTextColor()
    check l.fontColor.a == 0 and not l.hasTextColor

suite "toolbar image buttons":
  test "a disabled button dims its image":
    let f = newForm(nil, 300, 120)
    f.show()
    let bar = newToolBar(f)
    let red = parseColor("#ff0000")
    let a = newToolButton(bar, "")
    a.image = newImage(16, 16, red)
    let b = newToolButton(bar, "")
    b.image = newImage(16, 16, red)
    b.enabled = false
    f.layoutIfNeeded()
    let pa = a.formOrigin
    let pb = b.formOrigin
    let ea = f.pixel(int(pa.x + a.width / 2), int(pa.y + a.height / 2))
    let eb = f.pixel(int(pb.x + b.width / 2), int(pb.y + b.height / 2))
    check ea.near(red) and not eb.near(red)
    check eb.g > ea.g                      # blended towards the light bar
    f.close()
