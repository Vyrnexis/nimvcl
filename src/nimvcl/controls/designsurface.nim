## `FormDesigner`: design mode for a container (Delphi's form designer).
##
## Attach a designer to a container (a `Form` shown in its own window, or a
## `Panel` acting as "the form" inside an IDE) and the controls under it stop
## being operated: they are selected, moved and resized instead. Painting stays
## normal; the designer draws the grid, the selection handles and its guides in
## an overlay above the container (`Container.onPaintOver`).
##
## ```nim
## let design = newPanel(host, "", 10, 10, 400, 300)     # the form being designed
## newButton(design, "Button1", 20, 20)
## let fd = newFormDesigner(design)                       # attached right away
## fd.createControl = proc(cls: string): Control = ...    # the palette's factory
## fd.onSelectionChanged = proc(d: FormDesigner, sel: seq[Control]) = ...
## fd.beginCreate "Button"                                # then click or drag
## ```
##
## The designer knows nothing about control classes or properties: new controls
## come from the `createControl` hook, and copy/paste serialisation, double
## click handlers and context menus are the application's job (events below).
##
## Input (all in the designed container's coordinates)
## ---------------------------------------------------
## * Click selects the topmost control under the pointer; an empty area of a
##   container selects the container. Shift+click toggles (a selection always
##   has one parent). Dragging on the empty area of the design root, or
##   Ctrl+drag inside another container, draws a rubber band.
## * Dragging selected controls shows outlines and drops them where released:
##   onto another container that accepts children (it is highlighted) they are
##   reparented. Positions snap to the grid (`grid`, default 8) and, with
##   `snapLines`, to edges and centres of sibling controls (guide lines are
##   drawn); Alt disables both.
## * The 8 handles resize (live); the constraints and `minSize` apply. Aligned
##   controls (`align != alNone`) cannot be moved and show only the handle of
##   their free edge. The design root has the right, bottom and corner handles
##   (inside its corner), which resize the designed form as one undo step; it
##   cannot be moved.
## * Keys: arrows move 1 px (Ctrl: one grid step), Shift+arrows resize (with
##   Ctrl: grid step), Delete deletes, Esc cancels a drag or creation, else
##   selects the parent, Tab and Shift+Tab walk the siblings, Ctrl+A selects
##   all siblings, Ctrl+C / X / V raise `onCopy` / `onCut` / `onPaste`, Ctrl+Z
##   undoes, Ctrl+Y or Ctrl+Shift+Z redoes.
## * `beginCreate(className)`, then a click (default size) or a drag
##   (rectangle) on a container creates a control through `createControl`.
##
## Undo: move, resize, reparent, z-order, align commands, create and delete are
## undoable. A deleted control is kept in the stack and put back as the same
## object; with the `snapshot` and `restore` hooks set it is serialised and
## freed instead, and `restore` rebuilds it on undo.
##
## Non-visual components (timers, image lists, menus...) are registered with
## `addNonVisual` and drawn as small draggable tiles; they are not in the
## control tree. They appear in selections as `NonVisualTile` controls. A
## tile's position is kept in its component's `designLeft`/`designTop`.
##
## The overlay is repainted correctly with partial repaints as long as changes
## go through the designer. After you change the geometry of a selected control
## yourself (an inspector editing `left`), call `refresh()`.

import std/[algorithm, strutils, sequtils]
import ./common, ./panel, ./scrolling, ./scrollbar, ./scrollbox, ./pagecontrol
import ../graphics/image
import ../core/design
export design

type
  DesignHandle* = enum
    dhNW, dhN, dhNE, dhE, dhSE, dhS, dhSW, dhW

  AlignEdge* = enum
    aeLefts, aeRights, aeTops, aeBottoms, aeHCenters, aeVCenters

  NonVisualTile* = ref object of Control
    ## Stands for a non-visual component on the design surface. Not part of
    ## the control tree.
    component*: Component
    kind*: string
    icon*: Image

  SelectionEvent* = proc(sender: FormDesigner, selection: seq[Control])
  DesignNotify* = proc(sender: FormDesigner)
  DesignControlEvent* = proc(sender: FormDesigner, c: Control)
  DesignControlsEvent* = proc(sender: FormDesigner, controls: seq[Control])
  DesignDeletingEvent* = proc(sender: FormDesigner, controls: seq[Control],
                              allow: var bool)
  DesignContextEvent* = proc(sender: FormDesigner, c: Control, p: PointF)
    ## `p` is in the coordinates of the form window (ready for a popup).
  DesignPasteEvent* = proc(sender: FormDesigner, target: Container)
  CreateControlHook* = proc(className: string): Control
  NameControlHook* = proc(sender: FormDesigner, c: Control, className: string): string
  SnapshotHook* = proc(c: Control): string
  RestoreHook* = proc(snapshot: string, parent: Container, index: int): Control

  DragMode = enum dmNone, dmMove, dmResize, dmBand, dmCreate

  Placement = object
    parent: Container
    index: int
    bounds: RectF               # in the parent's client coordinates

  OpItem = object
    c: Control
    owner: Component
    hasBefore, hasAfter: bool
    before, after: Placement
    snap: string
    tree: seq[Control]          ## the deleted control and its descendants (preorder), to remap history on restore

  DesignOp = ref object
    items: seq[OpItem]

  FormDesigner* = ref object of DesignHook
    grid*: float32              ## grid size in px (default 8; < 2 = no snapping)
    snapToGrid*: bool           ## default true
    snapLines*: bool            ## snap to sibling edges and centres (default true)
    snapDistance*: float32      ## reach of the snap lines (default 5)
    minSize*: float32           ## smallest size a resize can produce (default 4)
    undoLimit*: int             ## default 100
    componentOwner*: Component  ## owner of created controls (default: the root)
    createControl*: CreateControlHook
    nameControl*: NameControlHook
    acceptsChildren*: proc(c: Container): bool
    snapshot*: SnapshotHook
    restore*: RestoreHook
    onSelectionChanged*: SelectionEvent
    onModified*: DesignNotify
    onCreated*: DesignControlEvent
    onDeleting*: DesignDeletingEvent
    onDeleted*: DesignControlsEvent
    onDoubleClick*: DesignControlEvent
    onContextMenu*: DesignContextEvent
    onCopy*, onCut*: DesignControlsEvent
    onPaste*: DesignPasteEvent
    fSel: seq[Control]
    fTiles: seq[NonVisualTile]
    fMode: DragMode
    fStart, fLast: PointF
    fMoved: bool
    fPending: Control           # selected control pressed without moving
    fMoveSet: seq[Control]
    fMoveOrig: seq[RectF]       # scope coordinates
    fGhosts: seq[RectF]
    fTarget: Container
    fGuides: seq[RectF]
    fResHandle: DesignHandle
    fResSet: seq[Control]
    fResOrig: seq[OpItem]
    fSelBeforeBand: seq[Control]  ## the selection a rubber band replaced, back on Esc
    fBandParent: Container
    fBand: RectF
    fCreating: string
    fCreateTarget: Container
    fUndo, fRedo: seq[DesignOp]
    fLastOver: seq[RectF]
    fAttached: bool
    fShowGrid, fShowHidden: bool

const
  HandleSize = 6'f32
  DragThreshold = 3'f32
  TileSize = 32'f32

# ------------------------------------------------------------------ helpers

func isTile(c: Control): bool = c of NonVisualTile

func sameRect(a, b: RectF): bool =
  a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h

func tileArea(t: Control): RectF =
  ## The tile with its caption.
  rectF(t.left - 24, t.top - 2, TileSize + 48, TileSize + 22)

