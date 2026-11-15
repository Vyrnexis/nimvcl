## `TreeView` (VCL TTreeView): a scrolling tree of `TreeNode`s.
##
## Nodes
## -----
## Nodes are created through the tree: `tv.items.addChild(parent, "text")`
## (`parent` nil = top level), `tv.items.add(sibling, text)` (appended right
## after `sibling`, nil = last top-level node), `tv.items.insert(sibling, text)`
## (before `sibling`), or on the node itself: `n.addChild(text)`,
## `n.insert(index, text)`, `n.delete()`, `n.clear()` (children). `tv.items`
## also has `clear`, `delete(node)`, `count` (all nodes), `topCount`, `top(i)`,
## `find(text)`.
##
## A node has `text`, `data` (RootRef) and `tag` (int) for the application,
## `imageIndex` / `selectedIndex` (into `tv.images`, -1 = none; the selected
## one is used while the node is selected), `expanded`, `hasChildren`, `checked`,
## `parent`, `level` (0 = top level), `index` (among its siblings), `children`.
##
## Lazy children: `n.hasChildren = true` on a node without children shows an
## expander. `onExpanding(sender, node, allow)` fires on every expand (also
## for nodes that already have children, so check `node.childCount == 0`); the
## handler adds the children and may set `allow = false`. A node that still has
## no children afterwards stops being expandable.
##
## Display
## -------
## `indent` (19) is the width of one level; `showButtons` draws chevron
## expanders; `showLines` draws subtle connector lines; `showRoot = false`
## removes the expander column of the top-level nodes (they are not expandable
## with the mouse then; keys and double click still work). `rowSelect` highlights
## the whole row instead of icon + label. `hideSelection` (default false) hides
## the selection while the tree has no focus; otherwise `selectionInactive` is
## used. `itemHeight` 0 = automatic. `images` is an `ImageList` (space for the
## icon is reserved for every node while it is set).
##
## Performance
## -----------
## The tree keeps a flat list of the visible rows. `expand`/`collapse`, adding
## and deleting nodes update that list incrementally (cost proportional to the
## rows after the change, not to the tree); painting and hit-testing touch only
## the visible rows. Wrap bulk changes in `beginUpdate` / `endUpdate` (one
## rebuild at the end). 100,000 nodes with 10,000 expanded are fine. Pixel
## positions are float32 (precise up to ~700,000 rows).
##
## Selection
## ---------
## `selected` is the focused node (nil = none). Single mode: it is the
## selection. `multiSelect` (with `extendedSelect`, default): Ctrl+click
## toggles, Shift+click / Shift+arrows select the range of visible rows from
## the anchor, Ctrl+arrows move the focus only, Ctrl+Space toggles, Ctrl+A
## selects all visible rows. `isSelected(node)`, `selCount`, `selectedNodes`,
## `clearSelection`, `selectAll`. Setting `selected` expands the ancestors and
## scrolls the node into view. Collapsing a node deselects its hidden
## descendants and moves the focus to it when the focus was inside.
## `onChanging(sender, node, allow)` (veto) fires before the focus moves to
## `node`, `onChange(sender, node)` after the focus or the selection changed.
##
## Check boxes
## -----------
## `checkboxes = true` shows a box per node (`checked`: cbUnchecked / cbChecked /
## cbGrayed); click or Space toggles; `onChecked(sender, node)`. With
## `propagateChecks = true` a user toggle is applied to all descendants and the
## ancestors become checked / grayed / unchecked from their children.
##
## Label editing
## -------------
## F2, or a second click on the label of the selected node after
## `slowClickDelay` ms (600; a click anywhere or a key cancels it), starts an
## in-place `Edit` (`beginEdit`). `readOnly` disables it. `onEditing(sender,
## node, allow)`, then Enter or focus loss commits (`onEdited(sender, node,
## text)` may change the text), Escape cancels. `endEdit(cancel)` ends it from
## code.
##
## Keys: Up/Down/Home/End/PgUp/PgDn, Left (collapse, else go to the parent),
## Right (expand, else go to the first child), `*` (expand everything below
## the node), `+` / `-` (expand / collapse), F2, Space, type-ahead on the
## labels of visible rows. Mouse: click an expander toggles, click on icon or
## label selects, double click toggles and fires `onDblClick`.
##
## `onCustomDrawItem(sender, canvas, node, rect, state, defaultDraw)` is called
## per painted row after the selection / hover background; `rect` is the row
## in client coordinates. Set `defaultDraw = false` to replace lines,
## expander, check box, icon and text. `tv.nodeRect(node)`, `tv.labelRect(node)`
## and `tv.hitTestAt(point)` help.

import std/[sets, hashes, strutils]
import ../graphics/context
import ../core/timer
import ./common, ./scrolling, ./edit, ./imagelist, ./viewsupport
export scrolling, imagelist, viewsupport.CheckBoxState, viewsupport.ItemState,
       viewsupport.ItemStates

type
  TreeNode* = ref object
    fTree: TreeView
    fParent: TreeNode            ## the hidden root for top-level nodes
    fKids: seq[TreeNode]
    fText: string
    fIdx, fRow, fLevel: int      ## row: index in the visible list, -1 = hidden
    fExpanded, fLazy: bool
    fCheck: CheckBoxState
    fImage, fSelImage: int
    data*: RootRef
    tag*: int

  TreeHit* = enum
    thNone, thRow, thButton, thCheck, thIcon, thLabel

  TreeNodeEvent* = proc(sender: Control, node: TreeNode)
  TreeAllowEvent* = proc(sender: Control, node: TreeNode, allow: var bool)
  TreeEditedEvent* = proc(sender: Control, node: TreeNode, text: var string)
  TreeDrawEvent* = proc(sender: Control, canvas: Canvas, node: TreeNode,
                        rect: RectF, state: ItemStates, defaultDraw: var bool)

  TreeView* = ref object of ScrollingControl
    fRoot: TreeNode
    fRows: seq[TreeNode]
    fSel: HashSet[TreeNode]
    fFocus, fAnchor, fHot, fDownNode, fSlowNode, fEditNode: TreeNode
    fDownPart: TreeHit
    fCount: int
    fVer: int
    fUpdating: int
    fRowsDirty: bool
    fPruneSel: bool              # a collapse was deferred: drop hidden selection
    fPendingChange: bool         # onChange due at the end of the update
    fExtentStale: bool           # recompute the horizontal extent at paint
    fSkipPress: bool             # doKeyDown already handled the + - * text
    fMulti, fExtended, fShowLines, fShowRoot, fShowButtons: bool
    fRowSelect, fHideSel, fReadOnly, fCheckboxes, fPropagate, fMouseIn: bool
    fIndent, fItemHeight, fLastIh, fExtent, fMouseY: float32
    fImages: ImageList
    fImgListener: int
    fEdit: Edit
    fSlowTimer: Timer
    fTypeBuf: string
    fTypeTime: int64
    slowClickDelay*: int         ## ms before a second click starts editing
    typeAheadTimeout*: int       ## ms
    onChange*: TreeNodeEvent
    onChanging*: TreeAllowEvent
    onExpanding*, onCollapsing*: TreeAllowEvent
    onExpanded*, onCollapsed*: TreeNodeEvent
    onEditing*: TreeAllowEvent
    onEdited*: TreeEditedEvent
    onChecked*: TreeNodeEvent
    onCustomDrawItem*: TreeDrawEvent

  TreeItems* = object
    ## `tv.items`: creating and deleting nodes.
    tv: TreeView

  NodeGeom = object
    expander, check, icon: RectF   ## empty rect when not present
    labelX, labelW: float32        ## label area (text is inset by LabelPad)
    selX: float32                  ## left edge of the highlight

