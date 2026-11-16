## Popup windows. Headless: SDL's offscreen driver cannot create popup windows
## (SDL_CreatePopupWindow fails), so PopupWindow runs on its fallback, a
## borderless top-level window at the same place; all logic is the same.
## Events are built by hand and fed through Application.dispatch.

import std/[unittest, os]
import nimvcl
import nimvcl/core/popup

type
  Probe = ref object of Container
    log: seq[string]

method doKeyDown(p: Probe, key: var Key, s: ShiftState) =
  p.log.add "key:" & $key
  if key == keyDown: key = Key(0)       # used; Esc is left for the popup
method doMouseDown(p: Probe, b: MouseButton, s: ShiftState, x, y: float32) =
  p.log.add "down:" & $int(x) & "," & $int(y)
  procCall doMouseDown(Container(p), b, s, x, y)
method doMouseUp(p: Probe, b: MouseButton, s: ShiftState, x, y: float32) =
  p.log.add "up"
  procCall doMouseUp(Container(p), b, s, x, y)

proc newProbe(w = 100'f32, h = 60'f32): Probe =
  new result
  result.initContainer()
  result.setBounds(0, 0, w, h)

proc ev(win: PlatformWindow, kind: EventKind, x = 0'f32, y = 0'f32,
        k = Key(0), button = mbLeft): PlatformEvent =
  PlatformEvent(kind: kind, windowId: win.id, x: x, y: y, key: k, button: button,
                clicks: 1)
proc mouse(f: Form, kind: EventKind, x, y: float32) =
  Application.dispatch(ev(f.win, kind, x, y))
proc click(f: Form, x, y: float32) = f.mouse(ekMouseDown, x, y); f.mouse(ekMouseUp, x, y)
proc key(win: PlatformWindow, k: Key) =
  Application.dispatch(ev(win, ekKeyDown, k = k))
  Application.dispatch(ev(win, ekKeyUp, k = k))

template queued(body: untyped) =
  Application.queue(proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      body)

suite "placement":
  const screen = rectF(0, 0, 800, 600)
  test "below, flips above, slides":
    check placePopup(rectF(10, 10, 50, 20), sizeF(100, 80), screen, plBelow) == rectF(10, 30, 100, 80)
    check placePopup(rectF(10, 560, 50, 20), sizeF(100, 80), screen, plBelow).y == 480
    check placePopup(rectF(750, 10, 40, 20), sizeF(100, 80), screen, plBelow).x == 700
    # neither side fits: stays on the preferred side and slides in
    check placePopup(rectF(10, 100, 50, 20), sizeF(100, 700), screen, plBelow).y == 0
  test "right flips left":
    check placePopup(rectF(100, 50, 60, 20), sizeF(100, 80), screen, plRight) == rectF(160, 50, 100, 80)
    let r = placePopup(rectF(700, 50, 80, 20), sizeF(100, 80), screen, plRight)
    check r.x == 600 and r.y == 50
    check placePopup(rectF(100, 590, 60, 20), sizeF(100, 80), screen, plRight).y == 520
  test "above and left; unconstrained":
    check placePopup(rectF(10, 300, 50, 20), sizeF(100, 80), screen, plAbove).y == 220
    check placePopup(rectF(10, 20, 50, 20), sizeF(100, 80), screen, plAbove).y == 40
    check placePopup(rectF(300, 10, 50, 20), sizeF(100, 80), rectF(0, 0, 0, 0), plLeft).x == 200
    check placePopup(rectF(-50, -50, 5, 5), sizeF(10, 10), rectF(0, 0, 0, 0), plBelow) == rectF(-50, -45, 10, 10)

