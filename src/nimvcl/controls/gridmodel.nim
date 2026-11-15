## Axis geometry of a grid (pure Nim, no SDL): `count` slots of one default
## size plus sparse per-slot overrides, with cheap cumulative lookups.
##
## `offset(i)` (start of slot i, `offset(count)` = total) and `indexAt(pos)`
## are O(log k) / O(log n * log k) where k is the number of overridden slots,
## independent of `count`: 1,000,000 rows of one height cost nothing. The
## override prefix sums are rebuilt lazily (O(k)) after a change, so a burst
## of `setSize` calls followed by queries is cheap. `total` is maintained
## incrementally (O(1)) and never triggers a rebuild; the sorted override keys
## are kept by insertion, so no re-sort happens either.

import std/[tables, algorithm]

type
  AxisSizes* = object
    n: int
    def: float32
    over: Table[int, float32]
    sumOver: float64             # sum of the override sizes
    keys: seq[int]               # sorted override indexes (always current)
    prefix: seq[float64]         # prefix[k] = sum of (size - def) of keys[0 ..< k]
    dirty: bool                  # prefix needs a rebuild

func initAxis*(count: int, defaultSize: float32): AxisSizes =
  AxisSizes(n: max(count, 0), def: max(defaultSize, 0))

func count*(a: AxisSizes): int = a.n
func defaultSize*(a: AxisSizes): float32 = a.def
func overrideCount*(a: AxisSizes): int = a.over.len

proc rebuild(a: var AxisSizes) =
  if not a.dirty: return
  a.prefix.setLen(a.keys.len + 1)
  a.prefix[0] = 0
  for j, k in a.keys:
    a.prefix[j + 1] = a.prefix[j] + float64(a.over[k]) - float64(a.def)
  a.dirty = false

proc setCount*(a: var AxisSizes, count: int) =
  ## Overrides beyond the new count are dropped.
  let c = max(count, 0)
  if c < a.n and a.over.len > 0:
    let cut = a.keys.lowerBound(c)
    for j in cut ..< a.keys.len:
      a.sumOver -= float64(a.over[a.keys[j]])
      a.over.del a.keys[j]
    a.keys.setLen(cut)
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
      a.sumOver -= float64(a.over[i])
      a.over.del i
      let j = a.keys.lowerBound(i)
      a.keys.delete(j)
      a.dirty = true
  elif not a.over.hasKey i:
    a.over[i] = v
    a.sumOver += float64(v)
    a.keys.insert(i, a.keys.lowerBound(i))
    a.dirty = true
  elif a.over[i] != v:
    a.sumOver += float64(v) - float64(a.over[i])
    a.over[i] = v
    a.dirty = true

proc resetSizes*(a: var AxisSizes) =
  a.over.clear()
  a.keys.setLen(0)
  a.sumOver = 0
  a.dirty = true

proc offset*(a: var AxisSizes, i: int): float64 =
  ## Start of slot `i` (clamped to 0 .. count); `offset(count)` is the total.
  let k = min(max(i, 0), a.n)
  result = float64(k) * float64(a.def)
  if a.over.len > 0:
    let j = a.keys.lowerBound(k)
    if a.dirty and j <= 64:              # few overrides before k: sum directly
      for q in 0 ..< j: result += float64(a.over[a.keys[q]]) - float64(a.def)
    else:
      a.rebuild()
      result += a.prefix[j]

func total*(a: AxisSizes): float64 =
  ## Sum of all sizes; O(1).
  float64(a.n - a.over.len) * float64(a.def) + a.sumOver

proc indexAt*(a: var AxisSizes, pos: float64): int =
  ## The slot containing `pos`; -1 before the first or after the last slot.
  if a.n == 0 or pos < 0 or pos >= a.total: return -1
  var lo = 0
  var hi = a.n - 1
  while lo < hi:                         # largest i with offset(i) <= pos
    let mid = (lo + hi + 1) div 2
    if a.offset(mid) <= pos: lo = mid else: hi = mid - 1
  lo
