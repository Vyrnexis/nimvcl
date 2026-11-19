## Fold regions for `CodeEdit`. Pure Nim, no SDL.
##
## A `FoldRegion` hides the lines `startLine + 1 .. endLine` when collapsed;
## `startLine` stays visible as the fold header. Three built-in sources can be
## combined (`kinds`) and a custom hook adds more:
## * `fkIndent`: a line starts a region when the next non-blank line is
##   indented deeper; the region runs while lines stay deeper (trailing blank
##   lines are not part of it). For Nim, Python, YAML...
## * `fkBrackets`: `{ [ (` opened on a line and closed on a later one. The
##   closing line stays visible (`endLine = closeLine - 1`). Brackets inside
##   strings and comments are skipped when a highlighter is supplied.
## * `fkMarkers`: lines starting with a region marker (`#region` ...
##   `#endregion`, `// region`, ...), nested; the end marker line is hidden.
##
## Incremental: the per-line facts (indent width, brackets, marker) are cached
## and only the lines named by a model change notification are recomputed.
## An edit that keeps the line count and leaves every recomputed fact as it
## was (typing inside a line) keeps the region list as it is. Otherwise the
## list is rebuilt lazily from the facts by one stack pass (integers only),
## which does not re-read any text. Bracket facts also depend on the lexer
## state, so a line is recomputed when its start state changed (e.g. a `#[`
## was opened above); the check stops where the states match again.
##
## Collapsed headers are remembered by line number and shifted by edits above
## them; a header that stops being a fold start is expanded automatically.

import std/[algorithm, strutils]
import ./[codemodel, highlight, textutil]

type
  FoldRegion* = object
    startLine*, endLine*: int

  FoldKind* = enum fkIndent, fkBrackets, fkMarkers

  FoldHook* = proc(m: CodeModel, hl: Highlighter): seq[FoldRegion] {.closure.}
    ## Extra regions for a language (a full scan on demand; the result is
    ## cached until the next change).

  FoldMap* = ref object
    model: CodeModel
    hl: Highlighter
    listenerId: int
    fKinds: set[FoldKind]
    hook: FoldHook
    ind: seq[int32]
    valid: seq[bool]
    brkState: seq[int32]
    brk: seq[string]
    mark: seq[int8]
    fRegions: seq[FoldRegion]
    dirty: bool
    structural: bool              ## the facts may differ from those the regions come from
    dirtyLo, dirtyHi: int         ## lines whose facts may need recomputing
    collapsed: seq[int]           ## sorted header lines
    hiddenCache: seq[tuple[a, b: int]]
    hiddenBefore: seq[int]        ## hidden lines in the ranges before range k
    hiddenDirty: bool
    markerStarts*, markerEnds*: seq[string]
    onChanged*: proc()            ## regions or collapsed set changed

# ---------------------------------------------------------------- per line

func firstNonSpace(s: string): int =
  while result < s.len and s[result] in {' ', '\t'}: inc result

proc computeLine(f: FoldMap, i: int): bool =
  ## Recomputes the facts of line `i`; true when any of them changed.
  let line = f.model.line(i)
  let (oldInd, oldMark, oldBrk, oldValid) = (f.ind[i], f.mark[i], f.brk[i], f.valid[i])
  f.ind[i] = int32(indentWidth(line, f.model.tabWidth))
  f.mark[i] = 0
  if fkMarkers in f.fKinds:
    let t = line[firstNonSpace(line) .. ^1]
    for s in f.markerStarts:
      if t.startsWith(s):
        f.mark[i] = 1
        break
    if f.mark[i] == 0:
      for s in f.markerEnds:
        if t.startsWith(s):
          f.mark[i] = -1
          break
  f.brk[i] = ""
  if fkBrackets in f.fKinds:
    if f.hl != nil:
      f.brkState[i] = int32(f.hl.stateAtLineStart(i))
      for t in f.hl.tokens(i):
        if t.kind in {tkString, tkChar, tkComment, tkDocComment}: continue
        for j in t.start ..< t.stop:
          if line[j] in {'{', '}', '[', ']', '(', ')'}: f.brk[i].add line[j]
    else:
      for c in line:
        if c in {'{', '}', '[', ']', '(', ')'}: f.brk[i].add c
  f.valid[i] = true
  not oldValid or oldInd != f.ind[i] or oldMark != f.mark[i] or oldBrk != f.brk[i]

