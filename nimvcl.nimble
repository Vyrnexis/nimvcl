import std/strutils

# Package

version       = "0.4.1"
author        = "Vyrnexis"
description   = "Delphi VCL-style UI library for Nim, drawn with SDL3"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.0"
# Official binding, by URL: the nimble package list maps "sdl3" to a different
# (transmutrix) package. A version range, not a #commit: nimble 0.22 leaves a
# #commit dependency off the compiler path when it is already installed.
requires "https://github.com/nim-lang/sdl3 >= 1.1"

task test, "Run the test suite headless (debug)":
  exec "bash scripts/test.sh"

task testRelease, "Run the test suite headless (release)":
  exec "bash scripts/test.sh -d:release"

task examples, "Build every example into build/examples":
  for f in listFiles("examples"):
    if f.endsWith(".nim"):
      exec "nim c --hints:off --outdir:build/examples " & f
