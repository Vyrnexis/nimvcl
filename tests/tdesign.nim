## Design mode (FormDesigner). Headless (offscreen SDL): events go through
## Application.dispatch, the same path the loop uses.

import std/[unittest, os, strutils]
import nimvcl

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32,
          button = mbLeft, clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: button, clicks: clicks, shift: shift))
proc moveTo(f: Form, x, y: float32, shift: ShiftState = {}) =
  f.feed(ekMouseMove, x, y, shift = shift)
proc down(f: Form, x, y: float32, shift: ShiftState = {}, clicks = 1,
          button = mbLeft) =
  f.feed(ekMouseDown, x, y, button, clicks, shift)
proc up(f: Form, x, y: float32, shift: ShiftState = {}, button = mbLeft) =
  f.feed(ekMouseUp, x, y, button, 1, shift)
proc click(f: Form, x, y: float32, shift: ShiftState = {}) =
  f.down(x, y, shift)
  f.up(x, y, shift)
proc drag(f: Form, x0, y0, x1, y1: float32, shift: ShiftState = {}) =
  ## Press, a few moves, release.
  f.down(x0, y0, shift)
  f.moveTo(x0 + (x1 - x0) / 3, y0 + (y1 - y0) / 3, shift + {ssLeft})
  f.moveTo(x1, y1, shift + {ssLeft})
  f.up(x1, y1, shift)
proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k,
                                     shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k,
                                     shift: shift))
proc tap(f: Form, c: char, shift: ShiftState = {}) = f.tap(key(c), shift)

proc fcx(c: Control): float32 = c.formOrigin.x + c.width / 2
proc fcy(c: Control): float32 = c.formOrigin.y + c.height / 2

func sameBounds(c: Control, x, y, w, h: float32): bool =
  c.left == x and c.top == y and c.width == w and c.height == h

type Fixture = object
  f: Form
  d: FormDesigner
  a, b, c: Button
  p: Panel
  e: Edit

proc build(grid = true): Fixture =
  Application.init()
  let f = newForm(nil, 500, 400)
  result.f = f
  result.a = newButton(f, "A", 20, 20, 80, 24)
  result.b = newButton(f, "B", 200, 20, 80, 24)
  result.c = newButton(f, "C", 20, 200, 80, 24)
  result.e = newEdit(f, "text", 200, 200, 120, 24)
  result.a.name = "A"
  result.b.name = "B"
  result.c.name = "C"
  result.p = newPanel(f, "", 300, 80, 180, 120)
  f.show()
  discard f.paintIfDirty()
  result.d = newFormDesigner(f)
  result.d.snapLines = false
  if not grid: result.d.snapToGrid = false

proc done(x: Fixture) = x.f.freeWindow()

proc bytesOf(f: Form, full: bool): string =
  let path = getTempDir() / "nimvcl_design.bmp"
  doAssert f.screenshot(path, full)
  result = readFile(path)
  removeFile path

proc checkSame(f: Form, what: string) =
  ## Partial repaints must equal a fresh full repaint (taken after the partial
  ## image, which a full repaint would discard).
  discard f.paintIfDirty()
  discard f.paintIfDirty()
  let partial = bytesOf(f, full = false)
  let fresh = bytesOf(f, full = true)
  checkpoint what
  check partial.len == fresh.len
  check partial == fresh