func defaultAccepts*(c: Container): bool =
  ## Containers that take dropped controls by default: panels (and their
  ## subclasses), group boxes, tab sheets, tab controls and scroll boxes.
  c of Panel or c of GroupBox or c of TabSheet or c of TabControl or
    c of ScrollBox

func isInternal(c: Control): bool =
  ## Scroll bars of a scrolling control are not design children.
  c of ScrollBar and c.parent != nil and c.parent of ScrollingControl

func snapV(v, grid: float32): float32 = round(v / grid) * grid

func hasGrid(d: FormDesigner): bool = d.grid >= 2

func showGrid*(d: FormDesigner): bool = d.fShowGrid
  ## Dots on the design root background (default true).
func showHidden*(d: FormDesigner): bool = d.fShowHidden
  ## `visible = false` controls are selectable and drawn as dashed outlines
  ## (default false).

proc boundsOf*(d: FormDesigner, c: Control): RectF =
  ## The control's rectangle in the design root's client coordinates.
  if c.isTile or c.parent == nil: rectF(c.left, c.top, c.width, c.height)
  else: rectInAncestor(d.scope, c)

proc parentOrigin(d: FormDesigner, p: Container): PointF =
  if p == d.scope: pointF(0, 0)
  else:
    let r = rectInAncestor(d.scope, p)
    pointF(r.x, r.y)

proc localOf(d: FormDesigner, parent: Container, p: PointF): PointF =
  ## Root coordinates to `left`/`top` values inside `parent`.
  let o = d.parentOrigin(parent)
  let s = parent.scrollOffset
  pointF(p.x - o.x + s.x, p.y - o.y + s.y)

proc accepts(d: FormDesigner, c: Container): bool =
  c == d.scope or
    (if d.acceptsChildren != nil: d.acceptsChildren(c) else: defaultAccepts(c))

proc shown(d: FormDesigner, c: Control): bool = c.visible or d.fShowHidden

proc hitIn(d: FormDesigner, c: Container, lp: PointF): Control =
  let vp = c.viewportRect()
  let inView = vp.contains(lp)
  for i in countdown(c.controlCount - 1, 0):
    let ch = c[i]
    if not d.shown(ch) or ch.isInternal: continue
    if ch.align == alNone and not inView: continue
    let q = ch.parentToClient(lp)
    if not ch.clientRect.contains(q): continue
    if ch of Container and d.accepts(Container(ch)):
      let deeper = d.hitIn(Container(ch), q)
      if deeper != nil: return deeper
    return ch

proc hit*(d: FormDesigner, p: PointF): Control =
  ## What a click at `p` selects: a non-visual tile, the topmost control, else
  ## the design root.
  for i in countdown(d.fTiles.high, 0):
    let t = d.fTiles[i]
    if rectF(t.left, t.top, t.width, t.height).contains(p): return t
  result = d.hitIn(d.scope, p)
  if result == nil: result = d.scope

proc containerAt(d: FormDesigner, c: Container, lp: PointF,
                 excl: seq[Control]): Container =
  ## The deepest accepting container at `lp` that is not one of `excl`.
  result = c
  let vp = c.viewportRect()
  let inView = vp.contains(lp)
  for i in countdown(c.controlCount - 1, 0):
    let ch = c[i]
    if not d.shown(ch) or ch.isInternal or ch in excl: continue
    if ch.align == alNone and not inView: continue
    let q = ch.parentToClient(lp)
    if not ch.clientRect.contains(q): continue
    if ch of Container and d.accepts(Container(ch)):
      return d.containerAt(Container(ch), q, excl)
    return

proc dropTarget(d: FormDesigner, p: PointF, excl: seq[Control]): Container =
  d.containerAt(d.scope, p, excl)

proc handleMask*(d: FormDesigner, c: Control): set[DesignHandle] =
  ## The handles `c` shows: all eight, the free edge of an aligned control,
  ## none for tiles and `alClient` controls. The design root has the right,
  ## bottom and bottom-right ones (drawn inside its corner) unless its size is
  ## owned by an `align`.
  if c == Control(d.scope):
    return if c.align in {alNone, alCustom}: {dhE, dhS, dhSE} else: {}
  if c.isTile: return {}
  case c.align
  of alNone, alCustom: {dhNW .. dhW}
  of alTop: {dhS}
  of alBottom: {dhN}
  of alLeft: {dhE}
  of alRight: {dhW}
  of alClient: {}

proc handleRect*(r: RectF, h: DesignHandle): RectF =
  ## Where handle `h` of a control occupying `r` is drawn.
  let s = HandleSize
  let mx = r.x + r.w / 2 - s / 2
  let my = r.y + r.h / 2 - s / 2
  case h
  of dhNW: rectF(r.x - s, r.y - s, s, s)
  of dhN: rectF(mx, r.y - s, s, s)
  of dhNE: rectF(r.right, r.y - s, s, s)
  of dhE: rectF(r.right, my, s, s)
  of dhSE: rectF(r.right, r.bottom, s, s)
  of dhS: rectF(mx, r.bottom, s, s)
  of dhSW: rectF(r.x - s, r.bottom, s, s)
  of dhW: rectF(r.x - s, my, s, s)

proc handleRectOf(d: FormDesigner, c: Control, r: RectF, h: DesignHandle): RectF =
  ## Handles of a control hang outside it; those of the design root sit
  ## inside its edges, since nothing outside the root is painted or hit.
  if c != Control(d.scope): return handleRect(r, h)
  let s = HandleSize
  let mx = r.x + r.w / 2 - s / 2
  let my = r.y + r.h / 2 - s / 2
  case h
  of dhE: rectF(r.right - s, my, s, s)
  of dhS: rectF(mx, r.bottom - s, s, s)
  of dhSE: rectF(r.right - s, r.bottom - s, s, s)
  else: handleRect(r, h)

proc visibleHandles(d: FormDesigner, c: Control): set[DesignHandle] =
  result = d.handleMask(c)
  let r = d.boundsOf(c)
  if r.w < 3 * HandleSize: result.excl {dhN, dhS}
  if r.h < 3 * HandleSize: result.excl {dhE, dhW}

func hx(h: DesignHandle): int =
  case h
  of dhNW, dhW, dhSW: -1
  of dhNE, dhE, dhSE: 1
  else: 0
func hy(h: DesignHandle): int =
  case h
  of dhNW, dhN, dhNE: -1
  of dhSW, dhS, dhSE: 1
  else: 0

proc handleCursor(h: DesignHandle): Cursor =
  case h
  of dhNW, dhSE: crSizeNWSE
  of dhNE, dhSW: crSizeNESW
  of dhN, dhS: crSizeNS
  of dhE, dhW: crSizeWE

proc handleAt(d: FormDesigner, p: PointF, h: var DesignHandle): bool =
  for c in d.fSel:
    let r = d.boundsOf(c)
    for k in d.visibleHandles(c):
      if d.handleRectOf(c, r, k).inflate(2).contains(p):
        h = k
        return true

# ---------------------------------------------------------- selection state

func selection*(d: FormDesigner): seq[Control] = d.fSel
func primary*(d: FormDesigner): Control =
  ## The first selected control (dark handles); nil when nothing is selected.
  if d.fSel.len > 0: d.fSel[0] else: nil
func isSelected*(d: FormDesigner, c: Control): bool = c in d.fSel
func attached*(d: FormDesigner): bool = d.fAttached
func creating*(d: FormDesigner): string = d.fCreating
  ## The class waiting for a click, "" when not creating.
func dragging*(d: FormDesigner): bool = d.fMode != dmNone
func canUndo*(d: FormDesigner): bool = d.fUndo.len > 0
func canRedo*(d: FormDesigner): bool = d.fRedo.len > 0
func nonVisuals*(d: FormDesigner): seq[NonVisualTile] = d.fTiles

