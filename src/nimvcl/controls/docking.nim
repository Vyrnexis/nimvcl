## Docking: IDE-style dock panels (`DockSite`, `DockPanel`, `DockTabs`).
##
## Model
## -----
## A `DockSite` (a Container, usually `alClient` on the main form) owns a tree:
##
##   DockSite -> root -> DockSplit (horizontal / vertical, weighted children)
##                          -> DockSplit | DockTabs (a tab group of panels)
##
## * `DockPanel`: a titled container (caption, optional icon from an
##   `ImageList`, `closable`) whose `content` is any Control or Frame.
## * `DockTabs`: a tab group. Its strip shows one tab per panel with a close
##   button; the group of the active panel is drawn highlighted.
## * `DockSplit`: lays its children out left-to-right (`orHorizontal`) or
##   top-to-bottom (`orVertical`) by WEIGHTS, so the proportions survive a
##   resize of the window. A divider between two children drags (live); the
##   two neighbours trade weight and the others keep theirs. A pane never gets
##   smaller than 64 px (unless the whole split is smaller than that).
##
## The tree keeps itself tidy: an empty group is removed, a split with one
## child is replaced by that child, a split inside a split of the same
## orientation is merged into it. An empty site is fine (it shows a hint);
## docking into it makes the new group the root.
##
## Panels belong to ONE site, the PRIMARY (the one `newDockPanel` was given).
## A panel is in one of three states (`panel.state`): `dpDocked` (in a group
## of the primary site), `dpFloating` (in a group of a floating site, i.e. its
## own window) or `dpHidden` (in no group; it remembers its place).
##
## Floating: `panel.makeFloating(rect)` (and dropping a dragged tab outside every
## site) moves the panel into a new `Form` (a normal window, title = the
## panel's caption) that holds a small DockSite of its own, so several panels
## can share a floating window and the user can rearrange them there too. When
## the last panel leaves, the window is freed. Closing the window closes
## (hides) its panels, subject to `onClose`.
##
## Dragging
## --------
## Press a tab and move more than 5 px: the panel is being dragged. The site
## under the pointer shows an overlay with guides, as in Delphi 2005+ and
## Visual Studio: four arrows plus a centre around the group under the
## pointer (dock left/right/top/bottom of that group, or add as a tab), four
## guides at the edges of the whole site, and a translucent preview of the
## result. Dropping on a guide docks there. Dropping on a group's tab strip
## inserts the tab at that place. Dropping on a window that is a dock site but
## not on a guide does nothing; dropping outside every dock site floats the
## panel at the pointer. Esc cancels. A double click on a tab floats a docked
## panel and docks a floating one back to where it was; the tab's context menu
## offers the same plus Close.
##
## The site under the pointer is found in SCREEN coordinates (window position
## plus pointer position), which works on Windows, macOS and X11. Wayland does
## not tell a client where its windows are, so there a tab cannot be dragged
## from one window to another; use the double click or the context menu to
## dock a floating panel back. `dockScreenOrigin` replaces the origin lookup
## (tests).
##
## Events (on the primary site; floating sites forward to it)
## ----------------------------------------------------------
## * `onDock(site, panel)`: the panel entered a group (docked or floating).
## * `onUndock(site, panel)`: the panel left its group (moved, hidden).
## * `onClose(site, panel, allow)`: the user (close button, Ctrl+F4, the menu,
##   closing a floating window) or `panel.close()` wants to close the panel;
##   set `allow = false` to veto. `hide()` does not ask.
## * `onActivate(site, panel)`: another panel became the active one (tab
##   selected, a click or focus inside it, Ctrl+Tab, docking it).
## * `onLayoutChanged(site)`: the arrangement changed (dock, undock, split
##   drag finished, load). Handy for autosaving `saveLayout`.
##
## Keyboard: Ctrl+Tab / Ctrl+Shift+Tab cycle the tabs of the active group,
## Ctrl+F4 closes the active panel when it is `closable`. The handler is in
## the form's key-handler chain (id "dock"), so it works while focus is
## inside a panel's content.
##
## Layout text: `saveLayout()` returns JSON, `loadLayout(s)` restores splits
## and their weights, tab order, active tabs, floating windows (position and
## size) and hidden panels (with their remembered place), all by panel NAME.
## Names in the text that no panel has are skipped; panels the text does not
## mention are added as tabs of the first group, so a newer program can load
## an older layout. A text that is not a layout returns `false` and changes
## nothing.

import std/[json, math]
import ../platform/[window, events]
import ../core/[form, application]
import ./[common, imagelist, menus]
export imagelist

type
  DockSide* = enum
    dsCenter,    ## into the group as a tab
    dsLeft, dsRight, dsTop, dsBottom

  DockState* = enum
    dpHidden,    ## in no group (closed or never shown)
    dpDocked,    ## in a group of the primary site
    dpFloating   ## in a group of a floating window

  DockPlace = object
    ## Where a hidden panel comes back to.
    valid: bool
    mates: seq[string]     ## panels that shared its group
    tabIndex: int
    anchors: seq[string]   ## panels of the neighbour it sat next to
    side: DockSide
    frac: float32

  DockPanelEvent* = proc(sender: DockSite, panel: DockPanel)
  DockCloseEvent* = proc(sender: DockSite, panel: DockPanel, allow: var bool)

  DockPanel* = ref object of Container
    fSite: DockSite
    fImages: ImageList
    fImageIndex: int
    fListener: int
    fClosable: bool
    fContent: Control
    fDockPlace: DockPlace
    fFloatRect: RectF
    fWasFloating: bool

  DockTabs* = ref object of Container
    fActive: DockPanel
    fHot, fHotClose: int
    fPressTab, fPressClose: int
    fPressPos: PointF
    fDragging: bool
    fMenu: PopupMenu

  DockSplit* = ref object of Container
    fOrient: Orientation
    fWeights: seq[float32]
    fHotGap, fDragGap: int
    fDragPos: float32
    fDragSizes: array[2, float32]
    fDragWeights: array[2, float32]

  TargetKind = enum tkNone, tkGroup, tkEdge, tkTabs, tkEmpty

  DockTarget = object
    kind: TargetKind
    group: DockTabs
    side: DockSide
    tabIndex: int
    preview: RectF

  DockOverlay = ref object of Control
    group: DockTabs        ## the group whose guides are shown
    edges: bool
    empty: bool
    target: DockTarget

  DockSite* = ref object of Container
    fRoot: Control
    fPanels: seq[DockPanel]       # primary only
    fFloats: seq[DockSite]        # primary only
    fPrimary: DockSite            # nil for the primary
    fForm: Form                   # floating sites: their window
    fOverlay: DockOverlay
    fActive: DockPanel            # primary only
    fLoading: bool
    onDock*, onUndock*, onActivate*: DockPanelEvent
    onClose*: DockCloseEvent
    onLayoutChanged*: NotifyEvent

  DragState = ref object
    panel: DockPanel
    source: DockTabs
    site: DockSite
    target: DockTarget

const
  GapSize = 5'f32
  MinPane = 64'f32
  EdgeFrac = 0.25'f32
  SideFrac = 0.5'f32
  DragThreshold = 5'f32
  DefaultFloatW = 340'f32
  DefaultFloatH = 280'f32

var
  gDrag: DragState
  gObserving: bool
  dockScreenOrigin*: proc(f: Form): PointF = nil
    ## Test seam: where the client area of `f` is on the screen (logical px).
    ## nil: the window position.

# ------------------------------------------------------------- small helpers

func primary(s: DockSite): DockSite = (if s.fPrimary == nil: s else: s.fPrimary)
func isFloating*(s: DockSite): bool = s.fPrimary != nil
  ## The site lives in a floating window.
func floatForm*(s: DockSite): Form = s.fForm
func rootNode*(s: DockSite): Control = s.fRoot
  ## The top node of the tree (a `DockSplit` or `DockTabs`), nil when empty.
func panels*(s: DockSite): seq[DockPanel] = s.primary.fPanels
  ## Every panel of the dock system, whatever its state (registration order).
func floatingSites*(s: DockSite): seq[DockSite] = s.primary.fFloats

proc siteOf(n: Control): DockSite =
  var c = n
  while c != nil and not (c of DockSite): c = Control(c.parent)
  if c == nil: nil else: DockSite(c)

func orientation*(s: DockSplit): Orientation = s.fOrient
func weights*(s: DockSplit): seq[float32] = s.fWeights

proc panels*(g: DockTabs): seq[DockPanel] =
  for c in g.children:
    if c of DockPanel: result.add DockPanel(c)

proc panelCount*(g: DockTabs): int =
  for c in g.children:
    if c of DockPanel: inc result

func activePanel*(g: DockTabs): DockPanel = g.fActive

proc activeIndex*(g: DockTabs): int =
  var i = 0
  for c in g.children:
    if Control(c) == Control(g.fActive): return i
    inc i
  -1

proc group*(p: DockPanel): DockTabs =
  ## The group the panel is in; nil when hidden.
  if p.parent != nil and p.parent of DockTabs: DockTabs(p.parent) else: nil

