## Memo extents on big documents: exact horizontal extent / wrapped row count
## (background measurement + incremental upkeep) and float64 scrolling.
## Headless (offscreen SDL).

import std/[unittest, strutils, monotimes, times, tables]
import nimvcl/core/[types, control, form, application, input, timer]
import nimvcl/platform/[events, window, timers]
import nimvcl/graphics/[context, geometry]
import nimvcl/controls/[edit, memo]

proc newShown(): Form =
  result = newForm(nil, 400, 300)
  result.show()

proc mkMemo(f: Form, text = "", w = 300'f32, h = 200'f32, wrap = false): Memo =
  result = newMemo(f, "", 10, 10, w, h)
  result.setBounds(10, 10, w, h)
  result.wordWrap = wrap
  if text.len > 0: result.text = text

proc key(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id,
                                     key: k, shift: shift))
proc typeText(f: Form, s: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id, text: s))
proc settle(f: Form) = discard f.paintIfDirty()

proc refW(f: Form, line: string): float64 =
  ## Horizontal extent of a one-line memo (always exact: small document).
  let r = f.mkMemo(line)
  discard r.extentsExact
  result = r.contentW
  r.free

proc refRows(f: Form, line: string, w: float32, h: float32): int =
  let r = f.mkMemo("", w, h, wrap = true)
  r.vScrollMode = sbmAlways          # as in the big memo: the bar takes its width
  r.text = line
  result = r.visualRowCount
  r.free