proc overlayRects(d: FormDesigner): seq[RectF] =
  for c in d.fSel:
    if not c.isTile: result.add d.boundsOf(c).inflate(HandleSize + 2)
  for t in d.fTiles: result.add tileArea(t).inflate(2)
  for g in d.fGhosts: result.add g.inflate(3)
  if d.fTarget != nil:
    result.add d.boundsOf(d.fTarget).inflate(3)
  for g in d.fGuides: result.add g.inflate(2)
  if d.fBand.w > 0 or d.fBand.h > 0: result.add d.fBand.inflate(2)

proc syncTiles(d: FormDesigner) =
  ## Keeps `designLeft`/`designTop` of the tiles' components at the tile position.
  for t in d.fTiles:
    if t.component != nil:
      t.component.designLeft = int(round(t.left))
      t.component.designTop = int(round(t.top))

proc refresh*(d: FormDesigner) =
  ## Repaints the overlay (old and new areas). Call after changing the
  ## geometry of a selected control from outside the designer.
  if d.scope == nil: return
  d.syncTiles()
  for r in d.fLastOver: d.scope.invalidate(r)
  d.fLastOver = d.overlayRects()
  for r in d.fLastOver: d.scope.invalidate(r)

proc prune(d: FormDesigner) =
  ## Drops selected controls that left the design root.
  var keep: seq[Control]
  for c in d.fSel:
    if c.isTile:
      if NonVisualTile(c) in d.fTiles: keep.add c
    elif c == Control(d.scope) or d.scope.isAncestorOf(c): keep.add c
  if keep.len != d.fSel.len:
    d.fSel = keep

proc setSelection(d: FormDesigner, items: seq[Control]) =
  if items == d.fSel:
    return
  d.fSel = items
  d.refresh()
  if d.onSelectionChanged != nil: d.onSelectionChanged(d, d.fSel)

proc select*(d: FormDesigner, c: Control) =
  ## Selects `c` alone (nil: the design root).
  d.setSelection(@[if c == nil: Control(d.scope) else: c])

proc select*(d: FormDesigner, cs: openArray[Control]) =
  d.setSelection(if cs.len == 0: @[Control(d.scope)] else: @cs)

proc clearSelection*(d: FormDesigner) = d.setSelection(@[])

proc groupOf(c: Control): Container = (if c.isTile: nil else: c.parent)

proc toggle*(d: FormDesigner, c: Control) =
  ## Shift+click: adds or removes `c`. A control with another parent replaces
  ## the selection; the design root is never part of a multi-selection.
  if c == Control(d.scope): return
  var s = d.fSel
  let i = s.find(c)
  if i >= 0: s.delete i
  elif s.len == 0 or s[0] == Control(d.scope) or s[0].groupOf != c.groupOf or
       (s[0].isTile != c.isTile): s = @[c]
  else: s.add c
  d.setSelection(s)

# ------------------------------------------------------- tree and undo ops

proc identOnly(s: string): string =
  for ch in s:
    if ch in IdentChars: result.add ch

proc nameUsed(d: FormDesigner, name: string): bool =
  ## True when a control or component under the design root (also one owned by
  ## another component: a menu item, a timer in a panel) has this name. Compared
  ## like Nim identifiers (case and underscores do not count), since the form
  ## file turns each name into a field.
  var seen: seq[Component]
  proc walk(c: Component, name: string): bool =
    if c == nil or c in seen: return false
    seen.add c
    if c.name.len > 0 and cmpIgnoreStyle(c.name, name) == 0: return true
    for x in c.components:
      if walk(x, name): return true
    if c of Container:
      for k in Container(c).children:
        if walk(k, name): return true
  if walk(d.scope, name): return true
  walk(if d.componentOwner != nil: d.componentOwner else: Component(d.scope), name)

proc uniqueName*(d: FormDesigner, className: string): string =
  ## `className` plus the smallest number that no control or component under
  ## the design root uses: "Button1", "Button2"...
  var base = identOnly(className)
  if base.len == 0: base = "Control"
  var n = 1
  while d.nameUsed(base & $n): inc n
  base & $n

proc placementOf(d: FormDesigner, c: Control): Placement =
  if c.isTile:
    Placement(index: d.fTiles.find(NonVisualTile(c)),
              bounds: rectF(c.left, c.top, c.width, c.height))
  else:
    Placement(parent: c.parent,
              index: (if c.parent != nil: c.parent.children.find(c) else: 0),
              bounds: rectF(c.left, c.top, c.width, c.height))

proc applyPlacement(d: FormDesigner, c: Control, pl: Placement) =
  if not c.isTile and pl.parent != nil:
    if c.parent != pl.parent or pl.parent.children.find(c) != pl.index:
      pl.parent.insertControl(c, pl.index)
  c.setBounds(pl.bounds.x, pl.bounds.y, pl.bounds.w, pl.bounds.h)

proc replaceRef(d: FormDesigner, op: DesignOp, old, nw: Control) =
  ## `nw` stands in for `old` (a control rebuilt by `restore`) everywhere the
  ## history or the selection mention it, also as the parent of a placement.
  let oldBox = if old of Container: Container(old) else: nil
  let newBox = if nw of Container: Container(nw) else: nil
  for st in [d.fUndo, d.fRedo, @[op]]:
    for o in st:
      for it in o.items.mitems:
        if it.c == old: it.c = nw
        if oldBox != nil and newBox != nil:
          if it.before.parent == oldBox: it.before.parent = newBox
          if it.after.parent == oldBox: it.after.parent = newBox
  for c in d.fSel.mitems:
    if c == old: c = nw

proc subtreeOf(c: Control): seq[Control] =
  ## `c` and the controls below it, in preorder.
  result = @[c]
  if c of Container:
    for k in Container(c).children: result.add subtreeOf(k)

proc detachItem(d: FormDesigner, op: DesignOp, i: int) =
  ## Takes the control out of the design (delete, undo of create).
  let c = op.items[i].c
  if c.isTile:
    let k = d.fTiles.find(NonVisualTile(c))
    if k >= 0: d.fTiles.delete k
    return
  # a deleted control's owner is kept for the undo; the component of a tile
  # stays with its owner (the host saves from `nonVisuals`)
  op.items[i].owner = c.owner
  if d.snapshot != nil and d.restore != nil:
    op.items[i].snap = d.snapshot(c)
    op.items[i].tree = subtreeOf(c)
    c.free()
  else:
    if c.parent != nil: c.parent.removeControl(c)
    if c.owner != nil: c.owner.removeComponent(c)

proc attachItem(d: FormDesigner, op: DesignOp, i: int, pl: Placement) =
  ## Puts the control back (undo of delete, redo of create).
  var c = op.items[i].c
  if c.isTile:
    let t = NonVisualTile(c)
    if t notin d.fTiles: d.fTiles.insert(t, min(max(pl.index, 0), d.fTiles.len))
    c.setBounds(pl.bounds.x, pl.bounds.y, pl.bounds.w, pl.bounds.h)
    return
  if d.restore != nil and op.items[i].snap.len > 0:
    let nc = d.restore(op.items[i].snap, pl.parent, pl.index)
    if nc != nil:
      # the rebuilt subtree replaces the freed one in the history
      let fresh = subtreeOf(nc)
      let old = op.items[i].tree
      if fresh.len == old.len:
        for k in 0 ..< old.len: d.replaceRef(op, old[k], fresh[k])
      else: d.replaceRef(op, c, nc)
      c = nc
      if c.parent != pl.parent: pl.parent.insertControl(c, pl.index)
      c.setBounds(pl.bounds.x, pl.bounds.y, pl.bounds.w, pl.bounds.h)
      return
  pl.parent.insertControl(c, pl.index)
  let o = op.items[i].owner
  if o != nil: o.insertComponent(c)
  c.setBounds(pl.bounds.x, pl.bounds.y, pl.bounds.w, pl.bounds.h)