proc site*(p: DockPanel): DockSite =
  ## The site whose tree holds the panel (the primary site or a floating one);
  ## nil when hidden.
  let g = p.group
  if g == nil: nil else: siteOf(g)

func dockSite*(p: DockPanel): DockSite = p.fSite
  ## The primary site the panel was created for.

proc state*(p: DockPanel): DockState =
  let s = p.site
  if s == nil: dpHidden
  elif s.isFloating: dpFloating
  else: dpDocked

proc floatForm*(p: DockPanel): Form =
  ## The window of a floating panel; nil otherwise.
  let s = p.site
  if s != nil and s.isFloating: s.fForm else: nil

func closable*(p: DockPanel): bool = p.fClosable
proc `closable=`*(p: DockPanel, v: bool) =
  p.fClosable = v
  if p.parent != nil: p.parent.invalidate()

func content*(p: DockPanel): Control = p.fContent
func imageIndex*(p: DockPanel): int = p.fImageIndex
func images*(p: DockPanel): ImageList = p.fImages

proc findPanel*(s: DockSite, name: string): DockPanel =
  ## The panel with this name, nil when there is none.
  for p in s.primary.fPanels:
    if p.name == name: return p

proc groups*(s: DockSite): seq[DockTabs] =
  ## Every group of this site's tree, depth first (left/top to right/bottom).
  proc walk(n: Control, acc: var seq[DockTabs]) =
    if n == nil: return
    if n of DockTabs: acc.add DockTabs(n)
    elif n of DockSplit:
      for c in DockSplit(n).children: walk(c, acc)
  walk(s.fRoot, result)

proc fire(s: DockSite, which: int, p: DockPanel) =
  let ps = s.primary
  if ps.fLoading: return
  case which
  of 0:
    let h = ps.onDock
    if h != nil: h(ps, p)
  of 1:
    let h = ps.onUndock
    if h != nil: h(ps, p)
  else:
    let h = ps.onActivate
    if h != nil: h(ps, p)

proc layoutChanged(s: DockSite) =
  let ps = s.primary
  if ps.fLoading: return
  let h = ps.onLayoutChanged
  if h != nil: h(ps)

# -------------------------------------------------------------- constructors

proc initDockPanel*(p: DockPanel, owner: Component = nil) =
  p.initContainer(owner)
  p.fClosable = true
  p.fImageIndex = -1
  p.setBounds(0, 0, 200, 150)
  p.designSet = false
  p.align = alClient

proc initDockTabs(g: DockTabs) =
  g.initContainer()
  g.fHot = -1
  g.fHotClose = -1
  g.fPressTab = -1
  g.fPressClose = -1
  g.setBounds(0, 0, 200, 150)
  g.designSet = false

proc newDockTabs(): DockTabs =
  new result
  result.initDockTabs()

proc newDockSplit(o: Orientation): DockSplit =
  new result
  result.initContainer()
  result.fOrient = o
  result.fHotGap = -1
  result.fDragGap = -1
  result.setBounds(0, 0, 200, 150)
  result.designSet = false

method hitTest*(o: DockOverlay, p: PointF): bool = false

proc initDockSite*(s: DockSite, owner: Component = nil) =
  s.initContainer(owner)
  s.setBounds(0, 0, 400, 300)
  s.designSet = false
  s.padding = spacing(3)
  s.fOverlay = DockOverlay()
  s.fOverlay.initControl(s)
  s.fOverlay.visible = false
  s.insertControl(s.fOverlay)

proc newDockSite*(parent: Container = nil, left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): DockSite {.discardable.} =
  ## A dock site; usually `site.align = alClient` on the main form.
  new result
  result.initDockSite(parent)
  result.placeControl(parent, left, top, width, height)

proc newDockPanel*(site: DockSite, name: string, caption = "",
                   content: Control = nil, closable = true): DockPanel {.discardable.} =
  ## Creates a panel registered with `site` (the primary site of the dock
  ## system), initially HIDDEN: place it with `site.dock(panel, ...)` or
  ## `panel.show()`. `name` identifies the panel in layouts and must be unique.
  doAssert site != nil, "newDockPanel: a site is required"
  doAssert name.len > 0, "newDockPanel: a name is required"
  let ps = site.primary
  doAssert ps.findPanel(name) == nil, "newDockPanel: duplicate panel name " & name
  new result
  result.initDockPanel(ps)
  result.name = name
  result.fSite = ps
  result.fClosable = closable
  Control(result).caption = (if caption.len > 0: caption else: name)
  if content != nil: result.fContent = content
  ps.fPanels.add result
  if content != nil:
    content.align = alClient
    result.insertControl content

proc `content=`*(p: DockPanel, c: Control) =
  ## The control shown in the panel (it fills the panel). A previous content
  ## is only detached.
  if p.fContent == c: return
  if p.fContent != nil and p.fContent.parent == Container(p):
    p.removeControl p.fContent
  p.fContent = c
  if c != nil:
    c.align = alClient
    p.insertControl c

# ---------------------------------------------------------- weights and tree

proc syncWeights(s: DockSplit) =
  let n = s.children.len
  if s.fWeights.len != n:
    s.fWeights = newSeq[float32](n)
    for i in 0 ..< n: s.fWeights[i] = 1'f32 / float32(max(n, 1))

proc normalizeWeights(s: DockSplit) =
  s.syncWeights()
  var sum = 0'f32
  for w in s.fWeights: sum += w
  if sum <= 0:
    for w in s.fWeights.mitems: w = 1'f32 / float32(s.fWeights.len)
  else:
    for w in s.fWeights.mitems: w /= sum

proc indexOfNode(s: DockSplit, n: Control): int = s.children.find(n)

proc insertNode(s: DockSplit, n: Control, index: int, weight: float32) =
  s.syncWeights()
  let at = clamp(index, 0, s.children.len)
  s.insertControl(n, at)
  n.align = alNone
  s.fWeights.insert(weight, min(at, s.fWeights.len))
  if s.fWeights.len != s.children.len: s.fWeights = @[]
  s.syncWeights()

proc rawRemove(s: DockSplit, i: int) =
  ## Removes child `i` and its weight (no redistribution).
  s.syncWeights()
  let n = s.children[i]
  s.removeControl n
  s.fWeights.delete(i)

proc removeNode(s: DockSplit, n: Control) =
  ## Removes `n`; its weight goes to the neighbour that follows it (the one
  ## before when it was last).
  s.syncWeights()
  let i = s.indexOfNode(n)
  if i < 0: return
  let w = s.fWeights[i]
  let nb = if i + 1 < s.children.len: i + 1 else: i - 1
  if nb >= 0: s.fWeights[nb] += w
  s.rawRemove(i)

proc setRoot(site: DockSite, n: Control) =
  if site.fRoot == n: return
  if site.fRoot != nil and site.fRoot.parent == Container(site):
    site.removeControl site.fRoot
  site.fRoot = n
  if n != nil:
    n.align = alClient
    site.insertControl(n, 0)       # the overlay stays on top
  site.relayout()
  site.invalidate()

proc replaceNode(old, nw: Control) =
  ## Puts `nw` where `old` is (same weight / root place); `old` is detached.
  let p = old.parent
  if p == nil: return
  if p of DockSplit:
    let s = DockSplit(p)
    s.syncWeights()
    let i = s.indexOfNode(old)
    let w = s.fWeights[i]
    s.rawRemove(i)
    s.insertNode(nw, i, w)
  elif p of DockSite:
    DockSite(p).setRoot(nw)

proc detachNode(n: Control) =
  let p = n.parent
  if p == nil: return
  if p of DockSplit: DockSplit(p).removeNode(n)
  elif p of DockSite: DockSite(p).setRoot(nil)

proc flatten(s: DockSplit) =
  ## Merges child splits of the same orientation into `s`.
  var i = 0
  while i < s.children.len:
    let c = s.children[i]
    if c of DockSplit and DockSplit(c).fOrient == s.fOrient:
      let cs = DockSplit(c)
      cs.syncWeights()
      s.syncWeights()
      let wc = s.fWeights[i]
      var sum = 0'f32
      for w in cs.fWeights: sum += w
      if sum <= 0: sum = 1
      let kids = cs.children
      let kw = cs.fWeights
      for j in 0 ..< kids.len:
        s.insertNode(kids[j], i + 1 + j, wc * kw[j] / sum)
      s.rawRemove(i)
      # the merged children are re-examined from the same index
    else:
      inc i

proc normalize(n: Control) =
  ## Restores the tidy-tree invariants from `n` upwards.
  var node = n
  while node != nil:
    let p = Control(node.parent)
    if node of DockTabs:
      if DockTabs(node).panelCount > 0: break
      detachNode(node)
      node = if p != nil and p of DockSplit: p else: nil
    elif node of DockSplit:
      let s = DockSplit(node)
      if s.children.len == 0:
        detachNode(node)
        node = if p != nil and p of DockSplit: p else: nil
      elif s.children.len == 1:
        let ch = s.children[0]
        if p == nil: break
        replaceNode(s, ch)
        node = if p of DockSplit: p else: nil
      else:
        s.flatten()
        break
    else: break

