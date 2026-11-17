## Bundled fonts come from the binary: no disk access to the assets folder.
## NIMVCL_ASSETS points to a folder that does not exist, so a disk load fails.
import std/[unittest, os]
import sdl3 except Color
import nimvcl

putEnv("NIMVCL_ASSETS", "/nonexistent/nimvcl-assets")

when not defined(nimvclNoEmbedFonts):
  suite "embedded fonts":
    test "sans and mono are embedded":
      check fontSource(font()) == "embedded"
      check fontSource(font(style = {fsBold})) == "embedded"
      check fontSource(font(style = {fsItalic})) == "embedded"
      check fontSource(font("mono")) == "embedded"

    test "text measures and renders from memory":
      doAssert initSdl(InitFlags(0)), sdlError()
      doAssert initTtf(), sdlError()
      let surf = createSurface(200, 60, PIXELFORMAT_RGBA32)
      doAssert surf != nil, sdlError()
      let rend = createSoftwareRenderer(surf)
      doAssert rend != nil, sdlError()
      let ctx = newRenderContext(rend, 1.0)
      defer: ctx.close()
      let c = beginFrame(ctx)
      for fam in ["sans", "mono"]:
        for st in [{}, {fsBold}, {fsItalic}]:
          let sz = c.measureText("Hello", font(fam, 16, st))
          check sz.w > 10 and sz.h > 8
          c.drawText("Hello", font(fam, 16, st), 4, 4, clBlack)
      c.endFrame()
      destroyRenderer(rend)
      destroySurface(surf)

    test "registered family wins":
      registerFontFamily("treg", "/nonexistent/x.ttf")
      check fontSource(font("treg")) == "registered"
else:
  suite "embedding disabled":
    test "falls back to disk":
      check fontSource(font()) == "disk"
