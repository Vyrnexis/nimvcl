## `FlowPanel` and `GridPanel` (VCL TFlowPanel / TGridPanel): panels that
## place their children themselves, through the layout `customAlign` hook.
##
## Children whose `align` is `alNone` are switched to `alCustom` automatically
## (when the panel is laid out), so plain `newButton(flow, ...)` works. A child
## with another `align` (alTop, ...) keeps it and is laid out as usual before
## the flow/grid takes the remaining space. Children's `margins` are honoured
## and are part of their cell/slot; hidden children are skipped.
##
## FlowPanel: children keep their own size and flow in child order.
## * `flowStyle = fsLeftRightTopBottom` (default): rows, wrapping when the next
##   child does not fit the width.
## * `fsTopBottomLeftRight`: columns, wrapping at the height.
## `hGap` / `vGap` add space between neighbours (0 by default).
##
## GridPanel: `columns` and `rows` are lists of tracks:
## * `gsAbsolute(n)`: n logical px,
## * `gsAuto()`: as large as the biggest child (preferred size + margins) that
##   sits in that track alone,
## * `gsPercent(p)`: share of the space left after absolute and auto tracks
##   (percentages that add up to more than 100 are normalised; less leaves the
##   rest empty).
## A panel without columns/rows behaves as one percent track on that axis.
## Children fill their cell (minus margins). `setCell(ctrl, row, col, rowSpan,
## colSpan)` puts one explicitly; the others take the free cells in row-major
## order (those beyond the last cell are not placed). `cellRect` gives a cell's
## rectangle.

import std/[tables, hashes]
import ./[common, panel]
export panel

type
  FlowStyle* = enum fsLeftRightTopBottom, fsTopBottomLeftRight

  FlowPanel* = ref object of Panel
    fStyle: FlowStyle
    fHGap, fVGap: float32

  GridSizeKind* = enum gkAbsolute, gkPercent, gkAuto
  GridSize* = object
    kind*: GridSizeKind
    value*: float32

  GridCell* = object
    row*, col*, rowSpan*, colSpan*: int

  GridPanel* = ref object of Panel
    fCols, fRows: seq[GridSize]
    fCells: Table[Control, GridCell]
    fArea: RectF

proc hash(c: Control): Hash = hash(cast[pointer](c))

func gsAbsolute*(v: float32): GridSize = GridSize(kind: gkAbsolute, value: v)
func gsPercent*(v: float32): GridSize = GridSize(kind: gkPercent, value: v)
func gsAuto*(): GridSize = GridSize(kind: gkAuto)

proc adopt(p: Container) =
  ## alNone children become alCustom so the panel's `customAlign` places them.
  for c in p.children:
    if c.align == alNone: c.align = alCustom

proc firstCustom(p: Container): Control =
  for c in p.children:
    if c.visible and c.align == alCustom: return c

# --------------------------------------------------------------- FlowPanel

func flowStyle*(f: FlowPanel): FlowStyle = f.fStyle
proc `flowStyle=`*(f: FlowPanel, v: FlowStyle) =
  if v == f.fStyle: return
  f.fStyle = v
  f.relayout()
func hGap*(f: FlowPanel): float32 = f.fHGap
proc `hGap=`*(f: FlowPanel, v: float32) =
  f.fHGap = v
  f.relayout()
func vGap*(f: FlowPanel): float32 = f.fVGap
proc `vGap=`*(f: FlowPanel, v: float32) =
  f.fVGap = v
  f.relayout()

method padding*(f: FlowPanel): Spacing =
  adopt(f)
  procCall padding(Container(f))

method customAlign*(f: FlowPanel, child: Control, avail: RectF) =
  if child != f.firstCustom: return
  var x = avail.x
  var y = avail.y
  var line = 0'f32            # extent of the current row/column across the flow
  for c in f.children:
    if not c.visible or c.align != alCustom: continue
    let m = c.margins
    let w = c.width + m.horizontal
    let h = c.height + m.vertical
    case f.fStyle
    of fsLeftRightTopBottom:
      if x > avail.x and x + w > avail.right:
        x = avail.x
        y += line + f.fVGap
        line = 0
      c.setBounds(round(x + m.left), round(y + m.top), c.width, c.height)
      x += w + f.fHGap
      line = max(line, h)
    of fsTopBottomLeftRight:
      if y > avail.y and y + h > avail.bottom:
        y = avail.y
        x += line + f.fHGap
        line = 0
      c.setBounds(round(x + m.left), round(y + m.top), c.width, c.height)
      y += h + f.fVGap
      line = max(line, w)

proc initFlowPanel*(f: FlowPanel, owner: Component = nil) =
  f.initPanel(owner)
  f.borderStyle = pbNone
  f.setBounds(0, 0, 200, 100)

proc newFlowPanel*(parent: Container = nil, left = 0'f32, top = 0'f32,
                   width = -1'f32, height = -1'f32): FlowPanel =
  new result
  result.initFlowPanel(parent)
  result.placeControl(parent, left, top, width, height)

# --------------------------------------------------------------- GridPanel

func columns*(g: GridPanel): seq[GridSize] = g.fCols
proc `columns=`*(g: GridPanel, v: seq[GridSize]) =
  g.fCols = v
  g.relayout()
func rows*(g: GridPanel): seq[GridSize] = g.fRows
proc `rows=`*(g: GridPanel, v: seq[GridSize]) =
  g.fRows = v
  g.relayout()
proc addColumn*(g: GridPanel, s: GridSize) =
  g.fCols.add s
  g.relayout()
proc addRow*(g: GridPanel, s: GridSize) =
  g.fRows.add s
  g.relayout()

