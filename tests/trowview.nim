## Shared row-view helpers: type-ahead, navigation targets, selection updates.

import std/[unittest, os]
import nimvcl
import nimvcl/controls/[rowview, indexset]

suite "TypeAhead":
  test "prefix grows within the timeout and wraps":
    var t = initTypeAhead(10_000)
    let items = @["apple", "avocado", "banana", "Berry"]
    let txt = proc(i: int): string = items[i]
    check t.search('a', -1, 4, txt) == 0
    check t.search('v', 0, 4, txt) == 1
    t.reset()
    check t.search('b', 1, 4, txt) == 2
    check t.search('E', 2, 4, txt) == 3          # case-insensitive, longer prefix
    t.reset()
    check t.search('z', 0, 4, txt) == -1
  test "a new prefix starts after the current row":
    var t = initTypeAhead(10_000)
    let items = @["aa", "ab", "ac"]
    let txt = proc(i: int): string = items[i]
    check t.search('a', 0, 3, txt) == 1
  test "timeout restarts the prefix":
    var t = initTypeAhead(0)
    let items = @["ab", "ba"]
    let txt = proc(i: int): string = items[i]
    check t.search('a', -1, 2, txt) == 0
    sleep(5)
    check t.search('b', 0, 2, txt) == 1
  test "keyChar: leading space and shifted digits are not type-ahead":
    var t = initTypeAhead(10_000)
    check t.keyChar(' '.key, {}) == '\0'
    check t.keyChar('1'.key, {ssShift}) == '\0'
    check t.keyChar('a'.key, {ssShift}) == 'a'
    t.feed 'a'
    check t.keyChar(' '.key, {}) == ' '

suite "rowNavTarget":
  test "keys":
    check rowNavTarget(keyUp, -1, 10, 0, 4) == 0
    check rowNavTarget(keyUp, 5, 10, 0, 4) == 4
    check rowNavTarget(keyDown, 5, 10, 0, 4) == 6
    check rowNavTarget(keyHome, 5, 10, 0, 4) == 0
    check rowNavTarget(keyEnd, 5, 10, 0, 4) == 9
    check rowNavTarget(keyPageDown, 1, 10, 0, 4) == 4      # to the last full row
    check rowNavTarget(keyPageDown, 4, 10, 0, 4) == 8      # then a page minus one
    check rowNavTarget(keyPageUp, 4, 10, 2, 6) == 2
    check rowNavTarget(keyPageUp, 2, 10, 2, 6) == -2
    check rowNavTarget('a'.key, 2, 10, 2, 6) == NotNav
    check clampRow(-2, 10) == 0
    check clampRow(12, 10) == 9

suite "selection updates":
  test "click":
    var sel = initIndexSet()
    var anchor = -1
    check sel.clickSelect(anchor, 3, true, true, {})
    check sel.len == 1 and anchor == 3
    check sel.clickSelect(anchor, 6, true, true, {ssShift})
    check sel.len == 4
    check sel.clickSelect(anchor, 1, true, true, {ssCtrl})
    check 1 in sel and 4 in sel and anchor == 1
    check sel.clickSelect(anchor, 8, false, false, {})
    check sel.len == 1 and 8 in sel
  test "key moves":
    var sel = initIndexSet()
    var anchor = -1
    check sel.keySelect(anchor, 2, 3, true, true, {ssShift})
    check sel.len == 2 and anchor == 2
    check not sel.keySelect(anchor, 3, 4, true, false, {})   # simple multi: focus only
    check sel.len == 2
    check sel.keySelect(anchor, 3, 5, true, true, {ssCtrl}) == false
    check sel.keySelect(anchor, 3, 5, false, false, {})
    check sel.len == 1 and 5 in sel
  test "selectOnly of nothing on an empty set is no change":
    var sel = initIndexSet()
    check not sel.selectOnly(-1)
