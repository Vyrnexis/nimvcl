## Anti-aliased geometry builders for `renderGeometry`.
##
## All coordinates here are DEVICE pixels. Shapes are built as rings of
## vertices; the outermost ring fades from alpha 1 to 0 over one device pixel
## (the "feather"), which gives smooth edges without multisampling.
## Pixel-aligned edges stay crisp: a rect edge on an integer coordinate covers
## its pixels fully and leaves the neighbours untouched.

import std/math
import sdl3 except Color
import ./color

type
  GeoBuf* = object
    ## Reusable vertex and index buffers (kept on the RenderContext).
    verts*: seq[Vertex]
    idx*: seq[cint]

  ShapeKind = enum skRoundRect, skEllipse

  Shape = object
    kind: ShapeKind
    x, y, w, h, r: float32
    seg: int

func clear*(g: var GeoBuf) =
  g.verts.setLen 0
  g.idx.setLen 0

func isEmpty*(g: GeoBuf): bool = g.idx.len == 0

func fcolor(c: Color, alpha: float32): FColor =
  FColor(r: c.r.float32 / 255, g: c.g.float32 / 255, b: c.b.float32 / 255,
         a: c.a.float32 / 255 * alpha)

proc addVert(g: var GeoBuf, x, y: float32, c: Color, alpha: float32): cint =
  result = g.verts.len.cint
  g.verts.add Vertex(position: FPoint(x: x, y: y), color: fcolor(c, alpha),
                     tex_coord: FPoint(x: 0, y: 0))

proc tri(g: var GeoBuf, a, b, c: cint) =
  g.idx.add a
  g.idx.add b
  g.idx.add c

func segFor(r: float32): int =
  clamp(int(ceil(r / 2.0)) + 3, 4, 32)