proc setCell*(g: GridPanel, c: Control, row, col: int, rowSpan = 1, colSpan = 1) =
  ## Places `c` explicitly (spans are clamped to the grid when laid out).
  g.fCells[c] = GridCell(row: row, col: col, rowSpan: max(rowSpan, 1),
                         colSpan: max(colSpan, 1))
  if c.align == alNone: c.align = alCustom
  g.relayout()

proc clearCell*(g: GridPanel, c: Control) =
  g.fCells.del c
  g.relayout()

func trackCount(tracks: seq[GridSize]): int = max(tracks.len, 1)

proc placements(g: GridPanel): seq[(Control, GridCell)] =
  ## Every visible custom child with its cell (explicit ones first, then the
  ## rest in free cells, row-major).
  let nr = trackCount(g.fRows)
  let nc = trackCount(g.fCols)
  var taken = newSeq[bool](nr * nc)
  var kids: seq[Control]
  for c in g.children:
    if c.visible and c.align == alCustom: kids.add c
  var res = initTable[Control, GridCell]()
  for c in kids:
    if c in g.fCells:
      var cell = g.fCells[c]
      cell.row = clamp(cell.row, 0, nr - 1)
      cell.col = clamp(cell.col, 0, nc - 1)
      cell.rowSpan = min(cell.rowSpan, nr - cell.row)
      cell.colSpan = min(cell.colSpan, nc - cell.col)
      for r in cell.row ..< cell.row + cell.rowSpan:
        for k in cell.col ..< cell.col + cell.colSpan: taken[r * nc + k] = true
      res[c] = cell
  var next = 0
  for c in kids:
    if c in res: continue
    while next < taken.len and taken[next]: inc next
    if next >= taken.len: break
    res[c] = GridCell(row: next div nc, col: next mod nc, rowSpan: 1, colSpan: 1)
    taken[next] = true
  for c in kids:
    if c in res: result.add (c, res[c])

proc trackSizes(g: GridPanel, tracks: seq[GridSize], total: float32,
                horizontal: bool, cells: seq[(Control, GridCell)]): seq[float32] =
  let n = trackCount(tracks)
  result = newSeq[float32](n)
  var used = 0'f32
  var pctSum = 0'f32
  for i in 0 ..< n:
    let t = if tracks.len == 0: gsPercent(100) else: tracks[i]
    case t.kind
    of gkAbsolute:
      result[i] = t.value
      used += t.value
    of gkAuto:
      for (c, cell) in cells:
        let (idx, span) = if horizontal: (cell.col, cell.colSpan) else: (cell.row, cell.rowSpan)
        if idx == i and span == 1:
          let ps = c.preferredSize()
          let m = c.margins
          result[i] = max(result[i], if horizontal: ps.w + m.horizontal else: ps.h + m.vertical)
      used += result[i]
    of gkPercent: pctSum += t.value
  let rest = max(total - used, 0)
  let norm = max(pctSum, 100'f32)
  for i in 0 ..< n:
    let t = if tracks.len == 0: gsPercent(100) else: tracks[i]
    if t.kind == gkPercent: result[i] = rest * t.value / norm

proc edges(sizes: seq[float32], origin: float32): seq[float32] =
  ## Rounded cumulative track edges (n + 1 values): no gaps, no overlaps.
  result = @[round(origin)]
  var acc = origin
  for s in sizes:
    acc += s
    result.add round(acc)

proc gridArea(g: GridPanel): RectF =
  let p = g.padding
  rectF(p.left, p.top, max(g.width - p.horizontal, 0), max(g.height - p.vertical, 0))

proc layoutCells(g: GridPanel, area: RectF): (seq[float32], seq[float32],
                                              seq[(Control, GridCell)]) =
  let cells = g.placements
  let cx = edges(g.trackSizes(g.fCols, area.w, true, cells), area.x)
  let cy = edges(g.trackSizes(g.fRows, area.h, false, cells), area.y)
  (cx, cy, cells)

proc cellRect*(g: GridPanel, row, col: int, rowSpan = 1, colSpan = 1): RectF =
  ## Rectangle of a cell (client coordinates), margins not applied.
  let (cx, cy, _) = g.layoutCells(g.gridArea)
  let r0 = clamp(row, 0, cy.len - 2)
  let c0 = clamp(col, 0, cx.len - 2)
  let r1 = clamp(r0 + max(rowSpan, 1), r0 + 1, cy.len - 1)
  let c1 = clamp(c0 + max(colSpan, 1), c0 + 1, cx.len - 1)
  rectF(cx[c0], cy[r0], cx[c1] - cx[c0], cy[r1] - cy[r0])

method padding*(g: GridPanel): Spacing =
  adopt(g)
  procCall padding(Container(g))

method customAlign*(g: GridPanel, child: Control, avail: RectF) =
  if child != g.firstCustom: return
  g.fArea = avail
  let (cx, cy, cells) = g.layoutCells(avail)
  for (c, cell) in cells:
    let m = c.margins
    let x0 = cx[cell.col]
    let y0 = cy[cell.row]
    let x1 = cx[cell.col + cell.colSpan]
    let y1 = cy[cell.row + cell.rowSpan]
    c.setBounds(x0 + m.left, y0 + m.top, max(x1 - x0 - m.horizontal, 0),
                max(y1 - y0 - m.vertical, 0))

proc initGridPanel*(g: GridPanel, owner: Component = nil) =
  g.initPanel(owner)
  g.borderStyle = pbNone
  g.setBounds(0, 0, 200, 100)

proc newGridPanel*(parent: Container = nil, left = 0'f32, top = 0'f32,
                   width = -1'f32, height = -1'f32): GridPanel =
  new result
  result.initGridPanel(parent)
  result.placeControl(parent, left, top, width, height)
