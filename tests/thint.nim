## Hints (tooltips). Headless (offscreen SDL), real timers: the tooltip runs on
## the popup fallback window (see tpopup.nim). Pauses are shortened.

import std/[unittest, monotimes, times]
import nimvcl
import nimvcl/controls/[menus, hint]

proc ev(win: PlatformWindow, kind: EventKind, x = 0'f32, y = 0'f32,
        k = Key(0)): PlatformEvent =
  PlatformEvent(kind: kind, windowId: win.id, x: x, y: y, key: k, button: mbLeft,
                clicks: 1)
proc move(f: Form, x, y: float32) = Application.dispatch(ev(f.win, ekMouseMove, x, y))

proc waitUntil(cond: proc(): bool, ms = 3000): bool =
  let t0 = getMonoTime()
  while not cond() and (getMonoTime() - t0).inMilliseconds < ms:
    Application.processMessages(10)
  cond()
proc settle(ms: int) =
  let t0 = getMonoTime()
  while (getMonoTime() - t0).inMilliseconds < ms: Application.processMessages(10)

proc flush() =
  ## The offscreen driver's fallback hint window makes SDL report a (late) mouse
  ## leave for the owner, which clears the hover; let it arrive before moving on.
  settle(60)

suite "hints":
  var f: Form
  var a, b, plain: Button
  setup:
    Application.init()
    Application.forceScale = 0
    Application.showHint = true
    hintLeaveHidesFallback = false
    Application.hintPause = 150
    f = newForm(nil, 400, 300)
    a = newButton(f, "A", 10, 10, 80, 28)
    b = newButton(f, "B", 10, 60, 80, 28)
    plain = newButton(f, "plain", 10, 110, 80, 28)
    a.hint = "Hint for A"
    b.hint = "Hint for B"
    f.show()
  teardown:
    hideHint()
    closeAllPopups(nil)
    for x in openForms(): x.freeWindow()

  test "appears after the pause, not before; settings":
    check Application.showHint and Application.hintPause == 150
    f.move(20, 20)
    check not hintVisible()
    settle(40)
    check not hintVisible()
    check waitUntil(proc(): bool = hintVisible())
    check hintText() == "Hint for A"
    let t = tooltipOf(f)
    check t != nil and t.kind == pkTooltip
    check t.bounds.x == 20 and t.bounds.y > 20          # below the pointer
    check menuChain(f).len == 0

  test "does not appear for controls without a hint, or when switched off":
    f.move(20, 120)
    settle(300)
    check not hintVisible()
    Application.showHint = false
    f.move(20, 20)
    settle(300)
    check not hintVisible()

  test "hides when the mouse leaves the control, on leave, click and key":
    f.move(20, 20)
    check waitUntil(proc(): bool = hintVisible())
    f.move(20, 120)                                     # another control without hint
    check not hintVisible() and tooltipOf(f) == nil
    flush()
    f.move(20, 20)
    check waitUntil(proc(): bool = hintVisible())
    check hintVisible()
    Application.dispatch(ev(f.win, ekWindowMouseLeave))
    flush()
    check hintVisible()                                 # SDL's own leave for a fallback hint window is ignored
    hintLeaveHidesFallback = true
    Application.dispatch(ev(f.win, ekWindowMouseLeave))
    hintLeaveHidesFallback = false
    check not hintVisible()
    flush()
    f.move(20, 20)
    check waitUntil(proc(): bool = hintVisible())
    flush()
    Application.dispatch(ev(f.win, ekMouseDown, 20, 20))
    check not hintVisible()
    Application.dispatch(ev(f.win, ekMouseUp, 20, 20))
    f.move(21, 21)                                      # moves again within the control
    settle(20)
    check not hintVisible()                             # (a new rest period starts)
    check waitUntil(proc(): bool = hintVisible())
    Application.dispatch(ev(f.win, ekKeyDown, k = keyEnter))
    check not hintVisible()

  test "a pending hint is cancelled when the mouse leaves":
    f.move(20, 20)
    f.move(20, 120)
    settle(350)
    check not hintVisible()

  test "small jitter inside the control keeps the pending hint timer":
    Application.hintPause = 200
    f.move(20, 20)
    settle(100)
    f.move(22, 21)
    f.move(23, 22)
    let t0 = getMonoTime()
    check waitUntil(proc(): bool = hintVisible())
    check (getMonoTime() - t0).inMilliseconds < 180      # not restarted by the jitter
    f.move(40, 25)                                       # moving in the control keeps it visible
    check hintVisible() and hintText() == "Hint for A"

  test "quick reshow when moving between hinted controls":
    Application.hintPause = 500
    f.move(20, 20)
    check waitUntil(proc(): bool = hintVisible())
    flush()
    f.move(20, 70)                                       # onto B
    check not hintVisible()
    let t0 = getMonoTime()
    check waitUntil(proc(): bool = hintVisible(), 400)
    check (getMonoTime() - t0).inMilliseconds < 400
    check hintText() == "Hint for B"

  test "the nearest ancestor's hint is used":
    let p = newPanel(f, "", 200, 10, 150, 100)
    p.hint = "Panel hint"
    let l = newLabel(p, "inner", 10, 10)
    check hintFor(l) == "Panel hint" and hintFor(a) == "Hint for A"
    f.move(210, 20)
    check waitUntil(proc(): bool = hintVisible())
    check hintText() == "Panel hint"

  test "no hint while a menu is open; menus hide a visible hint":
    let mm = newMainMenu(f)
    mm.addItem("&File").addItem("x")
    f.move(20, 80)                                       # on B (moved down by the bar)
    var found = false
    for c in [a, b]:
      let p = c.clientToForm(pointF(5, 5))
      f.move(p.x, p.y)
      if waitUntil(proc(): bool = hintVisible(), 500): found = true; break
    check found
    mm.openDropdown(0)
    Application.dispatch(ev(f.win, ekMouseDown, 5, 5))   # swallowed click closes the menu and the hint
    check not hintVisible()
    mm.openDropdown(0)
    let p = a.clientToForm(pointF(5, 5))
    f.move(p.x, p.y)
    settle(300)
    check not hintVisible()

  test "hint paints in both themes":
    for t in [themeLight(), themeDark()]:
      Application.theme = t
      f.move(20, 20)
      check waitUntil(proc(): bool = hintVisible())
      Application.paintForms()
      hideHint()
      flush()
    Application.theme = themeLight()
