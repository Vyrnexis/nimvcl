## `IndexSet`: a set of row indices stored as sorted runs of consecutive
## indices. Selecting a range of any size is one run, so extending a selection
## with Shift+arrow, Shift+click or a drag, comparing two selections and
## shifting indices on insert/delete cost O(runs), not O(rows).

import std/algorithm

type
  Run = tuple[lo, hi: int]          ## inclusive
  IndexSet* = object
    runs: seq[Run]                  ## sorted, disjoint, never adjacent

func initIndexSet*(): IndexSet = IndexSet()

func len*(s: IndexSet): int =
  for r in s.runs: result += r.hi - r.lo + 1

func runCount*(s: IndexSet): int = s.runs.len

func isEmpty*(s: IndexSet): bool = s.runs.len == 0

func `==`*(a, b: IndexSet): bool = a.runs == b.runs

func first*(s: IndexSet): int =
  ## The smallest index (-1 when empty).
  if s.runs.len == 0: -1 else: s.runs[0].lo

func findRun(s: IndexSet, i: int): int =
  ## Index of the first run with `hi >= i` (`runs.len` when none).
  var lo = 0
  var hi = s.runs.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if s.runs[mid].hi < i: lo = mid + 1 else: hi = mid
  lo

func contains*(s: IndexSet, i: int): bool =
  let k = s.findRun(i)
  k < s.runs.len and s.runs[k].lo <= i

proc clear*(s: var IndexSet) = s.runs.setLen(0)

proc inclRange*(s: var IndexSet, a, b: int) =
  ## Adds every index between `a` and `b` (either order).
  let lo = min(a, b)
  let hi = max(a, b)
  # runs that overlap or touch [lo, hi] merge into one
  var k = s.findRun(lo - 1)
  var j = k
  var nlo = lo
  var nhi = hi
  while j < s.runs.len and s.runs[j].lo <= hi + 1:
    nlo = min(nlo, s.runs[j].lo)
    nhi = max(nhi, s.runs[j].hi)
    inc j
  if j > k:
    s.runs[k] = (nlo, nhi)
    let drop = j - k - 1                  # runs absorbed into run k
    if drop > 0:
      for x in j ..< s.runs.len: s.runs[x - drop] = s.runs[x]
      s.runs.setLen(s.runs.len - drop)
  else:
    s.runs.insert((lo, hi), k)

proc incl*(s: var IndexSet, i: int) = s.inclRange(i, i)

proc excl*(s: var IndexSet, i: int) =
  let k = s.findRun(i)
  if k >= s.runs.len or s.runs[k].lo > i: return
  let r = s.runs[k]
  if r.lo == r.hi: s.runs.delete(k)
  elif i == r.lo: s.runs[k].lo = i + 1
  elif i == r.hi: s.runs[k].hi = i - 1
  else:
    s.runs[k].hi = i - 1
    s.runs.insert((i + 1, r.hi), k + 1)

proc toggle*(s: var IndexSet, i: int) =
  if i in s: s.excl i else: s.incl i

iterator items*(s: IndexSet): int =
  for r in s.runs:
    for i in r.lo .. r.hi: yield i

func minus*(a, b: IndexSet): IndexSet =
  ## The indices of `a` that are not in `b`.
  var j = 0
  for r in a.runs:
    var lo = r.lo
    while j < b.runs.len and b.runs[j].hi < lo: inc j
    var m = j
    while lo <= r.hi:
      if m >= b.runs.len or b.runs[m].lo > r.hi:
        result.runs.add (lo, r.hi)
        break
      if b.runs[m].lo > lo: result.runs.add (lo, b.runs[m].lo - 1)
      lo = b.runs[m].hi + 1
      inc m

proc shift*(s: var IndexSet, at, delta: int) =
  ## Every index >= `at` moves by `delta` (insert: `at` = the new row, +1;
  ## delete: `at` = the row after the removed one, -1, which must not be a
  ## member any more).
  var res: seq[Run]
  template push(a, b: int) =
    if res.len > 0 and res[^1].hi + 1 >= a: res[^1].hi = max(res[^1].hi, b)
    else: res.add (a, b)
  for r in s.runs:
    if r.hi < at: push(r.lo, r.hi)
    elif r.lo >= at: push(r.lo + delta, r.hi + delta)
    else:
      push(r.lo, at - 1)
      push(at + delta, r.hi + delta)
  s.runs = res

proc truncate*(s: var IndexSet, count: int): bool {.discardable.} =
  ## Drops the indices >= `count`; true when something was dropped.
  while s.runs.len > 0 and s.runs[^1].lo >= count:
    s.runs.setLen(s.runs.len - 1)
    result = true
  if s.runs.len > 0 and s.runs[^1].hi >= count:
    s.runs[^1].hi = count - 1
    result = true

proc remapped*(s: IndexSet, pos: openArray[int]): IndexSet =
  ## Every member `j` becomes `pos[j]` (a permutation after a sort).
  var v: seq[int]
  for j in s: v.add pos[j]
  v.sort()
  for i in v: result.incl i