proc nodePanelNames(n: Control, acc: var seq[string]) =
  if n of DockTabs:
    for p in DockTabs(n).panels: acc.add p.name
  elif n of DockSplit:
    for c in DockSplit(n).children: nodePanelNames(c, acc)

# ------------------------------------------------------------- group content

proc stripHeight*(g: DockTabs): float32 = max(g.theme.controlHeight - 2, 20)

method padding*(g: DockTabs): Spacing = spacing(1, g.stripHeight, 1, 1)

method inheritedColor*(g: DockTabs): Color = g.theme.surface
method inheritedColor*(p: DockPanel): Color = p.theme.surface

proc showActive(g: DockTabs) =
  for c in g.children:
    if c of DockPanel:
      let want = Control(c) == Control(g.fActive)
      if c.visible != want: c.visible = want

proc setActiveTab(g: DockTabs, p: DockPanel) =
  g.fActive = p
  g.showActive()
  g.invalidate()

method childBoundsChanged*(g: DockTabs, child: Control) =
  procCall childBoundsChanged(Container(g), child)
  # keep the selection valid when panels come and go
  var found = false
  for c in g.children:
    if c of DockPanel and Control(c) == Control(g.fActive): found = true
  if not found:
    g.fActive = nil
    for c in g.children:
      if c of DockPanel:
        g.fActive = DockPanel(c)
        break
  g.showActive()

# ----------------------------------------------------------- activation

proc updateFloatCaption(s: DockSite) =
  if s.isFloating and s.fForm != nil and s.fRoot != nil:
    let gs = s.groups
    if gs.len > 0 and gs[0].fActive != nil:
      s.fForm.caption = gs[0].fActive.caption

proc activate*(p: DockPanel, focus = false) =
  ## Makes the panel the active one: selects its tab, highlights its group,
  ## fires `onActivate` when it was not the active panel; `focus` also moves
  ## the keyboard focus into it.
  let g = p.group
  if g == nil: return
  let ps = p.fSite
  let oldG = if ps.fActive != nil: ps.fActive.group else: nil
  g.setActiveTab(p)
  let changed = ps.fActive != p
  ps.fActive = p
  if oldG != nil and oldG != g: oldG.invalidate()
  g.invalidate()
  let s = siteOf(g)
  if s != nil: s.updateFloatCaption()
  if changed and s != nil: s.fire(2, p)
  if focus:
    let stops = tabStops(p)
    if stops.len > 0: setFocus(stops[0])
    else:
      # nothing to focus here: do not leave the focus in another panel, which
      # would keep receiving the panel keys (Ctrl+Tab, Ctrl+F4)
      let h = p.host
      if h of UiRoot:
        let fc = UiRoot(h).focusedControl
        if fc != nil and not p.isAncestorOf(fc): UiRoot(h).focusControl(nil)

func activePanel*(s: DockSite): DockPanel = s.primary.fActive
  ## The panel that was activated last (nil when none is docked).

# ------------------------------------------------------- place memory

proc capturePlace(p: DockPanel): DockPlace =
  let g = p.group
  if g == nil: return
  result.valid = true
  let ps = g.panels
  for q in ps:
    if q != p: result.mates.add q.name
  result.tabIndex = ps.find(p)
  if result.mates.len > 0: return
  let par = g.parent
  if par != nil and par of DockSplit and DockSplit(par).children.len >= 2:
    let s = DockSplit(par)
    s.syncWeights()
    let i = s.indexOfNode(g)
    let after = i + 1 < s.children.len
    let nb = if after: i + 1 else: i - 1
    nodePanelNames(s.children[nb], result.anchors)
    let tot = s.fWeights[i] + s.fWeights[nb]
    result.frac = if tot > 0: s.fWeights[i] / tot else: 0.3'f32
    result.side =
      if s.fOrient == orHorizontal: (if after: dsLeft else: dsRight)
      else: (if after: dsTop else: dsBottom)

proc screenOrigin(f: Form): PointF =
  if dockScreenOrigin != nil: return dockScreenOrigin(f)
  if f.hasWindow:
    let (x, y) = f.win.position
    return pointF(f.win.toLogical(float32(x)), f.win.toLogical(float32(y)))
  pointF(0, 0)

proc floatRectOf(s: DockSite): RectF =
  ## Window rect of a floating site, logical screen px.
  let f = s.fForm
  if f == nil: return rectF(0, 0, 0, 0)
  let o = screenOrigin(f)
  rectF(o.x, o.y, f.width, f.height)

proc disposeFloat(s: DockSite) =
  let ps = s.primary
  let i = ps.fFloats.find(s)
  if i >= 0: ps.fFloats.delete(i)
  let f = s.fForm
  if f != nil:
    f.onClose = nil
    f.freeWindow()

proc detachPanel(p: DockPanel, remember: bool) =
  ## Takes the panel out of its group (tidying the tree) and fires onUndock.
  let g = p.group
  if g == nil: return
  let s = siteOf(g)
  if remember and s != nil:
    if s.isFloating:
      p.fFloatRect = s.floatRectOf
      p.fWasFloating = true
    else:
      p.fDockPlace = p.capturePlace()
      p.fWasFloating = false
  let ps = p.fSite
  let idx = g.panels.find(p)
  g.removeControl p
  p.visible = true
  if g.fActive == p:
    g.fActive = nil
    let rest = g.panels
    if rest.len > 0: g.fActive = rest[clamp(idx, 0, rest.high)]
    g.showActive()
    g.invalidate()
  if ps.fActive == p: ps.fActive = nil
  normalize(g)
  if s != nil:
    if s.isFloating:
      if s.fRoot == nil: s.disposeFloat()
      else: s.updateFloatCaption()
    s.fire(1, p)
    s.layoutChanged()

# -------------------------------------------------------------- docking

proc insertBeside(site: DockSite, target: Control, ng: DockTabs,
                  side: DockSide, frac: float32) =
  let orient = if side in {dsLeft, dsRight}: orHorizontal else: orVertical
  let before = side in {dsLeft, dsTop}
  let par = target.parent
  if par != nil and par of DockSplit and DockSplit(par).fOrient == orient:
    let s = DockSplit(par)
    s.syncWeights()
    let i = s.indexOfNode(target)
    let wt = s.fWeights[i]
    let nw = wt * frac
    s.fWeights[i] = wt - nw
    s.insertNode(ng, (if before: i else: i + 1), nw)
  else:
    let sp = newDockSplit(orient)
    replaceNode(target, sp)
    if before:
      sp.insertNode(ng, 0, frac)
      sp.insertNode(target, 1, 1 - frac)
    else:
      sp.insertNode(target, 0, 1 - frac)
      sp.insertNode(ng, 1, frac)
    sp.flatten()
    if sp.parent != nil and sp.parent of DockSplit: DockSplit(sp.parent).flatten()

proc insertAtEdge(site: DockSite, ng: DockTabs, side: DockSide, frac: float32) =
  let root = site.fRoot
  if root == nil:
    site.setRoot(ng)
    return
  let orient = if side in {dsLeft, dsRight}: orHorizontal else: orVertical
  let before = side in {dsLeft, dsTop}
  if root of DockSplit and DockSplit(root).fOrient == orient:
    let s = DockSplit(root)
    s.syncWeights()
    var sum = 0'f32
    for w in s.fWeights: sum += w
    let nw = frac / (1 - frac) * sum
    s.insertNode(ng, (if before: 0 else: s.children.len), nw)
    s.normalizeWeights()
  else:
    let sp = newDockSplit(orient)
    site.setRoot(sp)
    if before:
      sp.insertNode(ng, 0, frac)
      sp.insertNode(root, 1, 1 - frac)
    else:
      sp.insertNode(root, 0, 1 - frac)
      sp.insertNode(ng, 1, frac)
    sp.flatten()

proc firstGroup(s: DockSite): DockTabs =
  let gs = s.groups
  if gs.len > 0: gs[0] else: nil