proc resetCache(f: FoldMap) =
  let n = f.model.lineCount
  f.ind = newSeq[int32](n)
  f.valid = newSeq[bool](n)
  f.brkState = newSeq[int32](n)
  f.brk = newSeq[string](n)
  f.mark = newSeq[int8](n)
  f.dirty = true
  f.structural = true
  f.dirtyLo = 0
  f.dirtyHi = n - 1
  f.hiddenDirty = true

proc modelChanged(f: FoldMap, first, oldN, newN: int) =
  let delta = newN - oldN
  if delta == 0:
    # the same lines, new text: keep the old facts to see whether they change
    for i in first ..< first + newN: f.valid[i] = false
  else:
    f.ind.respliceSeq(first, oldN, newN)
    f.valid.respliceSeq(first, oldN, newN)
    f.brkState.respliceSeq(first, oldN, newN)
    f.brk.respliceSeq(first, oldN, newN)
    f.mark.respliceSeq(first, oldN, newN)
    f.structural = true
  if f.dirtyHi >= 0:                # shift the pending range past this change
    if f.dirtyLo >= first + oldN: f.dirtyLo += delta
    if f.dirtyHi >= first + oldN: f.dirtyHi += delta
  f.dirtyLo = min(f.dirtyLo, first)
  f.dirtyHi = max(f.dirtyHi, first + newN - 1)
  f.dirty = true
  f.hiddenDirty = true
  var keep: seq[int]
  for s in f.collapsed:
    if s < first: keep.add s
    elif s >= first + oldN: keep.add s + delta
    elif s == first: keep.add s
  f.collapsed = keep

# --------------------------------------------------------------- regions

proc refreshFacts(f: FoldMap): bool =
  ## Recomputes the facts of the lines that changed; true when any fact (or the
  ## line structure) differs from what the region list was built from.
  result = f.structural or f.hook != nil
  let n = f.model.lineCount
  let byState = fkBrackets in f.fKinds and f.hl != nil
  var i = max(f.dirtyLo, 0)
  while i < n:
    if not f.valid[i] or (byState and f.brkState[i] != int32(f.hl.stateAtLineStart(i))):
      if f.computeLine(i): result = true
    elif i > f.dirtyHi: break          # unchanged text and state: the rest is as well
    inc i
  f.dirtyLo = high(int)
  f.dirtyHi = -1
  f.structural = false

proc rebuild(f: FoldMap) =
  f.dirty = false
  if not f.refreshFacts(): return
  let n = f.model.lineCount
  var all: seq[FoldRegion]
  if fkIndent in f.fKinds:
    var stack: seq[tuple[line, indent: int]]
    var lastNonBlank = -1
    for i in 0 ..< n:
      let ind = int(f.ind[i])
      if ind < 0: continue
      while stack.len > 0 and stack[^1].indent >= ind:
        let r = stack.pop
        if lastNonBlank > r.line: all.add FoldRegion(startLine: r.line, endLine: lastNonBlank)
      stack.add (i, ind)
      lastNonBlank = i
    while stack.len > 0:
      let r = stack.pop
      if lastNonBlank > r.line: all.add FoldRegion(startLine: r.line, endLine: lastNonBlank)
  if fkBrackets in f.fKinds:
    var stack: seq[tuple[c: char, line: int]]
    for i in 0 ..< n:
      for c in f.brk[i]:
        case c
        of '{', '[', '(': stack.add (c, i)
        else:
          let open = case c
            of '}': '{'
            of ']': '['
            else: '('
          if stack.len > 0 and stack[^1].c == open:
            let o = stack.pop
            if i - 1 > o.line: all.add FoldRegion(startLine: o.line, endLine: i - 1)
  if fkMarkers in f.fKinds:
    var stack: seq[int]
    for i in 0 ..< n:
      if f.mark[i] == 1: stack.add i
      elif f.mark[i] == -1 and stack.len > 0:
        let o = stack.pop
        if i > o: all.add FoldRegion(startLine: o, endLine: i)
  if f.hook != nil:
    for r in f.hook(f.model, f.hl):
      if r.startLine >= 0 and r.endLine > r.startLine and r.endLine < n: all.add r
  all.sort(proc(a, b: FoldRegion): int =
    if a.startLine != b.startLine: cmp(a.startLine, b.startLine)
    else: cmp(b.endLine, a.endLine))
  f.fRegions.setLen 0
  for r in all:           # one region per header: the largest
    if f.fRegions.len == 0 or f.fRegions[^1].startLine != r.startLine:
      f.fRegions.add r
  # headers that stopped being fold starts are expanded
  var keep: seq[int]
  for s in f.collapsed:
    let k = f.fRegions.lowerBound(s, proc(r: FoldRegion, v: int): int = cmp(r.startLine, v))
    if k < f.fRegions.len and f.fRegions[k].startLine == s: keep.add s
  if keep.len != f.collapsed.len: f.collapsed = keep
  f.hiddenDirty = true