proc modified(d: FormDesigner) =
  if d.onModified != nil: d.onModified(d)

proc record(d: FormDesigner, op: DesignOp) =
  if op.items.len == 0: return
  d.fUndo.add op
  if d.undoLimit > 0 and d.fUndo.len > d.undoLimit: d.fUndo.delete 0
  d.fRedo.setLen 0
  d.modified()

proc item(d: FormDesigner, c: Control): OpItem =
  OpItem(c: c, hasBefore: true, hasAfter: true, before: d.placementOf(c))

proc finish(d: FormDesigner, it: var OpItem) =
  it.after = d.placementOf(it.c)

proc samePlacement(a, b: Placement): bool =
  a.parent == b.parent and a.index == b.index and sameRect(a.bounds, b.bounds)

proc clearUndo*(d: FormDesigner) =
  d.fUndo.setLen 0
  d.fRedo.setLen 0

proc afterHistory(d: FormDesigner, op: DesignOp, undone: bool) =
  var sel: seq[Control]
  for it in op.items:
    if (undone and it.hasBefore) or (not undone and it.hasAfter): sel.add it.c
  d.prune()
  d.select(sel)
  d.refresh()
  d.modified()

proc undo*(d: FormDesigner): bool =
  ## Reverts the last operation. False when there is nothing to undo.
  if d.fUndo.len == 0: return false
  let op = d.fUndo.pop()
  for i in countdown(op.items.high, 0):
    let it = op.items[i]
    if it.hasBefore:
      if it.hasAfter: d.applyPlacement(it.c, it.before)
      else: d.attachItem(op, i, it.before)
    else:
      d.detachItem(op, i)
  d.fRedo.add op
  d.afterHistory(op, true)
  true

proc redo*(d: FormDesigner): bool =
  if d.fRedo.len == 0: return false
  let op = d.fRedo.pop()
  for i in 0 .. op.items.high:
    let it = op.items[i]
    if it.hasAfter:
      if it.hasBefore: d.applyPlacement(it.c, it.after)
      else: d.attachItem(op, i, it.after)
    else:
      d.detachItem(op, i)
  d.fUndo.add op
  d.afterHistory(op, false)
  true

# ------------------------------------------------------------ non-visuals

proc addNonVisual*(d: FormDesigner, comp: Component, x, y: float32,
                   kind = "", icon: Image = nil): NonVisualTile {.discardable.} =
  ## Shows `comp` as a tile at (`x`, `y`) in the design root. `kind` (a short
  ## class name such as "Timer") and `icon` decide what the tile shows; the
  ## component's name is drawn under it. The position is kept in the
  ## component's `designLeft`/`designTop` while the tile is moved.
  let t = NonVisualTile(component: comp, kind: kind, icon: icon)
  t.initControl()
  t.name = comp.name
  t.setBounds(x, y, TileSize, TileSize)
  d.fTiles.add t
  d.refresh()
  t

proc addNonVisual*(d: FormDesigner, comp: Component, kind = "",
                   icon: Image = nil): NonVisualTile {.discardable.} =
  ## Like the other `addNonVisual`, at the position saved in the component
  ## (`designLeft`, `designTop`, as a form file stores them). A component
  ## without a saved position (both 0) goes to the next free spot of a row
  ## along the top of the design root.
  var x = float32(comp.designLeft)
  var y = float32(comp.designTop)
  if comp.designLeft == 0 and comp.designTop == 0:
    x = 8 + float32(d.fTiles.len) * (TileSize + 24)
    y = 8
  d.addNonVisual(comp, x, y, kind, icon)

proc removeNonVisual*(d: FormDesigner, comp: Component) =
  for i in 0 ..< d.fTiles.len:
    if d.fTiles[i].component == comp:
      let t = d.fTiles[i]
      d.fTiles.delete i
      d.prune()
      d.setSelection(d.fSel.filterIt(it != Control(t)))
      d.refresh()
      return

# ------------------------------------------------------------- operations

proc movable(d: FormDesigner, c: Control): bool =
  c != Control(d.scope) and (c.isTile or c.align == alNone)

proc sizeOk(d: FormDesigner, c: Control, w, h: float32): tuple[w, h: float32] =
  let k = c.constraints
  (k.clampWidth(max(w, d.minSize)), k.clampHeight(max(h, d.minSize)))

proc setLocal(c: Control, x, y, w, h: float32) =
  if c.align == alNone or c.isTile: c.setBounds(x, y, w, h)
  else: c.setBounds(c.left, c.top, w, h)

proc applyAll(d: FormDesigner, targets: seq[Control],
              change: proc(c: Control, i: int)) =
  ## Runs `change` for each control and records one undo step.
  let op = DesignOp()
  for i, c in targets:
    var it = d.item(c)
    change(c, i)
    d.finish(it)
    if not samePlacement(it.before, it.after): op.items.add it
  d.refresh()
  d.record op

proc sameParentSel(d: FormDesigner): seq[Control] =
  for c in d.fSel:
    if c != Control(d.scope) and (c.isTile or c.parent != nil): result.add c

proc nudge*(d: FormDesigner, dx, dy: float32, resize = false) =
  ## Moves (or with `resize`, resizes) the selection by (`dx`, `dy`) px as one
  ## undo step. Aligned controls only resize along their free edge.
  let sel = d.sameParentSel()
  d.applyAll(sel, proc(c: Control, i: int) =
    if resize:
      var ddx = dx
      var ddy = dy
      if c.align != alNone and c.align != alCustom:
        if c.align in {alTop, alBottom}: ddx = 0 else: ddy = 0
        if c.align == alBottom: ddy = -ddy      # the free edge is the top one
        if c.align == alRight: ddx = -ddx
        if c.align == alClient:
          ddx = 0
          ddy = 0
      if c.isTile:
        ddx = 0
        ddy = 0
      let (w, h) = d.sizeOk(c, c.width + ddx, c.height + ddy)
      c.setLocal(c.left, c.top, w, h)
    elif d.movable(c):
      c.setBounds(c.left + dx, c.top + dy, c.width, c.height))

proc bringToFront*(d: FormDesigner) =
  ## Raises the selection above its siblings (one undo step).
  var sel = d.sameParentSel().filterIt(not it.isTile)
  sel.sort(proc(a, b: Control): int = cmp(a.parent.children.find(a),
                                           b.parent.children.find(b)))
  d.applyAll(sel, proc(c: Control, i: int) = c.bringToFront())

proc sendToBack*(d: FormDesigner) =
  var sel = d.sameParentSel().filterIt(not it.isTile)
  sel.sort(proc(a, b: Control): int = cmp(b.parent.children.find(b),
                                           a.parent.children.find(a)))
  d.applyAll(sel, proc(c: Control, i: int) = c.sendToBack())

proc freeSel(d: FormDesigner): seq[Control] =
  ## The selected controls that can be repositioned by commands.
  d.sameParentSel().filterIt(d.movable(it))

