## Docking: DockSite / DockPanel / DockTabs. Headless (offscreen SDL): mouse
## drags and keys go through Application.dispatch like the real loop. The
## screen origin of a floating window is its own left/top (the offscreen driver
## has no meaningful window positions), set up with `dockScreenOrigin`.

import std/[unittest, json, strutils]
import nimvcl

var mainForm: Form

dockScreenOrigin = proc(f: Form): PointF =
  if f == mainForm: pointF(0, 0) else: pointF(f.left, f.top)

proc feed(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, clicks = 1,
          shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y,
                                     button: mbLeft, clicks: clicks, shift: shift))
proc moveTo(f: Form, p: PointF) = f.feed(ekMouseMove, p.x, p.y, shift = {ssLeft})
proc hoverTo(f: Form, p: PointF) = f.feed(ekMouseMove, p.x, p.y)
proc down(f: Form, p: PointF, clicks = 1) = f.feed(ekMouseDown, p.x, p.y, clicks)
proc up(f: Form, p: PointF) = f.feed(ekMouseUp, p.x, p.y)
proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: f.win.id, key: k,
                                     shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: f.win.id, key: k,
                                     shift: shift))

proc settle() =
  for f in Application.forms: layoutIfNeeded(f)

proc formOf(p: DockPanel): Form = Form(Control(p).root)

proc tabPoint(p: DockPanel): PointF =
  let g = p.group
  let i = g.panels.find(p)
  let r = g.tabRects[i]
  g.clientToForm(pointF(r.x + 18, r.h / 2))

proc center(r: RectF): PointF = pointF(r.x + r.w / 2, r.y + r.h / 2)

proc guidePoint(site: DockSite, g: DockTabs, side: DockSide): PointF =
  site.clientToForm(site.guideRect(g, side).center)

proc dragPanel(p: DockPanel, to: PointF, form: Form = nil) =
  ## Presses the panel's tab and drags it to `to` (coordinates of the window
  ## the tab is in, so for a panel in a floating window pass its own form).
  let f = if form != nil: form else: p.formOf
  let a = p.tabPoint
  f.down(a)
  f.moveTo(pointF(a.x + 3, a.y))                     # below the threshold
  f.moveTo(pointF((a.x + to.x) / 2, (a.y + to.y) / 2))
  f.moveTo(to)
  f.up(to)
  settle()

proc shape(s: string): string =
  ## A saved layout without the "active" fields (which `show` etc. change).
  proc strip(j: JsonNode) =
    if j.kind == JObject:
      if j.hasKey("active"): j.delete("active")
      for _, v in j: strip(v)
    elif j.kind == JArray:
      for v in j: strip(v)
  let j = parseJson(s)
  strip(j)
  $j