func roundRectShape(x, y, w, h, r: float32): Shape =
  let rr = clamp(r, 0'f32, min(w, h) / 2)
  Shape(kind: skRoundRect, x: x, y: y, w: w, h: h, r: rr, seg: segFor(rr))

func ellipseShape(x, y, w, h: float32): Shape =
  Shape(kind: skEllipse, x: x, y: y, w: w, h: h,
        seg: clamp(int(ceil(max(w, h) / 2 / 2.0)) + 3, 8, 32) * 4)

func ringCount(s: Shape): int =
  case s.kind
  of skRoundRect: 4 * (s.seg + 1)
  of skEllipse: s.seg

# Adds the ring of the shape inset by `d` (negative grows it); returns the first
# vertex index. Rings of one shape all have the same vertex count, so ring k and
# ring k+1 can be stitched index by index.
proc addRing(g: var GeoBuf, s: Shape, d: float32, c: Color, alpha: float32): cint =
  result = g.verts.len.cint
  case s.kind
  of skRoundRect:
    let rr = max(s.r - d, 0'f32)
    let ci = max(s.r, d)              # corner centres move inward once d > r
    let cx = [s.x + ci, s.x + s.w - ci, s.x + s.w - ci, s.x + ci]
    let cy = [s.y + ci, s.y + ci, s.y + s.h - ci, s.y + s.h - ci]
    let a0 = [PI, 1.5 * PI, 0.0, 0.5 * PI]
    for k in 0 .. 3:
      for i in 0 .. s.seg:
        let a = a0[k] + (PI / 2) * i.float / s.seg.float
        discard g.addVert(cx[k] + rr * cos(a).float32, cy[k] + rr * sin(a).float32,
                          c, alpha)
  of skEllipse:
    let rx = s.w / 2
    let ry = s.h / 2
    let mx = s.x + rx
    let my = s.y + ry
    for i in 0 ..< s.seg:
      let a = 2 * PI * i.float / s.seg.float
      let ca = cos(a).float32
      let sa = sin(a).float32
      # offset along the outward normal of the ellipse
      var nx = ca / rx
      var ny = sa / ry
      let nl = sqrt(nx * nx + ny * ny)
      nx /= nl
      ny /= nl
      discard g.addVert(mx + rx * ca - d * nx, my + ry * sa - d * ny, c, alpha)

proc fillShape(g: var GeoBuf, s: Shape, c: Color) =
  let half = min(s.w, s.h) / 2
  let inset = min(0.5'f32, half)
  let ctr = g.addVert(s.x + s.w / 2, s.y + s.h / 2, c, 1)
  let inner = g.addRing(s, inset, c, 1)
  let outer = g.addRing(s, inset - 1, c, 0)
  let n = s.ringCount.cint
  for i in 0 ..< n:
    let j = (i + 1) mod n
    g.tri ctr, inner + i, inner + j
    g.tri inner + i, outer + i, inner + j
    g.tri inner + j, outer + i, outer + j

proc strokeShape(g: var GeoBuf, s: Shape, bw: float32, c: Color) =
  # Border lies inside the shape, `bw` device px wide. Rings: outer feather,
  # outer edge, inner edge, inner feather.
  let ds = [-0.5'f32, 0.5, bw - 0.5, bw + 0.5]
  let al = [0'f32, 1, 1, 0]
  var first: array[4, cint]
  for k in 0 .. 3:
    first[k] = g.addRing(s, ds[k], c, al[k])
  let n = s.ringCount.cint
  for k in 0 .. 2:
    for i in 0 ..< n:
      let j = (i + 1) mod n
      g.tri first[k] + i, first[k + 1] + i, first[k] + j
      g.tri first[k] + j, first[k + 1] + i, first[k + 1] + j

proc addFillRoundRect*(g: var GeoBuf, x, y, w, h, r: float32, c: Color) =
  ## Filled rounded rect (device px). `r` is clamped to half the shorter side.
  if w > 0 and h > 0: g.fillShape(roundRectShape(x, y, w, h, r), c)

proc addStrokeRoundRect*(g: var GeoBuf, x, y, w, h, r, bw: float32, c: Color) =
  ## Rounded rect border, `bw` device px wide, inside the rect.
  if w > 0 and h > 0:
    g.strokeShape(roundRectShape(x, y, w, h, r), min(bw, min(w, h) / 2), c)

proc addFillEllipse*(g: var GeoBuf, x, y, w, h: float32, c: Color) =
  if w > 0 and h > 0: g.fillShape(ellipseShape(x, y, w, h), c)

proc addStrokeEllipse*(g: var GeoBuf, x, y, w, h, bw: float32, c: Color) =
  if w > 0 and h > 0:
    g.strokeShape(ellipseShape(x, y, w, h), min(bw, min(w, h) / 2), c)

proc addLine*(g: var GeoBuf, x1, y1, x2, y2, bw: float32, c: Color) =
  ## Line of width `bw` device px centred on the segment, butt caps, feathered
  ## sides. Widths below 1 px are drawn 1 px wide with proportionally lower alpha.
  let dx = x2 - x1
  let dy = y2 - y1
  let len = sqrt(dx * dx + dy * dy)
  if len < 1e-4: return
  let nx = -dy / len
  let ny = dx / len
  var hw = bw / 2
  var a = 1'f32
  if bw < 1:
    a = max(bw, 0'f32)
    hw = 0.5
  # cross-section offsets from the centre line: outer feather, edge, edge, feather
  let offs = [-(hw + 0.5), -(hw - 0.5), hw - 0.5, hw + 0.5]
  let al = [0'f32, a, a, 0]
  var vs: array[8, cint]
  for k in 0 .. 3:
    vs[k * 2] = g.addVert(x1 + nx * offs[k], y1 + ny * offs[k], c, al[k])
    vs[k * 2 + 1] = g.addVert(x2 + nx * offs[k], y2 + ny * offs[k], c, al[k])
  for k in 0 .. 2:
    g.tri vs[k * 2], vs[k * 2 + 1], vs[k * 2 + 2]
    g.tri vs[k * 2 + 1], vs[k * 2 + 3], vs[k * 2 + 2]

proc addFillPolygon*(g: var GeoBuf, pts: openArray[FPoint], c: Color) =
  ## Filled CONVEX polygon (device px), any winding. Concave input is not
  ## supported: it is triangulated as a fan and will fill incorrectly.
  let n = pts.len
  if n < 3: return
  var area = 0'f32
  var cx, cy = 0'f32
  for i in 0 ..< n:
    let p = pts[i]
    let q = pts[(i + 1) mod n]
    area += p.x * q.y - q.x * p.y
    cx += p.x
    cy += p.y
  if abs(area) < 1e-6: return
  cx /= n.float32
  cy /= n.float32
  let sgn = if area > 0: 1'f32 else: -1'f32   # y down: > 0 is clockwise on screen
  # outward vertex offsets from the averaged edge normals (miter, limited)
  proc offsetPt(pts: openArray[FPoint], i: int, d: float32, sgn: float32): FPoint =
    let n = pts.len
    let p0 = pts[(i + n - 1) mod n]
    let p1 = pts[i]
    let p2 = pts[(i + 1) mod n]
    var ax = p1.x - p0.x
    var ay = p1.y - p0.y
    var bx = p2.x - p1.x
    var by = p2.y - p1.y
    let al = sqrt(ax * ax + ay * ay)
    let bl = sqrt(bx * bx + by * by)
    if al > 0: ax /= al; ay /= al
    if bl > 0: bx /= bl; by /= bl
    # outward normals for clockwise (sgn > 0) winding on a y-down screen: (dy, -dx)
    var nx = (ay + by) * sgn
    var ny = -(ax + bx) * sgn
    let nl = sqrt(nx * nx + ny * ny)
    if nl < 1e-5: return p1
    nx /= nl
    ny /= nl
    let cosHalf = max(nx * ay * sgn - ny * ax * sgn, 0.5'f32)  # limit miter to 2x
    FPoint(x: p1.x + nx * d / cosHalf, y: p1.y + ny * d / cosHalf)
  let ctr = g.addVert(cx, cy, c, 1)
  let inner = g.verts.len.cint
  for i in 0 ..< n:
    let p = offsetPt(pts, i, -0.5, sgn)
    discard g.addVert(p.x, p.y, c, 1)
  let outer = g.verts.len.cint
  for i in 0 ..< n:
    let p = offsetPt(pts, i, 0.5, sgn)
    discard g.addVert(p.x, p.y, c, 0)
  for i in 0 ..< n.cint:
    let j = (i + 1) mod n.cint
    g.tri ctr, inner + i, inner + j
    g.tri inner + i, outer + i, inner + j
    g.tri inner + j, outer + i, outer + j