proc alignSelection*(d: FormDesigner, edge: AlignEdge) =
  ## Aligns the selected controls to the primary one (one undo step).
  let sel = d.freeSel()
  if sel.len < 2: return
  let p = if d.primary in sel: d.primary else: sel[0]
  let pr = rectF(p.left, p.top, p.width, p.height)
  d.applyAll(sel, proc(c: Control, i: int) =
    if c == p: return
    var x = c.left
    var y = c.top
    case edge
    of aeLefts: x = pr.x
    of aeRights: x = pr.right - c.width
    of aeTops: y = pr.y
    of aeBottoms: y = pr.bottom - c.height
    of aeHCenters: x = pr.x + (pr.w - c.width) / 2
    of aeVCenters: y = pr.y + (pr.h - c.height) / 2
    c.setBounds(round(x), round(y), c.width, c.height))

proc makeSameSize*(d: FormDesigner, width, height: bool) =
  ## Gives the selected controls the primary one's width and/or height.
  let sel = d.freeSel()
  if sel.len < 2: return
  let p = if d.primary in sel: d.primary else: sel[0]
  let pw = p.width
  let ph = p.height
  d.applyAll(sel, proc(c: Control, i: int) =
    if c == p: return
    c.setBounds(c.left, c.top, if width: pw else: c.width,
                if height: ph else: c.height))

proc spaceEvenly*(d: FormDesigner, horizontal: bool) =
  ## Spreads three or more controls with equal gaps between the outer two.
  var sel = d.freeSel().filterIt(not it.isTile)
  if sel.len < 3: return
  sel.sort(proc(a, b: Control): int =
    if horizontal: cmp(a.left, b.left) else: cmp(a.top, b.top))
  let first = sel[0]
  let last = sel[^1]
  var total = 0'f32
  for c in sel: total += (if horizontal: c.width else: c.height)
  let span = if horizontal: last.left + last.width - first.left
             else: last.top + last.height - first.top
  let gap = (span - total) / float32(sel.len - 1)
  var pos = if horizontal: first.left else: first.top
  d.applyAll(sel, proc(c: Control, i: int) =
    if horizontal: c.setBounds(round(pos), c.top, c.width, c.height)
    else: c.setBounds(c.left, round(pos), c.width, c.height)
    pos += (if horizontal: c.width else: c.height) + gap)

proc centerInParent*(d: FormDesigner, horizontal, vertical: bool) =
  ## Centres each selected control in its parent.
  let sel = d.freeSel().filterIt(not it.isTile)
  d.applyAll(sel, proc(c: Control, i: int) =
    let p = c.parent
    let x = if horizontal: round((p.width - c.width) / 2) else: c.left
    let y = if vertical: round((p.height - c.height) / 2) else: c.top
    c.setBounds(x, y, c.width, c.height))

proc deleteSelection*(d: FormDesigner): bool =
  ## Deletes the selection (not the design root). `onDeleting` can veto; a
  ## selection that holds an inherited component (`Component.inherited`) is
  ## never deleted.
  let sel = d.sameParentSel()
  if sel.len == 0: return false
  # a component that comes from the ancestor of an inherited form stays
  for c in sel:
    if c.inherited or (c.isTile and NonVisualTile(c).component != nil and
                       NonVisualTile(c).component.inherited): return false
  var allow = true
  if d.onDeleting != nil: d.onDeleting(d, sel, allow)
  if not allow: return false
  let op = DesignOp()
  let parent = sel[0].groupOf
  for c in sel:
    var it = d.item(c)
    it.hasAfter = false
    op.items.add it
    d.detachItem(op, op.items.high)
  d.fSel = @[]
  d.select(if parent != nil: Control(parent) else: Control(d.scope))
  d.refresh()
  d.record op
  if d.onDeleted != nil: d.onDeleted(d, sel)
  true

proc insertNew*(d: FormDesigner, parent: Container, c: Control,
                className = "") =
  ## Adds an already built control to the design (creation, paste): names it
  ## when it has no name, makes it owned by `componentOwner`, selects it and
  ## records an undo step. Its bounds are used as they are.
  if c.name.len == 0:
    c.name = if d.nameControl != nil: d.nameControl(d, c, className)
             else: d.uniqueName(className)
  if c.owner == nil:
    let o = if d.componentOwner != nil: d.componentOwner else: Component(d.scope)
    o.insertComponent(c)
  parent.insertControl(c)
  let op = DesignOp()
  op.items.add OpItem(c: c, hasAfter: true, after: d.placementOf(c))
  d.record op
  d.select(c)
  if d.onCreated != nil: d.onCreated(d, c)

# ---------------------------------------------------------------- creation

proc beginCreate*(d: FormDesigner, className: string) =
  ## The next click (default size) or drag (rectangle) on a container creates
  ## a control of this class through `createControl`.
  d.fCreating = className
  d.cursor = crCross

proc cancelCreate*(d: FormDesigner) =
  d.fCreating = ""
  d.fCreateTarget = nil
  d.fBand = rectF(0, 0, 0, 0)
  d.cursor = crArrow
  d.refresh()

proc snapPoint(d: FormDesigner, target: Container, p: PointF, on: bool): PointF =
  if not on or not d.snapToGrid or not d.hasGrid: return p
  let o = d.parentOrigin(target)
  let s = target.scrollOffset
  pointF(o.x - s.x + snapV(p.x - o.x + s.x, d.grid),
         o.y - s.y + snapV(p.y - o.y + s.y, d.grid))

proc finishCreate(d: FormDesigner, p0, p1: PointF, dragged: bool, snap: bool) =
  let cls = d.fCreating
  let target = d.fCreateTarget
  d.cancelCreate()
  if d.createControl == nil or target == nil: return
  let c = d.createControl(cls)
  if c == nil: return
  let a = d.snapPoint(target, p0, snap)
  var loc = d.localOf(target, a)
  var w = c.width
  var h = c.height
  if dragged:
    let b = d.snapPoint(target, p1, snap)
    let x0 = min(a.x, b.x)
    let y0 = min(a.y, b.y)
    loc = d.localOf(target, pointF(x0, y0))
    w = max(abs(b.x - a.x), d.minSize)
    h = max(abs(b.y - a.y), d.minSize)
  c.setBounds(loc.x, loc.y, w, h)
  d.insertNew(target, c, cls)

# ------------------------------------------------------------------ drags

proc endDrag(d: FormDesigner) =
  d.fMode = dmNone
  d.fMoved = false
  d.fPending = nil
  d.fMoveSet.setLen 0
  d.fMoveOrig.setLen 0
  d.fGhosts.setLen 0
  d.fGuides.setLen 0
  d.fTarget = nil
  d.fResSet.setLen 0
  d.fResOrig.setLen 0
  d.fSelBeforeBand.setLen 0
  d.fBandParent = nil
  d.fBand = rectF(0, 0, 0, 0)
  d.refresh()

proc startMove(d: FormDesigner) =
  d.fMoveSet = d.fSel.filterIt(d.movable(it))
  d.fMoveOrig = d.fMoveSet.mapIt(d.boundsOf(it))
  d.fMoved = true