func approx(a, b: float32, tol = 0.02'f32): bool = abs(a - b) <= tol

proc newContent(): Control =
  let p = newPanel(nil, "")
  p

type Ide = object
  f: Form
  site: DockSite
  ed1, ed2, palette, structure, inspector, messages: DockPanel

proc buildIde(): Ide =
  let f = newForm(nil, 900, 600)
  mainForm = f
  f.show()
  let site = newDockSite(f)
  site.align = alClient
  var ide = Ide(f: f, site: site)
  ide.ed1 = newDockPanel(site, "ed1", "main.nim", newMemo(nil, "one"))
  ide.ed2 = newDockPanel(site, "ed2", "util.nim", newMemo(nil, "two"))
  ide.palette = newDockPanel(site, "palette", "Palette", newContent())
  ide.structure = newDockPanel(site, "structure", "Structure", newContent())
  ide.inspector = newDockPanel(site, "inspector", "Inspector", newContent())
  ide.messages = newDockPanel(site, "messages", "Messages", newContent(), closable = false)
  site.dock(ide.ed1)
  site.dock(ide.ed2, ide.ed1, dsCenter)
  site.dock(ide.palette, nil, dsLeft, 0.2)
  site.dock(ide.structure, ide.palette, dsCenter)
  site.dock(ide.inspector, nil, dsRight, 0.2)
  site.dock(ide.messages, ide.ed1, dsBottom, 0.3)
  settle()
  ide

proc cleanup() =
  for f in Application.forms: f.freeWindow()
  mainForm = nil

proc names(g: DockTabs): seq[string] =
  for p in g.panels: result.add p.name

suite "docking":
  setup:
    Application.init()
  teardown:
    cleanup()

  test "structure built by dock()":
    let ide = buildIde()
    let site = ide.site
    check site.groups.len == 4
    let root = DockSplit(site.rootNode)
    check root.orientation == orHorizontal
    check root.children.len == 3
    # left: palette+structure tabs
    check ide.palette.group == ide.structure.group
    check ide.palette.group.names == @["palette", "structure"]
    check ide.palette.group.parent == Container(root)
    # centre: vertical split editors above messages
    let mid = DockSplit(root.children[1])
    check mid.orientation == orVertical
    check ide.ed1.group.parent == Container(mid)
    check ide.messages.group.parent == Container(mid)
    check ide.ed1.group.formOrigin.y < ide.messages.group.formOrigin.y
    check root.children[2] == Control(ide.inspector.group)
    # proportions: side panels take about a fifth of the width
    var sum = 0'f32
    for w in root.weights: sum += w
    check approx(sum, 1.0)
    check approx(root.weights[0], 0.2 * 0.8, 0.03) or approx(root.weights[0], 0.16, 0.03)
    check approx(root.weights[2], 0.2)
    check approx(ide.messages.group.height / mid.height, 0.3, 0.05)
    check ide.palette.state == dpDocked
    check site.panels.len == 6
    check site.findPanel("inspector") == ide.inspector
    check site.findPanel("nope") == nil
    # only the active tab of a group is visible
    check ide.ed1.visible != ide.ed2.visible
    check ide.ed2.group.activePanel == ide.ed2

  test "dock to each side of a group and of the site":
    let ide = buildIde()
    let site = ide.site
    for side in [dsLeft, dsRight, dsTop, dsBottom]:
      let p = newDockPanel(site, "x" & $side, "X", newContent())
      site.dock(p, ide.inspector, side, 0.4)
      settle()
      let g = p.group
      check g != ide.inspector.group
      let ig = ide.inspector.group
      case side
      of dsLeft: check g.formOrigin.x + g.width <= ig.formOrigin.x
      of dsRight: check ig.formOrigin.x + ig.width <= g.formOrigin.x
      of dsTop: check g.formOrigin.y + g.height <= ig.formOrigin.y
      of dsBottom: check ig.formOrigin.y + ig.height <= g.formOrigin.y
      of dsCenter: discard
    # the inspector group is now inside nested splits, all tidy
    proc tidy(n: Control): bool =
      if n of DockSplit:
        let s = DockSplit(n)
        if s.children.len < 2: return false
        for c in s.children:
          if c of DockSplit and DockSplit(c).orientation == s.orientation: return false
          if not tidy(c): return false
      true
    check tidy(site.rootNode)
    # site edges
    let top = newDockPanel(site, "top", "Top", newContent())
    site.dock(top, nil, dsTop, 0.2)
    settle()
    check top.group.formOrigin.y <= site.formOrigin.y + 4
    check top.group.width >= site.width - 12
    # centre of the group
    let c = newDockPanel(site, "c", "C", newContent())
    site.dock(c, ide.ed1, dsCenter, index = 0)
    check c.group == ide.ed1.group
    check c.group.names[0] == "c"
    check c.group.activePanel == c

  test "dock refuses foreign panels and undocked targets":
    let ide = buildIde()
    let other = newDockSite(ide.f)
    let stray = newDockPanel(other, "stray", "S", newContent())
    expect ValueError: ide.site.dock(stray)
    let hidden = newDockPanel(ide.site, "hid", "H", newContent())
    expect ValueError: ide.site.dock(ide.ed1, hidden, dsLeft)

  test "drag a tab to a side guide, centre guide and site edge":
    let ide = buildIde()
    let site = ide.site
    # inspector -> left of the editors
    ide.inspector.dragPanel(guidePoint(site, ide.ed1.group, dsLeft))
    check ide.inspector.state == dpDocked
    check ide.inspector.group != ide.ed1.group
    check ide.inspector.group.formOrigin.x < ide.ed1.group.formOrigin.x
    check ide.inspector.group.parent == ide.ed1.group.parent
    check site.groups.len == 4
    # messages -> as a tab of the editors (centre guide)
    ide.messages.dragPanel(guidePoint(site, ide.ed1.group, dsCenter))
    check ide.messages.group == ide.ed1.group
    check ide.ed1.group.names == @["ed1", "ed2", "messages"]
    check ide.messages.group.activePanel == ide.messages
    check site.groups.len == 3
    # structure -> bottom edge of the site
    ide.structure.dragPanel(guidePoint(site, nil, dsBottom))
    settle()
    check ide.structure.group.formOrigin.y > ide.ed1.group.formOrigin.y
    check ide.structure.group.width >= site.width - 12
    check ide.palette.group.names == @["palette"]
    # the overlay is gone afterwards
    check site.groups.len == 4

  test "drag shows guides while in progress and Esc cancels":
    let ide = buildIde()
    let site = ide.site
    let f = ide.f
    let a = ide.palette.tabPoint
    f.down(a)
    f.moveTo(pointF(a.x + 20, a.y + 40))
    f.moveTo(guidePoint(site, ide.ed1.group, dsRight))
    check dragging()
    check site.guidesVisible
    f.tap(keyEscape)
    f.up(guidePoint(site, ide.ed1.group, dsRight))
    settle()
    check ide.palette.group.names == @["palette", "structure"]   # unchanged
    check not dragging()
    check not site.guidesVisible

  test "drop outside every site floats; dragging back docks":
    let ide = buildIde()
    let site = ide.site
    let nForms = Application.forms.len
    let events: seq[string] = @[]
    var log = events
    site.onDock = proc(s: DockSite, p: DockPanel) = log.add "dock " & p.name & " " & $p.state
    site.onUndock = proc(s: DockSite, p: DockPanel) = log.add "undock " & p.name
    ide.inspector.dragPanel(pointF(2000, 300))
    check ide.inspector.state == dpFloating
    check Application.forms.len == nForms + 1
    let ff = ide.inspector.floatForm
    check ff != nil
    check ff.caption == "Inspector"
    check log == @["undock inspector", "dock inspector dpFloating"]
    check site.floatingSites.len == 1
    check site.groups.len == 3                      # inspector group collapsed
    # drag its tab (in the floating window) onto the editors' bottom guide
    settle()
    let ox = ff.left
    let oy = ff.top
    let g = guidePoint(site, ide.ed1.group, dsBottom)
    ide.inspector.dragPanel(pointF(g.x - ox, g.y - oy), ff)
    check ide.inspector.state == dpDocked
    # the window is destroyed after the event that emptied it, not inside it
    check Application.forms.len == nForms + 1
    Application.processMessages()
    check Application.forms.len == nForms           # the window went away
    check site.floatingSites.len == 0
    check ide.inspector.group.formOrigin.y > ide.ed1.group.formOrigin.y

  test "makeFloating, dockBack, double click and context menu path":
    let ide = buildIde()
    ide.palette.makeFloating(rectF(1000, 100, 300, 240))
    check ide.palette.state == dpFloating
    check ide.palette.floatForm.width == 300
    check ide.structure.state == dpDocked
    check ide.structure.group.names == @["structure"]
    # a panel alone in its window: makeFloating just moves the window
    let nForms = Application.forms.len
    ide.palette.makeFloating(rectF(1100, 120, 300, 240))
    check Application.forms.len == nForms
    check ide.palette.floatForm.left == 1100
    ide.palette.dockBack()
    check ide.palette.state == dpDocked
    check ide.palette.group == ide.structure.group      # back as a tab
    check ide.palette.group.names == @["palette", "structure"]
    Application.processMessages()
    check Application.forms.len == nForms - 1
    # double click on a tab floats a docked panel, and docks a floating one
    let f = ide.f
    let a = ide.inspector.tabPoint
    f.down(a); f.up(a)
    f.down(a, 2); f.up(a)
    check ide.inspector.state == dpFloating
    settle()
    let ff = ide.inspector.floatForm
    let b = ide.inspector.tabPoint
    ff.down(b); ff.up(b)
    ff.down(b, 2)                       # the window is gone after this press
    check ide.inspector.state == dpDocked

  test "two panels share a floating window; closing the window hides them":
    let ide = buildIde()
    ide.palette.makeFloating(rectF(1000, 100, 300, 240))
    ide.site.dock(ide.structure, ide.palette, dsCenter)
    check ide.structure.state == dpFloating
    check ide.structure.floatForm == ide.palette.floatForm
    let ff = ide.palette.floatForm
    ff.close()
    check ide.palette.state == dpHidden
    check ide.structure.state == dpHidden
    check ide.site.floatingSites.len == 0
    # a veto keeps the window
    ide.palette.show()
    check ide.palette.state == dpFloating
    var vetoed = 0
    ide.site.onClose = proc(s: DockSite, p: DockPanel, allow: var bool) =
      inc vetoed
      allow = false
    ide.palette.floatForm.close()
    check vetoed == 1
    check ide.palette.state == dpFloating
    ide.site.onClose = nil

  test "hide and show restore the place":
    let ide = buildIde()
    let site = ide.site
    let before = site.saveLayout()
    # alone in its group: back at the right edge, same share
    let w0 = ide.inspector.group.width
    ide.inspector.hide()
    check ide.inspector.state == dpHidden
    check ide.inspector.group == nil
    check site.groups.len == 3
    ide.inspector.show()
    settle()
    check ide.inspector.state == dpDocked
    check ide.inspector.group.formOrigin.x > ide.ed1.group.formOrigin.x
    check abs(ide.inspector.group.width - w0) <= 2
    check site.saveLayout().shape == before.shape
    # a tab: back at its index
    ide.palette.hide()
    check ide.structure.group.names == @["structure"]
    ide.palette.show()
    check ide.palette.group == ide.structure.group
    check ide.palette.group.names == @["palette", "structure"]
    # the bottom panel returns below the editors only
    ide.messages.hide()
    check site.groups.len == 3
    ide.messages.show()
    check ide.messages.group.parent == ide.ed1.group.parent
    check site.saveLayout().shape == before.shape
    # a floating panel floats again
    ide.inspector.makeFloating(rectF(1000, 50, 320, 200))
    ide.inspector.hide()
    ide.inspector.show()
    check ide.inspector.state == dpFloating
    check ide.inspector.floatForm.width == 320
    # a never-shown panel goes into the first group
    let n = newDockPanel(site, "late", "Late", newContent())
    n.show()
    check n.state == dpDocked
    check n.group == site.groups[0]

  test "splitter drag resizes proportionally and survives a form resize":
    let ide = buildIde()
    let site = ide.site
    let f = ide.f
    let root = DockSplit(site.rootNode)
    let w0 = root.weights
    let pg = ide.palette.group
    let gapX = pg.formOrigin.x + pg.width + 2
    let y = pg.formOrigin.y + pg.height / 2
    f.down(pointF(gapX, y))
    f.moveTo(pointF(gapX + 60, y))
    f.moveTo(pointF(gapX + 120, y))
    f.up(pointF(gapX + 120, y))
    settle()
    let w1 = root.weights
    check w1[0] > w0[0]
    check approx(w1[0] + w1[1], w0[0] + w0[1], 0.001)    # the pair trades
    check approx(w1[2], w0[2], 0.001)                    # the others keep theirs
    check abs(pg.width - (0.16 * (900 - 6 - 10) + 120)) < 60   # moved about 120 px
    # the proportions survive a resize of the window
    let share = pg.width / root.width
    f.setBounds(0, 0, 1400, 700)
    settle()
    check root.width > 1300
    check approx(pg.width / root.width, share, 0.02)
    # limits: cannot be dragged below the minimum pane size
    let gx = pg.formOrigin.x + pg.width + 2
    f.down(pointF(gx, y))
    f.moveTo(pointF(gx - 2000, y))
    f.up(pointF(gx - 2000, y))
    settle()
    check pg.width >= 63

  test "split drag in a vertical split":
    let ide = buildIde()
    let f = ide.f
    let mid = DockSplit(ide.ed1.group.parent)
    let w0 = mid.weights
    let eg = ide.ed1.group
    let x = eg.formOrigin.x + eg.width / 2
    let gy = eg.formOrigin.y + eg.height + 2
    f.down(pointF(x, gy))
    f.moveTo(pointF(x, gy - 50))
    f.up(pointF(x, gy - 50))
    settle()
    check mid.weights[0] < w0[0]
    check approx(mid.weights[0] + mid.weights[1], w0[0] + w0[1], 0.001)

  test "save / load round trip":
    let ide = buildIde()
    let site = ide.site
    let f = ide.f
    # shape it: a drag, a floating window, a hidden panel, a chosen tab
    let pg = ide.palette.group
    let gapX = pg.formOrigin.x + pg.width + 2
    let y = pg.formOrigin.y + pg.height / 2
    f.down(pointF(gapX, y)); f.moveTo(pointF(gapX + 40, y)); f.up(pointF(gapX + 40, y))
    ide.ed1.activate()
    ide.structure.makeFloating(rectF(1000, 80, 300, 220))
    ide.inspector.hide()
    settle()
    let s1 = site.saveLayout()
    check parseJson(s1).kind == JObject
    # destroy the arrangement, then load
    ide.structure.dockBack()
    ide.inspector.show()
    ide.messages.hide()
    ide.palette.makeFloating(rectF(1000, 300, 280, 200))
    check site.saveLayout() != s1
    check site.loadLayout(s1)
    settle()
    check site.saveLayout() == s1
    check ide.structure.state == dpFloating
    check ide.structure.floatForm.width == 300
    check ide.inspector.state == dpHidden
    check ide.palette.state == dpDocked
    check ide.ed1.group.activePanel == ide.ed1
    # and once more, then show/hide still restore sensibly
    check site.loadLayout(s1)
    check site.saveLayout() == s1
    ide.inspector.show()
    check ide.inspector.state == dpDocked

  test "load validates first: bad parts are refused and nothing changes (N9)":
    let ide = buildIde()
    let site = ide.site
    let s1 = site.saveLayout()
    var j = parseJson(s1)
    var v2 = j.copy
    v2["version"] = %2
    check not site.loadLayout($v2)
    var bad = j.copy
    bad["root"] = %*"junk"
    check not site.loadLayout($bad)
    bad = j.copy
    bad["root"] = %*{"split": "h", "children": 5}
    check not site.loadLayout($bad)
    bad = j.copy
    bad["root"] = %*{"tabs": ["ghost", "phantom"]}
    bad["floats"] = %*[]
    bad["hidden"] = %*[]
    check not site.loadLayout($bad)             # none of its panels is here
    bad = j.copy
    bad["floats"] = %*[{"x": "left", "root": {"tabs": ["ed1"]}}]
    check not site.loadLayout($bad)
    check site.saveLayout() == s1

  test "loadLayout cancels a drag in progress (N9)":
    let ide = buildIde()
    let site = ide.site
    let f = ide.f
    let s1 = site.saveLayout()
    let a = ide.palette.tabPoint
    f.down(a)
    f.moveTo(pointF(a.x + 20, a.y + 40))
    f.moveTo(guidePoint(site, ide.ed1.group, dsRight))
    check dragging()
    check site.loadLayout(s1)
    check not dragging()
    check not site.guidesVisible
    f.up(guidePoint(site, ide.ed1.group, dsRight))
    settle()
    check site.saveLayout() == s1

  test "load ignores unknown names, keeps unmentioned panels, rejects junk":
    let ide = buildIde()
    let site = ide.site
    let s1 = site.saveLayout()
    check not site.loadLayout("not json")
    check not site.loadLayout("{\"x\": 1}")
    check not site.loadLayout("[1, 2]")
    check site.saveLayout() == s1
    var j = parseJson(s1)
    j["root"] = %*{"split": "h", "weights": [0.3, 0.7],
                   "children": [{"tabs": ["ghost", "ed1"], "active": "ghost"},
                                {"tabs": ["messages", "phantom"]}]}
    j["floats"] = %*[{"x": 5, "y": 5, "w": 200, "h": 150, "root": {"tabs": ["ghost2"]}}]
    check site.loadLayout($j)
    settle()
    check ide.ed1.state == dpDocked
    check ide.messages.group.names == @["messages"]
    # not mentioned at all (ed2, palette, structure, inspector): tabs of the first group
    check ide.ed1.group.names == @["ed1", "ed2", "palette", "structure", "inspector"]
    check ide.ed2.group == ide.ed1.group
    check ide.palette.group == ide.ed1.group
    check ide.inspector.group == ide.ed1.group
    check site.floatingSites.len == 0               # a floating window with no known panel is not made
    check site.groups.len == 2

  test "empty groups and splits collapse; an empty site is usable":
    let ide = buildIde()
    let site = ide.site
    ide.messages.hide()
    check site.groups.len == 3
    let mid = ide.ed1.group
    check mid.parent == Container(site.rootNode)    # the vertical split vanished
    ide.palette.hide()
    ide.structure.hide()
    ide.inspector.hide()
    check DockTabs(site.rootNode) == ide.ed1.group  # one group left: it is the root
    ide.ed1.hide()
    ide.ed2.hide()
    check site.rootNode == nil
    check site.groups.len == 0
    settle()
    # docking into the empty site
    ide.messages.show()
    check ide.messages.group == DockTabs(site.rootNode)
    ide.site.dock(ide.inspector, nil, dsLeft, 0.3)
    check DockSplit(site.rootNode).children.len == 2
    ide.site.dock(ide.palette, nil, dsLeft, 0.3)
    check DockSplit(site.rootNode).children.len == 3     # same orientation: merged
    # the last panel of a floating window frees the window
    let n = Application.forms.len
    ide.palette.makeFloating(rectF(1000, 10, 300, 200))
    check Application.forms.len == n + 1
    ide.palette.hide()
    Application.processMessages()
    check Application.forms.len == n

  test "events: dock, undock, activate, close and veto":
    let ide = buildIde()
    let site = ide.site
    var log: seq[string]
    site.onDock = proc(s: DockSite, p: DockPanel) = log.add "dock:" & p.name
    site.onUndock = proc(s: DockSite, p: DockPanel) = log.add "undock:" & p.name
    site.onActivate = proc(s: DockSite, p: DockPanel) = log.add "act:" & p.name
    var allow = true
    site.onClose = proc(s: DockSite, p: DockPanel, a: var bool) =
      log.add "close:" & p.name
      a = allow
    var changed = 0
    site.onLayoutChanged = proc(sender: Control) = inc changed
    ide.ed1.activate()
    log = @[]
    ide.ed2.activate()
    check log == @["act:ed2"]
    log = @[]
    allow = false
    check not ide.ed2.close()
    check ide.ed2.state == dpDocked
    check log == @["close:ed2"]
    log = @[]
    allow = true
    check ide.ed2.close()
    check ide.ed2.state == dpHidden
    check log == @["close:ed2", "undock:ed2"]
    log = @[]
    changed = 0
    ide.ed2.show()
    check log == @["dock:ed2", "act:ed2"]
    check changed >= 1
    # hide() does not ask
    log = @[]
    allow = false
    ide.ed2.hide()
    check log == @["undock:ed2"]
    # the close button
    allow = false
    log = @[]
    ide.inspector.activate()
    log = @[]
    let g = ide.inspector.group
    let cr = g.tabCloseRect(0)
    check not cr.isEmpty
    let pt = g.clientToForm(cr.center)
    ide.f.down(pt); ide.f.up(pt)
    check log == @["close:inspector"]
    check ide.inspector.state == dpDocked
    allow = true
    ide.f.down(pt); ide.f.up(pt)
    check ide.inspector.state == dpHidden
    # a panel that is not closable has no close button
    check ide.messages.group.tabCloseRect(0).isEmpty
    # click on a tab activates
    log = @[]
    let t = ide.palette.tabPoint
    ide.f.down(t); ide.f.up(t)
    check "act:palette" in log

  test "keyboard: Ctrl+Tab cycles tabs, Ctrl+F4 closes":
    let ide = buildIde()
    let f = ide.f
    let site = ide.site
    ide.ed1.activate(focus = true)
    check ide.ed1.group.activePanel == ide.ed1
    f.tap(keyTab, {ssCtrl})
    check ide.ed1.group.activePanel == ide.ed2
    check site.activePanel == ide.ed2
    f.tap(keyTab, {ssCtrl})
    check ide.ed1.group.activePanel == ide.ed1       # wraps
    f.tap(keyTab, {ssCtrl, ssShift})
    check ide.ed1.group.activePanel == ide.ed2
    # the focus followed into the new panel (a Memo)
    check f.activeControl != nil
    check ide.ed2.isAncestorOf(f.activeControl)
    # a single-tab group: nothing to cycle
    ide.inspector.activate(focus = true)
    f.tap(keyTab, {ssCtrl})
    check ide.inspector.group.activePanel == ide.inspector
    # Ctrl+F4
    f.tap(keyF4, {ssCtrl})
    check ide.inspector.state == dpHidden
    # not closable: stays
    ide.messages.activate(focus = true)
    f.tap(keyF4, {ssCtrl})
    check ide.messages.state == dpDocked
    # closable active tab in a group closes, the neighbour takes over
    ide.ed2.activate(focus = true)
    f.tap(keyF4, {ssCtrl})
    check ide.ed2.state == dpHidden
    check ide.ed1.group.activePanel == ide.ed1

  test "Ctrl+Tab inside a nested PageControl cycles its pages, not the panels":
    let ide = buildIde()
    let f = ide.f
    let pc = newPageControl(nil)
    let s1 = newTabSheet(pc, "one")
    let s2 = newTabSheet(pc, "two")
    let e1 = newEdit(s1)
    discard newEdit(s2)
    let pg = newDockPanel(ide.site, "pages", "Pages", pc)
    ide.site.dock(pg, ide.messages.group, dsLeft, 0.3)   # a group of its own
    settle()
    pg.activate()
    f.activeControl = e1
    check pc.tabIndex == 0
    f.tap(keyTab, {ssCtrl})
    check pc.tabIndex == 1
    # a single-panel group does not swallow the key either
    check pg.group.panels.len == 1

  test "docking a panel onto its own group appends it last":
    let ide = buildIde()
    let c = newDockPanel(ide.site, "c", "c", newContent())
    ide.site.dock(c, ide.ed1, dsCenter)
    check ide.ed1.group.names == @["ed1", "ed2", "c"]
    ide.site.dock(ide.ed1, ide.ed2, dsCenter)       # default index: last
    check ide.ed1.group.names == @["ed2", "c", "ed1"]

  test "focus inside a panel makes it the active panel":
    let ide = buildIde()
    let f = ide.f
    ide.ed1.activate()
    ide.palette.activate()
    check ide.site.activePanel == ide.palette
    let memo = Memo(ide.ed1.content)
    check ide.ed1.group.activePanel == ide.ed1
    let p = memo.formOrigin
    f.down(pointF(p.x + 20, p.y + 10)); f.up(pointF(p.x + 20, p.y + 10))
    check ide.site.activePanel == ide.ed1

  test "tab reorder by dragging within the strip":
    let ide = buildIde()
    let g = ide.ed1.group
    check g.names == @["ed1", "ed2"]
    let rs = g.tabRects
    let to = g.clientToForm(pointF(rs[1].right - 4, rs[1].h / 2))
    ide.ed1.dragPanel(to)
    check g.names == @["ed2", "ed1"]
    check g.activePanel == ide.ed1
    # dropping into another group's strip inserts there
    let pg = ide.palette.group
    let prs = pg.tabRects
    let to2 = pg.clientToForm(pointF(prs[0].x + 3, prs[0].h / 2))
    ide.ed2.dragPanel(to2)
    check pg.names == @["ed2", "palette", "structure"]
    check g.names == @["ed1"]

  test "dropping on a site but not on a guide does nothing":
    let ide = buildIde()
    let before = ide.site.saveLayout()
    let g = ide.ed1.group
    let r = ide.site.groupRect(g)
    ide.palette.dragPanel(ide.site.clientToForm(pointF(r.x + 12, r.y + r.h - 12)))
    check ide.site.saveLayout().shape == before.shape

  test "a panel alone in the site offers no guides to itself":
    let f = newForm(nil, 500, 400)
    mainForm = f
    f.show()
    let site = newDockSite(f)
    site.align = alClient
    let p = newDockPanel(site, "only", "Only", newContent())
    site.dock(p)
    settle()
    let before = site.saveLayout()
    p.dragPanel(guidePoint(site, p.group, dsLeft))
    check site.saveLayout() == before
    p.dragPanel(guidePoint(site, nil, dsRight))
    check site.saveLayout() == before
    check site.groups.len == 1

  test "panel properties: caption, icon, content, closable":
    let ide = buildIde()
    let il = newImageList(16, 16)
    il.add newImage(32, 32, rgba(200, 30, 30, 255))
    ide.ed1.images = il
    ide.ed1.imageIndex = 0
    check ide.ed1.imageIndex == 0
    let w0 = ide.ed1.group.tabRects[0].w
    ide.ed1.caption = "a considerably longer caption.nim"
    check ide.ed1.group.tabRects[0].w > w0
    let c = newContent()
    ide.palette.content = c
    check ide.palette.content == c
    check c.parent == Container(ide.palette)
    check c.align == alClient
    ide.palette.closable = false
    check ide.palette.group.tabCloseRect(0).isEmpty
    # a floating window shows the active panel's caption
    ide.palette.makeFloating(rectF(1000, 100, 300, 240))
    check ide.palette.floatForm.caption == "Palette"
    ide.palette.caption = "Tools"
    check ide.palette.floatForm.caption == "Tools"
    discard il

  test "painting every state does not raise (light and dark)":
    let ide = buildIde()
    let site = ide.site
    for dark in [false, true]:
      Application.theme = if dark: themeDark() else: themeLight()
      check ide.f.paintIfDirty() or true
      let a = ide.palette.tabPoint
      ide.f.down(a)
      ide.f.moveTo(pointF(a.x + 30, a.y + 30))
      ide.f.moveTo(guidePoint(site, ide.ed1.group, dsLeft))
      Application.paintForms()
      ide.f.moveTo(guidePoint(site, nil, dsTop))
      Application.paintForms()
      ide.f.moveTo(pointF(ide.ed1.group.formOrigin.x + 40, ide.ed1.group.formOrigin.y + 8))
      Application.paintForms()
      ide.f.up(pointF(0, 0))
      settle()
    Application.theme = themeLight()