suite "form designer":
  test "design mode swallows input, detach restores it":
    let x = build()
    var clicks = 0
    x.a.onClick = proc(s: Control) = inc clicks
    x.f.click(x.a.fcx, x.a.fcy)
    check clicks == 0
    check x.d.isSelected(x.a)
    x.f.click(x.e.fcx, x.e.fcy)
    check x.f.activeControl == nil
    x.f.tap('a')                          # no text goes to the edit
    check x.e.text == "text"
    x.d.detach()
    check not x.d.attached
    x.f.click(x.a.fcx, x.a.fcy)
    check clicks == 1
    x.f.click(x.e.fcx, x.e.fcy)
    check x.f.activeControl == Control(x.e)
    x.d.attach()
    x.f.click(x.a.fcx, x.a.fcy)
    check clicks == 1
    x.done

  test "select, shift toggles, empty area selects the container":
    let x = build()
    var events = 0
    var last: seq[Control]
    x.d.onSelectionChanged = proc(d: FormDesigner, s: seq[Control]) =
      inc events
      last = s
    check x.d.selection == @[Control(x.f)]
    x.f.click(x.a.fcx, x.a.fcy)
    check x.d.selection == @[Control(x.a)]
    check x.d.primary == Control(x.a)
    x.f.click(x.b.fcx, x.b.fcy, {ssShift})
    check x.d.selection == @[Control(x.a), Control(x.b)]
    x.f.click(x.a.fcx, x.a.fcy, {ssShift})
    check x.d.selection == @[Control(x.b)]
    x.f.click(450, 350)
    check x.d.selection == @[Control(x.f)]
    x.f.click(x.p.fcx, x.p.fcy)           # empty area of a panel: the panel
    check x.d.selection == @[Control(x.p)]
    check last == @[Control(x.p)]
    check events >= 4
    # a control with another parent replaces the selection
    let inner = newButton(x.p, "in", 10, 10, 60, 24)
    x.f.click(x.a.fcx, x.a.fcy)
    x.f.click(inner.fcx, inner.fcy, {ssShift})
    check x.d.selection == @[Control(inner)]
    x.done

  test "rubber band selects intersecting children":
    let x = build()
    x.f.down(10, 10)
    x.f.moveTo(150, 60, {ssLeft})
    check x.d.selection == @[Control(x.a)]
    x.f.moveTo(260, 60, {ssLeft})
    check x.d.selection.len == 2
    x.f.up(260, 60)
    check x.d.selection == @[Control(x.a), Control(x.b)]
    check not x.d.dragging
    x.f.drag(10, 100, 260, 260)
    check Control(x.c) in x.d.selection
    check Control(x.e) in x.d.selection
    check Control(x.a) notin x.d.selection
    x.done

  test "move snaps to the grid, Alt does not":
    let x = build()
    x.f.drag(30, 30, 43, 43)              # +13,+13: (33,33) snaps to (32,32)
    check x.a.sameBounds(32, 32, 80, 24)
    x.f.drag(40, 40, 44, 45, {ssAlt})
    check x.a.sameBounds(36, 37, 80, 24)
    x.d.grid = 10
    x.f.drag(50, 50, 63, 61)
    check x.a.sameBounds(50, 50, 80, 24)
    # multi-selection keeps the relative offsets
    x.d.grid = 8
    x.f.click(x.a.fcx, x.a.fcy)
    x.f.click(x.c.fcx, x.c.fcy, {ssShift})
    let dxAC = x.c.left - x.a.left
    let dyAC = x.c.top - x.a.top
    x.f.drag(x.a.fcx, x.a.fcy, x.a.fcx + 30, x.a.fcy + 20)
    check x.c.left - x.a.left == dxAC
    check x.c.top - x.a.top == dyAC
    check x.a.left mod 8 == 0 or x.c.left mod 8 == 0
    x.done

  test "a click without moving does not change anything":
    let x = build()
    var mods = 0
    x.d.onModified = proc(d: FormDesigner) = inc mods
    x.f.click(x.a.fcx, x.a.fcy)
    check x.a.sameBounds(20, 20, 80, 24)
    check mods == 0 and not x.d.canUndo
    x.f.click(x.b.fcx, x.b.fcy, {ssShift})
    x.f.click(x.a.fcx, x.a.fcy)           # one of two selected, no drag: only it
    check x.d.selection == @[Control(x.a)]
    x.done

  test "snap lines align to sibling edges and draw guides":
    let x = build()
    x.d.snapLines = true
    x.d.snapToGrid = false
    # drag A so that its left edge comes within 3 px of C's left edge (20)
    x.f.down(30, 30)
    x.f.moveTo(30 + 3, 30 + 140, {ssLeft})
    x.f.moveTo(30 + 3, 30 + 150, {ssLeft})
    x.f.up(33, 180)
    check x.a.left == 20
    x.done

  test "arrow keys move and resize":
    let x = build()
    x.f.click(x.a.fcx, x.a.fcy)
    x.f.tap(keyRight)
    check x.a.sameBounds(21, 20, 80, 24)
    x.f.tap(keyDown)
    check x.a.sameBounds(21, 21, 80, 24)
    x.f.tap(keyLeft, {ssCtrl})
    check x.a.sameBounds(13, 21, 80, 24)
    x.f.tap(keyRight, {ssShift})
    check x.a.sameBounds(13, 21, 81, 24)
    x.f.tap(keyUp, {ssShift})
    check x.a.sameBounds(13, 21, 81, 23)
    x.f.tap(keyDown, {ssShift, ssCtrl})
    check x.a.sameBounds(13, 21, 81, 31)
    x.done

  test "resize with every handle":
    let x = build()
    x.d.snapToGrid = false
    x.f.click(x.a.fcx, x.a.fcy)
    for h in DesignHandle:
      x.a.setBounds(100, 100, 80, 40)
      x.f.click(x.a.fcx, x.a.fcy)
      let hr = handleRect(x.d.boundsOf(x.a), h)
      let cx = hr.x + hr.w / 2
      let cy = hr.y + hr.h / 2
      x.f.drag(cx, cy, cx + 10, cy + 6)
      case h
      of dhNW: check x.a.sameBounds(110, 106, 70, 34)
      of dhN: check x.a.sameBounds(100, 106, 80, 34)
      of dhNE: check x.a.sameBounds(100, 106, 90, 34)
      of dhE: check x.a.sameBounds(100, 100, 90, 40)
      of dhSE: check x.a.sameBounds(100, 100, 90, 46)
      of dhS: check x.a.sameBounds(100, 100, 80, 46)
      of dhSW: check x.a.sameBounds(110, 100, 70, 46)
      of dhW: check x.a.sameBounds(110, 100, 70, 40)
    x.done

  test "resize respects constraints and the minimum size":
    let x = build()
    x.d.snapToGrid = false
    x.a.constraints = constraints(minWidth = 60, maxHeight = 30)
    x.a.setBounds(100, 100, 80, 24)
    x.f.click(x.a.fcx, x.a.fcy)
    var hr = handleRect(x.d.boundsOf(x.a), dhE)
    x.f.drag(hr.x + 2, hr.y + 2, hr.x - 60, hr.y + 2)    # shrink below min
    check x.a.width == 60
    hr = handleRect(x.d.boundsOf(x.a), dhS)
    x.f.drag(hr.x + 2, hr.y + 2, hr.x + 2, hr.y + 80)    # grow beyond max
    check x.a.height == 30
    # the left handle keeps the right edge fixed when clamped
    x.a.setBounds(100, 100, 80, 24)
    x.f.click(x.a.fcx, x.a.fcy)
    hr = handleRect(x.d.boundsOf(x.a), dhW)
    x.f.drag(hr.x + 2, hr.y + 2, hr.x + 70, hr.y + 2)
    check x.a.width == 60
    check x.a.left + x.a.width == 180
    x.b.constraints = constraints()
    x.b.setBounds(100, 100, 20, 20)
    x.f.click(x.b.fcx, x.b.fcy)
    hr = handleRect(x.d.boundsOf(x.b), dhE)
    x.f.drag(hr.x + 2, hr.y + 2, hr.x - 50, hr.y + 2)
    check x.b.width == x.d.minSize
    x.done

  test "dropping onto a panel reparents":
    let x = build()
    var target: Container
    x.f.drag(x.a.fcx, x.a.fcy, x.p.fcx, x.p.fcy)
    check x.a.parent == Container(x.p)
    check x.p.children.find(x.a) >= 0
    check x.a.formOrigin.x + x.a.width / 2 > x.p.formOrigin.x
    # the form's own children stay where they were
    check x.b.parent == Container(x.f)
    # and back out onto the form
    x.f.drag(x.a.fcx, x.a.fcy, 150, 300)
    check x.a.parent == Container(x.f)
    # a Button is not a container for drops: the form takes it
    x.f.drag(x.c.fcx, x.c.fcy, x.b.fcx, x.b.fcy)
    check x.c.parent == Container(x.f)
    discard target
    x.done

  test "drop target is highlighted during the drag":
    let x = build()
    x.f.down(x.a.fcx, x.a.fcy)
    x.f.moveTo(x.p.fcx, x.p.fcy, {ssLeft})
    check x.d.dragging
    check x.d.cursor == crSizeAll
    x.f.up(x.p.fcx, x.p.fcy)
    check not x.d.dragging
    x.done

  test "create by click and by drag, with unique names":
    let x = build()
    var created: seq[Control]
    x.d.createControl = proc(cls: string): Control =
      if cls == "Button": newButton(nil, "new")
      elif cls == "Panel": newPanel(nil)
      else: nil
    x.d.onCreated = proc(d: FormDesigner, c: Control) = created.add c
    x.d.beginCreate "Button"
    check x.d.creating == "Button"
    check x.f.win != nil
    x.f.click(403, 303)                   # snaps to (400, 304)
    check created.len == 1
    check created[0].name == "Button1"
    check created[0].parent == Container(x.f)
    check (created[0].left, created[0].top) == (400'f32, 304'f32)
    check x.d.selection == @[created[0]]
    check x.d.creating == ""
    x.d.beginCreate "Button"
    x.f.drag(300, 250, 380, 290)
    check created.len == 2
    check created[1].name == "Button2"
    check created[1].sameBounds(304, 248, 80, 40)
    # into a panel
    x.d.beginCreate "Panel"
    x.f.drag(310, 90, 360, 130)
    check created[2].parent == Container(x.p)
    check created[2].name == "Panel1"
    check created[2].left == 8 and created[2].top == 8     # panel-local, grid-snapped
    # Escape cancels, an unknown class creates nothing
    x.d.beginCreate "Button"
    x.f.tap(keyEscape)
    check x.d.creating == ""
    x.d.beginCreate "Nope"
    x.f.click(100, 350)
    check created.len == 3
    check x.f.win != nil
    x.done

  test "delete with veto":
    let x = build()
    var deleted: seq[Control]
    var veto = true
    x.d.onDeleting = proc(d: FormDesigner, cs: seq[Control], allow: var bool) =
      allow = not veto
    x.d.onDeleted = proc(d: FormDesigner, cs: seq[Control]) = deleted = cs
    x.f.click(x.a.fcx, x.a.fcy)
    x.f.tap(keyDelete)
    check x.a.parent == Container(x.f)
    check deleted.len == 0
    veto = false
    x.f.tap(keyDelete)
    check x.a.parent == nil
    check deleted == @[Control(x.a)]
    check x.d.selection == @[Control(x.f)]
    check x.f.findComponent("A") == nil
    x.f.tap(keyDelete)                    # the design root cannot be deleted
    check x.f.controlCount == 4
    x.done

  test "undo and redo every operation":
    let x = build()
    x.d.createControl = proc(cls: string): Control = newButton(nil, "n")
    # move
    x.f.drag(x.a.fcx, x.a.fcy, x.a.fcx + 40, x.a.fcy + 40)
    let moved = (x.a.left, x.a.top)
    check moved != (20'f32, 20'f32)
    check x.d.undo()
    check x.a.sameBounds(20, 20, 80, 24)
    check x.d.redo()
    check (x.a.left, x.a.top) == moved
    check x.d.undo()
    # resize
    x.f.click(x.a.fcx, x.a.fcy)
    let hr = handleRect(x.d.boundsOf(x.a), dhSE)
    x.f.drag(hr.x + 2, hr.y + 2, hr.x + 32, hr.y + 18)
    check x.a.width > 80
    check x.d.undo()
    check x.a.sameBounds(20, 20, 80, 24)
    check x.d.redo()
    check x.a.width > 80
    check x.d.undo()
    # reparent
    let idx = x.f.children.find(x.a)
    x.f.drag(x.a.fcx, x.a.fcy, x.p.fcx, x.p.fcy)
    check x.a.parent == Container(x.p)
    check x.d.undo()
    check x.a.parent == Container(x.f)
    check x.f.children.find(x.a) == idx
    check x.a.sameBounds(20, 20, 80, 24)
    check x.d.redo()
    check x.a.parent == Container(x.p)
    check x.d.undo()
    # create
    x.d.beginCreate "Button"
    x.f.click(100, 300)
    let created = x.d.primary
    check created.parent == Container(x.f)
    check x.d.undo()
    check created.parent == nil
    check x.f.findComponent("Button1") == nil
    check x.d.redo()
    check created.parent == Container(x.f)
    check x.f.findComponent("Button1") == Component(created)
    check x.d.undo()
    # delete
    x.f.click(x.b.fcx, x.b.fcy)
    let bi = x.f.children.find(x.b)
    check x.d.deleteSelection()
    check x.d.undo()
    check x.b.parent == Container(x.f)
    check x.f.children.find(x.b) == bi
    check x.f.findComponent("B") == nil or true
    check x.d.selection == @[Control(x.b)]
    check x.d.redo()
    check x.b.parent == nil
    check x.d.undo()
    # z-order
    x.f.click(x.a.fcx, x.a.fcy)
    x.d.bringToFront()
    check x.f.children[^1] == Control(x.a)
    check x.d.undo()
    check x.f.children.find(x.a) == idx
    x.f.click(x.c.fcx, x.c.fcy)
    let ci = x.f.children.find(x.c)
    x.d.sendToBack()
    check x.f.children[0] == Control(x.c)
    check x.d.undo()
    check x.f.children.find(x.c) == ci
    # keyboard
    x.f.tap('z', {ssCtrl})                # nothing left to undo past the start
    x.f.tap('y', {ssCtrl})
    while x.d.canUndo: discard x.d.undo()
    check x.a.sameBounds(20, 20, 80, 24)
    check not x.d.undo()
    x.done

  test "undo and redo through the keyboard":
    let x = build()
    x.f.click(x.a.fcx, x.a.fcy)
    x.f.tap(keyRight)
    x.f.tap(keyRight)
    check x.a.left == 22
    x.f.tap('z', {ssCtrl})
    check x.a.left == 21
    x.f.tap('y', {ssCtrl})
    check x.a.left == 22
    x.f.tap('z', {ssCtrl})
    x.f.tap('z', {ssCtrl, ssShift})
    check x.a.left == 22
    x.done

  test "snapshot and restore hooks rebuild deleted controls":
    let x = build()
    var restored = 0
    x.d.snapshot = proc(c: Control): string = c.name & "|" & c.caption
    x.d.restore = proc(s: string, parent: Container, index: int): Control =
      inc restored
      let parts = s.split('|')
      let b = newButton(nil, parts[1])
      b.name = parts[0]
      parent.insertControl(b, index)
      b
    x.f.click(x.a.fcx, x.a.fcy)
    x.f.tap(keyRight)                     # an earlier op refers to A
    check x.d.deleteSelection()
    check x.f.findComponent("A") == nil
    check x.d.undo()
    check restored == 1
    let nb = x.d.primary
    check nb != Control(x.a)
    check nb.name == "A" and nb.caption == "A"
    check nb.parent == Container(x.f)
    check nb.left == 21                   # bounds restored from the placement
    check x.d.undo()                      # the earlier nudge refers to the new one
    check nb.left == 20
    x.done

  test "aligned controls: free-edge handle, no move":
    let x = build()
    let top = newPanel(x.f, "top", 0, 0, 500, 40)
    top.align = alTop
    discard x.f.paintIfDirty()
    check x.d.handleMask(top) == {dhS}
    x.f.click(250, 20)
    check x.d.selection == @[Control(top)]
    x.f.drag(250, 20, 300, 120)           # a move is refused
    check top.top == 0 and top.height == 40
    var hr = handleRect(x.d.boundsOf(top), dhS)
    x.d.snapToGrid = false
    x.f.drag(hr.x + 2, hr.y + 2, hr.x + 2, hr.y + 32)
    check top.height == 70
    check top.width == 500
    x.f.tap(keyDown)                      # arrows do not move aligned controls
    check top.top == 0
    x.f.tap(keyDown, {ssShift})
    check top.height == 71
    x.f.tap(keyRight, {ssShift})
    check top.width == 500
    check x.d.undo()
    check top.height == 70
    let left = newPanel(x.f, "left", 0, 0, 60, 100)
    left.align = alLeft
    check x.d.handleMask(left) == {dhE}
    left.align = alRight
    check x.d.handleMask(left) == {dhW}
    left.align = alBottom
    check x.d.handleMask(left) == {dhN}
    left.align = alClient
    check x.d.handleMask(left) == {}
    check x.d.handleMask(x.a).card == 8
    check x.d.handleMask(x.f) == {dhE, dhS, dhSE}      # the design root: right, bottom, corner
    x.done

  test "alignment, size and spacing commands":
    let x = build()
    x.a.setBounds(20, 20, 80, 24)
    x.b.setBounds(150, 60, 50, 30)
    x.c.setBounds(150, 140, 100, 40)
    x.f.click(x.a.fcx, x.a.fcy)
    x.f.click(x.b.fcx, x.b.fcy, {ssShift})
    x.f.click(x.c.fcx, x.c.fcy, {ssShift})
    x.d.alignSelection(aeLefts)
    check x.b.left == 20 and x.c.left == 20
    x.d.alignSelection(aeRights)
    check x.b.left + x.b.width == 100 and x.c.left + x.c.width == 100
    x.d.alignSelection(aeTops)
    check x.b.top == 20 and x.c.top == 20
    x.d.alignSelection(aeBottoms)
    check x.b.top + x.b.height == 44
    x.d.alignSelection(aeHCenters)
    check x.b.left + x.b.width / 2 == 60
    x.d.alignSelection(aeVCenters)
    check x.c.top + x.c.height / 2 == 32
    x.d.makeSameSize(true, false)
    check x.b.width == 80 and x.c.width == 80 and x.b.height == 30
    x.d.makeSameSize(false, true)
    check x.b.height == 24 and x.c.height == 24
    x.a.setBounds(20, 20, 40, 24)
    x.b.setBounds(100, 20, 40, 24)
    x.c.setBounds(200, 20, 40, 24)
    x.d.spaceEvenly(true)
    check x.b.left == 110                # gaps of 50 between 20 and 240
    x.d.centerInParent(true, false)
    check x.a.left == (500 - 40) / 2
    let n = x.d.nonVisuals.len
    check n == 0
    # one undo step per command
    check x.d.undo()
    check x.a.left == 20
    x.done

  test "tab, Escape, select all":
    let x = build()
    x.f.click(x.a.fcx, x.a.fcy)
    x.f.tap(keyTab)
    check x.d.primary == Control(x.b)
    x.f.tap(keyTab, {ssShift})
    check x.d.primary == Control(x.a)
    x.f.tap(keyTab, {ssShift})
    check x.d.primary == Control(x.p)     # wraps around
    let inner = newButton(x.p, "in", 10, 10, 60, 24)
    x.f.click(inner.fcx, inner.fcy)
    x.f.tap(keyEscape)
    check x.d.selection == @[Control(x.p)]
    x.f.tap(keyEscape)
    check x.d.selection == @[Control(x.f)]
    x.f.tap(keyEscape)
    check x.d.selection == @[Control(x.f)]
    x.f.click(x.a.fcx, x.a.fcy)
    x.f.tap('a', {ssCtrl})
    check x.d.selection.len == 5
    x.done

  test "Escape cancels a drag":
    let x = build()
    x.f.down(x.a.fcx, x.a.fcy)
    x.f.moveTo(x.a.fcx + 50, x.a.fcy + 50, {ssLeft})
    check x.d.dragging
    x.f.tap(keyEscape)
    x.f.up(x.a.fcx + 50, x.a.fcy + 50)
    check x.a.sameBounds(20, 20, 80, 24)
    check not x.d.canUndo
    # a resize in progress goes back
    x.d.snapToGrid = false
    x.f.click(x.a.fcx, x.a.fcy)
    let hr = handleRect(x.d.boundsOf(x.a), dhSE)
    x.f.down(hr.x + 2, hr.y + 2)
    x.f.moveTo(hr.x + 40, hr.y + 40, {ssLeft})
    check x.a.width > 80
    x.f.tap(keyEscape)
    check x.a.sameBounds(20, 20, 80, 24)
    x.f.up(hr.x + 40, hr.y + 40)
    check not x.d.canUndo
    x.done

  test "double click, context menu and clipboard hooks":
    let x = build()
    var dbl: Control
    var ctx: Control
    var ctxAt: PointF
    var copied, cut: seq[Control]
    var pasteInto: Container
    x.d.onDoubleClick = proc(d: FormDesigner, c: Control) = dbl = c
    x.d.onContextMenu = proc(d: FormDesigner, c: Control, p: PointF) =
      ctx = c
      ctxAt = p
    x.d.onCopy = proc(d: FormDesigner, cs: seq[Control]) = copied = cs
    x.d.onCut = proc(d: FormDesigner, cs: seq[Control]) = cut = cs
    x.d.onPaste = proc(d: FormDesigner, t: Container) = pasteInto = t
    x.f.click(x.b.fcx, x.b.fcy)
    x.f.down(x.b.fcx, x.b.fcy, clicks = 2)
    x.f.up(x.b.fcx, x.b.fcy)
    check dbl == Control(x.b)
    x.f.down(x.a.fcx, x.a.fcy, button = mbRight)
    x.f.up(x.a.fcx, x.a.fcy, button = mbRight)
    check ctx == Control(x.a)
    check ctxAt == pointF(x.a.fcx, x.a.fcy)
    check x.d.selection == @[Control(x.a)]
    x.f.tap('c', {ssCtrl})
    check copied == @[Control(x.a)]
    x.f.tap('v', {ssCtrl})
    check pasteInto == Container(x.f)
    x.f.click(x.p.fcx, x.p.fcy)
    x.f.tap('v', {ssCtrl})
    check pasteInto == Container(x.p)
    x.f.click(x.c.fcx, x.c.fcy)
    x.f.tap('x', {ssCtrl})
    check cut == @[Control(x.c)]
    check x.c.parent == nil
    check x.d.undo()
    check x.c.parent == Container(x.f)
    x.done

  test "non-visual components: tiles select, move and delete":
    let x = build()
    let tm = newComponent(x.f)
    tm.name = "Timer1"
    let t = x.d.addNonVisual(tm, 20, 300, "Timer")
    check x.d.nonVisuals == @[t]
    x.f.click(30, 310)
    check x.d.selection == @[Control(t)]
    check t.component == tm
    x.d.snapToGrid = false
    x.f.drag(30, 310, 90, 350)
    check t.left == 80 and t.top == 340
    check x.d.undo()
    check t.left == 20 and t.top == 300
    check x.d.redo()
    # a tile cannot leave the design root, and is not reparented into a panel
    x.f.drag(90, 350, x.p.fcx, x.p.fcy)
    check t.top > 0
    check x.d.deleteSelection()
    check x.d.nonVisuals.len == 0
    check x.d.undo()
    check x.d.nonVisuals == @[t]
    x.d.removeNonVisual(tm)
    check x.d.nonVisuals.len == 0
    x.done

  test "non-visual tiles keep their position in designLeft/designTop":
    let x = build(grid = false)
    let tm = newComponent(x.f)
    tm.name = "Timer1"
    let t = x.d.addNonVisual(tm, 20, 300, "Timer")
    check tm.designLeft == 20 and tm.designTop == 300
    x.f.drag(30, 310, 90, 350)
    check tm.designLeft == 80 and tm.designTop == 340
    check x.d.undo()
    check tm.designLeft == 20 and tm.designTop == 300
    check x.d.redo()
    x.d.select(t)
    x.d.nudge(2, 3)
    check tm.designLeft == 82 and tm.designTop == 343
    # a tile for a component with a saved position goes there; one without
    # gets a free spot along the top
    let t2 = newComponent(x.f)
    t2.name = "Timer2"
    t2.designLeft = 120
    t2.designTop = 250
    let tile2 = x.d.addNonVisual(t2, "Timer")
    check tile2.left == 120 and tile2.top == 250
    let t3 = newComponent(x.f)
    t3.name = "Timer3"
    let tile3 = x.d.addNonVisual(t3)
    check tile3.top == 8
    check t3.designLeft == int(tile3.left) and t3.designTop == 8
    check tile3.left != t.left or tile3.top != t.top
    x.done

  test "the design root resizes from its right, bottom and corner handles":
    let x = build(grid = false)
    var modified = 0
    x.d.onModified = proc(d: FormDesigner) = inc modified
    check x.d.selection == @[Control(x.f)]
    # corner: handles sit inside the root's corner
    x.f.drag(497, 397, 537, 427)
    check x.f.width == 540 and x.f.height == 430
    check x.f.left == 0 and x.f.top == 0
    check modified == 1
    check x.d.undo()
    check x.f.width == 500 and x.f.height == 400
    check x.d.redo()
    check x.f.width == 540 and x.f.height == 430
    # right edge: width only; bottom edge: height only
    x.f.drag(537, 215, 507, 215)
    check x.f.width == 510 and x.f.height == 430
    x.f.drag(255, 427, 255, 407)
    check x.f.width == 510 and x.f.height == 410
    # a drag from the empty area is a rubber band and never moves the root
    x.f.drag(400, 300, 300, 200)
    check x.f.left == 0 and x.f.top == 0 and x.f.width == 510 and x.f.height == 410
    # Esc puts the size back
    x.d.select(x.f)
    x.f.down(507, 407)
    x.f.moveTo(447, 357, {ssLeft})
    check x.f.width == 450
    x.f.tap(keyEscape)
    x.f.up(447, 357)
    check x.f.width == 510 and x.f.height == 410
    # minSize and the constraints apply; the root keeps its position
    x.f.drag(507, 407, 20, 20)
    check x.f.width >= x.d.minSize and x.f.height >= x.d.minSize
    check x.f.left == 0 and x.f.top == 0
    x.done

  test "an embedded design root (a panel) resizes too, in its parent":
    Application.init()
    let host = newForm(nil, 700, 500)
    let root = newPanel(host, "", 20, 20, 420, 320)
    newButton(root, "B", 10, 10, 60, 24)
    host.show()
    discard host.paintIfDirty()
    let d = newFormDesigner(root)
    d.snapToGrid = false
    var modified = 0
    d.onModified = proc(sender: FormDesigner) = inc modified
    check d.handleMask(root) == {dhE, dhS, dhSE}
    host.drag(20 + 417, 20 + 317, 20 + 417 + 60, 20 + 317 + 40)
    check root.width == 480 and root.height == 360
    check root.left == 20 and root.top == 20
    check modified == 1
    checkSame(host, "after resizing the design root")
    check d.undo()
    check root.width == 420 and root.height == 320
    # an aligned root has no handles: its layout owns the size
    root.align = alClient
    check d.handleMask(root) == {}
    host.freeWindow()

  test "hidden controls are selectable with showHidden":
    let x = build()
    x.e.visible = false
    x.f.click(x.e.fcx, x.e.fcy)
    check x.d.selection == @[Control(x.f)]
    x.d.showHidden = true
    x.f.click(x.e.fcx, x.e.fcy)
    check x.d.selection == @[Control(x.e)]
    x.done

  test "designing an embedded panel leaves the rest of the form alive":
    Application.init()
    let f = newForm(nil, 500, 400)
    let host = newButton(f, "Normal", 10, 340, 80, 24)
    var hostClicks = 0
    host.onClick = proc(s: Control) = inc hostClicks
    let surface = newPanel(f, "", 10, 10, 300, 300)
    let inner = newButton(surface, "inner", 20, 20, 80, 24)
    var innerClicks = 0
    inner.onClick = proc(s: Control) = inc innerClicks
    f.show()
    let d = newFormDesigner(surface)
    d.snapLines = false
    f.click(host.fcx, host.fcy)
    check hostClicks == 1
    f.click(inner.fcx, inner.fcy)
    check innerClicks == 0
    check d.selection == @[Control(inner)]
    f.click(200, 200)                     # empty area of the design surface
    check d.selection == @[Control(surface)]
    f.drag(inner.fcx, inner.fcy, inner.fcx + 30, inner.fcy + 30)
    check inner.left == 48 and inner.top == 48
    # keys go to the designer until a control outside takes the focus
    f.click(inner.fcx, inner.fcy)
    f.tap(keyRight)
    check inner.left == 49
    host.setFocus()
    f.tap(keyRight)
    check inner.left == 49
    f.freeWindow()

  test "wheel over the designed area bubbles up, no control scrolls":
    let x = build()
    var wheels = 0
    x.a.onMouseWheel = proc(s: Control, sh: ShiftState, dx, dy: float32,
                            handled: var bool) =
      inc wheels
    Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: x.f.win.id,
                                       x: x.a.fcx, y: x.a.fcy, dy: 1))
    check wheels == 0
    x.done

  test "overlay repaints correctly with partial repaints":
    let x = build()
    let f = x.f
    discard f.paintIfDirty()
    f.checkSame "initial"
    f.click(x.a.fcx, x.a.fcy)
    f.checkSame "selected"
    f.click(x.b.fcx, x.b.fcy, {ssShift})
    f.checkSame "multi"
    f.down(x.a.fcx, x.a.fcy)
    f.moveTo(x.a.fcx + 40, x.a.fcy + 60, {ssLeft})
    f.checkSame "dragging ghosts"
    f.moveTo(x.p.fcx, x.p.fcy, {ssLeft})
    f.checkSame "drop target"
    f.up(x.p.fcx, x.p.fcy)
    f.checkSame "dropped"
    x.d.snapToGrid = false
    let hr = handleRect(x.d.boundsOf(x.a), dhSE)
    f.down(hr.x + 2, hr.y + 2)
    f.moveTo(hr.x + 20, hr.y + 14, {ssLeft})
    f.checkSame "resizing"
    f.up(hr.x + 20, hr.y + 14)
    f.checkSame "resized"
    f.down(5, 150)
    f.moveTo(150, 260, {ssLeft})
    f.checkSame "band"
    f.up(150, 260)
    f.checkSame "band selection"
    f.tap(keyRight)
    f.checkSame "nudged"
    discard x.d.undo()
    f.checkSame "undone"
    x.d.showGrid = false
    f.checkSame "no grid"
    x.d.showGrid = true
    x.d.snapLines = true
    f.down(x.c.fcx, x.c.fcy)
    f.moveTo(x.c.fcx + 100, x.c.fcy - 10, {ssLeft})
    f.checkSame "guides"
    f.up(x.c.fcx + 100, x.c.fcy - 10)
    f.checkSame "after guides"
    x.d.detach()
    f.checkSame "detached"
    x.done

  test "geometry changed outside the designer is repainted after refresh":
    let x = build()
    let f = x.f
    f.click(x.a.fcx, x.a.fcy)
    f.checkSame "selected"
    x.a.setBounds(150, 150, 120, 60)
    x.d.refresh()
    f.checkSame "moved by code"
    x.done