suite "memo extents (big documents)":
  setup:
    Application.init()
    Application.forceScale = 0
  teardown:
    for f in openForms(): f.freeWindow()

  test "horizontal extent is exact after the sweep, and follows edits":
    let f = newShown()
    let m = f.mkMemo()
    var parts = newSeq[string](60_000)
    for i in 0 ..< parts.len: parts[i] = "row " & $i & " " & "x".repeat(i mod 40)
    const widest = 45_001
    parts[widest] = "W".repeat(60)
    parts[7] = "m".repeat(70)                # second widest
    m.text = parts.join("\n")
    settle f
    check not m.extentsExact or m.lineCount <= 500
    m.measureAll()
    check m.extentsExact
    let wW = f.refW("W".repeat(60))
    let wM = f.refW("m".repeat(70))
    check wW > 0 and wM > 0
    let want1 = max(wW, wM)
    check abs(m.contentW - want1) < 0.01
    # narrow the widest line: the extent drops to the next widest
    m.lines[widest] = "short"
    settle f
    m.measureAll()
    check abs(m.contentW - wM) < 0.01
    # delete the second widest line: it falls back to the longest remaining
    m.lines.delete(7)
    settle f
    m.measureAll()
    check m.contentW < wM and m.contentW > 0
    var longest = 0.0
    for i in 0 ..< 40:                       # the widest remaining line is one of "row N xxx..."
      longest = max(longest, f.refW("row 5999" & $(i mod 10) & " " & "x".repeat(39)))
    check abs(m.contentW - longest) < 40     # (digit widths differ by a pixel or so)
    # insert a wider line near the end
    m.lines.insert(50_000, "W".repeat(90))
    settle f
    check abs(m.contentW - f.refW("W".repeat(90))) < 0.01     # small edits are exact at once
    # typing makes the (unique) widest line wider, backspace narrows it again
    m.setFocus()
    m.caretPos = (50_000, 90)
    for i in 0 ..< 5: f.typeText("W")
    settle f
    check abs(m.contentW - f.refW("W".repeat(95))) < 0.01
    for i in 0 ..< 5: f.key(keyBackspace)
    settle f
    check abs(m.contentW - f.refW("W".repeat(90))) < 0.01
    # replacing the whole text resets the extent
    m.text = "a\nbb\nccc"
    settle f
    check abs(m.contentW - f.refW("ccc")) < 0.01

  test "the background sweep runs from a timer in slices and stops itself":
    var tags: seq[int]
    startTimerImpl = proc(ms: uint32, tag: int): uint32 =
      tags.add tag
      1'u32
    defer: startTimerImpl = startPlatformTimer
    let f = newShown()
    let m = f.mkMemo()
    var parts = newSeq[string](20_000)
    for i in 0 ..< parts.len: parts[i] = "line " & $i & " " & "y".repeat(i mod 30)
    parts[12_345] = "W".repeat(70)
    m.text = parts.join("\n")
    settle f
    check tags.len >= 1                    # kickSweep started a timer
    let id = tags[^1]
    check not m.extentsExact
    var ticks = 0
    while dispatchTimer(id) and not m.extentsExact:
      inc ticks
      check ticks < 100_000
    check m.extentsExact
    check ticks >= 2                       # more than one slice
    check abs(m.contentW - f.refW("W".repeat(70))) < 0.01
    discard dispatchTimer(id)              # the finishing tick disables the timer
    check not dispatchTimer(id)

  test "wrapped row count is exact after the sweep":
    let f = newShown()
    let m = f.mkMemo(w = 200, h = 150, wrap = true)
    let variants = @["short", "a bit longer line of text here",
                     "this is a considerably longer line of text that has to wrap onto several rows",
                     "x".repeat(300), "", "word ".repeat(40)]
    var parts = newSeq[string](30_000)
    for i in 0 ..< parts.len: parts[i] = variants[(i * 7 + i div 3) mod variants.len]
    m.text = parts.join("\n")
    settle f
    m.measureAll()
    check m.extentsExact
    var counts = initCountTable[string]()
    for p in parts: counts.inc p
    var want = 0
    for v, c in counts: want += c * f.refRows(v, 200, 150)
    check m.visualRowCount == want
    check abs(m.contentH - (float64(want) * float64(m.rowHeight) + 8)) < 0.01
    # a resize re-wraps everything: converges again
    m.width = 120
    settle f
    m.measureAll()
    var want2 = 0
    for v, c in counts: want2 += c * f.refRows(v, 120, 150)
    check m.visualRowCount == want2
    check want2 > want
    # an edit in the first line only re-measures that line
    m.lines[0] = "x".repeat(300)
    settle f
    check m.extentsExact == false or m.visualRowCount > 0
    m.measureAll()
    check m.visualRowCount == want2 - f.refRows(parts[0], 120, 150) + f.refRows("x".repeat(300), 120, 150)

  test "the wrapped view stays anchored while rows above it are measured":
    let f = newShown()
    let m = f.mkMemo(w = 200, h = 150, wrap = true)
    var parts = newSeq[string](40_000)
    for i in 0 ..< parts.len:
      parts[i] = "line " & $i & " " & "lorem ipsum dolor sit amet ".repeat(3)
    m.text = parts.join("\n")
    settle f
    m.caretPos = (20_000, 0)
    m.scrollCaretIntoView()
    settle f
    let top = m.topLine
    check top >= 19_990 and top <= 20_000
    m.measureAll()
    check abs(m.topLine - top) <= 1
    # the caret is still in the viewport
    let cr = m.caretRect
    check cr.y >= m.viewport.y - 1 and cr.bottom <= m.viewport.bottom + 1

  test "1,000,000 lines: scroll to the exact pixel, hit-test":
    let f = newShown()
    let m = f.mkMemo(w = 300, h = 200)
    var parts = newSeq[string](1_000_000)
    for i in 0 ..< parts.len: parts[i] = "line " & $i
    parts[654_321] = "W".repeat(50)
    m.text = parts.join("\n")
    settle f
    let rh = float64(m.rowHeight)
    check m.contentH == 1_000_000.0 * rh + 8
    m.scrollTo(0, 1e18)
    check m.scrollPosY == m.maxScrollY
    settle f
    let vp = m.viewport
    # the last line sits at the bottom edge (plus the bottom padding)
    let p = m.posAtPoint(vp.x + 20, vp.bottom - 6)
    check p.line == 999_999
    for target in [3, 654_321, 777_777, 999_990]:
      m.scrollTo(0, float64(target) * rh + 4)   # rows start at PadY (4): line `target` at y = 0
      let q = m.posAtPoint(vp.x + 20, vp.y + rh / 2)
      check q.line == target
      check m.topLine == target
    check not m.extentsExact              # the sweep runs in the background
    # the (not yet measured) widest line is found as soon as it is measured
    m.lines[654_321] = "W".repeat(60)
    check m.contentW >= f.refW("W".repeat(60)) - 0.01

  test "typing at the end of a 200,000 line memo stays fast":
    let f = newShown()
    let m = f.mkMemo(w = 300, h = 200)
    var parts = newSeq[string](200_000)
    for i in 0 ..< parts.len: parts[i] = "line number " & $i & " with some more text"
    m.text = parts.join("\n")
    settle f
    m.setFocus()
    f.key(keyEnd, {ssCtrl})
    settle f
    check m.caretPos.line == 199_999
    var worst = 0.0
    var total = 0.0
    const N = 60
    for i in 0 ..< N:
      let t0 = getMonoTime()
      f.typeText("x")
      settle f
      let ms = float((getMonoTime() - t0).inMicroseconds) / 1000
      total += ms
      worst = max(worst, ms)
    check m.lines[199_999].endsWith("xxxxxxxxxx")
    # backspacing the widest line repeatedly (rescans) is fine too
    var worstBs = 0.0
    for i in 0 ..< N:
      let t0 = getMonoTime()
      f.key(keyBackspace)
      settle f
      let bms = float((getMonoTime() - t0).inMicroseconds) / 1000
      worstBs = max(worstBs, bms)
    echo "  200k lines typing at end: avg ", (total / N).formatFloat(ffDecimal, 2),
         " ms, worst ", worst.formatFloat(ffDecimal, 2), " ms; backspace worst ",
         worstBs.formatFloat(ffDecimal, 2), " ms"
    when defined(release):
      check worst < 20 and worstBs < 30