proc updateMove(d: FormDesigner, p: PointF, shift: ShiftState) =
  if d.fMoveSet.len == 0: return
  let free = ssAlt in shift
  let rawDx = p.x - d.fStart.x
  let rawDy = p.y - d.fStart.y
  var target = d.scope
  if not d.fMoveSet[0].isTile:
    # a control of the ancestor form stays where the ancestor put it: a form
    # file has no way to say that it lives in another container
    target = if d.fMoveSet.anyIt(it.inherited): d.fMoveSet[0].parent
             else: d.dropTarget(p, d.fMoveSet)
  var grp = d.fMoveOrig[0]
  for r in d.fMoveOrig:
    let x0 = min(grp.x, r.x)
    let y0 = min(grp.y, r.y)
    grp = rectF(x0, y0, max(grp.right, r.right) - x0, max(grp.bottom, r.bottom) - y0)
  var gx = grp.x + rawDx
  var gy = grp.y + rawDy
  let org = d.parentOrigin(target)
  let scr = target.scrollOffset
  # sibling and container anchor lines
  var sibs: seq[RectF]
  if d.snapLines and not free:
    for ch in target.children:
      if ch notin d.fMoveSet and d.shown(ch) and not ch.isInternal:
        sibs.add d.boundsOf(ch)
    if target == d.scope:
      for t in d.fTiles:
        if Control(t) notin d.fMoveSet: sibs.add d.boundsOf(t)
    sibs.add rectF(org.x, org.y, target.width, target.height)
  if not free:
    var bestX = d.snapDistance + 1
    var adjX = 0'f32
    var bestY = bestX
    var adjY = 0'f32
    for s in sibs:
      for t in [s.x, s.x + s.w / 2, s.right]:
        for cand in [gx, gx + grp.w / 2, gx + grp.w]:
          if abs(t - cand) < bestX: (bestX = abs(t - cand); adjX = t - cand)
      for t in [s.y, s.y + s.h / 2, s.bottom]:
        for cand in [gy, gy + grp.h / 2, gy + grp.h]:
          if abs(t - cand) < bestY: (bestY = abs(t - cand); adjY = t - cand)
    if bestX <= d.snapDistance: gx += adjX
    elif d.snapToGrid and d.hasGrid:
      gx = org.x - scr.x + snapV(gx - org.x + scr.x, d.grid)
    if bestY <= d.snapDistance: gy += adjY
    elif d.snapToGrid and d.hasGrid:
      gy = org.y - scr.y + snapV(gy - org.y + scr.y, d.grid)
  var dx = gx - grp.x
  var dy = gy - grp.y
  if d.fMoveSet[0].isTile:   # tiles stay inside the design root
    dx = max(min(dx, d.scope.width - grp.right), -grp.x)
    dy = max(min(dy, d.scope.height - grp.bottom), -grp.y)
  # guides: matching edges/centres with siblings
  var guides: seq[RectF]
  if d.snapLines and not free:
    let g = rectF(grp.x + dx, grp.y + dy, grp.w, grp.h)
    for s in sibs:
      for (a, b) in [(g.x, s.x), (g.x, s.right), (g.right, s.x), (g.right, s.right),
                     (g.x + g.w / 2, s.x + s.w / 2), (g.x, s.x + s.w / 2),
                     (g.right, s.x + s.w / 2), (g.x + g.w / 2, s.x),
                     (g.x + g.w / 2, s.right)]:
        if abs(a - b) < 0.5:
          let y0 = min(g.y, s.y)
          guides.add rectF(b, y0, 0, max(g.bottom, s.bottom) - y0)
      for (a, b) in [(g.y, s.y), (g.y, s.bottom), (g.bottom, s.y), (g.bottom, s.bottom),
                     (g.y + g.h / 2, s.y + s.h / 2), (g.y, s.y + s.h / 2),
                     (g.bottom, s.y + s.h / 2), (g.y + g.h / 2, s.y),
                     (g.y + g.h / 2, s.bottom)]:
        if abs(a - b) < 0.5:
          let x0 = min(g.x, s.x)
          guides.add rectF(x0, b, max(g.right, s.right) - x0, 0)
  d.fGhosts = d.fMoveOrig.mapIt(it.offset(dx, dy))
  d.fGuides = guides
  let reparent = not d.fMoveSet[0].isTile and d.fMoveSet.anyIt(it.parent != target)
  d.fTarget = if reparent: target else: nil
  d.fLast = p
  d.cursor = crSizeAll
  d.refresh()

proc commitMove(d: FormDesigner) =
  if d.fGhosts.len != d.fMoveSet.len or d.fMoveSet.len == 0:
    d.endDrag()
    return
  var target = d.scope
  if not d.fMoveSet[0].isTile:
    target = d.fTarget
  let op = DesignOp()
  for i, c in d.fMoveSet:
    let g = d.fGhosts[i]
    var it = d.item(c)
    if c.isTile:
      c.setBounds(g.x, g.y, c.width, c.height)
    else:
      let tgt = if target != nil: target else: c.parent
      let loc = d.localOf(tgt, pointF(g.x, g.y))
      if tgt != c.parent:
        c.setBounds(loc.x, loc.y, c.width, c.height)
        tgt.insertControl(c)
      else:
        c.setBounds(loc.x, loc.y, c.width, c.height)
    d.finish(it)
    if not samePlacement(it.before, it.after): op.items.add it
  d.endDrag()
  d.record op

proc startResize(d: FormDesigner, h: DesignHandle) =
  d.fMode = dmResize
  d.fResHandle = h
  d.fResSet = d.fSel.filterIt(d.handleMask(it).len > 0)
  d.fResOrig = d.fResSet.mapIt(d.item(it))

proc updateResize(d: FormDesigner, p: PointF, shift: ShiftState) =
  let free = ssAlt in shift
  let h = d.fResHandle
  let dx = p.x - d.fStart.x
  let dy = p.y - d.fStart.y
  proc snapE(v: float32): float32 =
    if free or not d.snapToGrid or not d.hasGrid: v else: snapV(v, d.grid)
  for i, c in d.fResSet:
    let o = d.fResOrig[i].before.bounds
    let m = d.handleMask(c)
    let okX = (h.hx < 0 and m * {dhW, dhNW, dhSW} != {}) or
              (h.hx > 0 and m * {dhE, dhNE, dhSE} != {})
    let okY = (h.hy < 0 and m * {dhN, dhNW, dhNE} != {}) or
              (h.hy > 0 and m * {dhS, dhSW, dhSE} != {})
    if c == Control(d.scope):
      # the design root keeps its position; its size (not the edge) snaps
      let (w, hh) = d.sizeOk(c, if okX: snapE(o.w + dx) else: o.w,
                             if okY: snapE(o.h + dy) else: o.h)
      c.setBounds(o.x, o.y, w, hh)
      continue
    var l = o.x
    var t = o.y
    var r = o.right
    var b = o.bottom
    if okX and h.hx < 0: l = snapE(o.x + dx)
    if okX and h.hx > 0: r = snapE(o.right + dx)
    if okY and h.hy < 0: t = snapE(o.y + dy)
    if okY and h.hy > 0: b = snapE(o.bottom + dy)
    let (w, hh) = d.sizeOk(c, r - l, b - t)
    if okX and h.hx < 0: l = o.right - w
    if okY and h.hy < 0: t = o.bottom - hh
    c.setLocal(l, t, w, hh)
  d.refresh()

proc commitResize(d: FormDesigner) =
  let op = DesignOp()
  for i in 0 ..< d.fResSet.len:
    var it = d.fResOrig[i]
    d.finish(it)
    if not samePlacement(it.before, it.after): op.items.add it
  d.endDrag()
  d.record op

proc cancelDrag*(d: FormDesigner) =
  ## Aborts the drag in progress (what Esc does): a move or a band is
  ## dropped, a resize goes back to the original size.
  case d.fMode
  of dmResize:
    for it in d.fResOrig: d.applyPlacement(it.c, it.before)
  of dmBand:
    d.setSelection(d.fSelBeforeBand)
  else: discard
  d.endDrag()