proc dockImpl(p: DockPanel, site: DockSite, target: Control, side: DockSide,
              frac: float32, index: int) =
  ## The one place that puts a panel into a tree. `target` is a node of
  ## `site` (a DockTabs or DockSplit), or nil.
  let ps = p.fSite
  # reorder inside the same group
  if side == dsCenter and target != nil and target of DockTabs and
     p.group == DockTabs(target):
    let g = DockTabs(target)
    let ids = g.panels
    var at = if index < 0: ids.high else: index
    let cur = ids.find(p)
    if at > cur: dec at
    at = clamp(at, 0, ids.high)
    if at != cur:
      g.removeControl p
      g.insertControl(p, at)
      g.fActive = p
      g.showActive()
      g.invalidate()
      site.layoutChanged()
    activate(p)
    return
  p.detachPanel(remember = true)
  # the target may have been tidied away while detaching (only edges can be
  # affected: groups survive because they still hold a panel)
  p.align = alClient
  var ng: DockTabs
  if side == dsCenter:
    var g: DockTabs = nil
    if target != nil and target of DockTabs and target.parent != nil:
      g = DockTabs(target)
    elif target != nil and target of DockSplit:
      let gs = site.groups
      for x in gs:
        if target.isAncestorOf(x):
          g = x
          break
    if g == nil: g = site.firstGroup
    if g == nil:
      ng = newDockTabs()
      site.setRoot(ng)
      g = ng
    let at = if index < 0 or index > g.children.len: g.children.len else: index
    g.insertControl(p, at)
    g.fActive = p
    g.showActive()
  else:
    ng = newDockTabs()
    ng.insertControl p
    ng.fActive = p
    ng.showActive()
    let t = if target != nil and target.parent != nil: target else: nil
    if t == nil or t == site.fRoot:
      insertAtEdge(site, ng, side, if frac > 0: frac else: EdgeFrac)
    else:
      insertBeside(site, t, ng, side, if frac > 0: frac else: SideFrac)
  site.relayout()
  site.invalidate()
  site.fire(0, p)
  activate(p)
  site.layoutChanged()
  discard ps

proc pointInOwnTree(a: Control, b: Control): bool = a == b or a.isAncestorOf(b)

proc lcaNode(site: DockSite, names: seq[string]): Control =
  var gs: seq[DockTabs]
  for nm in names:
    let q = site.primary.findPanel(nm)
    if q != nil and q.group != nil and siteOf(q.group) == site: gs.add q.group
  if gs.len == 0: return nil
  var node: Control = gs[0]
  while node != nil and not (node of DockSite):
    var all = true
    for g in gs:
      if not pointInOwnTree(node, g): all = false
    if all: return node
    node = Control(node.parent)
  nil

proc floatImpl(p: DockPanel, rect: RectF)

proc restoreImpl(p: DockPanel, forceDock: bool) =
  let site = p.fSite
  if not forceDock and p.fWasFloating and not p.fFloatRect.isEmpty:
    floatImpl(p, p.fFloatRect)
    return
  let pl = p.fDockPlace
  if pl.valid:
    for nm in pl.mates:
      let m = site.findPanel(nm)
      if m != nil and m != p and m.state == dpDocked:
        dockImpl(p, site, m.group, dsCenter, 0, pl.tabIndex)
        return
    if pl.anchors.len > 0:
      let node = lcaNode(site, pl.anchors)
      if node != nil:
        dockImpl(p, site, node, pl.side, pl.frac, -1)
        return
  dockImpl(p, site, site.firstGroup, dsCenter, 0, -1)

proc newFloatSite(primary: DockSite, rect: RectF, caption: string): DockSite =
  let f = newForm(nil, rect.w, rect.h)
  f.position = poDesigned
  f.left = rect.x
  f.top = rect.y
  f.caption = caption
  let s = DockSite()
  s.initDockSite()
  s.fPrimary = primary
  s.fForm = f
  s.align = alClient
  f.insertControl s
  primary.fFloats.add s
  f.onClose = proc(sender: Form, action: var CloseAction) =
    action = caNone
    for q in s.groups:
      for pn in q.panels:
        let ps = pn.fSite
        var allow = true
        let h = ps.onClose
        if h != nil: h(ps, pn, allow)
        if allow: pn.detachPanel(remember = true)
  s