proc regions*(f: FoldMap): lent seq[FoldRegion] =
  ## All fold regions, sorted by header line (one per header).
  if f.dirty: f.rebuild()
  f.fRegions

proc regionAt*(f: FoldMap, line: int): int =
  ## Index in `regions` of the region whose header is `line`, or -1.
  let rs = f.regions
  let k = rs.lowerBound(line, proc(r: FoldRegion, v: int): int = cmp(r.startLine, v))
  if k < rs.len and rs[k].startLine == line: k else: -1

proc canFold*(f: FoldMap, line: int): bool = f.regionAt(line) >= 0

proc foldEnd*(f: FoldMap, line: int): int =
  ## Last line hidden when `line` is collapsed; -1 if `line` is no header.
  let k = f.regionAt(line)
  if k < 0: -1 else: f.fRegions[k].endLine

# ------------------------------------------------------------- collapsing

proc changed(f: FoldMap) =
  f.hiddenDirty = true
  if f.onChanged != nil: f.onChanged()

func collapsedLines*(f: FoldMap): seq[int] = f.collapsed
  ## Header lines of the collapsed regions, ascending.

proc isCollapsed*(f: FoldMap, line: int): bool =
  f.collapsed.binarySearch(line) >= 0

proc collapse*(f: FoldMap, line: int): bool =
  ## Collapses the region headed by `line`; false if there is none.
  if f.regionAt(line) < 0: return false
  if not f.isCollapsed(line):
    f.collapsed.insert(line, f.collapsed.lowerBound(line))
    f.changed()
  true

proc expand*(f: FoldMap, line: int) =
  let k = f.collapsed.binarySearch(line)
  if k >= 0:
    f.collapsed.delete k
    f.changed()

proc toggle*(f: FoldMap, line: int) =
  if f.isCollapsed(line): f.expand(line) else: discard f.collapse(line)

proc collapseAll*(f: FoldMap) =
  f.collapsed.setLen 0
  for r in f.regions: f.collapsed.add r.startLine
  f.changed()

proc expandAll*(f: FoldMap) =
  if f.collapsed.len > 0:
    f.collapsed.setLen 0
    f.changed()

proc hiddenRanges*(f: FoldMap): lent seq[tuple[a, b: int]] =
  ## Sorted, disjoint line ranges hidden by the collapsed headers.
  if f.dirty: f.rebuild()
  if f.hiddenDirty:
    f.hiddenCache.setLen 0
    for s in f.collapsed:
      let e = f.foldEnd(s)
      if e < 0: continue
      let a = s + 1
      if f.hiddenCache.len > 0 and a <= f.hiddenCache[^1].b:
        if e > f.hiddenCache[^1].b: f.hiddenCache[^1].b = e
      else: f.hiddenCache.add (a, e)
    f.hiddenBefore.setLen f.hiddenCache.len
    var sum = 0
    for k, r in f.hiddenCache:
      f.hiddenBefore[k] = sum
      sum += r.b - r.a + 1
    f.hiddenDirty = false
  f.hiddenCache

