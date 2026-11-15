## Refinement round: theme-relative text colours, CJK fallback probe, PageControl
## `showTabs`, PNG screenshots, RectF.inflate(dx, dy). Headless (offscreen SDL).

import std/[unittest, os, strutils]
import nimvcl

proc countNear(img: Image, c: Color, tol = 24): int =
  for y in 0 ..< img.height:
    for x in 0 ..< img.width:
      let p = img.getPixel(x, y)
      if abs(int(p.r) - int(c.r)) <= tol and abs(int(p.g) - int(c.g)) <= tol and
         abs(int(p.b) - int(c.b)) <= tol: inc result

proc shotOf(f: Form, name: string): Image =
  let path = getTempDir() / name
  doAssert f.screenshot(path)
  result = loadImage(path)
  removeFile path

suite "geometry":
  test "RectF.inflate(dx, dy)":
    let r = rectF(10, 20, 100, 50)
    check r.inflate(5, 2) == rectF(5, 18, 110, 54)
    check r.inflate(-5, -2) == rectF(15, 22, 90, 46)
    check r.inflate(3, 3) == r.inflate(3)

suite "theme colours":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    Application.theme = themeLight()
    for f in openForms(): f.freeWindow()

  test "ThemeColor resolves against a theme":
    let l = themeLight()
    let d = themeDark()
    check l.resolve(tcText) == l.text
    check l.resolve(tcMuted) == l.textMuted
    check d.resolve(tcAccent) == d.accent
    check l.resolve(tcMuted) != d.resolve(tcMuted)

  test "label: muted, textRole, textColor and reset":
    let l = newLabel(nil, "x")
    check not l.muted and not l.hasTextColor and l.textRole == tcText
    l.muted = true
    check l.muted and l.textRole == tcMuted and not l.hasTextColor
    l.textColor = hex"#ff0000"                # a fixed colour replaces the role
    check l.hasTextColor and not l.muted
    l.textRole = tcAccent
    check not l.hasTextColor and l.textRole == tcAccent and not l.muted
    l.muted = true
    l.muted = false
    check l.textRole == tcText
    l.textRole = tcAccent
    l.muted = false                           # only undoes `muted`
    check l.textRole == tcAccent
    l.resetTextColor()
    check l.textRole == tcText and not l.hasTextColor

  test "a muted label follows a theme switch without being touched":
    let f = newForm(nil, 200, 60)
    let l = newLabel(f, "MMMMMMMM", 4, 4)
    l.font = font(size = 28, style = {fsBold})
    l.muted = true
    let light = f.shotOf("nimvcl_trefine_l.bmp")
    check light.countNear(themeLight().textMuted) > 50
    Application.theme = themeDark()
    let dark = f.shotOf("nimvcl_trefine_d.bmp")
    check dark.countNear(themeDark().textMuted) > 50
    check dark.countNear(themeLight().textMuted) * 4 < dark.countNear(themeDark().textMuted)

  test "a fixed textColor does not follow the theme":
    let f = newForm(nil, 200, 60)
    let l = newLabel(f, "MMMMMMMM", 4, 4)
    l.font = font(size = 28, style = {fsBold})
    l.textColor = hex"#ff0000"
    Application.theme = themeDark()
    check f.shotOf("nimvcl_trefine_r.bmp").countNear(hex"#ff0000") > 50

  test "panel caption colour: role and fixed":
    let p = newPanel(nil, "cap")
    check not p.hasTextColor and p.textRole == tcText
    p.textRole = tcMuted
    check p.textRole == tcMuted and not p.hasTextColor
    p.textColor = hex"#00ff00"
    check p.hasTextColor and p.textColor == hex"#00ff00"
    p.resetTextColor()
    check not p.hasTextColor and p.textRole == tcText
    let f = newForm(nil, 200, 60)
    let q = newPanel(f, "MMMM", 0, 0, 200, 60)
    q.font = font(size = 28, style = {fsBold})
    q.textRole = tcAccent
    check f.shotOf("nimvcl_trefine_p.bmp").countNear(themeLight().accent) > 50

suite "fonts":
  test "CJK fallback: probed lazily, only when a font is present":
    let p = cjkFallbackFont()
    if p.len > 0:
      check fileExists(p)
      check p in fallbackFontFiles()
    else:
      for f in fallbackFontFiles(): check "CJK" notin f

suite "pagecontrol showTabs":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "hiding the strip removes it and the user's way to switch":
    let f = newForm(nil, 400, 300)
    f.show()
    let pc = newPageControl(f)
    pc.align = alClient
    let a = newTabSheet(pc, "&One")
    let b = newTabSheet(pc, "&Two")
    discard f.paintIfDirty()
    check pc.showTabs and pc.stripHeight > 0 and a.top >= pc.stripHeight
    pc.showTabs = false
    discard f.paintIfDirty()
    check not pc.showTabs and pc.stripHeight == 0
    check a.top == 1 and a.left == 1 and a.width == pc.width - 2
    check a.height == pc.height - 2
    check pc.tabAt(20, 5) == -1
    check not pc.canFocus
    var k = keyRight
    pc.doKeyDown(k, {})
    check pc.activePage == a
    check not pc.activateMnemonic(mnemonicOf("&Two"))
    pc.activePage = b                       # code still switches
    check pc.activePage == b and b.visible and not a.visible
    pc.cycle(1)
    check pc.activePage == a
    pc.showTabs = true
    discard f.paintIfDirty()
    check a.top >= pc.stripHeight and pc.stripHeight > 0

suite "screenshots":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  proc magic(path: string, n: int): string =
    let s = readFile(path)
    s[0 ..< n]

  test "form screenshot picks the format from the extension":
    let f = newForm(nil, 120, 80)
    let png = getTempDir() / "nimvcl_trefine_shot.PNG"
    let bmp = getTempDir() / "nimvcl_trefine_shot.bmp"
    check f.screenshot(png)
    check f.screenshot(bmp)
    check magic(png, 4) == "\x89PNG"
    check magic(bmp, 2) == "BM"
    let img = loadImage(png)
    check img.width > 0 and img.height > 0
    removeFile png
    removeFile bmp

  test "screenshotWithPopups writes PNG too":
    let f = newForm(nil, 120, 80)
    let png = getTempDir() / "nimvcl_trefine_shot2.png"
    check f.screenshotWithPopups(png)
    check magic(png, 4) == "\x89PNG"
    removeFile png
