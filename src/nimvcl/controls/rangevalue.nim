## `RangeValue`: the clamped integer `lo <= pos <= hi` behind the range
## controls (`TrackBar`, `ProgressBar`, `SpinEdit`). The setters return whether
## the position moved so the control can fire its change event once.

type
  RangeValue* = object
    lo*, hi*, pos*: int

func initRange*(lo, hi, pos = 0): RangeValue =
  RangeValue(lo: lo, hi: max(hi, lo), pos: clamp(pos, lo, max(hi, lo)))

proc setPos*(r: var RangeValue, v: int): bool =
  ## Moves the position (clamped); true when it changed.
  let nv = clamp(v, r.lo, r.hi)
  if nv == r.pos: return false
  r.pos = nv
  true

proc setMin*(r: var RangeValue, v: int): bool =
  ## New lower bound (the upper one follows when below it); true when the
  ## position had to move.
  r.lo = v
  if r.hi < v: r.hi = v
  r.setPos(r.pos)

proc setMax*(r: var RangeValue, v: int): bool =
  ## New upper bound (the lower one follows when above it); true when the
  ## position had to move.
  r.hi = v
  if r.lo > v: r.lo = v
  r.setPos(r.pos)
