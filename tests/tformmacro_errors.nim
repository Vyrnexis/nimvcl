## Compile-error tests for the `form` macro: each file in tests/macro_fail/
## must fail to compile with the expected message on the expected line.

import std/[unittest, osproc, strutils, os]

const
  here = currentSourcePath().parentDir
  root = here.parentDir

proc compileFail(file: string): string =
  ## Output of `nim c` on tests/macro_fail/<file> (compile only).
  let cmd = "nim c --hints:off --path:" & quoteShell(root / "src") &
            " --compileOnly --nimcache:" & quoteShell(root / "build" / ("nimcache_fail_" & $getCurrentProcessId())) &
            " -o:" & quoteShell(root / "build" / ("macro_fail_out_" & $getCurrentProcessId())) &
            " " & quoteShell(here / "macro_fail" / file)
  let (output, code) = execCmdEx(cmd)
  check code != 0
  output

proc firstError(output: string): string =
  for line in output.splitLines:
    if "Error:" in line and "template/generic instantiation" notin line: return line
  ""

proc expectError(file, message: string, line: int) =
  let err = firstError(compileFail(file))
  check err.len > 0
  check message in err
  check (file & "(" & $line & ",") in err

suite "form macro errors":
  test "unknown property":
    expectError("unknown_property.nim", "`Button` has no property `captoin`", 7)

  test "unknown child type":
    expectError("unknown_type.nim", "unknown control type `Buttn`", 5)

  test "duplicate child name":
    expectError("duplicate_name.nim", "duplicate name `ok`", 7)

  test "child named like a Component/Control property":
    expectError("reserved_name.nim", "`caption` is reserved", 4)

  test "shorthand on an event that is not a NotifyEvent":
    expectError("shorthand_not_notify.nim", "`onClose` of `Bad` is not a NotifyEvent", 5)

  test "wrong value type is reported on the property's line":
    expectError("wrong_type.nim", "width", 6)