proc hash*(n: TreeNode): Hash = hash(cast[pointer](n))

const
  LeftPad = 2'f32
  LabelPad = 4'f32
  KeyKpMultiply = Key(0x40000055)
  KeyKpMinus = Key(0x40000056)
  KeyKpPlus = Key(0x40000057)

# ------------------------------------------------------------- node basics

func tree*(n: TreeNode): TreeView = n.fTree
func text*(n: TreeNode): string = n.fText
func level*(n: TreeNode): int = n.fLevel
func index*(n: TreeNode): int = n.fIdx
func childCount*(n: TreeNode): int = n.fKids.len
func children*(n: TreeNode): lent seq[TreeNode] = n.fKids
func child*(n: TreeNode, i: int): TreeNode =
  if i in 0 ..< n.fKids.len: n.fKids[i] else: nil
func expanded*(n: TreeNode): bool = n.fExpanded
func hasChildren*(n: TreeNode): bool = n.fKids.len > 0 or n.fLazy
func checked*(n: TreeNode): CheckBoxState = n.fCheck
func imageIndex*(n: TreeNode): int = n.fImage
func selectedIndex*(n: TreeNode): int = n.fSelImage
func rowIndex*(n: TreeNode): int = n.fRow
  ## Row in the visible list; -1 when hidden by a collapsed ancestor.
func isVisible*(n: TreeNode): bool = n.fRow >= 0
func isDetached*(n: TreeNode): bool = n.fTree == nil

func parent*(n: TreeNode): TreeNode =
  ## nil for a top-level node.
  if n.fTree == nil or n.fParent == n.fTree.fRoot: nil else: n.fParent

func isAncestorOf*(a, n: TreeNode): bool =
  var p = n.fParent
  while p != nil:
    if p == a: return true
    p = p.fParent

proc invalidateTree(n: TreeNode) =
  if n.fTree != nil: n.fTree.invalidate()

proc `text=`*(n: TreeNode, v: string) =
  n.fText = v
  n.invalidateTree()
proc `imageIndex=`*(n: TreeNode, v: int) =
  n.fImage = v
  n.invalidateTree()
proc `selectedIndex=`*(n: TreeNode, v: int) =
  n.fSelImage = v
  n.invalidateTree()

# -------------------------------------------------------------- tree basics

func items*(tv: TreeView): TreeItems = TreeItems(tv: tv)
func images*(tv: TreeView): ImageList = tv.fImages
func indent*(tv: TreeView): float32 = tv.fIndent
func multiSelect*(tv: TreeView): bool = tv.fMulti
func extendedSelect*(tv: TreeView): bool = tv.fExtended
func showLines*(tv: TreeView): bool = tv.fShowLines
func showRoot*(tv: TreeView): bool = tv.fShowRoot
func showButtons*(tv: TreeView): bool = tv.fShowButtons
func rowSelect*(tv: TreeView): bool = tv.fRowSelect
func hideSelection*(tv: TreeView): bool = tv.fHideSel
func readOnly*(tv: TreeView): bool = tv.fReadOnly
func checkboxes*(tv: TreeView): bool = tv.fCheckboxes
func propagateChecks*(tv: TreeView): bool = tv.fPropagate
func selected*(tv: TreeView): TreeNode = tv.fFocus
func rowCount*(tv: TreeView): int = tv.fRows.len
  ## Number of visible rows.
func nodeCount*(tv: TreeView): int = tv.fCount
func isEditing*(tv: TreeView): bool = tv.fEditNode != nil
func editingNode*(tv: TreeView): TreeNode = tv.fEditNode
func editControl*(tv: TreeView): Edit = tv.fEdit
  ## The in-place editor (nil until the first edit).
func isUpdating*(tv: TreeView): bool = tv.fUpdating > 0

func nodeAtRow*(tv: TreeView, row: int): TreeNode =
  if row in 0 ..< tv.fRows.len: tv.fRows[row] else: nil

