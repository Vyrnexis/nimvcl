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

suite "loadForm errors (.nfm files)":
  test "syntax error is reported with file:line:col":
    expectError("nfm_parse_error.nim", "nfm_parse_error.nfm:2:13: unterminated string", 4)

  test "unknown class":
    expectError("nfm_unknown_class.nim", "nfm_unknown_class.nfm:2:3: unknown class `Buttn`", 4)

  test "unknown property":
    expectError("nfm_unknown_property.nim",
                "nfm_unknown_property.nfm:3:5: `Button` has no property `captoin`", 4)

  test "value of the wrong type":
    expectError("nfm_bad_value.nim",
                "nfm_bad_value.nfm:3:5: the value of `width` does not fit its type in `Button`", 4)

  test "duplicate object name":
    expectError("nfm_duplicate_name.nim", "nfm_duplicate_name.nfm:4:3: duplicate object name `ok`", 4)

  test "unknown event":
    expectError("nfm_unknown_event.nim", "nfm_unknown_event.nfm:3:5: `Button` has no event `onTap`", 4)

  test "a handler that is never defined":
    expectError("nfm_missing_handler.nim", "implementation of", 4)
    check "okClick" in firstError(compileFail("nfm_missing_handler.nim"))

  test "missing file":
    expectError("nfm_missing_file.nim", "cannot read", 4)

  test "inherited object the ancestor does not have":
    expectError("nfm_inherit_ghost.nim",
                "nfm_inherit_ghost.nfm:3:3: `inherited ghost`: the ancestor form has no object of that name", 5)

  test "inherited object inside a new container":
    expectError("nfm_inherit_nested.nim",
                "nfm_inherit_nested.nfm:4:5: `inherited ok` can only stand directly in an `inherited` object", 5)

  test "new object named like an ancestor's":
    expectError("nfm_inherit_dup.nim", "nfm_inherit_dup.nfm:3:3: duplicate object name `ok`", 5)
