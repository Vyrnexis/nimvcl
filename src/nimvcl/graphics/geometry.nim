## Small float geometry types in logical pixels. Pure Nim, no SDL.

type
  PointF* = object
    x*, y*: float32
  SizeF* = object
    w*, h*: float32
  RectF* = object
    ## Rectangle: origin plus size. Empty when w <= 0 or h <= 0.
    x*, y*, w*, h*: float32

func pointF*(x, y: float32): PointF = PointF(x: x, y: y)
func sizeF*(w, h: float32): SizeF = SizeF(w: w, h: h)
func rectF*(x, y, w, h: float32): RectF = RectF(x: x, y: y, w: w, h: h)

func right*(r: RectF): float32 = r.x + r.w
func bottom*(r: RectF): float32 = r.y + r.h
func isEmpty*(r: RectF): bool = r.w <= 0 or r.h <= 0

func offset*(r: RectF, dx, dy: float32): RectF =
  rectF(r.x + dx, r.y + dy, r.w, r.h)

func inflate*(r: RectF, d: float32): RectF =
  ## Grows (d > 0) or shrinks (d < 0) on every side.
  rectF(r.x - d, r.y - d, r.w + 2 * d, r.h + 2 * d)

func inflate*(r: RectF, dx, dy: float32): RectF =
  ## Grows (positive) or shrinks (negative) by `dx` left and right and by `dy`
  ## top and bottom.
  rectF(r.x - dx, r.y - dy, r.w + 2 * dx, r.h + 2 * dy)

func intersect*(a, b: RectF): RectF =
  ## Intersection; an empty rect (w = h = 0) when they do not overlap.
  let x0 = max(a.x, b.x)
  let y0 = max(a.y, b.y)
  let x1 = min(a.right, b.right)
  let y1 = min(a.bottom, b.bottom)
  if x1 <= x0 or y1 <= y0: rectF(x0, y0, 0, 0)
  else: rectF(x0, y0, x1 - x0, y1 - y0)

func intersects*(a, b: RectF): bool = not intersect(a, b).isEmpty

func contains*(r: RectF, p: PointF): bool =
  p.x >= r.x and p.y >= r.y and p.x < r.right and p.y < r.bottom
