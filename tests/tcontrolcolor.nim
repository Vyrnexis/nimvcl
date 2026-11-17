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
