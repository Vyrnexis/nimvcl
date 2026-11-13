import std/strutils

# Package

version       = "0.0.1"
author        = "Vyrnexis"
description   = "Delphi VCL-style UI library for Nim, drawn with SDL3"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.0"
# Official binding, pinned by URL: stale local nimble package lists map "sdl3"
# to a different (transmutrix) package.
requires "https://github.com/nim-lang/sdl3#533d22196dab2ea637ea0131171ed3f8db61fe90"

task test, "Run the test suite (headless)":
  putEnv "SDL_VIDEO_DRIVER", "offscreen"
  putEnv "SDL_RENDER_DRIVER", "software"
  for f in listFiles("tests"):
    if f.startsWith("tests/t") and f.endsWith(".nim"):
      exec "nim c -r --hints:off --outdir:build " & f

task spike, "Run the phase 0 spike":
  exec "nim c -r --outdir:build examples/spike.nim"

task demo, "Run the phase 1 canvas demo":
  exec "nim c -r --outdir:build examples/canvas_demo.nim"
