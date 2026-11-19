## System fonts (fontconfig), unknown families and fonts registered from memory.
## Skips the fontconfig cases when fc-list is not installed.
import std/[unittest, os, strutils]
import sdl3 except Color
import nimvcl
import nimvcl/controls/inspector

const CompiledFonts = currentSourcePath().parentDir.parentDir / "src" / "nimvcl" / "assets" / "fonts"

putEnv("NIMVCL_ASSETS", "/nonexistent/nimvcl-assets")   # bundled fonts must come from the binary

# Windows and macOS scan the font folders, no fontconfig needed there.
let haveFc = defined(windows) or defined(macosx) or
  findExe("fc-list").len > 0
let fams = if haveFc: systemFontFamilies() else: @[]

suite "system fonts":
  test "unknown family falls back to the bundled sans":
    let f = font("No Such Family 12345")
    check fontSource(f) == "embedded"
    check resolveFont(f).path == resolveFont(font("sans")).path
    check fontSource(font("sans-serif-nonexistent")) == "embedded"

  test "a family fontconfig only substitutes is treated as missing":
    if not haveFc: skip()
    else:
      check fontSource(font("Zzz Not A Real Font")) == "embedded"

  test "installed families resolve to a file":
    if fams.len == 0: skip()
    else:
      check fams.len > 0
      for i in 1 ..< fams.len: check fams[i - 1] != fams[i]   # no duplicates
      let name = (if "DejaVu Sans" in fams: "DejaVu Sans" else: fams[0])
      let f = font(name)
      let r = resolveFont(f)
      check r.isSystem
      check fileExists(r.path)
      check fontSource(f) == "system"
      check fontSource(font(name.toUpperAscii)) == "system"   # case-insensitive
      check resolveFont(font(name, style = {fsBold})).isSystem

  test "bundled and registered families win over system ones":
    check fontSource(font("sans")) == "embedded"
    check fontSource(font("MONO")) == "embedded"
    if fams.len > 0:
      registerFontFamily(fams[0], "/nonexistent/x.ttf")
      check fontSource(font(fams[0])) == "registered"

  test "a system font renders":
    if fams.len == 0: skip()
    else:
      doAssert initSdl(InitFlags(0)), sdlError()
      doAssert initTtf(), sdlError()
      let surf = createSurface(200, 60, PIXELFORMAT_RGBA32)
      let rend = createSoftwareRenderer(surf)
      let ctx = newRenderContext(rend, 1.0)
      let c = beginFrame(ctx)
      let sz = c.measureText("Hello", font("DejaVu Sans", 16))
      check sz.w > 10 and sz.h > 8
      c.drawText("Hello", font(fams[0], 16, {fsBold}), 4, 4, clBlack)
      c.endFrame()
      ctx.close()
      destroyRenderer(rend)
      destroySurface(surf)

suite "fonts from memory":
  test "registerFontFamilyData opens from memory and renders":
    let reg = readFile(CompiledFonts / "NotoSans-Regular.ttf")
    let bld = readFile(CompiledFonts / "NotoSans-Bold.ttf")
    registerFontFamilyData("Memo Family", reg, bold = bld)
    check "memo family" in registeredFontFamilies()
    check fontSource(font("memo family")) == "registered"
    check resolveFont(font("Memo Family", style = {fsBold})).ttfStyle == 0       # real bold
    check resolveFont(font("Memo Family", style = {fsItalic})).ttfStyle != 0     # synthetic italic
    check embeddedFontData(resolveFont(font("Memo Family")).path).len > 0
    doAssert initSdl(InitFlags(0)), sdlError()
    doAssert initTtf(), sdlError()
    let surf = createSurface(200, 60, PIXELFORMAT_RGBA32)
    let rend = createSoftwareRenderer(surf)
    let ctx = newRenderContext(rend, 1.0)
    let c = beginFrame(ctx)
    for st in [{}, {fsBold}, {fsItalic}]:
      check c.measureText("Hello", font("Memo Family", 16, st)).w > 10
      c.drawText("Hello", font("Memo Family", 16, st), 4, 4, clBlack)
    c.endFrame()
    # re-registering replaces the data and rebuilds the caches
    registerFontFamilyData("Memo Family", bld)
    let c2 = beginFrame(ctx)
    check c2.measureText("Hello", font("Memo Family", 16)).w > 10
    c2.endFrame()
    ctx.close()
    destroyRenderer(rend)
    destroySurface(surf)

  test "unregisterFontFamily drops the family and flushes the caches":
    let reg = readFile(CompiledFonts / "NotoSans-Regular.ttf")
    unregisterFontFamily("never registered")                   # safe
    registerFontFamilyData("Gone Family", reg)
    check "gone family" in registeredFontFamilies()
    doAssert initSdl(InitFlags(0)), sdlError()
    doAssert initTtf(), sdlError()
    let surf = createSurface(200, 60, PIXELFORMAT_RGBA32)
    let rend = createSoftwareRenderer(surf)
    let ctx = newRenderContext(rend, 1.0)
    let c = beginFrame(ctx)
    c.drawText("Hello", font("Gone Family", 16), 4, 4, clBlack)
    c.endFrame()
    check ctx.fontCount > 0
    let epoch = fontRegistryEpoch()
    unregisterFontFamily("GONE family")                        # case-insensitive
    check fontRegistryEpoch() > epoch
    check "gone family" notin registeredFontFamilies()
    check fontSource(font("Gone Family")) == "embedded"        # back to the fallback
    let c2 = beginFrame(ctx)                                   # flushes what used it
    check ctx.fontCount == 0 and ctx.textCount == 0
    check c2.measureText("Hello", font("Gone Family", 16)).w > 10
    c2.endFrame()
    unregisterFontFamily("gone family")                        # twice is fine
    ctx.close()
    destroyRenderer(rend)
    destroySurface(surf)

  test "unregistering a replaced bundled family restores it":
    let reg = readFile(CompiledFonts / "NotoSans-Regular.ttf")
    registerFontFamilyData("sans", reg)
    check fontSource(font("sans")) == "registered"
    unregisterFontFamily("sans")
    check fontSource(font("sans")) == "embedded"

  test "fontFileInfo reads family and style from a file":
    let i = fontFileInfo(CompiledFonts / "NotoSans-Bold.ttf")
    check i.family.len > 0
    check fsBold in i.style
    check fontFileInfo("/nonexistent.ttf").family == ""

suite "inspector family choices":
  test "groups: bundled, project (registered), system":
    let f = newForm(nil, 300, 300)
    let ins = newObjectInspector(f, 0, 0, 280, 280)
    let b = newButton(f, "OK", 20, 40)
    ins.inspect(b)
    let items = ins.fontFamilyItems
    check items[0] == FontGroupBundled and "sans" in items and "mono" in items
    check FontGroupProject in items
    check "memo family" in items or "Memo Family" in items
    if fams.len > 0: check FontGroupSystem in items
    ins.onGetFontFamilies = proc(s: Control, t: Obj): seq[string] = @["Only One"]
    check "Only One" in ins.fontFamilyItems
    check "memo family" notin ins.fontFamilyItems
    # a free name is accepted; a group header is not
    ins.setExpanded("font", true)
    check ins.beginEdit("font.family", openList = false)
    check isFontGroupHeader(FontGroupSystem) and not isFontGroupHeader("sans")
    ins.cancelEdit()
    check ins.setValue("font.family", pvString("Some Free Name"))
    check b.font.family == "Some Free Name"
    f.close()