suite "popup windows":
  setup:
    Application.init()
    Application.forceScale = 0
    popupFocusGrace = 0
    focusIdProc = proc(): uint32 = 0
  teardown:
    closeAllPopups(nil)
    for f in openForms(): f.freeWindow()

  proc newShown(): Form =
    result = newForm(nil, 400, 300)
    result.show()

  test "showPopup creates a window, paints, close frees it":
    let f = newShown()
    let c = newProbe(120, 70)
    let p = showPopup(f, c, rectF(50, 60, 0, 0))
    check p.isOpen and p.ui.win != nil and p.ui.win.id != f.win.id
    check findPopup(p.ui.win.id) == p
    check popupOwnerOf(p.ui.win.id) == f
    check p.bounds == rectF(50, 60, 120, 70)
    check p.ui.win.popup
    check c.width == 120 and c.host == RootHost(p.ui)
    var closed = 0
    p.onClosed = proc(q: PopupWindow) = inc closed
    let ctx = p.ui.ctx
    closePopup(p)
    check not p.isOpen and closed == 1 and ctx.isClosed
    closePopup(p)                       # idempotent
    check closed == 1

  test "showPopup needs a shown owner":
    let f = newForm(nil, 100, 100)
    expect ValueError: discard showPopup(f, newProbe(), rectF(0, 0, 0, 0))

  test "mouse events go to the popup in its own coordinates":
    let f = newShown()
    let c = newProbe()
    let p = showPopup(f, c, rectF(50, 60, 0, 0))
    Application.dispatch(ev(p.ui.win, ekMouseDown, 10, 20))
    Application.dispatch(ev(p.ui.win, ekMouseUp, 10, 20))
    check c.log == @["down:10,20", "up"]
    check p.isOpen

  test "outside click closes the chain and is swallowed":
    let f = newShown()
    var clicks = 0
    let b = newButton(f, "B", 10, 10, 80, 28)
    b.onClick = proc(s: Control) = inc clicks
    let a = showPopup(f, newProbe(), rectF(200, 100, 0, 0))
    let c = showPopup(f, newProbe(), rectF(300, 100, 0, 0), plRight, pkMenu, a)
    check menuChain(f).len == 2 and topPopup(f) == c
    f.click(20, 20)                     # on the button
    check clicks == 0
    check menuChain(f).len == 0 and not a.isOpen and not c.isOpen
    f.click(20, 20)
    check clicks == 1                   # works again

  test "the release after a swallowed press does not leave capture behind":
    let f = newShown()
    var ups = 0
    let b = newButton(f, "B", 10, 10, 80, 28)
    b.onMouseUp = proc(s: Control, bt: MouseButton, sh: ShiftState, x, y: float32) = inc ups
    # press on the button, popup opens meanwhile (as MainMenu does), then release
    f.mouse(ekMouseDown, 20, 20)
    let a = showPopup(f, newProbe(), rectF(200, 100, 0, 0))
    f.mouse(ekMouseUp, 20, 20)
    check ups == 1 and a.isOpen
    check f.ui.captured == nil

  test "a click in a window of the chain keeps it open":
    let f = newShown()
    let a = showPopup(f, newProbe(), rectF(200, 100, 0, 0))
    let c = newProbe()
    let b = showPopup(f, c, rectF(300, 100, 0, 0), plRight, pkMenu, a)
    Application.dispatch(ev(a.ui.win, ekMouseDown, 5, 5))
    Application.dispatch(ev(a.ui.win, ekMouseUp, 5, 5))
    check a.isOpen and b.isOpen

  test "a new root popup replaces the chain; a child closes the ones above":
    let f = newShown()
    let a = showPopup(f, newProbe(), rectF(100, 100, 0, 0))
    let b = showPopup(f, newProbe(), rectF(200, 100, 0, 0), plRight, pkMenu, a)
    let c = showPopup(f, newProbe(), rectF(300, 100, 0, 0), plRight, pkMenu, b)
    check menuChain(f).len == 3
    let d = showPopup(f, newProbe(), rectF(300, 150, 0, 0), plRight, pkMenu, a)
    check not b.isOpen and not c.isOpen and menuChain(f) == @[a, d]
    let e = showPopup(f, newProbe(), rectF(10, 100, 0, 0))
    check not a.isOpen and not d.isOpen and menuChain(f) == @[e]

  test "Esc closes the topmost popup only (key sent to the owner or to a popup)":
    let f = newShown()
    let a = showPopup(f, newProbe(), rectF(100, 100, 0, 0))
    let b = showPopup(f, newProbe(), rectF(200, 100, 0, 0), plRight, pkMenu, a)
    f.win.key(keyEscape)                # X11 style: the owner has the focus
    check a.isOpen and not b.isOpen
    a.ui.win.key(keyEscape)             # Wayland style: the popup has it
    check not a.isOpen
    check menuChain(f).len == 0

  test "keys go to the topmost popup first, then not to the form":
    let f = newShown()
    var formKeys = 0
    let e = newButton(f, "x", 10, 10, 80, 28)
    e.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) = inc formKeys
    f.activeControl = e
    let ca = newProbe()
    let cb = newProbe()
    let a = showPopup(f, ca, rectF(100, 100, 0, 0))
    discard showPopup(f, cb, rectF(200, 100, 0, 0), plRight, pkMenu, a)
    f.win.key(keyDown)
    check cb.log == @["key:Down"] and ca.log.len == 0 and formKeys == 0
    closePopup(topPopup(f))
    f.win.key(keyDown)
    check ca.log == @["key:Down"] and formKeys == 0
    closeAllPopups(f)
    f.win.key(keyDown)
    check formKeys == 1

  test "owner losing focus closes the popups, unless the focus is within the group":
    let f = newShown()
    let a = showPopup(f, newProbe(), rectF(100, 100, 0, 0))
    focusIdProc = proc(): uint32 = a.ui.win.id
    Application.dispatch(ev(f.win, ekWindowFocusLost))
    check a.isOpen
    focusIdProc = proc(): uint32 = f.win.id
    Application.dispatch(ev(a.ui.win, ekWindowFocusLost))
    check a.isOpen
    focusIdProc = proc(): uint32 = 0
    Application.dispatch(ev(f.win, ekWindowFocusLost))
    check not a.isOpen

  test "hiding or freeing the owner closes its popups":
    let f = newShown()
    let a = showPopup(f, newProbe(), rectF(100, 100, 0, 0))
    f.hide()
    check not a.isOpen
    f.show()
    let b = showPopup(f, newProbe(), rectF(100, 100, 0, 0))
    f.freeWindow()
    check not b.isOpen

  test "tooltips are outside the chain and take no input":
    let f = newShown()
    let a = showPopup(f, newProbe(), rectF(100, 100, 0, 0))
    let t = showPopup(f, newProbe(), rectF(10, 10, 0, 0), plBelow, pkTooltip)
    check menuChain(f) == @[a] and tooltipOf(f) == t
    Application.dispatch(ev(t.ui.win, ekMouseDown, 3, 3))
    check a.isOpen and t.isOpen
    let t2 = showPopup(f, newProbe(), rectF(10, 10, 0, 0), plBelow, pkTooltip)
    check not t.isOpen and t2.isOpen and a.isOpen   # a new tooltip replaces the old
    closeAllPopups(f)
    check not t2.isOpen

  test "popups paint when dirty":
    let f = newShown()
    let c = newProbe()
    let p = showPopup(f, c, rectF(100, 100, 0, 0))
    check not p.ui.needsPaint
    c.invalidate()
    check p.ui.needsPaint
    Application.paintForms()
    check not p.ui.needsPaint

  test "modal form: its popup works, the form below is gated and loses its popups":
    let main = newShown()
    let below = showPopup(main, newProbe(), rectF(10, 10, 0, 0))
    let m = newForm(nil, 300, 200)
    var inside, belowOpen, outsideClosed, mainGated = false
    queued:
      belowOpen = below.isOpen
      let c = newProbe()
      let p = showPopup(m, c, rectF(20, 20, 0, 0))
      Application.dispatch(ev(p.ui.win, ekMouseDown, 5, 5))
      Application.dispatch(ev(p.ui.win, ekMouseUp, 5, 5))
      inside = c.log == @["down:5,5", "up"]
      m.win.key(keyEscape)
      outsideClosed = not p.isOpen
      let p2 = showPopup(m, newProbe(), rectF(20, 20, 0, 0))
      m.click(200, 150)
      outsideClosed = outsideClosed and not p2.isOpen
      let gc = newProbe()
      let g = showPopup(main, gc, rectF(20, 20, 0, 0))
      Application.dispatch(ev(g.ui.win, ekMouseDown, 5, 5))
      mainGated = gc.log.len == 0
      m.modalResult = mrOk
    check m.showModal() == mrOk
    check mainGated
    check inside and outsideClosed and not belowOpen
    check menuChain(m).len == 0