proc itemHeight*(tv: TreeView): float32 =
  ## Row height in logical pixels (the automatic one when not set).
  if tv.fItemHeight > 0: return tv.fItemHeight
  let icon = if tv.fImages != nil: tv.fImages.height + 4 else: 0'f32
  if tv.canMeasure:
    max(max(ceil(tv.renderCtx.fontMetrics(tv.font).lineHeight) + 6, 18), icon)
  else: max(22'f32, icon)

method scrollLineSize*(tv: TreeView): SizeF = sizeF(24, tv.itemHeight)

proc refresh(tv: TreeView) =
  if tv.fUpdating > 0: return
  let ih = tv.itemHeight
  let cs = sizeF(tv.fExtent, float32(tv.fRows.len) * ih)
  if tv.fLastIh > 0 and ih != tv.fLastIh:
    let old = tv.fLastIh
    let y = float32(float64(tv.scrollPos.y) / float64(old) * float64(ih))
    tv.fLastIh = ih
    if ih < old: tv.scrollTo(tv.scrollPos.x, y)
    tv.setContentSize(cs.w, cs.h)
    if ih >= old: tv.scrollTo(tv.scrollPos.x, y)
  else:
    tv.fLastIh = ih
    tv.setContentSize(cs.w, cs.h)
  tv.invalidate()

method beforeLayout*(tv: TreeView) =
  tv.refresh()
  procCall beforeLayout(ScrollingControl(tv))

proc touch(tv: TreeView) = inc tv.fVer

proc notifyChange(tv: TreeView, ver: int) =
  if tv.fVer != ver:
    tv.invalidate()
    if tv.fUpdating > 0:                 # one onChange at endUpdate
      tv.fPendingChange = true
      return
    if tv.onChange != nil: tv.onChange(tv, tv.fFocus)

# ------------------------------------------------------ the visible row list

proc renumber(tv: TreeView, from0: int) =
  for i in max(from0, 0) ..< tv.fRows.len: tv.fRows[i].fRow = i

proc visibleBelow(tv: TreeView, n: TreeNode): int =
  ## Number of rows directly after `n`'s row that belong to its subtree.
  var j = n.fRow + 1
  while j < tv.fRows.len and tv.fRows[j].fLevel > n.fLevel: inc j
  j - n.fRow - 1

proc collectVisible(n: TreeNode, acc: var seq[TreeNode]) =
  ## Appends the visible descendants of `n` (expanded chains), `n` excluded.
  var stack = @[(n, 0)]
  while stack.len > 0:
    let (p, i) = stack[^1]
    if i >= p.fKids.len:
      stack.setLen(stack.len - 1)
      continue
    stack[^1][1] = i + 1
    let k = p.fKids[i]
    acc.add k
    if k.fExpanded and k.fKids.len > 0: stack.add (k, 0)

proc rebuildRows(tv: TreeView) =
  for n in tv.fRows: n.fRow = -1
  tv.fRows.setLen(0)
  collectVisible(tv.fRoot, tv.fRows)
  tv.renumber(0)
  tv.fRowsDirty = false

proc insertRows(tv: TreeView, pos: int, acc: seq[TreeNode]) =
  let old = tv.fRows.len
  tv.fRows.setLen(old + acc.len)
  for i in countdown(old - 1, pos): tv.fRows[i + acc.len] = tv.fRows[i]
  for i in 0 ..< acc.len: tv.fRows[pos + i] = acc[i]

proc cutRows(tv: TreeView, a, count: int) =
  ## Removes `count` rows starting at `a` (their `fRow` is reset).
  if count <= 0: return
  for i in a ..< a + count: tv.fRows[i].fRow = -1
  let n = tv.fRows.len
  for i in a ..< n - count: tv.fRows[i] = tv.fRows[i + count]
  tv.fRows.setLen(n - count)
  tv.renumber(a)

proc hotUpdate(tv: TreeView)

# ----------------------------------------------------------------- scrolling

proc makeRowVisible*(tv: TreeView, row: int) =
  if row < 0 or row >= tv.fRows.len: return
  let ih = tv.itemHeight
  tv.scrollIntoView(rectF(tv.scrollPos.x, float32(row) * ih, 1, ih))

proc layoutEdit(tv: TreeView)

method contentScrolled*(tv: TreeView) =
  procCall contentScrolled(ScrollingControl(tv))
  tv.fSlowNode = nil
  tv.hotUpdate()
  tv.layoutEdit()

proc firstFullRow(tv: TreeView): int =
  int(ceil(float64(tv.scrollPos.y) / float64(tv.itemHeight)))
proc lastFullRow(tv: TreeView): int =
  min(int(floor((float64(tv.scrollPos.y) + float64(tv.viewport.h)) /
                float64(tv.itemHeight))) - 1, tv.fRows.len - 1)

# ----------------------------------------------------------------- geometry

func colOf(tv: TreeView, n: TreeNode): int =
  n.fLevel - (if tv.fShowRoot: 0 else: 1)

proc rowTop(tv: TreeView, i: int, ih: float32): float32 =
  tv.viewport.y + float32(float64(i) * float64(ih) - float64(tv.scrollPos.y))

proc geom(tv: TreeView, n: TreeNode, y: float32, ih: float32): NodeGeom =
  let vp = tv.viewport
  let x0 = vp.x - tv.scrollPos.x + LeftPad
  let col = tv.colOf(n)
  var x = x0 + float32(max(col + 1, 0)) * tv.fIndent
  if col >= 0 and tv.fShowButtons and n.hasChildren:
    result.expander = rectF(x0 + float32(col) * tv.fIndent, y, tv.fIndent, ih)
  if tv.fCheckboxes:
    result.check = rectF(x, y + floor((ih - CheckSize) / 2), CheckSize, CheckSize)
    x += CheckSize + 4
  if tv.fImages != nil:
    result.icon = rectF(x, y + floor((ih - tv.fImages.height) / 2),
                        tv.fImages.width, tv.fImages.height)
    x += tv.fImages.width + 4
  result.labelX = x
  result.labelW = tv.textWidth(n.fText, tv.font) + 2 * LabelPad
  if tv.fImages != nil: result.selX = result.icon.x - 2
  else: result.selX = result.labelX

proc nodeRect*(tv: TreeView, n: TreeNode): RectF =
  ## The row of `n` in client coordinates (empty when hidden).
  if n == nil or n.fRow < 0: return rectF(0, 0, 0, 0)
  let vp = tv.viewport
  rectF(vp.x - tv.scrollPos.x, tv.rowTop(n.fRow, tv.itemHeight),
        max(vp.w, tv.contentSize.w), tv.itemHeight)

proc labelRect*(tv: TreeView, n: TreeNode): RectF =
  ## The label area of `n` in client coordinates (empty when hidden).
  if n == nil or n.fRow < 0: return rectF(0, 0, 0, 0)
  let ih = tv.itemHeight
  let y = tv.rowTop(n.fRow, ih)
  let g = tv.geom(n, y, ih)
  rectF(g.labelX, y, g.labelW, ih)

proc expanderRect*(tv: TreeView, n: TreeNode): RectF =
  ## Where the expander of `n` is (empty when it has none).
  if n == nil or n.fRow < 0: return rectF(0, 0, 0, 0)
  let ih = tv.itemHeight
  tv.geom(n, tv.rowTop(n.fRow, ih), ih).expander

proc checkRect*(tv: TreeView, n: TreeNode): RectF =
  if n == nil or n.fRow < 0: return rectF(0, 0, 0, 0)
  let ih = tv.itemHeight
  tv.geom(n, tv.rowTop(n.fRow, ih), ih).check

proc rowAt*(tv: TreeView, p: PointF): int =
  ## Visible row under `p` (client coordinates); -1 outside the rows.
  let vp = tv.viewport
  if not vp.contains(p): return -1
  let i = int(floor((float64(p.y - vp.y) + float64(tv.scrollPos.y)) /
                    float64(tv.itemHeight)))
  if i < 0 or i >= tv.fRows.len: -1 else: i

proc hitTestAt*(tv: TreeView, p: PointF): tuple[node: TreeNode, part: TreeHit] =
  ## The node and the part of it under `p` (client coordinates).
  let i = tv.rowAt(p)
  if i < 0: return (nil, thNone)
  let n = tv.fRows[i]
  let ih = tv.itemHeight
  let g = tv.geom(n, tv.rowTop(i, ih), ih)
  result.node = n
  if g.expander.w > 0 and p.x >= g.expander.x and p.x < g.expander.right:
    result.part = thButton
  elif g.check.w > 0 and p.x >= g.check.x - 2 and p.x < g.check.right + 2:
    result.part = thCheck
  elif g.icon.w > 0 and p.x >= g.icon.x and p.x < g.icon.right:
    result.part = thIcon
  elif p.x >= g.labelX and p.x < g.labelX + g.labelW:
    result.part = thLabel
  else:
    result.part = thRow

proc nodeAt*(tv: TreeView, p: PointF): TreeNode =
  ## The node whose row is under `p`.
  let i = tv.rowAt(p)
  if i < 0: nil else: tv.fRows[i]

proc hotUpdate(tv: TreeView) =
  let h = if tv.fMouseIn and tv.isEnabled:
            tv.nodeAt(pointF(tv.viewport.x + 1, tv.fMouseY))
          else: nil
  if h != tv.fHot:
    tv.fHot = h
    tv.invalidate()

# ---------------------------------------------------------------- selection

func isSelected*(tv: TreeView, n: TreeNode): bool = n != nil and n in tv.fSel
func selCount*(tv: TreeView): int = tv.fSel.len

proc selectedNodes*(tv: TreeView): seq[TreeNode] =
  ## The selected nodes in tree order.
  if tv.fSel.len == 0: return
  if tv.fSel.len == 1:
    for n in tv.fSel: result.add n
    return
  var stack = @[(tv.fRoot, 0)]
  while stack.len > 0 and result.len < tv.fSel.len:
    let (p, i) = stack[^1]
    if i >= p.fKids.len:
      stack.setLen(stack.len - 1)
      continue
    stack[^1][1] = i + 1
    let k = p.fKids[i]
    if k in tv.fSel: result.add k
    if k.fKids.len > 0: stack.add (k, 0)

proc selectOnly(tv: TreeView, n: TreeNode) =
  if tv.fSel.len == 1 and n in tv.fSel: return
  tv.fSel.clear()
  if n != nil: tv.fSel.incl n
  tv.touch()

proc selectRows(tv: TreeView, a, b: int) =
  var s = initHashSet[TreeNode]()
  for j in min(a, b) .. max(a, b): s.incl tv.fRows[j]
  if s == tv.fSel: return
  tv.fSel = s
  tv.touch()

type SelHow = enum shReplace, shToggle, shRange, shFocusOnly

proc ensureVisible*(tv: TreeView, n: TreeNode): bool {.discardable.}
  ## Expands the ancestors of `n` so that it has a row; false when refused.

proc selectNode(tv: TreeView, n: TreeNode, how: SelHow) =
  ## The one place where the focus / selection change (user and code).
  if n == nil or n.fTree != tv: return
  if n != tv.fFocus and tv.onChanging != nil:
    var allow = true
    tv.onChanging(tv, n, allow)
    if not allow: return
  let ver = tv.fVer
  tv.ensureVisible(n)
  case how
  of shReplace:
    tv.selectOnly(n)
    tv.fAnchor = n
  of shToggle:
    if n in tv.fSel: tv.fSel.excl n else: tv.fSel.incl n
    tv.touch()
    tv.fAnchor = n
  of shRange:
    let a = if tv.fAnchor != nil and tv.fAnchor.fRow >= 0: tv.fAnchor.fRow
            else: n.fRow
    if n.fRow >= 0 and a >= 0: tv.selectRows(a, n.fRow)
    else: tv.selectOnly(n)
  of shFocusOnly: discard
  if n != tv.fFocus:
    tv.fFocus = n
    tv.touch()
  tv.makeRowVisible(n.fRow)
  tv.notifyChange(ver)

proc clearSelection*(tv: TreeView) =
  ## Deselects everything (the focus stays).
  if tv.fSel.len == 0: return
  let v = tv.fVer
  tv.fSel.clear()
  tv.touch()
  tv.notifyChange(v)

proc `selected=`*(tv: TreeView, n: TreeNode) =
  ## Selects exactly `n` (nil clears the selection and the focus), expands its
  ## ancestors and scrolls it into view.
  if n == nil:
    if tv.fFocus == nil and tv.fAnchor == nil and tv.fSel.len == 0: return
    let v = tv.fVer
    tv.fSel.clear()
    tv.fFocus = nil
    tv.fAnchor = nil
    tv.touch()
    tv.notifyChange(v)
  else:
    tv.selectNode(n, shReplace)

proc selectAll*(tv: TreeView) =
  ## Multi-select only: selects every visible row.
  if not tv.fMulti or tv.fRows.len == 0: return
  let v = tv.fVer
  tv.selectRows(0, tv.fRows.len - 1)
  tv.notifyChange(v)

proc setSelected*(tv: TreeView, n: TreeNode, v: bool) =
  ## Adds / removes `n` from the selection (single mode: selects / clears).
  if n == nil or n.fTree != tv: return
  if not tv.fMulti:
    if v: tv.selected = n
    elif n == tv.fFocus: tv.selected = nil
    return
  if v == (n in tv.fSel): return
  let ver = tv.fVer
  if v: tv.fSel.incl n else: tv.fSel.excl n
  tv.touch()
  tv.notifyChange(ver)

proc `selected=`*(n: TreeNode, v: bool) =
  if n.fTree != nil: n.fTree.setSelected(n, v)
proc selected*(n: TreeNode): bool = n.fTree != nil and n in n.fTree.fSel

proc `multiSelect=`*(tv: TreeView, v: bool) =
  if v == tv.fMulti: return
  tv.fMulti = v
  if not v and tv.fSel.len > 1: tv.selectOnly(tv.fFocus)
  tv.invalidate()

proc `extendedSelect=`*(tv: TreeView, v: bool) = tv.fExtended = v

# --------------------------------------------------------------- expand etc.

proc fixFocusAfterHide(tv: TreeView, owner: TreeNode, hiddenFocus: bool) =
  ## The focus was inside a subtree that just got hidden: it moves to `owner`
  ## (no `onChanging`: the move is forced), which joins the selection; the
  ## other still-visible selected nodes stay selected.
  if not hiddenFocus: return
  let ver = tv.fVer
  tv.fFocus = owner
  tv.fSel.incl owner
  tv.touch()
  tv.makeRowVisible(owner.fRow)
  tv.notifyChange(ver)

proc doCollapse(tv: TreeView, n: TreeNode): bool {.discardable.} =
  if not n.fExpanded: return false
  if tv.onCollapsing != nil:
    var allow = true
    tv.onCollapsing(tv, n, allow)
    if not allow: return false
  n.fExpanded = false
  tv.fExtentStale = true
  if n.fRow >= 0 and tv.fUpdating == 0:
    let cnt = tv.visibleBelow(n)
    var hiddenFocus = false
    for j in n.fRow + 1 .. n.fRow + cnt:
      let m = tv.fRows[j]
      if m == tv.fFocus: hiddenFocus = true
      if tv.fSel.len > 0 and m in tv.fSel:
        tv.fSel.excl m
        tv.touch()
      if m == tv.fAnchor: tv.fAnchor = n
      if m == tv.fHot: tv.fHot = nil
    tv.cutRows(n.fRow + 1, cnt)
    tv.refresh()
    tv.fixFocusAfterHide(n, hiddenFocus)
    tv.scrollBy(0, 0)
  elif tv.fUpdating > 0:
    tv.fRowsDirty = true
    tv.fPruneSel = true                  # pruned at endUpdate
  if tv.onCollapsed != nil: tv.onCollapsed(tv, n)
  true

proc doExpand(tv: TreeView, n: TreeNode): bool {.discardable.} =
  if n.fExpanded: return true
  if not n.hasChildren: return false
  if tv.onExpanding != nil:
    var allow = true
    tv.onExpanding(tv, n, allow)
    if not allow: return false
  n.fLazy = false
  if n.fKids.len == 0:
    tv.invalidate()
    return false
  n.fExpanded = true
  if n.fRow >= 0 and tv.fUpdating == 0:
    var acc: seq[TreeNode]
    collectVisible(n, acc)
    tv.insertRows(n.fRow + 1, acc)
    tv.renumber(n.fRow + 1)
    tv.refresh()
  elif tv.fUpdating > 0:
    tv.fRowsDirty = true
  if tv.onExpanded != nil: tv.onExpanded(tv, n)
  true

proc beginUpdate*(tv: TreeView) =
  ## Defers the row bookkeeping until the matching `endUpdate` (nestable).
  inc tv.fUpdating

proc endUpdate*(tv: TreeView) =
  if tv.fUpdating == 0: return
  dec tv.fUpdating
  if tv.fUpdating == 0:
    if tv.fRowsDirty: tv.rebuildRows()
    if tv.fPruneSel:                     # collapses deferred by the update
      tv.fPruneSel = false
      var gone: seq[TreeNode]
      for m in tv.fSel:
        if m.fRow < 0: gone.add m
      for m in gone: tv.fSel.excl m
      if gone.len > 0: tv.touch()
      if tv.fHot != nil and tv.fHot.fRow < 0: tv.fHot = nil
    # a node can have been hidden or deleted meanwhile
    if tv.fFocus != nil and tv.fFocus.fRow < 0 and tv.fFocus.fTree == tv:
      var p = tv.fFocus.fParent
      while p != nil and p != tv.fRoot and p.fRow < 0: p = p.fParent
      if p != nil and p != tv.fRoot:
        tv.fixFocusAfterHide(p, true)
        if tv.fAnchor != nil and tv.fAnchor.fRow < 0: tv.fAnchor = p
    tv.refresh()
    tv.scrollBy(0, 0)
    if tv.fPendingChange:
      tv.fPendingChange = false
      tv.invalidate()
      if tv.onChange != nil: tv.onChange(tv, tv.fFocus)

proc expand*(n: TreeNode, recursive = false) =
  ## Expands `n` (and with `recursive` everything below it).
  let tv = n.fTree
  if tv == nil: return
  if not recursive:
    tv.doExpand(n)
    return
  tv.beginUpdate()
  var stack = @[n]
  while stack.len > 0:
    let m = stack.pop()
    if m.fKids.len > 0 or m.fLazy:
      tv.doExpand(m)
      for k in m.fKids: stack.add k
  tv.endUpdate()

proc collapse*(n: TreeNode, recursive = false) =
  let tv = n.fTree
  if tv == nil: return
  if not recursive:
    tv.doCollapse(n)
    return
  # Collapses every expanded node below `n`, innermost first (so each
  # onCollapsed sees its subtree already closed); the visible rows are
  # rebuilt once at endUpdate instead of cut once per node.
  var stack = @[n]
  var all: seq[TreeNode]
  while stack.len > 0:
    let m = stack.pop()
    if m.fExpanded: all.add m
    for k in m.fKids: stack.add k
  tv.beginUpdate()
  for i in countdown(all.high, 0): tv.doCollapse(all[i])
  tv.endUpdate()

proc `expanded=`*(n: TreeNode, v: bool) =
  if v: n.expand() else: n.collapse()

proc `hasChildren=`*(n: TreeNode, v: bool) =
  ## Marks a node without children as expandable (see lazy children).
  n.fLazy = v
  n.invalidateTree()

proc expandAll*(tv: TreeView) =
  ## Expands every node (lazy ones call `onExpanding`).
  tv.beginUpdate()
  var stack: seq[TreeNode]
  for k in tv.fRoot.fKids: stack.add k
  while stack.len > 0:
    let m = stack.pop()
    if m.fKids.len > 0 or m.fLazy:
      tv.doExpand(m)
      for k in m.fKids: stack.add k
  tv.endUpdate()

proc collapseAll*(tv: TreeView) =
  tv.beginUpdate()
  var stack: seq[TreeNode]
  for k in tv.fRoot.fKids: stack.add k
  while stack.len > 0:
    let m = stack.pop()
    if m.fExpanded: tv.doCollapse(m)
    for k in m.fKids: stack.add k
  tv.endUpdate()

proc ensureVisible*(tv: TreeView, n: TreeNode): bool {.discardable.} =
  if n == nil or n.fTree != tv: return false
  var chain: seq[TreeNode]
  var p = n.fParent
  while p != nil and p != tv.fRoot:
    if not p.fExpanded: chain.add p
    p = p.fParent
  for i in countdown(chain.high, 0):
    if not tv.doExpand(chain[i]): return false
  n.fRow >= 0 or tv.fUpdating > 0

proc makeVisible*(n: TreeNode) =
  ## Expands the ancestors and scrolls `n` into view.
  let tv = n.fTree
  if tv != nil and tv.ensureVisible(n): tv.makeRowVisible(n.fRow)

# ------------------------------------------------------------- node editing

proc growCount(tv: TreeView, delta: int) = tv.fCount += delta

proc attach(tv: TreeView, parent: TreeNode, index: int, text: string): TreeNode =
  let i = min(max(index, 0), parent.fKids.len)
  result = TreeNode(fTree: tv, fParent: parent, fText: text, fIdx: i, fRow: -1,
                    fLevel: parent.fLevel + 1, fImage: -1, fSelImage: -1)
  parent.fKids.insert(result, i)
  for j in i + 1 ..< parent.fKids.len: parent.fKids[j].fIdx = j
  inc tv.fCount
  if tv.fUpdating > 0:
    tv.fRowsDirty = true
    return
  if parent != tv.fRoot and (parent.fRow < 0 or not parent.fExpanded):
    tv.invalidate()           # parent may show a new expander
    return
  var pos = 0
  if i == 0:
    pos = if parent == tv.fRoot: 0 else: parent.fRow + 1
  else:
    let prev = parent.fKids[i - 1]
    pos = prev.fRow + 1 + tv.visibleBelow(prev)
  tv.fRows.insert(result, pos)
  tv.renumber(pos)
  tv.refresh()

proc addChild*(n: TreeNode, text: string): TreeNode {.discardable.} =
  ## Appends a child to `n`.
  let tv = n.fTree
  if tv == nil: return nil
  tv.attach(n, n.fKids.len, text)

proc insert*(n: TreeNode, index: int, text: string): TreeNode {.discardable.} =
  ## Inserts a child of `n` at `index` (clamped).
  let tv = n.fTree
  if tv == nil: return nil
  tv.attach(n, index, text)

proc detach(tv: TreeView, n: TreeNode) =
  let p = n.fParent
  var lostFocus = false
  # rows
  if n.fRow >= 0 and tv.fUpdating == 0:
    let cnt = 1 + tv.visibleBelow(n)
    tv.cutRows(n.fRow, cnt)
  elif tv.fUpdating > 0:
    tv.fRowsDirty = true
  # bookkeeping of the whole subtree
  var stack = @[n]
  while stack.len > 0:
    let m = stack.pop()
    if m == tv.fFocus: lostFocus = true
    if tv.fSel.len > 0: tv.fSel.excl m
    if m == tv.fAnchor: tv.fAnchor = nil
    if m == tv.fHot: tv.fHot = nil
    if m == tv.fDownNode: tv.fDownNode = nil
    if m == tv.fSlowNode: tv.fSlowNode = nil
    m.fTree = nil
    m.fRow = -1
    dec tv.fCount
    for k in m.fKids: stack.add k
  p.fKids.delete(n.fIdx)
  for j in n.fIdx ..< p.fKids.len: p.fKids[j].fIdx = j
  n.fParent = nil
  tv.fExtentStale = true
  if p != tv.fRoot and p.fKids.len == 0 and not p.fLazy:
    p.fExpanded = false
  if tv.fEditNode != nil and tv.fEditNode.fTree == nil:
    tv.fEditNode = nil
    if tv.fEdit != nil: tv.fEdit.visible = false
  if tv.fUpdating == 0: tv.refresh()
  if lostFocus:
    let ver = tv.fVer
    let idx = n.fIdx
    var cand: TreeNode = nil
    if idx < p.fKids.len: cand = p.fKids[idx]
    elif idx > 0: cand = p.fKids[idx - 1]
    elif p != tv.fRoot: cand = p
    tv.fFocus = cand
    tv.fAnchor = cand
    if cand != nil and (not tv.fMulti or tv.fSel.len == 0): tv.fSel.incl cand
    tv.touch()
    if cand != nil and cand.fRow >= 0: tv.makeRowVisible(cand.fRow)
    tv.notifyChange(ver)
  elif tv.fUpdating == 0:
    tv.scrollBy(0, 0)

proc delete*(n: TreeNode) =
  ## Removes `n` and its subtree from the tree.
  let tv = n.fTree
  if tv == nil: return
  tv.detach(n)

proc clear*(n: TreeNode) =
  ## Removes all children of `n`.
  let tv = n.fTree
  if tv == nil: return
  if n.fKids.len == 0: return
  tv.beginUpdate()
  let ver = tv.fVer
  # Drop focus / anchor / selection once, up front (not per removed node);
  # onChange then fires once at endUpdate.
  if n == tv.fRoot:
    if tv.fFocus != nil or tv.fAnchor != nil or tv.fSel.len > 0:
      tv.fFocus = nil
      tv.fAnchor = nil
      tv.fSel.clear()
      tv.touch()
  else:
    var changed = false
    if tv.fFocus != nil and n.isAncestorOf(tv.fFocus):
      tv.fFocus = n
      changed = true
    if tv.fAnchor != nil and n.isAncestorOf(tv.fAnchor):
      tv.fAnchor = n
    if tv.fSel.len > 0:
      var gone: seq[TreeNode]
      for m in tv.fSel:
        if n.isAncestorOf(m): gone.add m
      for m in gone: tv.fSel.excl m
      if gone.len > 0: changed = true
    if changed:
      if tv.fFocus == n and (not tv.fMulti or tv.fSel.len == 0): tv.fSel.incl n
      tv.touch()
  tv.fHot = nil
  while n.fKids.len > 0: tv.detach(n.fKids[^1])
  tv.notifyChange(ver)
  tv.endUpdate()

proc `[]`*(it: TreeItems, i: int): TreeNode = it.tv.fRoot.child(i)
  ## Top-level node `i`.
proc topCount*(it: TreeItems): int = it.tv.fRoot.fKids.len
proc top*(it: TreeItems, i: int): TreeNode = it.tv.fRoot.child(i)
proc count*(it: TreeItems): int = it.tv.fCount
proc len*(it: TreeItems): int = it.tv.fCount

proc addChild*(it: TreeItems, parent: TreeNode, text: string): TreeNode {.discardable.} =
  ## Appends a child to `parent` (nil: a new top-level node).
  let p = if parent == nil: it.tv.fRoot else: parent
  it.tv.attach(p, p.fKids.len, text)

proc add*(it: TreeItems, sibling: TreeNode, text: string): TreeNode {.discardable.} =
  ## Adds a node right after `sibling` on its level (nil: last top-level node).
  if sibling == nil or sibling.fTree != it.tv:
    return it.tv.attach(it.tv.fRoot, it.tv.fRoot.fKids.len, text)
  it.tv.attach(sibling.fParent, sibling.fIdx + 1, text)

proc insert*(it: TreeItems, sibling: TreeNode, text: string): TreeNode {.discardable.} =
  ## Inserts a node right before `sibling` on its level (nil: first top-level).
  if sibling == nil or sibling.fTree != it.tv:
    return it.tv.attach(it.tv.fRoot, 0, text)
  it.tv.attach(sibling.fParent, sibling.fIdx, text)

proc delete*(it: TreeItems, n: TreeNode) = n.delete()

proc clear*(it: TreeItems) =
  let tv = it.tv
  tv.fRoot.clear()
  tv.fExtent = 0
  tv.fExtentStale = false
  tv.refresh()
  tv.scrollTo(0, 0)

proc find*(it: TreeItems, text: string): TreeNode =
  ## First node (depth first) whose text equals `text`.
  var stack = @[(it.tv.fRoot, 0)]
  while stack.len > 0:
    let (p, i) = stack[^1]
    if i >= p.fKids.len:
      stack.setLen(stack.len - 1)
      continue
    stack[^1][1] = i + 1
    let k = p.fKids[i]
    if k.fText == text: return k
    if k.fKids.len > 0: stack.add (k, 0)

iterator topNodes*(it: TreeItems): TreeNode =
  for n in it.tv.fRoot.fKids: yield n

# ----------------------------------------------------------------- checks

proc setCheckInternal(tv: TreeView, n: TreeNode, v: CheckBoxState) =
  n.fCheck = v
  if not tv.fPropagate: return
  if v != cbGrayed:
    var stack: seq[TreeNode]
    for k in n.fKids: stack.add k
    while stack.len > 0:
      let m = stack.pop()
      m.fCheck = v
      for k in m.fKids: stack.add k
  var p = n.fParent
  while p != nil and p != tv.fRoot:
    var allOn, allOff = true
    for k in p.fKids:
      if k.fCheck != cbChecked: allOn = false
      if k.fCheck != cbUnchecked: allOff = false
    p.fCheck = if allOn: cbChecked elif allOff: cbUnchecked else: cbGrayed
    p = p.fParent

proc `checked=`*(n: TreeNode, v: CheckBoxState) =
  ## Sets the check state from code (propagates like a user toggle when
  ## `propagateChecks`; `onChecked` is not fired).
  if n.fTree == nil or n.fCheck == v: return
  n.fTree.setCheckInternal(n, v)
  n.fTree.invalidate()

proc `checked=`*(n: TreeNode, v: bool) =
  n.checked = if v: cbChecked else: cbUnchecked

proc toggleCheck*(tv: TreeView, n: TreeNode) =
  ## The user toggles the check box of `n` (fires `onChecked`).
  if n == nil or n.fTree != tv: return
  tv.setCheckInternal(n, if n.fCheck == cbChecked: cbUnchecked else: cbChecked)
  tv.invalidate()
  if tv.onChecked != nil: tv.onChecked(tv, n)

# ----------------------------------------------------------------- editing

proc layoutEdit(tv: TreeView) =
  if tv.fEditNode == nil or tv.fEdit == nil: return
  let n = tv.fEditNode
  if n.fRow < 0: return
  let ih = tv.itemHeight
  let y = tv.rowTop(n.fRow, ih)
  let g = tv.geom(n, y, ih)
  let vp = tv.viewport
  let x = g.labelX - 3
  let w = max(g.labelW + 24, 80)
  tv.fEdit.setBounds(x, y, min(w, max(vp.right - x, 40)), ih)

proc endEdit*(tv: TreeView, cancel = false) =
  ## Ends the in-place edit: commits (`onEdited`) unless `cancel`.
  if tv.fEditNode == nil: return
  let n = tv.fEditNode
  tv.fEditNode = nil
  var txt = tv.fEdit.text
  if tv.fEdit.focused: tv.setFocus()
  tv.fEdit.visible = false
  if not cancel and n.fTree == tv:
    if tv.onEdited != nil: tv.onEdited(tv, n, txt)
    n.fText = txt
  tv.invalidate()

proc beginEdit*(tv: TreeView, n: TreeNode): bool {.discardable.} =
  ## Starts editing the label of `n` (F2). False when read-only, vetoed by
  ## `onEditing`, or the node is not visible.
  if tv.fReadOnly or n == nil or n.fTree != tv or not tv.isEnabled: return false
  if tv.fEditNode != nil: tv.endEdit()
  if not tv.ensureVisible(n) or n.fRow < 0: return false
  var allow = true
  if tv.onEditing != nil: tv.onEditing(tv, n, allow)
  if not allow: return false
  tv.makeRowVisible(n.fRow)
  if tv.fEdit == nil:
    let e = newEdit(tv)
    e.visible = false
    e.tabStop = false
    e.onKeyDown = proc(s: Control, key: var Key, shift: ShiftState) =
      if key == keyEnter: key = Key(0); tv.endEdit()
      elif key == keyEscape: key = Key(0); tv.endEdit(cancel = true)
    e.onExit = proc(s: Control) = tv.endEdit()
    tv.fEdit = e
  tv.fEditNode = n
  tv.fEdit.text = n.fText
  tv.layoutEdit()
  tv.fEdit.visible = true
  tv.fEdit.setFocus()
  tv.fEdit.selectAll()
  tv.invalidate()
  true

proc beginEdit*(n: TreeNode): bool {.discardable.} =
  if n.fTree == nil: false else: n.fTree.beginEdit(n)

proc `readOnly=`*(tv: TreeView, v: bool) =
  tv.fReadOnly = v
  if v: tv.endEdit(cancel = true)

# ---------------------------------------------------------- property setters

proc `images=`*(tv: TreeView, v: ImageList) =
  if tv.fImages != nil and tv.fImgListener != 0:
    tv.fImages.removeListener(tv.fImgListener)
  tv.fImgListener = 0
  tv.fImages = v
  if v != nil:                           # repaint / re-measure on list changes
    tv.fImgListener = v.addListener(proc() =
      tv.refresh()
      tv.invalidate())
  tv.refresh()
method releaseResources*(tv: TreeView) =
  tv.images = nil
proc `indent=`*(tv: TreeView, v: float32) =
  tv.fIndent = max(v, 8)
  tv.invalidate()
proc `itemHeight=`*(tv: TreeView, v: float32) =
  tv.fItemHeight = max(v, 0)
  tv.refresh()
proc `showLines=`*(tv: TreeView, v: bool) = tv.fShowLines = v; tv.invalidate()
proc `showRoot=`*(tv: TreeView, v: bool) = tv.fShowRoot = v; tv.invalidate()
proc `showButtons=`*(tv: TreeView, v: bool) = tv.fShowButtons = v; tv.invalidate()
proc `rowSelect=`*(tv: TreeView, v: bool) = tv.fRowSelect = v; tv.invalidate()
proc `hideSelection=`*(tv: TreeView, v: bool) = tv.fHideSel = v; tv.invalidate()
proc `checkboxes=`*(tv: TreeView, v: bool) = tv.fCheckboxes = v; tv.invalidate()
proc `propagateChecks=`*(tv: TreeView, v: bool) = tv.fPropagate = v

# ---------------------------------------------------------------- user input

proc cancelSlow(tv: TreeView) =
  tv.fSlowNode = nil
  if tv.fSlowTimer != nil: tv.fSlowTimer.enabled = false

proc armSlow(tv: TreeView, n: TreeNode) =
  tv.fSlowNode = n
  if tv.fSlowTimer == nil:
    let t = newTimer(tv, tv.slowClickDelay)
    t.onTimer = proc(s: Timer) =
      s.enabled = false
      let m = tv.fSlowNode
      tv.fSlowNode = nil
      if m != nil and m == tv.fFocus and m.fTree == tv and tv.focused:
        tv.beginEdit(m)
    tv.fSlowTimer = t
  tv.fSlowTimer.enabled = false
  tv.fSlowTimer.interval = max(tv.slowClickDelay, 1)
  tv.fSlowTimer.enabled = true

method canFocus*(tv: TreeView): bool = tv.isVisible and tv.isEnabled

method doMouseEnter*(tv: TreeView) =
  tv.fMouseIn = true
  procCall doMouseEnter(Control(tv))

method doMouseLeave*(tv: TreeView) =
  tv.fMouseIn = false
  tv.hotUpdate()
  procCall doMouseLeave(Control(tv))

proc applyClick(tv: TreeView, n: TreeNode, shift: ShiftState) =
  if tv.fMulti and tv.fExtended:
    if ssShift in shift and tv.fAnchor != nil: tv.selectNode(n, shRange)
    elif ssCtrl in shift: tv.selectNode(n, shToggle)
    else: tv.selectNode(n, shReplace)
  elif tv.fMulti and ssCtrl in shift: tv.selectNode(n, shToggle)
  else: tv.selectNode(n, shReplace)

method doMouseDown*(tv: TreeView, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  tv.cancelSlow()
  tv.fDownNode = nil
  if button in {mbLeft, mbRight}:
    let (n, part) = tv.hitTestAt(pointF(x, y))
    if n != nil:
      tv.fDownNode = n
      tv.fDownPart = part
      case part
      of thButton:
        if button == mbLeft and ssDouble notin shift:
          if n.fExpanded: tv.doCollapse(n) else: tv.doExpand(n)
      of thCheck:
        if button == mbLeft: tv.toggleCheck(n)
      of thIcon, thLabel, thRow:
        if part != thRow or tv.fRowSelect:
          let wasOnly = n == tv.fFocus and tv.fSel.len == 1 and
                        shift * {ssShift, ssCtrl, ssDouble} == {} and
                        button == mbLeft and part == thLabel
          tv.applyClick(n, shift)
          if wasOnly and not tv.fReadOnly: tv.armSlow(n)
      else: discard
  procCall doMouseDown(Control(tv), button, shift, x, y)

method doDblClick*(tv: TreeView) =
  tv.cancelSlow()
  let n = tv.fDownNode
  if n != nil and n.fTree == tv and tv.fDownPart in {thIcon, thLabel, thRow} and
     n.hasChildren:
    if n.fExpanded: tv.doCollapse(n) else: tv.doExpand(n)
  procCall doDblClick(Control(tv))

method doMouseMove*(tv: TreeView, shift: ShiftState, x, y: float32) =
  tv.fMouseIn = true
  tv.fMouseY = y
  tv.hotUpdate()
  procCall doMouseMove(Control(tv), shift, x, y)

proc moveFocus(tv: TreeView, n: TreeNode, shift: ShiftState) =
  if n == nil: return
  if tv.fMulti and tv.fExtended:
    if ssShift in shift: tv.selectNode(n, shRange)
    elif ssCtrl in shift: tv.selectNode(n, shFocusOnly)
    else: tv.selectNode(n, shReplace)
  elif tv.fMulti and ssCtrl in shift: tv.selectNode(n, shFocusOnly)
  else: tv.selectNode(n, shReplace)

proc typeAhead(tv: TreeView, ch: char) =
  let now = nowMs()
  if now - tv.fTypeTime > tv.typeAheadTimeout: tv.fTypeBuf.setLen(0)
  tv.fTypeTime = now
  tv.fTypeBuf.add toLowerAscii(ch)
  let n = tv.fRows.len
  if n == 0: return
  let cur = if tv.fFocus != nil and tv.fFocus.fRow >= 0: tv.fFocus.fRow else: -1
  let start = if tv.fTypeBuf.len == 1: cur + 1 else: max(cur, 0)
  for k in 0 ..< n:
    let i = (start + k) mod n
    if prefixIC(tv.fRows[i].fText, tv.fTypeBuf):
      tv.moveFocus(tv.fRows[i], {})
      break

proc focusRow(tv: TreeView): int =
  if tv.fFocus != nil: tv.fFocus.fRow else: -1

method doKeyDown*(tv: TreeView, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(tv), key, shift)
  tv.fSkipPress = false
  if key == Key(0) or not tv.isEnabled or tv.fEditNode != nil: return
  tv.cancelSlow()
  if shift * {ssAlt} != {}: return
  let n = tv.fRows.len
  let fr = tv.focusRow
  var target = low(int)                   # row; low(int): not a navigation key
  let span = max(tv.lastFullRow - tv.firstFullRow, 1)
  if key == keyUp: target = if fr < 0: 0 else: fr - 1
  elif key == keyDown: target = fr + 1
  elif key == keyHome: target = 0
  elif key == keyEnd: target = n - 1
  elif key == keyPageDown:
    let lf = tv.lastFullRow
    target = if fr < lf: lf else: fr + span
  elif key == keyPageUp:
    let ff = tv.firstFullRow
    target = if fr > ff: ff else: fr - span
  if target != low(int):
    key = Key(0)
    if n > 0: tv.moveFocus(tv.fRows[min(max(target, 0), n - 1)], shift)
    return
  let f = tv.fFocus
  if key == keyLeft and f != nil and f.fTree == tv:
    key = Key(0)
    if f.fExpanded and f.fKids.len > 0: tv.doCollapse(f)
    elif f.parent != nil: tv.moveFocus(f.parent, {})
  elif key == keyRight and f != nil and f.fTree == tv:
    key = Key(0)
    if f.hasChildren and not f.fExpanded: tv.doExpand(f)
    elif f.fExpanded and f.fKids.len > 0: tv.moveFocus(f.fKids[0], {})
  elif (key == '*'.key or key == KeyKpMultiply) and f != nil:
    key = Key(0)
    tv.fSkipPress = true               # the text event of this key is not repeated
    f.expand(recursive = true)
  elif (key == '+'.key or key == KeyKpPlus) and f != nil:
    key = Key(0)
    tv.fSkipPress = true
    tv.doExpand(f)
  elif (key == '-'.key or key == KeyKpMinus) and f != nil:
    key = Key(0)
    tv.fSkipPress = true
    tv.doCollapse(f)
  elif key == keyF2 and f != nil:
    key = Key(0)
    tv.beginEdit(f)
  elif key == keySpace and f != nil and
       (tv.fCheckboxes or (tv.fMulti and ssCtrl in shift)):
    key = Key(0)
    if ssCtrl in shift and tv.fMulti: tv.selectNode(f, shToggle)
    else: tv.toggleCheck(f)
  elif tv.fMulti and tv.fExtended and ssCtrl in shift and key == 'a'.key:
    key = Key(0)
    tv.selectAll()
  else:
    let ch = typeAheadChar(key, shift)
    if ch != '\0' and (ch != ' ' or tv.fTypeBuf.len > 0 and
                       nowMs() - tv.fTypeTime <= tv.typeAheadTimeout):
      key = Key(0)
      tv.typeAhead(ch)

method doKeyPress*(tv: TreeView, text: var string) =
  procCall doKeyPress(Control(tv), text)
  # '*', '+' (typed with Shift on most layouts) arrive as text only
  let f = tv.fFocus
  if tv.fSkipPress:                      # already handled by doKeyDown
    tv.fSkipPress = false
    if text.len == 1 and text[0] in {'*', '+', '-'}: return
  if f == nil or tv.fEditNode != nil or text.len != 1: return
  case text[0]
  of '*': f.expand(recursive = true)
  of '+': tv.doExpand(f)
  of '-': tv.doCollapse(f)
  else: discard

method doExit*(tv: TreeView) =
  tv.cancelSlow()
  tv.invalidate()
  procCall doExit(Control(tv))

# -------------------------------------------------------------------- paint

proc lineColor(t: Theme): Color = t.border

proc hasNext(n: TreeNode): bool =
  n.fParent != nil and n.fIdx + 1 < n.fParent.fKids.len

proc drawLines(tv: TreeView, c: Canvas, n: TreeNode, y, ih: float32) =
  let t = tv.theme
  let lc = lineColor(t)
  let x0 = tv.viewport.x - tv.scrollPos.x + LeftPad
  let ind = tv.fIndent
  let cy = floor(y + ih / 2) + 0.5
  # vertical continuation of the ancestors that have later siblings
  var a = n.fParent
  while a != nil and a != tv.fRoot:
    let col = tv.colOf(a)
    if col >= 0 and a.hasNext:
      let cx = floor(x0 + float32(col) * ind + ind / 2) + 0.5
      c.line(cx, y, cx, y + ih, lc, 1)
    a = a.fParent
  let col = tv.colOf(n)
  if col < 0: return
  let cx = floor(x0 + float32(col) * ind + ind / 2) + 0.5
  let hasPrev = n.fIdx > 0 or n.fParent != tv.fRoot
  let button = tv.fShowButtons and n.hasChildren
  let gap = if button: 7'f32 else: 0'f32
  if hasPrev: c.line(cx, y, cx, cy - gap, lc, 1)
  if n.hasNext: c.line(cx, cy + gap, cx, y + ih, lc, 1)
  c.line(cx + gap, cy, x0 + float32(col + 1) * ind - 2, cy, lc, 1)

method paint*(tv: TreeView, c: Canvas) =
  let t = tv.theme
  let enabled = tv.isEnabled
  let r = tv.clientRect
  c.fillRoundRect(r, t.radius, if enabled: t.surface else: t.surfaceAlt)
  let vp = tv.viewport
  let ih = tv.itemHeight
  let focused = tv.focused
  let n = tv.fRows.len
  c.pushClip(vp)
  let first = max(int(floor(float64(tv.scrollPos.y) / float64(ih))), 0)
  let last = min(int(ceil((float64(tv.scrollPos.y) + float64(vp.h)) / float64(ih))), n)
  let rad = max(t.radius - 1, 2)
  var maxRight = 0'f32
  for i in first ..< last:
    let node = tv.fRows[i]
    let y = tv.rowTop(i, ih)
    let g = tv.geom(node, y, ih)
    maxRight = max(maxRight, g.labelX + g.labelW + tv.scrollPos.x - vp.x + 4)
    var st: ItemStates
    let sel = node in tv.fSel
    if sel and (focused or not tv.fHideSel): st.incl isSelected
    if focused and node == tv.fFocus: st.incl isFocused
    if node == tv.fHot: st.incl isHot
    if not enabled: st.incl isDisabled
    let row = rectF(vp.x - tv.scrollPos.x, y, max(vp.w, tv.contentSize.w), ih)
    let box =
      if tv.fRowSelect: rectF(row.x + 2, y + 1, row.w - 4, ih - 2)
      else: rectF(g.selX, y + 1, g.labelX + g.labelW - g.selX, ih - 2)
    if isSelected in st:
      c.fillRoundRect(box, rad, if focused and enabled: t.selection
                                else: t.selectionInactive)
    elif isHot in st:
      c.fillRoundRect(box, rad, t.hover)
    if isFocused in st and tv.fMulti:
      c.strokeRoundRect(box, rad, t.focusRing, 1)
    var def = true
    if tv.onCustomDrawItem != nil:
      tv.onCustomDrawItem(tv, c, node, row, st, def)
    if not def: continue
    if tv.fShowLines: tv.drawLines(c, node, y, ih)
    let col = if isDisabled in st: t.textDisabled
              elif isSelected in st and focused: t.selectionText
              else: t.text
    if g.expander.w > 0:
      drawChevron(c, pointF(g.expander.x + g.expander.w / 2,
                            g.expander.y + g.expander.h / 2), node.fExpanded,
                  if isDisabled in st: t.textDisabled else: t.textMuted)
    if g.check.w > 0:
      drawCheckGlyph(c, g.check, node.fCheck, t, enabled)
    if g.icon.w > 0:
      let idx = if sel and node.fSelImage >= 0: node.fSelImage else: node.fImage
      tv.fImages.draw(c, idx, g.icon.x, g.icon.y, enabled)
    c.textRect(node.fText, tv.font,
               rectF(g.labelX + LabelPad, y, g.labelW - LabelPad, ih), col,
               taLeft, vaCenter)
  c.popClip()
  let ring = focused
  c.strokeRoundRect(r, t.radius, if ring: t.focusRing else: t.borderStrong,
                    if ring: t.focusRingWidth else: t.borderWidth)
  procCall paint(Control(tv), c)
  if tv.fExtentStale:                    # rows were removed / hidden: shrink
    tv.fExtentStale = false
    if abs(maxRight - tv.fExtent) > 0.5:
      tv.fExtent = maxRight
      tv.refresh()
  elif maxRight > tv.fExtent + 0.5:
    tv.fExtent = maxRight
    tv.refresh()

# -------------------------------------------------------------------- init

proc initTreeView*(tv: TreeView, owner: Component = nil) =
  tv.initScrollingControl(owner)
  tv.setBounds(0, 0, 200, 220)
  tv.tabStop = true
  tv.fRoot = TreeNode(fTree: tv, fRow: -1, fLevel: -1, fExpanded: true,
                      fImage: -1, fSelImage: -1)
  tv.fSel = initHashSet[TreeNode]()
  tv.fIndent = 19
  tv.fExtended = true
  tv.fShowRoot = true
  tv.fShowButtons = true
  tv.slowClickDelay = 600
  tv.typeAheadTimeout = 1000
  tv.padding = spacing(1)

proc newTreeView*(parent: Container = nil, left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): TreeView {.discardable.} =
  new result
  result.initTreeView(parent)
  result.placeControl(parent, left, top, width, height)
