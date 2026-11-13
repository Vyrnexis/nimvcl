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

task test, "Run the test suite":
  exec "testament pattern 'tests/t*.nim'"

task spike, "Run the phase 0 spike":
  exec "nim c -r --outdir:build examples/spike.nim"
