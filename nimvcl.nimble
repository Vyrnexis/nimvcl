import std/strutils

# Package

version       = "0.1.3"
author        = "Vyrnexis"
description   = "Delphi VCL-style UI library for Nim, drawn with SDL3"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.0"
# Official binding, pinned by URL: stale local nimble package lists map "sdl3"
# to a different (transmutrix) package.
requires "https://github.com/nim-lang/sdl3#533d22196dab2ea637ea0131171ed3f8db61fe90"

task test, "Run the test suite headless (debug)":
  exec "bash scripts/test.sh"

task testRelease, "Run the test suite headless (release)":
  exec "bash scripts/test.sh -d:release"

task examples, "Build every example into build/examples":
  for f in listFiles("examples"):
    if f.endsWith(".nim"):
      exec "nim c --hints:off --outdir:build/examples " & f