proc updateBand(d: FormDesigner, p: PointF, shift: ShiftState) =
  let x0 = min(d.fStart.x, p.x)
  let y0 = min(d.fStart.y, p.y)
  d.fBand = rectF(x0, y0, abs(p.x - d.fStart.x), abs(p.y - d.fStart.y))
  var hits: seq[Control]
  let par = d.fBandParent
  for ch in par.children:
    if not d.shown(ch) or ch.isInternal: continue
    if d.boundsOf(ch).intersects(d.fBand) and ch notin hits: hits.add ch
  if par == d.scope:
    for t in d.fTiles:
      if d.boundsOf(t).intersects(d.fBand) and Control(t) notin hits: hits.add t
  if hits.len == 0: hits = @[Control(par)]
  d.setSelection(hits)
  d.refresh()

# ------------------------------------------------------------------ mouse

proc updateCursor(d: FormDesigner, p: PointF) =
  d.cursor = crArrow
  if d.fCreating.len > 0:
    d.cursor = crCross
    return
  var h: DesignHandle
  if d.handleAt(p, h):
    d.cursor = handleCursor(h)
    return
  let c = d.hit(p)
  if c in d.fSel and d.movable(c): d.cursor = crSizeAll

method designMouseDown*(d: FormDesigner, p: PointF, button: MouseButton,
                        shift: ShiftState, clicks: int) =
  if d.fMode != dmNone: return      # a second button during a drag changes nothing
  d.fStart = p
  d.fLast = p
  d.fMoved = false
  if button == mbRight:
    if d.fCreating.len > 0:
      d.cancelCreate()
      return
    let c = d.hit(p)
    if c notin d.fSel: d.select(c)
    if d.onContextMenu != nil:
      d.onContextMenu(d, c, d.scope.clientToForm(p))
    return
  if button != mbLeft: return
  if d.fCreating.len > 0:
    d.fCreateTarget = d.dropTarget(p, @[])
    d.fMode = dmCreate
    return
  if clicks >= 2:
    let c = d.hit(p)
    d.select(c)
    if d.onDoubleClick != nil: d.onDoubleClick(d, c)
    return
  var h: DesignHandle
  if d.handleAt(p, h):
    d.startResize(h)
    return
  let c = d.hit(p)
  if ssShift in shift:
    d.toggle(c)
    return
  if c == Control(d.scope) or (ssCtrl in shift and c of Container):
    # rubber band (select the container itself until it grows)
    d.fBandParent = Container(c)
    d.fMode = dmBand
    d.fSelBeforeBand = d.fSel
    d.select(c)
    return
  if c in d.fSel:
    d.fPending = c
  else:
    d.select(c)
  d.fMode = dmMove

method designMouseMove*(d: FormDesigner, p: PointF, shift: ShiftState) =
  case d.fMode
  of dmNone:
    d.updateCursor(p)
  of dmMove:
    if ssLeft notin shift: return
    if not d.fMoved:
      if abs(p.x - d.fStart.x) < DragThreshold and abs(p.y - d.fStart.y) < DragThreshold:
        return
      d.startMove()
    d.updateMove(p, shift)
  of dmResize:
    d.updateResize(p, shift)
  of dmBand:
    if not d.fMoved:
      if abs(p.x - d.fStart.x) < DragThreshold and abs(p.y - d.fStart.y) < DragThreshold:
        return
      d.fMoved = true
    d.updateBand(p, shift)
  of dmCreate:
    if abs(p.x - d.fStart.x) >= DragThreshold or abs(p.y - d.fStart.y) >= DragThreshold:
      d.fMoved = true
      let free = ssAlt in shift
      let t = d.fCreateTarget
      let a = d.snapPoint(t, d.fStart, not free)
      let b = d.snapPoint(t, p, not free)
      d.fBand = rectF(min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y))
      d.fTarget = t
      d.refresh()

method designMouseUp*(d: FormDesigner, p: PointF, button: MouseButton,
                      shift: ShiftState) =
  if button != mbLeft: return
  case d.fMode
  of dmMove:
    if d.fMoved: d.commitMove()
    else:
      let pend = d.fPending
      d.endDrag()
      if pend != nil and d.fSel.len > 1: d.select(pend)
  of dmResize: d.commitResize()
  of dmBand: d.endDrag()
  of dmCreate:
    let moved = d.fMoved
    d.fMode = dmNone
    d.fMoved = false
    d.fBand = rectF(0, 0, 0, 0)
    d.fTarget = nil
    d.finishCreate(d.fStart, p, moved, ssAlt notin shift)
  of dmNone: discard

method designMouseWheel*(d: FormDesigner, p: PointF, shift: ShiftState,
                         dx, dy: float32): bool =
  false

method designCancel*(d: FormDesigner) =
  if d.fMode == dmCreate:
    d.fMode = dmNone
    d.cancelCreate()
  elif d.fMode != dmNone: d.cancelDrag()

# --------------------------------------------------------------- keyboard

proc siblingsOf(d: FormDesigner, c: Control): seq[Control] =
  if c.isTile or c.parent == nil: return @[]
  for ch in c.parent.children:
    if d.shown(ch) and not ch.isInternal: result.add ch

proc selectParent*(d: FormDesigner) =
  let c = d.primary
  if c == nil or c == Control(d.scope): return
  d.select(if c.isTile or c.parent == nil: Control(d.scope) else: Control(c.parent))

method designKeyDown*(d: FormDesigner, key: var Key, shift: ShiftState): bool =
  let ctrl = ssCtrl in shift
  let shf = ssShift in shift
  if ssAlt in shift: return false
  if d.fMode != dmNone:
    if key == keyEscape:
      if d.fMode == dmCreate: d.designCancel() else: d.cancelDrag()
      return true
    return true
  if key == keyEscape:
    if d.fCreating.len > 0: d.cancelCreate()
    else: d.selectParent()
    return true
  let step = if ctrl and d.hasGrid: d.grid else: 1'f32
  if key == keyLeft or key == keyRight or key == keyUp or key == keyDown:
    let dx = if key == keyLeft: -step elif key == keyRight: step else: 0'f32
    let dy = if key == keyUp: -step elif key == keyDown: step else: 0'f32
    d.nudge(dx, dy, resize = shf)
    return true
  if key == keyDelete:
    discard d.deleteSelection()
    return true
  if key == keyTab and not ctrl:
    let c = d.primary
    var sibs: seq[Control]
    if c != nil and c != Control(d.scope): sibs = d.siblingsOf(c)
    else:
      for ch in d.scope.children:
        if d.shown(ch) and not ch.isInternal: sibs.add ch
    if sibs.len > 0:
      let i = sibs.find(c)
      let n = if i < 0: (if shf: sibs.high else: 0)
              elif shf: (i + sibs.len - 1) mod sibs.len
              else: (i + 1) mod sibs.len
      d.select(sibs[n])
    return true
  if ctrl:
    if key == key('a'):
      let c = d.primary
      let sibs = if c == nil or c == Control(d.scope): d.scope.children.filterIt(
                   d.shown(it) and not it.isInternal)
                 else: d.siblingsOf(c)
      if sibs.len > 0: d.select(sibs)
      return true
    if key == key('c'):
      if d.onCopy != nil: d.onCopy(d, d.sameParentSel())
      return true
    if key == key('x'):
      let sel = d.sameParentSel()
      if sel.len > 0:
        if d.onCut != nil: d.onCut(d, sel)
        elif d.onCopy != nil: d.onCopy(d, sel)
        discard d.deleteSelection()
      return true
    if key == key('v'):
      if d.onPaste != nil:
        let c = d.primary
        var t = d.scope
        if c != nil:
          if c of Container and d.accepts(Container(c)): t = Container(c)
          elif not c.isTile and c.parent != nil: t = c.parent
        d.onPaste(d, t)
      return true
    if key == key('z'):
      discard (if shf: d.redo() else: d.undo())
      return true
    if key == key('y'):
      discard d.redo()
      return true
  false

# ----------------------------------------------------------------- painting

