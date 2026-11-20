## System font lookups are lazy (one fontconfig query per family) and replaced
## font data is released once no rendering context can read it.
import std/[unittest, os, strutils, osproc]
import sdl3 except Color
import nimvcl

const CompiledFonts = currentSourcePath().parentDir.parentDir / "src" / "nimvcl" / "assets" / "fonts"

putEnv("NIMVCL_ASSETS", "/nonexistent/nimvcl-assets")

suite "lazy system fonts":
  test "a family lookup does not scan every font":
    # Windows and macOS scan the font folders (cached) instead of asking fontconfig
    if findExe("fc-list").len == 0 or defined(nimvclFontScan) or defined(windows) or
       defined(macosx): skip()
    else:
      let name = execProcess("fc-list : family").splitLines[0].split(',')[0].strip
      if name.len == 0: skip()
      else:
        check not systemFontsScanned()
        check fontSource(font("No Such Family 12345")) == "embedded"
        check not systemFontsScanned()
        let r = resolveFont(font(name))
        check r.isSystem and fileExists(r.path)
        check not systemFontsScanned()
        check resolveFont(font(name.toUpperAscii)).path == r.path
        check systemFontFamilies().len > 0     # the full list is read on demand
        check systemFontsScanned()
        check resolveFont(font(name)).path == r.path

suite "retired font data":
  test "freed once every context flushed or was closed":
    let data = readFile(CompiledFonts / "NotoSans-Bold.ttf")
    let f = newForm(nil, 200, 100)
    f.show()
    registerFontFamilyData("zz retire", data)
    registerFontFamilyData("zz retire", data)       # replaces: the old bytes are retired
    check retiredFontCount() == 1                   # the context may still read them
    f.ctx.beginFrameTick()                          # it flushes its fonts
    check retiredFontCount() == 0
    registerFontFamilyData("zz retire", data)
    unregisterFontFamily("zz retire")
    check retiredFontCount() > 0
    f.freeWindow()                                  # closing the context releases them
    check retiredFontCount() == 0