proc isHidden*(f: FoldMap, line: int): bool =
  let h = f.hiddenRanges
  let k = h.lowerBound(line, proc(r: tuple[a, b: int], v: int): int =
    if r.b < v: -1 else: 0)
  k < h.len and h[k].a <= line

proc expandTo*(f: FoldMap, line: int) =
  ## Expands every collapsed region hiding `line` (e.g. before jumping there).
  var any = false
  var k = 0
  while k < f.collapsed.len:
    let s = f.collapsed[k]
    let e = f.foldEnd(s)
    if s < line and line <= e:
      f.collapsed.delete k
      any = true
    else: inc k
  if any: f.changed()

proc visibleLineCount*(f: FoldMap): int =
  result = f.model.lineCount
  for r in f.hiddenRanges: result -= r.b - r.a + 1

proc hiddenIndex(h: seq[tuple[a, b: int]], line: int): int =
  ## Index of the range containing `line`, or -1.
  let k = h.lowerBound(line, proc(r: tuple[a, b: int], v: int): int =
    if r.b < v: -1 else: 0)
  if k < h.len and h[k].a <= line: k else: -1

proc lineToRow*(f: FoldMap, line: int): int =
  ## Row of `line` in the folded view; a hidden line maps to the row of the
  ## header that hides it.
  let h = f.hiddenRanges
  let k = h.lowerBound(line, proc(r: tuple[a, b: int], v: int): int =
    if r.a <= v: -1 else: 0)           # k = ranges starting at or before `line`
  if k == 0: return line
  result = line - f.hiddenBefore[k - 1] - (min(h[k - 1].b, line) - h[k - 1].a + 1)

proc rowToLine*(f: FoldMap, row: int): int =
  ## First document line shown on `row` of the folded view.
  let h = f.hiddenRanges
  # the first row hidden by range k, a - hiddenBefore, never decreases with k
  var lo = 0
  var hi = h.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if h[mid].a - f.hiddenBefore[mid] <= row: lo = mid + 1 else: hi = mid
  result = row
  if lo > 0: result += f.hiddenBefore[lo - 1] + h[lo - 1].b - h[lo - 1].a + 1
  result = min(result, f.model.lineCount - 1)

proc nextVisibleLine*(f: FoldMap, line: int): int =
  ## The visible line after `line`, or -1 at the end.
  let h = f.hiddenRanges
  var l = line + 1
  var k = h.hiddenIndex(l)
  while k >= 0:                        # adjacent ranges chain
    l = h[k].b + 1
    k = h.hiddenIndex(l)
  if l >= f.model.lineCount: -1 else: l

proc prevVisibleLine*(f: FoldMap, line: int): int =
  let h = f.hiddenRanges
  var l = line - 1
  var k = h.hiddenIndex(l)
  while k >= 0:
    l = h[k].a - 1
    k = h.hiddenIndex(l)
  l

# ----------------------------------------------------------------- set up

proc detach*(f: FoldMap) =
  if f.listenerId != 0: f.model.removeChangeListener(f.listenerId)
  f.listenerId = 0

proc newFoldMap*(m: CodeModel, hl: Highlighter = nil,
                 kinds: set[FoldKind] = {fkIndent}): FoldMap =
  ## `hl` (optional) lets bracket folding skip strings and comments.
  result = FoldMap(model: m, hl: hl, fKinds: kinds,
    markerStarts: @["#region", "//#region", "// region", "# region", "//region"],
    markerEnds: @["#endregion", "//#endregion", "// endregion", "# endregion",
                  "//endregion"])
  result.resetCache()
  let f = result
  result.listenerId = m.addChangeListener(proc(first, oldN, newN: int) =
    f.modelChanged(first, oldN, newN))

func kinds*(f: FoldMap): set[FoldKind] = f.fKinds

proc setKinds*(f: FoldMap, k: set[FoldKind]) =
  f.fKinds = k
  f.resetCache()

proc setHook*(f: FoldMap, h: FoldHook) =
  f.hook = h
  f.dirty = true
  f.structural = true

proc invalidateAll*(f: FoldMap) =
  ## After `tabWidth`, the markers or the language changed.
  f.resetCache()