proc floatImpl(p: DockPanel, rect: RectF) =
  let primary = p.fSite
  var r = rect
  let cur = p.site
  # a panel alone in its floating window: just move the window
  if cur != nil and cur.isFloating and p.group.panelCount == 1 and
     cur.groups.len == 1 and cur.fForm != nil:
    if not r.isEmpty and cur.fForm.hasWindow:
      let fs = max(cur.fForm.win.forcedScale, 1'f32)
      cur.fForm.win.setPosition(int(r.x * fs), int(r.y * fs))
      cur.fForm.left = r.x
      cur.fForm.top = r.y
    return
  if r.isEmpty:
    var w = DefaultFloatW
    var h = DefaultFloatH
    let g = p.group
    if g != nil and g.width > 80 and g.height > 80:
      w = min(max(g.width, 240), 640)
      h = min(max(g.height, 180), 640)
    var o = pointF(60, 60)
    let mf = Control(primary).root
    if mf != nil and mf of Form and Form(mf).hasWindow:
      let mo = screenOrigin(Form(mf))
      o = pointF(mo.x + 60, mo.y + 60)
    r = rectF(o.x, o.y, w, h)
  p.detachPanel(remember = true)
  let fs = newFloatSite(primary, r, p.caption)
  let ng = newDockTabs()
  ng.insertControl p
  p.align = alClient
  ng.fActive = p
  ng.showActive()
  fs.setRoot(ng)
  fs.fForm.show()
  fs.fForm.relayoutAll()
  fs.fire(0, p)
  activate(p)
  fs.layoutChanged()

# ------------------------------------------------------------------ site API

proc dock*(site: DockSite, panel: DockPanel, target: Control = nil,
           side = dsCenter, size = 0'f32, index = -1) =
  ## Docks `panel` (from any state) at a place.
  ## * `target` a DockPanel (or its DockTabs): relative to that panel's group.
  ##   `dsCenter` adds a tab (at `index`, default last), a side splits the
  ##   group and gives the new group `size` of the pair (default 0.5).
  ## * `target` nil: relative to the whole site. `dsCenter` goes into the first
  ##   group (the first panel of an empty site), a side docks at that edge
  ##   taking `size` of the site (default 0.25).
  ## `size` is a fraction, 0 < size < 1. A panel of another dock system is
  ## refused (`ValueError`).
  if panel.fSite != site.primary:
    raise newException(ValueError, "dock: the panel belongs to another dock system")
  var t: Control = target
  var ts = site
  if t != nil:
    if t of DockPanel:
      let g = DockPanel(t).group
      if g == nil:
        raise newException(ValueError, "dock: the target panel is not docked")
      t = g
    ts = siteOf(t)
    if ts == nil: raise newException(ValueError, "dock: the target is not in a site")
  let fr = if size > 0 and size < 1: size else: 0'f32
  dockImpl(panel, ts, t, side, fr, index)

proc makeFloating*(p: DockPanel, rect = rectF(0, 0, 0, 0)) =
  ## Moves the panel into a floating window at `rect` (logical screen px; an
  ## empty rect picks a size and a place near the main window). A panel that
  ## is alone in its floating window just moves the window.
  floatImpl(p, rect)

proc hide*(p: DockPanel) =
  ## Takes the panel out of the layout; it remembers where it was (`show`
  ## brings it back). Does not ask `onClose`.
  p.detachPanel(remember = true)

proc show*(p: DockPanel) =
  ## Hidden: restores the panel where it was (a floating one floats again,
  ## a docked one returns next to the panels it sat beside, or as a tab).
  ## Docked or floating: activates it (and raises its window).
  if p.group != nil:
    p.activate()
    let f = p.floatForm
    if f != nil: f.bringToFront()
    return
  restoreImpl(p, false)

proc dockBack*(p: DockPanel) =
  ## A floating (or hidden) panel returns to its last docked place.
  if p.group != nil and p.state == dpDocked: return
  if p.group != nil: p.detachPanel(remember = true)
  restoreImpl(p, true)

proc close*(p: DockPanel): bool {.discardable.} =
  ## Asks `onClose`; when allowed, hides the panel. Returns whether it closed.
  if p.group == nil: return true
  let ps = p.fSite
  var allow = true
  let h = ps.onClose
  if h != nil: h(ps, p, allow)
  if not allow: return false
  p.detachPanel(remember = true)
  true

proc setSize*(p: DockPanel, size: float32) =
  ## Sets the size (width in a horizontal split, height in a vertical one) of
  ## the panel's group, in px, by shifting weight to or from its neighbour.
  ## No-op when the group is not inside a split.
  let g = p.group
  if g == nil: return
  let par = g.parent
  if par == nil or not (par of DockSplit): return
  let s = DockSplit(par)
  s.syncWeights()
  let i = s.indexOfNode(g)
  let nb = if i + 1 < s.children.len: i + 1 else: i - 1
  let total = (if s.fOrient == orHorizontal: s.width else: s.height) -
              GapSize * float32(s.children.len - 1)
  if total <= 0: return
  var sum = 0'f32
  for w in s.fWeights: sum += w
  let pair = s.fWeights[i] + s.fWeights[nb]
  let want = clamp(size / total * sum, MinPane / total * sum, pair - MinPane / total * sum)
  s.fWeights[i] = want
  s.fWeights[nb] = pair - want
  s.relayout()
  s.invalidate()
  siteOf(s).layoutChanged()

# ------------------------------------------------------------------ persist

proc placeToJson(pl: DockPlace): JsonNode =
  result = %*{"mates": pl.mates, "ti": pl.tabIndex, "anchors": pl.anchors,
              "side": ord(pl.side), "frac": round(float64(pl.frac), 4)}

proc placeFromJson(j: JsonNode): DockPlace =
  if j == nil or j.kind != JObject: return
  result.valid = true
  for e in j{"mates"}.getElems(): result.mates.add e.getStr
  result.tabIndex = j{"ti"}.getInt(0)
  for e in j{"anchors"}.getElems(): result.anchors.add e.getStr
  let sd = j{"side"}.getInt(0)
  result.side = if sd in 0 .. ord(high(DockSide)): DockSide(sd) else: dsCenter
  result.frac = float32(j{"frac"}.getFloat(0.3))

proc nodeToJson(n: Control): JsonNode =
  if n of DockTabs:
    let g = DockTabs(n)
    var names = newJArray()
    for p in g.panels: names.add %p.name
    result = %*{"tabs": names}
    if g.fActive != nil: result["active"] = %g.fActive.name
  elif n of DockSplit:
    let s = DockSplit(n)
    s.syncWeights()
    var ws = newJArray()
    for w in s.fWeights: ws.add %round(float64(w), 4)
    var cs = newJArray()
    for c in s.children: cs.add nodeToJson(c)
    result = %*{"split": (if s.fOrient == orHorizontal: "h" else: "v"),
                "weights": ws, "children": cs}

proc saveLayout*(site: DockSite): string =
  ## The arrangement as JSON text (see the module comment).
  let ps = site.primary
  var j = %*{"version": 1}
  j["root"] = if ps.fRoot != nil: nodeToJson(ps.fRoot) else: newJNull()
  var fl = newJArray()
  for f in ps.fFloats:
    if f.fRoot == nil: continue
    let r = f.floatRectOf
    fl.add %*{"x": int(round(r.x)), "y": int(round(r.y)),
              "w": int(round(r.w)), "h": int(round(r.h)),
              "root": nodeToJson(f.fRoot)}
  j["floats"] = fl
  var hid = newJArray()
  for p in ps.fPanels:
    if p.state != dpHidden: continue
    var e = %*{"name": p.name, "float": p.fWasFloating,
               "x": int(round(p.fFloatRect.x)), "y": int(round(p.fFloatRect.y)),
               "w": int(round(p.fFloatRect.w)), "h": int(round(p.fFloatRect.h))}
    e["place"] = if p.fDockPlace.valid: placeToJson(p.fDockPlace) else: newJNull()
    hid.add e
  j["hidden"] = hid
  if ps.fActive != nil: j["active"] = %ps.fActive.name
  $j

proc buildNode(ps: DockSite, j: JsonNode, placed: var seq[DockPanel]): Control =
  if j == nil or j.kind != JObject: return nil
  if j.hasKey("tabs"):
    let g = newDockTabs()
    var act: DockPanel
    for e in j["tabs"].getElems():
      let p = ps.findPanel(e.getStr)
      if p == nil or p in placed: continue
      g.insertControl p
      p.align = alClient
      placed.add p
      if p.name == j{"active"}.getStr: act = p
    if g.panelCount == 0: return nil
    g.fActive = if act != nil: act else: g.panels[0]
    g.showActive()
    return g
  if j.hasKey("split"):
    let s = newDockSplit(if j["split"].getStr == "v": orVertical else: orHorizontal)
    let ws = j{"weights"}.getElems()
    var i = 0
    for cj in j{"children"}.getElems():
      let ch = buildNode(ps, cj, placed)
      let w = if i < ws.len: float32(ws[i].getFloat(1)) else: 1'f32
      inc i
      if ch == nil: continue
      s.insertNode(ch, s.children.len, max(w, 0.01'f32))
    if s.children.len == 0: return nil
    if s.children.len == 1:
      let only = s.children[0]
      s.removeControl only
      s.fWeights = @[]
      return only
    s.flatten()
    return s
  nil

proc loadLayout*(site: DockSite, text: string): bool =
  ## Restores a layout made by `saveLayout`. False (and nothing changed) when
  ## `text` is not a layout. Events: panels that were docked or floating and
  ## end up hidden get `onUndock`, hidden ones that appear get `onDock`.
  let ps = site.primary
  var j: JsonNode
  try: j = parseJson(text)
  except CatchableError: return false
  if j.kind != JObject or not j.hasKey("root") or not j.hasKey("version"): return false
  var before: seq[DockState]
  for p in ps.fPanels: before.add p.state
  ps.fLoading = true
  try:
    # tear down
    let oldFloats = ps.fFloats
    for f in oldFloats: f.fRoot = nil          # keep the dispose below simple
    for p in ps.fPanels:
      let g = p.group
      if g != nil:
        g.removeControl p
        p.visible = true
    for f in oldFloats: f.disposeFloat()
    ps.fFloats.setLen 0
    ps.setRoot(nil)
    ps.fActive = nil
    var placed: seq[DockPanel]
    ps.setRoot(buildNode(ps, j["root"], placed))
    for fj in j{"floats"}.getElems():
      let r = rectF(float32(fj{"x"}.getInt(60)), float32(fj{"y"}.getInt(60)),
                    float32(max(fj{"w"}.getInt(320), 160)),
                    float32(max(fj{"h"}.getInt(260), 120)))
      let node = buildNode(ps, fj{"root"}, placed)
      if node == nil: continue
      let fs = newFloatSite(ps, r, "")
      fs.setRoot(node)
      fs.updateFloatCaption()
      fs.fForm.show()
      fs.fForm.relayoutAll()
    for hj in j{"hidden"}.getElems():
      let p = ps.findPanel(hj{"name"}.getStr)
      if p == nil or p in placed: continue
      p.fWasFloating = hj{"float"}.getBool(false)
      p.fFloatRect = rectF(float32(hj{"x"}.getInt(0)), float32(hj{"y"}.getInt(0)),
                           float32(hj{"w"}.getInt(0)), float32(hj{"h"}.getInt(0)))
      p.fDockPlace = placeFromJson(hj{"place"})
      placed.add p
    # panels the layout does not mention: tabs of the first group
    for p in ps.fPanels:
      if p in placed: continue
      var g = ps.firstGroup
      if g == nil:
        g = newDockTabs()
        ps.setRoot(g)
      g.insertControl p
      p.align = alClient
      if g.fActive == nil: g.fActive = p
      g.showActive()
    let an = j{"active"}.getStr
    if an.len > 0:
      let ap = ps.findPanel(an)
      if ap != nil and ap.group != nil: ap.activate()
  finally:
    ps.fLoading = false
  ps.relayout()
  ps.invalidate()
  var i = 0
  for p in ps.fPanels:
    let now = p.state
    if before[i] != dpHidden and now == dpHidden: ps.fire(1, p)
    elif before[i] == dpHidden and now != dpHidden: ps.fire(0, p)
    inc i
  ps.layoutChanged()
  true

# --------------------------------------------------------- guides geometry

const
  GuideSize = 32'f32
  GuideGap = 4'f32

func guideRects*(r: RectF): array[DockSide, RectF] =
  ## The five guides around the centre of `r` (the group's rect, site coords).
  let g = clamp(min(r.w, r.h) / 4, 22'f32, GuideSize)
  let cx = r.x + r.w / 2
  let cy = r.y + r.h / 2
  let d = g + GuideGap
  result[dsCenter] = rectF(cx - g / 2, cy - g / 2, g, g)
  result[dsLeft] = rectF(cx - g / 2 - d, cy - g / 2, g, g)
  result[dsRight] = rectF(cx - g / 2 + d, cy - g / 2, g, g)
  result[dsTop] = rectF(cx - g / 2, cy - g / 2 - d, g, g)
  result[dsBottom] = rectF(cx - g / 2, cy - g / 2 + d, g, g)

func edgeGuideRects*(r: RectF): array[DockSide, RectF] =
  ## The four guides at the edges of the site rect `r` (centre unused).
  let g = GuideSize
  let m = 10'f32
  result[dsLeft] = rectF(r.x + m, r.y + (r.h - g) / 2, g, g)
  result[dsRight] = rectF(r.right - m - g, r.y + (r.h - g) / 2, g, g)
  result[dsTop] = rectF(r.x + (r.w - g) / 2, r.y + m, g, g)
  result[dsBottom] = rectF(r.x + (r.w - g) / 2, r.bottom - m - g, g, g)

func sidePreview(r: RectF, side: DockSide, frac: float32): RectF =
  case side
  of dsLeft: rectF(r.x, r.y, r.w * frac, r.h)
  of dsRight: rectF(r.right - r.w * frac, r.y, r.w * frac, r.h)
  of dsTop: rectF(r.x, r.y, r.w, r.h * frac)
  of dsBottom: rectF(r.x, r.bottom - r.h * frac, r.w, r.h * frac)
  of dsCenter: r

proc siteArea(s: DockSite): RectF =
  let pad = s.padding
  rectF(pad.left, pad.top, max(s.width - pad.horizontal, 0), max(s.height - pad.vertical, 0))

proc groupRect*(s: DockSite, g: DockTabs): RectF =
  ## The group's rect in the site's client coordinates.
  s.rectInAncestor(g)

proc guideRect*(s: DockSite, g: DockTabs, side: DockSide): RectF =
  ## Guide of `side` around group `g` (site coordinates); with `g` nil the
  ## guide at the site's edge.
  if g == nil: edgeGuideRects(s.siteArea)[side]
  else: guideRects(s.groupRect g)[side]

func tabInsertIndex(rects: seq[RectF], x: float32): int =
  result = rects.len
  for i, r in rects:
    if x < r.x + r.w / 2: return i

# ---------------------------------------------------------- tab strip layout

proc tabWidthNatural(g: DockTabs, p: DockPanel): float32 =
  var w = 20'f32 + g.textWidth(displayText(p.caption), g.font.bold)
  if p.fImages != nil and p.fImageIndex >= 0: w += p.fImages.width + 6
  if p.fClosable and p == g.fActive: w += 20   # only the selected tab reserves room
  clamp(w, 56'f32, 220'f32)

proc tabRects*(g: DockTabs): seq[RectF] =
  ## Rect of every tab (client coordinates of the group).
  let ps = g.panels
  var widths: seq[float32]
  var sum = 0'f32
  for p in ps:
    let w = g.tabWidthNatural(p)
    widths.add w
    sum += w
  let avail = max(g.width - 4, 40)
  let k = if sum > avail: avail / sum else: 1'f32
  var x = 2'f32
  let h = g.stripHeight
  for w in widths:
    let tw = floor(w * k)
    result.add rectF(x, 0, tw, h)
    x += tw

proc closeRectOf(g: DockTabs, p: DockPanel, tab: RectF): RectF =
  if not p.fClosable: return rectF(0, 0, 0, 0)
  rectF(tab.right - 21, (tab.h - 16) / 2, 16, 16)

proc tabCloseRect*(g: DockTabs, i: int): RectF =
  ## The close button of tab `i` (empty when the panel is not closable).
  let ps = g.panels
  let rs = g.tabRects
  if i < 0 or i >= ps.len: return rectF(0, 0, 0, 0)
  g.closeRectOf(ps[i], rs[i])

proc tabAt*(g: DockTabs, x, y: float32): int =
  if y < 0 or y >= g.stripHeight: return -1
  let rs = g.tabRects
  for i, r in rs:
    if r.contains(pointF(x, y)): return i
  -1

proc isActiveGroup(g: DockTabs): bool =
  let s = siteOf(g)
  s != nil and s.primary.fActive != nil and s.primary.fActive.group == g

# ---------------------------------------------------------------- drag logic

proc formOf(s: DockSite): Form =
  let r = Control(s).root
  if r != nil and r of Form: Form(r) else: nil

proc dragSites(ps: DockSite): seq[DockSite] =
  for i in countdown(ps.fFloats.high, 0): result.add ps.fFloats[i]
  result.add ps

proc groupAtPoint(s: DockSite, pt: PointF): DockTabs =
  for g in s.groups:
    if s.groupRect(g).contains(pt): return g

proc computeTarget(s: DockSite, pt: PointF, dp: DockPanel): tuple[t: DockTarget, group: DockTabs, edges, empty: bool] =
  let dg = dp.group
  result.t = DockTarget(kind: tkNone)
  if s.fRoot == nil:
    result.empty = true
    let r = s.siteArea
    let gr = guideRects(r)
    if gr[dsCenter].contains(pt):
      result.t = DockTarget(kind: tkEmpty, side: dsCenter, preview: r)
    return
  # no-op cases: the panel alone in the only group of this site
  let soloRoot = dg != nil and siteOf(dg) == s and dg.panelCount == 1 and
                 Control(dg) == s.fRoot
  if not soloRoot:
    result.edges = true
    let er = edgeGuideRects(s.siteArea)
    for side in [dsLeft, dsRight, dsTop, dsBottom]:
      if er[side].contains(pt):
        result.t = DockTarget(kind: tkEdge, side: side,
                              preview: sidePreview(s.siteArea, side, EdgeFrac))
        return
  let g = s.groupAtPoint(pt)
  if g == nil: return
  let gr = s.groupRect(g)
  let solo = dg == g and g.panelCount == 1
  if not solo:
    result.group = g
    let guides = guideRects(gr)
    for side in [dsCenter, dsLeft, dsRight, dsTop, dsBottom]:
      if guides[side].contains(pt):
        result.t = DockTarget(kind: tkGroup, group: g, side: side,
                              preview: sidePreview(gr, side, SideFrac))
        return
  # the tab strip: insert at the pointer (also reorders inside a group)
  let strip = rectF(gr.x, gr.y, gr.w, g.stripHeight)
  if strip.contains(pt) and not (solo and dg == g):
    var rs = g.tabRects
    for r in rs.mitems: r.x += gr.x; r.y += gr.y
    let idx = tabInsertIndex(rs, pt.x)
    let x = if idx < rs.len: rs[idx].x else: (if rs.len > 0: rs[^1].right else: gr.x)
    result.t = DockTarget(kind: tkTabs, group: g, side: dsCenter, tabIndex: idx,
                          preview: rectF(x - 1, gr.y + 2, 3, g.stripHeight - 4))
    result.group = g

proc setOverlay(s: DockSite, group: DockTabs, edges, empty: bool, t: DockTarget) =
  let o = s.fOverlay
  o.group = group
  o.edges = edges
  o.empty = empty
  o.target = t
  if not o.visible:
    o.setBounds(0, 0, s.width, s.height)
    o.visible = true
  o.invalidate()
  s.invalidate()

proc clearOverlay(s: DockSite) =
  if s == nil: return
  let o = s.fOverlay
  o.group = nil
  o.target = DockTarget(kind: tkNone)
  if o.visible:
    o.visible = false
    s.invalidate()

proc clearAllOverlays(ps: DockSite) =
  ps.clearOverlay()
  for f in ps.fFloats: f.clearOverlay()

proc dragging*(): bool = gDrag != nil
  ## A tab is being dragged right now (some site may be showing its guides).

func guidesVisible*(s: DockSite): bool = s.fOverlay.visible
  ## The drag overlay (guides and preview) is showing on this site.

proc cancelDrag() =
  if gDrag == nil: return
  let st = gDrag
  gDrag = nil
  st.panel.fSite.clearAllOverlays()
  if st.source != nil:
    st.source.fDragging = false
    st.source.fPressTab = -1
    st.source.cursor = crDefault

proc pointerSite(ps: DockSite, screen: PointF): tuple[site: DockSite, pt: PointF] =
  for s in ps.dragSites:
    let f = s.formOf
    if f == nil or not f.visible or not f.hasWindow: continue
    let o = screenOrigin(f)
    let local = pointF(screen.x - o.x, screen.y - o.y)
    let sp = s.formToClient(local)
    if s.clientRect.contains(sp): return (s, sp)

proc updateDrag(g: DockTabs, formPt: PointF) =
  let st = gDrag
  let f = Control(g.root)
  if st == nil or f == nil or not (f of Form): return
  let ps = st.panel.fSite
  let screen = pointF(screenOrigin(Form(f)).x + formPt.x, screenOrigin(Form(f)).y + formPt.y)
  let (s, sp) = pointerSite(ps, screen)
  if st.site != nil and st.site != s: st.site.clearOverlay()
  st.site = s
  st.target = DockTarget(kind: tkNone)
  if s == nil: return
  let r = computeTarget(s, sp, st.panel)
  st.target = r.t
  s.setOverlay(r.group, r.edges, r.empty, r.t)

proc finishDrag(g: DockTabs, formPt: PointF) =
  let st = gDrag
  if st == nil: return
  gDrag = nil
  g.fDragging = false
  g.fPressTab = -1
  g.cursor = crDefault
  let p = st.panel
  let ps = p.fSite
  ps.clearAllOverlays()
  let f = Control(g.root)
  if f == nil or not (f of Form): return
  let o = screenOrigin(Form(f))
  let screen = pointF(o.x + formPt.x, o.y + formPt.y)
  let (s, sp) = pointerSite(ps, screen)
  if s == nil:
    # outside every dock site: float it where the pointer is
    let sz = if p.group != nil: sizeF(p.group.width, p.group.height) else: sizeF(0, 0)
    let w = min(max(sz.w, 240), 640)
    let h = min(max(sz.h, 180), 640)
    floatImpl(p, rectF(screen.x - 40, screen.y - 14, w, h))
    return
  let r = computeTarget(s, sp, p)
  let t = r.t
  case t.kind
  of tkNone: discard
  of tkEmpty: dockImpl(p, s, nil, dsCenter, 0, -1)
  of tkEdge: dockImpl(p, s, nil, t.side, EdgeFrac, -1)
  of tkTabs: dockImpl(p, s, t.group, dsCenter, 0, t.tabIndex)
  of tkGroup:
    if t.side == dsCenter: dockImpl(p, s, t.group, dsCenter, 0, -1)
    else: dockImpl(p, s, t.group, t.side, SideFrac, -1)

# -------------------------------------------------------------- DockOverlay

proc drawGuide(c: Canvas, th: Theme, r: RectF, side: DockSide, hot: bool) =
  c.fillRoundRect(r.offset(0, 1), 5, th.shadow)
  c.fillRoundRect(r, 5, if hot: th.accent else: th.surface)
  c.strokeRoundRect(r, 5, if hot: th.accent else: th.borderStrong, 1)
  let ink = if hot: th.accentText else: th.textMuted
  let inner = r.inflate(-7)
  c.strokeRoundRect(inner, 1.5, ink, 1)
  let half = 0.5'f32
  case side
  of dsLeft: c.fillRect(rectF(inner.x, inner.y, inner.w * half, inner.h), ink)
  of dsRight: c.fillRect(rectF(inner.x + inner.w * half, inner.y, inner.w * half, inner.h), ink)
  of dsTop: c.fillRect(rectF(inner.x, inner.y, inner.w, inner.h * half), ink)
  of dsBottom: c.fillRect(rectF(inner.x, inner.y + inner.h * half, inner.w, inner.h * half), ink)
  of dsCenter:
    c.fillRect(rectF(inner.x, inner.y, inner.w * 0.55, 3), ink)
    c.fillRect(rectF(inner.x + inner.w * 0.6, inner.y, inner.w * 0.4, 3), ink.withAlpha(120))

method paint*(o: DockOverlay, c: Canvas) =
  let s = DockSite(o.parent)
  let th = o.theme
  let t = o.target
  if t.kind in {tkGroup, tkEdge, tkEmpty} and not t.preview.isEmpty:
    c.fillRect(t.preview, th.accent.withAlpha(70))
    c.frameRect(t.preview, th.accent.withAlpha(230), 2)
  elif t.kind == tkTabs:
    let strip = s.groupRect(t.group)
    c.fillRect(rectF(strip.x, strip.y, strip.w, t.group.stripHeight), th.accent.withAlpha(45))
    c.fillRect(t.preview, th.accent)
  if o.edges:
    let er = edgeGuideRects(s.siteArea)
    for side in [dsLeft, dsRight, dsTop, dsBottom]:
      c.drawGuide(th, er[side], side, t.kind == tkEdge and t.side == side)
  if o.empty:
    let gr = guideRects(s.siteArea)
    c.drawGuide(th, gr[dsCenter], dsCenter, t.kind == tkEmpty)
  elif o.group != nil and o.group.parent != nil:
    let gr = s.groupRect(o.group)
    let guides = guideRects(gr)
    let hull = rectF(guides[dsLeft].x, guides[dsTop].y,
                     guides[dsRight].right - guides[dsLeft].x,
                     guides[dsBottom].bottom - guides[dsTop].y).inflate(6)
    c.fillRoundRect(hull, 8, th.window.withAlpha(215))
    c.strokeRoundRect(hull, 8, th.border, 1)
    for side in [dsCenter, dsLeft, dsRight, dsTop, dsBottom]:
      c.drawGuide(th, guides[side], side, t.kind == tkGroup and t.group == o.group and t.side == side)

# ---------------------------------------------------------------- DockSite

method paint*(s: DockSite, c: Canvas) =
  let th = s.theme
  c.fillRect(s.clientRect, th.window)
  if s.fRoot == nil:
    c.textRect("Drop panels here", s.font, s.clientRect, th.textMuted, taCenter, vaCenter)

method inheritedColor*(s: DockSite): Color = s.theme.window

proc keyHook(site: DockSite, ui: UiRoot, key: var Key, shift: ShiftState) =
  if gDrag != nil and key == keyEscape:
    cancelDrag()
    key = Key(0)
    return
  if ssAlt in shift or ssSuper in shift or ssCtrl notin shift: return
  var p: DockPanel
  var c = ui.focusedControl
  while c != nil and not (c of DockPanel): c = Control(c.parent)
  if c != nil: p = DockPanel(c)
  else:
    let a = site.primary.fActive
    if a != nil and a.group != nil and Control(a.root) == Control(ui.root): p = a
  if p == nil or p.group == nil: return
  if key == keyTab:
    let ps = p.group.panels
    if ps.len > 1:
      let i = ps.find(p)
      let n = ps[((i + (if ssShift in shift: -1 else: 1)) mod ps.len + ps.len) mod ps.len]
      n.activate(focus = true)
    key = Key(0)
  elif key == keyF4 and ssShift notin shift:
    if p.fClosable: p.close()
    key = Key(0)

proc observeEvent(f: Form, pe: PlatformEvent) =
  ## After each input event: the panel under the click / holding the focus
  ## becomes the active panel.
  if f == nil: return
  var c: Control
  case pe.kind
  of ekMouseDown: c = f.ui.hovered
  of ekKeyDown, ekMouseUp: c = f.ui.focusedControl
  else: return
  while c != nil and not (c of DockPanel): c = Control(c.parent)
  if c == nil: return
  let p = DockPanel(c)
  if p.group != nil and p.fSite.fActive != p: p.activate()

method visibilityChanged*(s: DockSite) =
  if not gObserving:
    gObserving = true
    Application.addEventObserver(observeEvent)
  let h = s.host
  if h of UiRoot:
    let ui = UiRoot(h)
    if not ui.hasKeyHandler("dock"):
      ui.addKeyHandler("dock", proc(key: var Key, shift: ShiftState) =
        keyHook(s, ui, key, shift))

# ---------------------------------------------------------------- DockSplit

proc distribute(w: seq[float32], total, minSize: float32): seq[float32] =
  let n = w.len
  result = newSeq[float32](n)
  if n == 0: return
  var sumAll = 0'f32
  for x in w: sumAll += max(x, 1e-4'f32)
  if total < float32(n) * minSize:
    for i in 0 ..< n: result[i] = max(w[i], 1e-4'f32) / sumAll * total
    return
  var fixed = newSeq[bool](n)
  for _ in 0 .. n:
    var sw = 0'f32
    var rest = total
    for i in 0 ..< n:
      if fixed[i]: rest -= minSize else: sw += max(w[i], 1e-4'f32)
    var again = false
    for i in 0 ..< n:
      if fixed[i]:
        result[i] = minSize
      else:
        result[i] = max(w[i], 1e-4'f32) / sw * rest
        if result[i] < minSize:
          fixed[i] = true
          again = true
    if not again: break

proc paneSizes(s: DockSplit, avail: RectF): seq[float32] =
  s.syncWeights()
  let n = s.children.len
  let total = (if s.fOrient == orHorizontal: avail.w else: avail.h) - GapSize * float32(max(n - 1, 0))
  distribute(s.fWeights, max(total, 0), MinPane)

proc gapRect(s: DockSplit, k: int): RectF =
  ## Gap `k` (between child k and k+1) in client coordinates.
  let a = s.children[k]
  let b = s.children[k + 1]
  if s.fOrient == orHorizontal: rectF(a.left + a.width, 0, b.left - (a.left + a.width), s.height)
  else: rectF(0, a.top + a.height, s.width, b.top - (a.top + a.height))

proc gapAt(s: DockSplit, x, y: float32): int =
  for k in 0 ..< s.children.len - 1:
    if s.gapRect(k).inflate(1).contains(pointF(x, y)): return k
  -1

method arrangeChildren*(s: DockSplit, area: RectF): bool =
  let n = s.children.len
  if n == 0: return true
  let sizes = s.paneSizes(area)
  var pos = if s.fOrient == orHorizontal: area.x else: area.y
  let kids = s.children
  for i in 0 ..< n:
    let e = if i == n - 1: (if s.fOrient == orHorizontal: area.right else: area.bottom)
            else: round(pos + sizes[i])
    let ext = max(e - pos, 0)
    if s.fOrient == orHorizontal: kids[i].setBounds(pos, area.y, ext, area.h)
    else: kids[i].setBounds(area.x, pos, area.w, ext)
    pos = e + GapSize
  true

method paint*(s: DockSplit, c: Canvas) =
  let th = s.theme
  for k in 0 ..< s.children.len - 1:
    if k == s.fDragGap: c.fillRect(s.gapRect(k), th.accent.withAlpha(120))
    elif k == s.fHotGap: c.fillRect(s.gapRect(k), th.accent.withAlpha(50))

method doMouseMove*(s: DockSplit, shift: ShiftState, x, y: float32) =
  if s.fDragGap >= 0:
    if ssLeft notin shift:
      s.fDragGap = -1
      s.invalidate()
    else:
      let k = s.fDragGap
      let pos = if s.fOrient == orHorizontal: x else: y
      let pair = s.fDragSizes[0] + s.fDragSizes[1]
      let first = clamp(s.fDragSizes[0] + pos - s.fDragPos, min(MinPane, pair / 2),
                        pair - min(MinPane, pair / 2))
      let wsum = s.fDragWeights[0] + s.fDragWeights[1]
      s.fWeights[k] = wsum * first / pair
      s.fWeights[k + 1] = wsum - s.fWeights[k]
      s.relayout()
      s.invalidate()
  else:
    let g = s.gapAt(x, y)
    if g != s.fHotGap:
      s.fHotGap = g
      s.invalidate()
    s.cursor = if g < 0: crDefault
               elif s.fOrient == orHorizontal: crSizeWE else: crSizeNS
  procCall doMouseMove(Container(s), shift, x, y)

method doMouseDown*(s: DockSplit, button: MouseButton, shift: ShiftState, x, y: float32) =
  if button == mbLeft:
    let k = s.gapAt(x, y)
    if k >= 0:
      s.syncWeights()
      let sizes = s.paneSizes(rectF(0, 0, s.width, s.height))
      s.fDragGap = k
      s.fDragPos = if s.fOrient == orHorizontal: x else: y
      s.fDragSizes = [sizes[k], sizes[k + 1]]
      s.fDragWeights = [s.fWeights[k], s.fWeights[k + 1]]
      s.invalidate()
  procCall doMouseDown(Container(s), button, shift, x, y)

method doMouseUp*(s: DockSplit, button: MouseButton, shift: ShiftState, x, y: float32) =
  if button == mbLeft and s.fDragGap >= 0:
    s.fDragGap = -1
    s.invalidate()
    let st = siteOf(s)
    if st != nil: st.layoutChanged()
  procCall doMouseUp(Container(s), button, shift, x, y)

method captureLost*(s: DockSplit) =
  if s.fDragGap >= 0:
    s.fDragGap = -1
    s.invalidate()
  procCall captureLost(Container(s))

method doMouseLeave*(s: DockSplit) =
  if s.fHotGap != -1:
    s.fHotGap = -1
    s.invalidate()
  procCall doMouseLeave(Container(s))

# ---------------------------------------------------------------- DockTabs

proc drawCloseGlyph(c: Canvas, r: RectF, col: Color) =
  let cx = r.x + r.w / 2
  let cy = r.y + r.h / 2
  c.line(cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5, col, 1.4)
  c.line(cx - 3.5, cy + 3.5, cx + 3.5, cy - 3.5, col, 1.4)

method paint*(g: DockTabs, c: Canvas) =
  let th = g.theme
  let h = g.stripHeight
  let active = g.isActiveGroup
  let stripBg = if active: mix(th.surfaceAlt, th.accent, 0.1) else: th.surfaceAlt
  c.fillRect(rectF(0, 0, g.width, h), stripBg)
  c.fillRect(rectF(0, h, g.width, max(g.height - h, 0)), th.surface)
  c.fillRect(rectF(0, h - 1, g.width, 1), if active: th.accent.withAlpha(150) else: th.border)
  c.frameRect(g.clientRect, if active: th.accent.withAlpha(150) else: th.border, 1)
  let ps = g.panels
  let rs = g.tabRects
  for i, p in ps:
    let r = rs[i]
    let sel = p == g.fActive
    let hot = g.fHot == i
    if sel:
      c.fillRect(rectF(r.x, r.y, r.w, r.h), th.surface)
      c.fillRect(rectF(r.x, r.y, r.w, 2), if active: th.accent else: th.borderStrong)
    elif hot:
      c.fillRect(rectF(r.x, r.y + 2, r.w, r.h - 3), th.hover)
    var tx = r.x + 10
    if p.fImages != nil and p.fImageIndex >= 0 and r.w >= 80:
      p.fImages.draw(c, p.fImageIndex, tx, r.y + (r.h - p.fImages.height) / 2)
      tx += p.fImages.width + 6
    let cr = g.closeRectOf(p, r)
    let showClose = not cr.isEmpty and (sel or hot)
    let right = if showClose: cr.x - 2 else: r.right - 8
    let col = if sel: th.text else: th.textMuted
    c.textRect(displayText(p.caption), (if sel and active: g.font.bold else: g.font),
               rectF(tx, r.y + 1, max(right - tx, 0), r.h - 1), col, taLeft, vaCenter)
    if showClose:
      let rect = cr
      if g.fHotClose == i:
        c.fillRoundRect(rect, 3, th.pressed)
      c.drawCloseGlyph(rect, if g.fHotClose == i: th.text else: th.textMuted)
  procCall paint(Container(g), c)

proc updateHot(g: DockTabs, x, y: float32) =
  let i = g.tabAt(x, y)
  var hc = -1
  if i >= 0:
    let cr = g.tabCloseRect(i)
    if not cr.isEmpty and cr.contains(pointF(x, y)): hc = i
  if i != g.fHot or hc != g.fHotClose:
    g.fHot = i
    g.fHotClose = hc
    g.invalidate()

proc toggleFloat(p: DockPanel) =
  if p.state == dpFloating: p.dockBack() else: p.makeFloating()

proc showMenu(g: DockTabs, p: DockPanel, x, y: float32) =
  let f = Control(g.root)
  if f == nil or not (f of Form): return
  if g.fMenu == nil: g.fMenu = newPopupMenu()
  let m = g.fMenu
  m.items.clear()
  m.items.addItem(if p.state == dpFloating: "Dock" else: "Float",
                  proc(sender: MenuItem) = toggleFloat(p))
  if p.fClosable:
    m.items.addSeparator()
    m.items.addItem("Close", proc(sender: MenuItem) = p.close())
  let o = g.clientToForm(pointF(x, y))
  m.popup(Form(f), o.x, o.y)

method doMouseDown*(g: DockTabs, button: MouseButton, shift: ShiftState, x, y: float32) =
  let i = g.tabAt(x, y)
  let ps = g.panels
  if i >= 0:
    if button == mbLeft:
      if g.tabCloseRect(i).contains(pointF(x, y)):
        g.fPressClose = i
      else:
        g.fPressTab = i
        g.fPressPos = pointF(x, y)
        ps[i].activate(focus = true)
    elif button == mbRight:
      ps[i].activate()
      g.showMenu(ps[i], x, y)
  elif g.fActive != nil and button == mbLeft:
    g.fActive.activate()
  procCall doMouseDown(Container(g), button, shift, x, y)

method doMouseMove*(g: DockTabs, shift: ShiftState, x, y: float32) =
  g.updateHot(x, y)
  if g.fPressTab >= 0 and ssLeft in shift:
    let ps = g.panels
    if gDrag == nil and g.fPressTab < ps.len:
      let dx = x - g.fPressPos.x
      let dy = y - g.fPressPos.y
      if dx * dx + dy * dy >= DragThreshold * DragThreshold:
        gDrag = DragState(panel: ps[g.fPressTab], source: g)
        g.fDragging = true
        g.cursor = crSizeAll
    if gDrag != nil and gDrag.source == g:
      g.updateDrag(g.clientToForm(pointF(x, y)))
  procCall doMouseMove(Container(g), shift, x, y)

method doMouseUp*(g: DockTabs, button: MouseButton, shift: ShiftState, x, y: float32) =
  if button == mbLeft:
    if gDrag != nil and gDrag.source == g:
      g.finishDrag(g.clientToForm(pointF(x, y)))
    elif g.fPressClose >= 0:
      let i = g.fPressClose
      g.fPressClose = -1
      let ps = g.panels
      if i < ps.len and g.tabCloseRect(i).contains(pointF(x, y)): ps[i].close()
    g.fPressTab = -1
    g.fPressClose = -1
  procCall doMouseUp(Container(g), button, shift, x, y)

method doDblClick*(g: DockTabs) =
  let i = g.fPressTab
  let ps = g.panels
  procCall doDblClick(Container(g))
  if i >= 0 and i < ps.len:
    g.fPressTab = -1
    toggleFloat(ps[i])

method captureLost*(g: DockTabs) =
  if gDrag != nil and gDrag.source == g: cancelDrag()
  g.fPressTab = -1
  g.fPressClose = -1
  procCall captureLost(Container(g))

method doMouseLeave*(g: DockTabs) =
  if g.fHot != -1 or g.fHotClose != -1:
    g.fHot = -1
    g.fHotClose = -1
    g.invalidate()
  procCall doMouseLeave(Container(g))

# --------------------------------------------------------------- DockPanel

method `caption=`*(p: DockPanel, v: string) =
  procCall `caption=`(Control(p), v)
  if p.parent != nil:
    p.parent.invalidate()
    let s = p.site
    if s != nil: s.updateFloatCaption()

proc `images=`*(p: DockPanel, il: ImageList) =
  ## The icon source for `imageIndex`.
  if p.fImages == il: return
  if p.fImages != nil: p.fImages.removeListener(p.fListener)
  p.fImages = il
  if il != nil:
    p.fListener = il.addListener(proc() =
      if p.parent != nil: p.parent.invalidate())
  if p.parent != nil: p.parent.invalidate()

proc `imageIndex=`*(p: DockPanel, v: int) =
  ## Icon of the tab: an index into `images` (-1: none).
  p.fImageIndex = v
  if p.parent != nil: p.parent.invalidate()

method releaseResources*(p: DockPanel) =
  if p.fImages != nil:
    p.fImages.removeListener(p.fListener)
    p.fImages = nil
  procCall releaseResources(Control(p))
