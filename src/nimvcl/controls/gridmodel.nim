## Axis geometry of a grid (pure Nim, no SDL): `count` slots of one default
## size plus sparse per-slot overrides, with cheap cumulative lookups.
##
## `offset(i)` (start of slot i, `offset(count)` = total) and `indexAt(pos)`
## are O(log k) / O(log n * log k) where k is the number of overridden slots,
## independent of `count`: 1,000,000 rows of one height cost nothing. The
## override prefix sums are rebuilt lazily (O(k log k)) after a change, so a
## burst of `setSize` calls followed by queries is cheap.

import std/[tables, algorithm]

type
  AxisSizes* = object
    n: int
    def: float32
    over: Table[int, float32]
    keys: seq[int]               # sorted override indexes (valid unless dirty)
    prefix: seq[float64]         # prefix[k] = sum of (size - def) of keys[0 ..< k]
    dirty: bool

func initAxis*(count: int, defaultSize: float32): AxisSizes =
  AxisSizes(n: max(count, 0), def: max(defaultSize, 0))

func count*(a: AxisSizes): int = a.n
func defaultSize*(a: AxisSizes): float32 = a.def
func overrideCount*(a: AxisSizes): int = a.over.len

proc rebuild(a: var AxisSizes) =
  if not a.dirty: return
  a.keys.setLen(0)
  for k in a.over.keys: a.keys.add k
  a.keys.sort()
  a.prefix.setLen(a.keys.len + 1)
  a.prefix[0] = 0
  for j, k in a.keys:
    a.prefix[j + 1] = a.prefix[j] + float64(a.over[k]) - float64(a.def)
  a.dirty = false

proc setCount*(a: var AxisSizes, count: int) =
  ## Overrides beyond the new count are dropped.
  let c = max(count, 0)
  if c < a.n and a.over.len > 0:
    var drop: seq[int]
    for k in a.over.keys:
      if k >= c: drop.add k
    for k in drop: a.over.del k
    a.dirty = true
  a.n = c

proc setDefaultSize*(a: var AxisSizes, s: float32) =
  ## Overrides keep their own sizes.
  a.def = max(s, 0)
  a.dirty = true

func size*(a: AxisSizes, i: int): float32 =
  if i < 0 or i >= a.n: return 0
  a.over.getOrDefault(i, a.def)

proc setSize*(a: var AxisSizes, i: int, s: float32) =
  if i < 0 or i >= a.n: return
  let v = max(s, 0)
  if v == a.def:
    if a.over.hasKey i:
      a.over.del i
      a.dirty = true
  elif a.over.getOrDefault(i, a.def) != v or not a.over.hasKey i:
    a.over[i] = v
    a.dirty = true

proc resetSizes*(a: var AxisSizes) =
  a.over.clear()
  a.dirty = true

proc offset*(a: var AxisSizes, i: int): float64 =
  ## Start of slot `i` (clamped to 0 .. count); `offset(count)` is the total.
  let k = min(max(i, 0), a.n)
  result = float64(k) * float64(a.def)
  if a.over.len > 0:
    a.rebuild()
    result += a.prefix[a.keys.lowerBound(k)]

proc total*(a: var AxisSizes): float64 = a.offset(a.n)

proc indexAt*(a: var AxisSizes, pos: float64): int =
  ## The slot containing `pos`; -1 before the first or after the last slot.
  if a.n == 0 or pos < 0 or pos >= a.total: return -1
  var lo = 0
  var hi = a.n - 1
  while lo < hi:                         # largest i with offset(i) <= pos
    let mid = (lo + hi + 1) div 2
    if a.offset(mid) <= pos: lo = mid else: hi = mid - 1
  lo
