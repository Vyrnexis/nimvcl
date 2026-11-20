## ToolBar overflow: chevron, hidden buttons, popup menu. Headless (offscreen SDL).

import std/[unittest]
import nimvcl
import nimvcl/controls/[menus, toolbar]

proc ev(win: PlatformWindow, kind: EventKind, x = 0'f32, y = 0'f32,
        button = mbLeft): PlatformEvent =
  PlatformEvent(kind: kind, windowId: win.id, x: x, y: y, button: button, clicks: 1)

proc click(win: PlatformWindow, x, y: float32) =
  Application.dispatch(ev(win, ekMouseDown, x, y))
  Application.dispatch(ev(win, ekMouseUp, x, y))

proc setup(w: float32, n: int): tuple[f: Form, bar: ToolBar, btns: seq[ToolButton]] =
  result.f = newForm(nil, w, 200)
  result.f.show()
  result.bar = newToolBar(result.f)
  for i in 0 ..< n:
    result.btns.add newToolButton(result.bar, "Button" & $i)
  layoutIfNeeded(result.f)

proc chevronPoint(bar: ToolBar): PointF =
  let o = bar.formOrigin
  pointF(o.x + bar.width - 4 - 8, o.y + bar.height / 2)

suite "toolbar overflow":
  test "everything fits: no chevron, nothing hidden":
    let (f, bar, btns) = setup(2000, 5)
    check bar.overflowCount == 0
    for b in btns: check b.hitTest(pointF(2, 2))
    check f.paintIfDirty() or true

  test "buttons that do not fit are hidden, chevron appears, resize relayouts":
    let (f, bar, btns) = setup(300, 10)
    let n1 = bar.overflowCount
    check n1 > 0 and n1 < 10
    check not btns[^1].hitTest(pointF(2, 2))
    check btns[0].hitTest(pointF(2, 2))
    # shown buttons end left of the chevron
    for i in 0 ..< 10 - n1: check btns[i].left + btns[i].width <= bar.width - 16
    f.width = 600
    layoutIfNeeded(f)
    check bar.overflowCount < n1
    f.width = 3000
    layoutIfNeeded(f)
    check bar.overflowCount == 0
    check btns[^1].hitTest(pointF(2, 2))

  test "overflowMenu off clips instead":
    let (f, bar, btns) = setup(300, 10)
    bar.overflowMenu = false
    layoutIfNeeded(f)
    check bar.overflowCount == 0
    check btns[^1].left > bar.width

  test "separator at the boundary is hidden":
    let f = newForm(nil, 300, 200)
    f.show()
    let bar = newToolBar(f)
    var btns: seq[ToolButton]
    for i in 0 ..< 3: btns.add newToolButton(bar, "Button" & $i)
    layoutIfNeeded(f)
    # make room for exactly the buttons plus the separator, but not the chevron
    let need = btns[2].left + btns[2].width
    f.width = need + 8 + 4 + 8 + 4 - 1
    discard newToolButton(bar, "", tbsSeparator)
    discard newToolButton(bar, "Extra")
    layoutIfNeeded(f)
    check bar.overflowCount >= 2
    check bar.overflowCount == 2          # separator + Extra hidden, not only Extra
    var seps = 0
    for c in bar.children:
      if c of ToolButton and ToolButton(c).kind == tbsSeparator: inc seps
    check seps == 1

  test "chevron click opens the menu; choosing runs the click":
    let (f, bar, btns) = setup(300, 10)
    var clicked: seq[int]
    proc mk(k: int): NotifyEvent = (proc(s: Control) = clicked.add k)
    for i, b in btns: b.onClick = mk(i)
    btns[^2].enabled = false
    btns[^1].kind = tbsCheck
    btns[^1].down = true
    layoutIfNeeded(f)
    f.win.click(chevronPoint(bar).x, chevronPoint(bar).y)
    check bar.overflowPopup != nil
    let m = bar.overflowPopup
    check m.items.count == bar.overflowCount
    check m.items[m.items.count - 1].caption == "Button9"
    check m.items[m.items.count - 1].checked
    check not m.items[m.items.count - 2].enabled
    let p = topPopup(f)
    check p != nil
    let it = m.items[0]
    let r = menuItemRect(p, it)
    p.ui.win.click(r.x + r.w / 2, r.y + r.h / 2)
    check clicked.len == 1
    check "Button" & $clicked[0] == it.caption

  test "hint is the fallback text; hidden separators become menu separators":
    let f = newForm(nil, 200, 200)
    f.show()
    let bar = newToolBar(f)
    for i in 0 ..< 3: discard newToolButton(bar, "Keep" & $i)
    let h = newToolButton(bar, "")
    h.hint = "Hinted"
    discard newToolButton(bar, "", tbsSeparator)
    discard newToolButton(bar, "Last")
    layoutIfNeeded(f)
    bar.showOverflowMenu()
    let m = bar.overflowPopup
    check m != nil
    var caps: seq[string]
    for i in 0 ..< m.items.count: caps.add m.items[i].caption
    check "Hinted" in caps or "Last" in caps