suite "popups leave the owner window alone":
  ## Opening and closing a drop-down or a context menu (a separate window, a
  ## borderless top-level one on the offscreen driver) must not change the
  ## owner's window size, logical size or what a screenshot shows.

  proc shotBytes(f: Form, full: bool): string =
    let path = getTempDir() / "nimvcl_popup_shot.bmp"
    doAssert f.screenshot(path, full)
    result = readFile(path)
    removeFile path

  proc sizes(f: Form): string =
    $f.win.pointSize & $f.win.pixelSize & $f.win.logicalSize & $f.width & "x" & $f.height

  test "ComboBox drop-down and PopupMenu: size and image unchanged":
    let f = newForm(nil, 1200, 800)
    let cb = newComboBox(f, csDropDownList, 10, 10, 200, 28)
    cb.items = ["one", "two", "three"]
    cb.itemIndex = 1
    let pm = newPopupMenu(f)
    pm.addItem("Copy")
    pm.addItem("Paste")
    f.show()
    Application.processMessages()
    let before = sizes(f)
    let ref0 = shotBytes(f, full = true)
    cb.dropDown()
    Application.processMessages()
    check sizes(f) == before
    cb.closeUp()
    Application.processMessages()
    check sizes(f) == before
    check shotBytes(f, full = false) == ref0      # partial path
    pm.popup(f, 300, 300)
    Application.processMessages()
    check sizes(f) == before
    closeAllPopups(f)
    Application.processMessages()
    check sizes(f) == before
    check shotBytes(f, full = false) == ref0
    check shotBytes(f, full = true) == ref0

  test "two screenshots of a 1200x800 form in a row are equal and unclipped":
    let f = newForm(nil, 1200, 800)
    newButton(f, "far corner", 1000, 700, 150, 40)
    f.show()
    let a = shotBytes(f, full = false)
    let b = shotBytes(f, full = false)
    check f.win.pixelSize == (1200, 800)
    check a == b
    check b == shotBytes(f, full = true)