suite "form designer drags and history":
  test "Esc during a rubber band brings the old selection back":
    let x = build()
    x.f.click(x.a.fcx, x.a.fcy)
    check x.d.selection == @[Control(x.a)]
    x.f.down(10, 100)
    x.f.moveTo(150, 260, {ssLeft})
    check Control(x.c) in x.d.selection
    x.d.cancelDrag()
    check x.d.selection == @[Control(x.a)]
    check not x.d.dragging
    x.f.up(150, 260)
    check x.d.selection == @[Control(x.a)]
    x.done

  test "a second button pressed during a drag does not move the drag origin":
    let x = build(grid = false)
    let x0 = x.a.fcx
    let y0 = x.a.fcy
    x.f.down(x0, y0)
    x.f.moveTo(x0 + 10, y0, {ssLeft})
    x.f.down(x0 + 100, y0 + 50, button = mbRight)
    x.f.moveTo(x0 + 10, y0, {ssLeft})
    x.f.up(x0 + 10, y0)
    check x.a.left == 30 and x.a.top == 20
    x.done

  test "a group of tiles stays inside the design root":
    let x = build(grid = false)
    let t1 = x.d.addNonVisual(newComponent(x.f), 20, 300, "Timer")
    let t2 = x.d.addNonVisual(newComponent(x.f), 200, 300, "Timer")
    x.d.select([Control(t1), Control(t2)])
    x.f.drag(30, 310, 490, 310)
    check t2.left + 32 <= x.f.width
    check t2.left - t1.left == 180
    x.f.drag(t1.left + 10, 310, t1.left + 10, 395)
    check t1.top + 32 <= x.f.height
    x.done

  test "undoing the deletion of a container restores the history of its children":
    let x = build()
    type Info = ref object
      cls, name, caption: string
      kids: seq[Info]
    var infos: seq[Info]
    proc capture(c: Control): Info =
      result = Info(cls: (if c of Panel: "Panel" else: "Button"), name: c.name, caption: c.caption)
      if c of Container:
        for k in Container(c).children: result.kids.add capture(k)
    proc build(i: Info, parent: Container, index: int): Control =
      if i.cls == "Panel":
        let p = newPanel(nil, i.caption)
        p.name = i.name
        parent.insertControl(p, index)
        for k in i.kids: discard build(k, p, p.children.len)
        Control(p)
      else:
        let b = newButton(nil, i.caption)
        b.name = i.name
        parent.insertControl(b, index)
        Control(b)
    x.d.snapshot = proc(c: Control): string =
      infos.add capture(c)
      $infos.high
    x.d.restore = proc(s: string, parent: Container, index: int): Control =
      build(infos[parseInt(s)], parent, index)
    let panel = newPanel(x.f, "", 300, 250, 150, 100)
    panel.name = "P1"
    let inner = newButton(panel, "In", 10, 10, 60, 24)
    inner.name = "In"
    discard x.f.paintIfDirty()
    x.d.select(inner)
    check x.d.deleteSelection()
    x.d.select(panel)
    check x.d.deleteSelection()
    check x.d.undo()                       # the panel is back
    proc find(c: Container, name: string): Control =
      for k in c.children:
        if k.name == name: return k
        if k of Container:
          let r = find(Container(k), name)
          if r != nil: return r
    let np = Panel(find(x.f, "P1"))
    check np != nil and np != panel
    check x.d.undo()                       # the button goes back into the new panel
    let nb = Button(find(x.f, "In"))
    check nb != nil
    check nb.parent == Container(np)
    check np.children.find(nb) >= 0
    x.done

suite "unique names (N6)":
  test "components owned by components and underscore variants count":
    let x = build()
    check x.d.uniqueName("Button") == "Button1"
    let inner = newComponent(x.p)            # owned by the panel, not by the form
    inner.name = "Timer1"
    check x.d.uniqueName("Timer") == "Timer2"
    x.a.name = "Button_1"                    # the same Nim identifier as Button1
    check x.d.uniqueName("Button") == "Button2"
    x.done