proc dashed(cv: Canvas, r: RectF, col: Color) =
  const dash = 3'f32
  var x = r.x
  while x < r.right:
    let e = min(x + dash, r.right)
    cv.line(x, r.y + 0.5, e, r.y + 0.5, col)
    cv.line(x, r.bottom - 0.5, e, r.bottom - 0.5, col)
    x += 2 * dash
  var y = r.y
  while y < r.bottom:
    let e = min(y + dash, r.bottom)
    cv.line(r.x + 0.5, y, r.x + 0.5, e, col)
    cv.line(r.right - 0.5, y, r.right - 0.5, e, col)
    y += 2 * dash

proc paintGrid(d: FormDesigner, cv: Canvas, t: Theme) =
  let g = d.grid
  let clip = intersect(cv.currentClip, d.scope.clientRect)
  if clip.isEmpty: return
  let col = t.textMuted.withAlpha(110)
  var covered: seq[RectF]
  for ch in d.scope.children:
    if ch.visible and not ch.isInternal: covered.add ch.visualRect
  var y = ceil(clip.y / g) * g
  var row: seq[RectF]               # the covered rectangles this row of dots meets
  while y < clip.bottom:
    row.setLen 0
    for r in covered:
      if y >= r.y and y < r.bottom: row.add r
    var x = ceil(clip.x / g) * g
    while x < clip.right:
      var hidden = false
      for r in row:
        if x >= r.x and x < r.right:
          hidden = true
          break
      if not hidden: cv.fillRect(rectF(x, y, 1, 1), col)
      x += g
    y += g

proc paintHidden(d: FormDesigner, cv: Canvas, c: Container, t: Theme) =
  for ch in c.children:
    if ch.isInternal: continue
    if not ch.visible:
      let r = d.boundsOf(ch)
      cv.dashed(r, t.textMuted)
      cv.textRect(ch.name, t.font, r.inflate(-3), t.textMuted)
    elif ch of Container and d.accepts(Container(ch)):
      d.paintHidden(cv, Container(ch), t)

proc paintTile(cv: Canvas, tl: NonVisualTile, t: Theme) =
  let r = rectF(tl.left, tl.top, tl.width, tl.height)
  cv.fillRoundRect(r, 5, t.surface)
  cv.strokeRoundRect(r, 5, t.borderStrong, 1)
  if tl.icon != nil:
    cv.drawImage(tl.icon, r.inflate(-6))
  else:
    var s = if tl.kind.len > 0: tl.kind else: tl.component.name
    s = s[0 ..< min(s.len, 2)]
    var f = t.font
    f.size = f.size * 1.15
    cv.textRect(s, f, r, t.accent, taCenter, vaCenter)
  cv.textRect(tl.name, t.font, rectF(r.x - 24, r.bottom + 2, r.w + 48, 18),
              t.textMuted, taCenter, vaTop)

proc paintInherited(d: FormDesigner, cv: Canvas, c: Container, t: Theme) =
  ## A small corner flag on every component that comes from the ancestor form.
  for k in c.children:
    if k.inherited and not k.isInternal and k.visible:
      let r = d.boundsOf(k)
      let f = rectF(r.x, r.y, 9, 9)
      cv.fillRect(f, t.accent.withAlpha(200))
      cv.line(f.x + 2, f.y + 7, f.x + 7, f.y + 2, hex"#ffffff", 1)
      cv.line(f.x + 4, f.y + 2, f.x + 7, f.y + 2, hex"#ffffff", 1)
      cv.line(f.x + 7, f.y + 2, f.x + 7, f.y + 5, hex"#ffffff", 1)
    if k of Container: d.paintInherited(cv, Container(k), t)

proc paintOverlay(d: FormDesigner, cv: Canvas) =
  let t = d.scope.theme
  d.paintInherited(cv, d.scope, t)
  if d.fShowGrid and d.hasGrid: d.paintGrid(cv, t)
  if d.fShowHidden: d.paintHidden(cv, d.scope, t)
  for tl in d.fTiles:
    paintTile(cv, tl, t)
    if tl.component != nil and tl.component.inherited:
      cv.fillRect(rectF(tl.left, tl.top, 9, 9), t.accent.withAlpha(200))
  let guideCol = hex"#e0359e"
  if d.fTarget != nil:
    let r = d.boundsOf(d.fTarget)
    cv.fillRect(r, t.accent.withAlpha(28))
    cv.frameRect(r, t.accent, 2)
  for g in d.fGuides:
    if g.w == 0: cv.line(g.x + 0.5, g.y, g.x + 0.5, g.bottom, guideCol)
    else: cv.line(g.x, g.y + 0.5, g.right, g.y + 0.5, guideCol)
  for g in d.fGhosts:
    cv.fillRect(g, t.accent.withAlpha(36))
    cv.dashed(g, t.accent)
  if d.fBand.w > 0 or d.fBand.h > 0:
    cv.fillRect(d.fBand, t.accent.withAlpha(32))
    cv.frameRect(d.fBand, t.accent, 1)
  # selection: outline and handles
  let single = d.fSel.len == 1
  for i, c in d.fSel:
    let r = d.boundsOf(c)
    if c == Control(d.scope):
      cv.frameRect(r, t.accent, 2)
      continue
    cv.dashed(r, if i == 0: t.accent else: t.borderStrong)
    let fill = if i == 0 or single: t.accent else: t.textMuted
    for h in d.visibleHandles(c):
      let hr = d.handleRectOf(c, r, h)
      cv.fillRect(hr, hex"#ffffff")
      cv.fillRect(hr.inflate(-1), fill)
  # the pending state is also what the next refresh compares against
  let now = d.overlayRects()
  var same = now.len == d.fLastOver.len
  if same:
    for i in 0 ..< now.len:
      if not sameRect(now[i], d.fLastOver[i]): same = false
  if not same: d.refresh()

# --------------------------------------------------------------- lifecycle

proc attach*(d: FormDesigner) =
  ## Starts intercepting input of the design root's window. The root must be
  ## in a form or host already (call again after moving it to another one).
  let h = d.scope.host
  if h == nil or not (h of UiRoot): return
  let ui = UiRoot(h)
  ui.addDesigner(d)
  d.scope.onPaintOver = proc(sender: Control, cv: Canvas) = d.paintOverlay(cv)
  d.fAttached = true
  d.scope.invalidate()
  d.refresh()

proc detach*(d: FormDesigner) =
  ## Back to normal operation; the selection is cleared.
  let h = d.scope.host
  if h != nil and h of UiRoot: UiRoot(h).removeDesigner(d)
  d.scope.onPaintOver = nil
  d.fAttached = false
  d.endDrag()
  d.fCreating = ""
  d.fSel = @[]
  d.fLastOver.setLen 0
  d.scope.invalidate()

proc `showGrid=`*(d: FormDesigner, v: bool) =
  if v == d.fShowGrid: return
  d.fShowGrid = v
  d.scope.invalidate()

proc `showHidden=`*(d: FormDesigner, v: bool) =
  if v == d.fShowHidden: return
  d.fShowHidden = v
  d.scope.invalidate()

proc newFormDesigner*(root: Container, attachNow = true): FormDesigner =
  ## A designer for `root`, selecting the root itself at first. With `attachNow`
  ## (default) it starts intercepting input immediately when `root` is already
  ## in a form; otherwise call `attach()` later.
  result = FormDesigner(grid: 8, fShowGrid: true, snapToGrid: true,
                        snapLines: true, snapDistance: 5, minSize: 4,
                        undoLimit: 100, cursor: crArrow)
  result.scope = root
  result.fSel = @[Control(root)]
  if attachNow: result.attach()
