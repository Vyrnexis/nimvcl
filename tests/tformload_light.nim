## `loadForm` must stay light: an application that imports `dsl/formload` and
## the modules of its controls compiles without the property registry, the
## object inspector and the run-time `.nfm` loader, and still runs.
## The module graph is read from the compiler's `Processing` hints.

import std/[unittest, osproc, strutils, os]

const
  here = currentSourcePath().parentDir
  root = here.parentDir
  app = here / "lightapp" / "lightapp.nim"

proc cache(id: string): string = root / "build" / ("nimcache_light_" & id)

proc nimCmd(command, extra: string): string =
  let id = $getCurrentProcessId()
  "nim " & command & " --hints:off --warnings:off " & extra & " --path:" &
    quoteShell(root / "src") & " --nimcache:" & quoteShell(cache(id)) &
    " -o:" & quoteShell(root / "build" / ("lightapp_" & id)) & " " & quoteShell(app)

suite "loadForm applications stay light":
  test "the module graph has no registry, inspector or run-time loader":
    # `nim genDepend` writes <nimcache>/lightapp.deps: every module the program
    # reads, transitively
    let id = $getCurrentProcessId()
    createDir cache(id)
    let (output, code) = execCmdEx(nimCmd("genDepend", ""))
    check code == 0
    if code != 0: echo output
    var mods: seq[string]
    for line in lines(cache(id) / "lightapp.deps"):
      mods.add line.extractFilename
    check "formload.nim" in mods
    check "nfmsyntax.nim" in mods
    for banned in ["props.nim", "props_std.nim", "nfm.nim", "inspector.nim",
                   "propeditors.nim", "designsurface.nim", "codeedit.nim"]:
      check banned notin mods

  test "it builds and runs":
    putEnv("SDL_VIDEO_DRIVER", "offscreen")
    putEnv("SDL_RENDER_DRIVER", "software")
    let (output, code) = execCmdEx(nimCmd("c", "-r"))
    check code == 0
    check "light ok" in output

removeDir cache($getCurrentProcessId())
removeFile root / "build" / ("lightapp_" & $getCurrentProcessId())
