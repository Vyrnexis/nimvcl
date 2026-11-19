## `Memo`: a multi-line text editor (VCL TMemo) on top of `ScrollingControl`.
##
## The text model (lines, selection, undo, word logic) lives in
## `memomodel.nim`; this file adds layout, drawing, mouse and keyboard
## handling, scrolling, the caret blink, IME composition and the clipboard.
##
## Text
## ----
## `text` joins the lines with "\n". `lines` is a view onto the lines:
## `memo.lines.add "x"`, `insert`, `delete`, `clear`, `lines[i]`, `lines.count`,
## `for s in memo.lines`. An empty memo has ONE empty line (`lines.count == 1`);
## `lines.add` on a memo that is still pristine (empty text, never edited, no
## line added yet) fills that line instead of adding a second one; after any
## edit or add (also `text = ""`, which makes it pristine again) it appends.
## The line API and `text=` are programmatic: they work when `readOnly` and
## clear the undo history. `selStart`/`selLength` are byte offsets in the
## joined `text`; `caretPos` is `(line, column)` with a BYTE column.
## `maxLength` counts runes of the whole text (a line break is one rune).
##
## Layout
## ------
## Tabs are drawn 4 space-widths wide (a fixed width, not tab stops).
## `wordWrap` wraps lines at the viewport width (after the last space that
## fits, else inside a word) and removes horizontal scrolling; off, long lines
## scroll horizontally. `scrollBars` chooses the axes that may show a bar
## (always automatic: only while the content exceeds the viewport).
##
## Large texts: only the lines in view (plus the caret line) are drawn, and
## per-line widths and wrap breaks are cached and dropped only for the edited
## lines. A Fenwick tree maps lines to visual rows in O(log n) (wrap mode),
## the widest line is tracked with a count of the lines at that width (so
## editing never needs a rescan unless the last widest line got narrower), and
## positions are float64, so a million lines scroll to the exact pixel.
## Up to 500 lines everything is measured at once and the scroll range is
## always exact. A bigger document is measured in the background, a few
## milliseconds at a time (a timer, so typing and scrolling stay responsive):
## the horizontal extent (no wrap) and the row count (`wordWrap`) are exact for
## the lines measured so far and converge to the exact value within a fraction
## of a second (about 1 s per million lines); `extentsExact` tells when the
## sweep is done, `measureAll` finishes it synchronously (tests, or before
## reading `visualRowCount` of a huge text). While wrapping, the view stays
## anchored on the same text when the rows above it are measured.
##
## Keys
## ----
## Arrows, Home/End (line, or visual line when wrapping), Ctrl+Home/End,
## PgUp/PgDn, Ctrl+Left/Right (word); Shift extends. Up/Down keep the pixel
## column. Backspace/Delete (Ctrl = word), Ctrl+A/C/X/V/Z/Y, Ctrl+Shift+Z,
## Ctrl+Insert, Shift+Insert, Shift+Delete. Enter inserts a line break when
## `wantReturns` (default true; the key is then consumed, so it never reaches a
## default button), Tab inserts a TAB when `wantTabs` (default false; else
## focus moves). Mouse: click, drag (auto-scrolls outside), Shift+click, double
## click selects a word, triple click a line.
##
## IME: the composition is drawn inline at the caret and underlined; the commit
## arrives as text input. The clipboard hooks are those of `Edit`
## (`editClipboardGet` / `editClipboardSet`).

import std/[unicode, monotimes, times, strutils]
import ../graphics/context
import ../core/[timer, form]
import ./common, ./scrolling, ./memomodel, ./edit, ./textutil
export memomodel.MemoPos, scrolling

type
  MemoScrollBars* = enum msNone, msHorizontal, msVertical, msBoth

  LineLayout = object
    valid: bool
    wrapW: float32            ## wrap width this layout was made for (0: none)
    width: float32            ## width of the whole line (no wrap)
    breaks: seq[int32]        ## byte start of visual lines 1 ..

  Memo* = ref object of ScrollingControl
    fBorder: BorderStyle
    model: MemoModel
    layouts: seq[LineLayout]
    fRows: seq[int32]         ## visual rows per line (wrap mode)
    fFen: seq[int32]          ## Fenwick tree over fRows
    fTotalRows: int
    fMaxW: float32            ## widest measured line (no wrap)
    fMaxCount: int            ## measured lines whose width equals fMaxW
    fMaxDirty: bool           ## the last widest line changed: fMaxW is only an upper bound
    fSweep: int               ## lines [0, fSweep) are all measured (background sweep)
    sweeper: Timer
    fWrapW: float32
    fWrap, fWantTabs, fWantReturns: bool
    fScrollBars: MemoScrollBars
    fPlaceholder: string
    fEol: bool                ## caret drawn at the end of the previous visual line
    fDesiredX: float32        ## pixel column kept by Up/Down; < 0: none
    fPreparing, fChanged, fLastMeasure: bool
    fPristine: bool           ## empty and untouched: `lines.add` fills line 0
    fLastFont: FontSpec
    fLastRowH: float32
    caretOn: bool
    blink, dragTimer: Timer
    dragging: bool
    dragX, dragY: float32
    composition: string
    compCursor: int
    compLine, compCol: int
    lastDblAt: MonoTime
    lastDblX, lastDblY: float32
    onChange*: NotifyEvent

  MemoLines* = object
    m: Memo

const
  BlinkMs = 530
  DragScrollMs = 45
  PadX = 6'f32
  PadY = 4'f32
  FullMeasureLines = 500
  TabSpaces = 4
  BreakMark = 5'f32           ## width of the selected line break

# ----------------------------------------------------------------- metrics


proc tw(e: Memo, s: string): float32 =
  ## Raw logical width of a tab-free string.
  if s.len == 0: return 0
  if e.canMeasure:
    let ctx = e.renderCtx
    return ctx.measureWidthDevice(s, e.font) / ctx.scale
  float32(runeCount(s)) * e.font.size * 0.55'f32

proc tabW(e: Memo): float32 =
  if e.canMeasure: float32(TabSpaces) * e.tw(" ")
  else: float32(TabSpaces) * e.font.size * 0.55'f32

proc rowH(e: Memo): float32 =
  if e.canMeasure: ceil(e.renderCtx.fontMetrics(e.font).lineHeight)
  else: ceil(e.font.size * 1.25'f32)

proc fitCount(e: Memo, seg: string, w: float32): int =
  ## Bytes of `seg` (no tabs) that fit in `w` logical px.
  if seg.len == 0 or w <= 0: return 0
  if e.canMeasure:
    let ctx = e.renderCtx
    if w * ctx.scale < 1: return 0       # < 1 device px: SDL_ttf would treat it as unlimited
    return snapIndex(seg, ctx.fitPrefix(seg, e.font, w * ctx.scale))
  let per = max(e.font.size * 0.55'f32, 1'f32)
  var n = 0
  var i = 0
  while i < seg.len and float32(n + 1) * per <= w:
    i = nextBoundary(seg, i)
    inc n
  i

proc slotIn(e: Memo, seg: string, x: float32): int =
  ## Nearest caret slot (byte index) of `seg` (no tabs) for `x`.
  if x <= 0 or seg.len == 0: return 0
  if not e.canMeasure:
    let per = max(e.font.size * 0.55'f32, 1'f32)
    var n = 0
    var i = 0
    while i < seg.len and float32(n) + 0.5 < x / per:
      i = nextBoundary(seg, i)
      inc n
    return i
  let ctx = e.renderCtx
  let xd = x * ctx.scale
  let n = snapIndex(seg, ctx.fitPrefix(seg, e.font, xd))
  if n >= seg.len: return seg.len
  let n2 = nextBoundary(seg, n)
  let w1 = ctx.measureWidthDevice(seg[0 ..< n], e.font)
  let w2 = ctx.measureWidthDevice(seg[0 ..< n2], e.font)
  if xd - w1 < w2 - xd: n else: n2

proc widthTabs(e: Memo, s: string, a, b: int): float32 =
  ## Width of `s[a ..< b]`, tabs included.
  if b <= a: return 0
  var i = a
  var tab = -1'f32
  while i < b:
    let t = s.find('\t', i, b - 1)
    let stop = if t < 0: b else: t
    if stop > i: result += e.tw(s[i ..< stop])
    if t < 0: break
    if tab < 0: tab = e.tabW
    result += tab
    i = t + 1

proc slotTabs(e: Memo, s: string, a, b: int, x: float32): int =
  ## Nearest caret slot in `[a, b]` of `s` for `x` measured from `a`.
  var i = a
  var base = 0'f32
  let tab = e.tabW
  while i < b:
    let t = s.find('\t', i, b - 1)
    let stop = if t < 0: b else: t
    if t < 0: return i + e.slotIn(s[i ..< b], x - base)
    if stop > i:
      let seg = s[i ..< stop]
      let w = e.tw(seg)
      if x < base + w: return i + e.slotIn(seg, x - base)
      base += w
    if x < base + tab / 2: return t
    if x < base + tab: return t + 1
    base += tab
    i = t + 1
  b

proc fitEnd(e: Memo, s: string, a: int, w: float32): int =
  ## End of the longest piece starting at `a` that fits `w` (at least one
  ## rune); `s.len` when the rest fits.
  var x = 0'f32
  var i = a
  let tab = e.tabW
  while i < s.len:
    let t = s.find('\t', i)
    let stop = if t < 0: s.len else: t
    if stop > i:
      let seg = s[i ..< stop]
      let n = e.fitCount(seg, w - x)
      if n < seg.len: return max(i + n, nextBoundary(s, a))
      x += e.tw(seg)
    if t < 0: return s.len
    if x + tab > w: return (if t > a: t else: t + 1)
    x += tab
    i = t + 1
  s.len

proc computeBreaks(e: Memo, s: string, w: float32): seq[int32] =
  var start = 0
  while true:
    let en = e.fitEnd(s, start, w)
    if en >= s.len: break
    var b = en
    if s[en] == ' ': b = en + 1
    else:
      var j = en
      while j > start + 1 and s[j - 1] notin {' ', '\t'}: dec j
      if j > start + 1 or (j == start + 1 and s[start] in {' ', '\t'}): b = j
    if b <= start: b = nextBoundary(s, start)
    if b >= s.len: break
    result.add int32(b)
    start = b

# ---------------------------------------------------------- generic helpers

# ------------------------------------------------------------ rows (Fenwick)

proc rebuildFen(e: Memo) =
  let n = e.model.lineCount
  if not e.fWrap:
    e.fTotalRows = n
    return
  e.fRows.setLen n
  e.fFen.setLen n + 1
  e.fTotalRows = 0
  for i in 0 ..< n:
    if e.fRows[i] <= 0: e.fRows[i] = 1
    e.fFen[i + 1] = e.fRows[i]
    e.fTotalRows += int(e.fRows[i])
  e.fFen[0] = 0
  for i in 1 .. n:
    let j = i + (i and -i)
    if j <= n: e.fFen[j] += e.fFen[i]

proc rowStart(e: Memo, line: int): int =
  ## First visual row of `line`.
  if not e.fWrap: return line
  var k = min(line, e.model.lineCount)
  while k > 0:
    result += int(e.fFen[k])
    k -= k and -k

proc lineAtRow(e: Memo, row: int): int =
  let n = e.model.lineCount
  if not e.fWrap: return clamp(row, 0, n - 1)
  var pos = 0
  var rem = max(row, 0)
  var pw = 1
  while pw * 2 <= n: pw *= 2
  while pw > 0:
    if pos + pw <= n and int(e.fFen[pos + pw]) <= rem:
      pos += pw
      rem -= int(e.fFen[pos])
    pw = pw div 2
  min(pos, n - 1)

proc setRows(e: Memo, line, nr: int) =
  let d = nr - int(e.fRows[line])
  if d == 0: return
  e.fRows[line] = int32(nr)
  var k = line + 1
  let n = e.model.lineCount
  while k <= n:
    e.fFen[k] += int32(d)
    k += k and -k
  e.fTotalRows += d

# ------------------------------------------------------------------- text

proc isComposing*(e: Memo): bool = e.composition.len > 0

proc lineText(e: Memo, i: int): string =
  if e.composition.len > 0 and i == e.compLine:
    let l = e.model.line(i)
    let c = min(e.compCol, l.len)
    l[0 ..< c] & e.composition & l[c .. ^1]
  else: e.model.line(i)

proc dropLayout(e: Memo, i: int) =
  ## Line `i` changed: forget its layout (keeps the widest-line bookkeeping and
  ## the background-sweep watermark right).
  if i < 0 or i >= e.layouts.len: return
  if i < e.fSweep: e.fSweep = i
  if e.layouts[i].valid:
    if not e.fWrap and e.layouts[i].width >= e.fMaxW:
      dec e.fMaxCount
      if e.fMaxCount <= 0: e.fMaxDirty = true
    e.layouts[i].valid = false

proc ensureLayout(e: Memo, i: int) =
  if i < 0 or i >= e.layouts.len: return
  if e.layouts[i].valid and e.layouts[i].wrapW == e.fWrapW: return
  let text = e.lineText(i)
  var lay = LineLayout(valid: true, wrapW: e.fWrapW)
  if e.fWrap:
    lay.width = e.widthTabs(text, 0, text.len)
    # a line that fits needs no break search (one measurement instead of many)
    if lay.width > e.fWrapW: lay.breaks = e.computeBreaks(text, e.fWrapW)
    e.setRows(i, lay.breaks.len + 1)
  else:
    lay.width = e.widthTabs(text, 0, text.len)
    if lay.width > e.fMaxW:
      e.fMaxW = lay.width
      e.fMaxCount = 1
      e.fMaxDirty = false          # larger than the old upper bound: exact again
    elif lay.width == e.fMaxW:
      inc e.fMaxCount
      e.fMaxDirty = false
  e.layouts[i] = lay

proc vlineCount(e: Memo, i: int): int =
  e.ensureLayout(i)
  if e.fWrap: e.layouts[i].breaks.len + 1 else: 1

proc vlineBounds(e: Memo, i, k: int, textLen: int): (int, int) =
  let lay = e.layouts[i]
  let a = if k == 0 or not e.fWrap: 0 else: int(lay.breaks[k - 1])
  let b = if e.fWrap and k < lay.breaks.len: int(lay.breaks[k]) else: textLen
  (a, b)

# ---------------------------------------------------------------- geometry

proc wrapWidth(e: Memo): float32 =
  if not e.fWrap: 0'f32 else: max(e.viewport.w - 2 * PadX, 16'f32)

proc invalidateLayouts(e: Memo) =
  for i in 0 ..< e.layouts.len: e.layouts[i].valid = false
  e.fSweep = 0
  e.fMaxW = 0
  e.fMaxCount = 0
  e.fMaxDirty = false

proc rescanMax(e: Memo) =
  ## Exact widest line among the measured lines (O(n), only after the last
  ## widest line became narrower).
  var m = 0'f32
  var c = 0
  for i in 0 ..< e.layouts.len:
    if e.layouts[i].valid:
      let w = e.layouts[i].width
      if w > m:
        m = w
        c = 1
      elif w == m: inc c
  e.fMaxW = m
  e.fMaxCount = c
  e.fMaxDirty = false

proc measureVisible(e: Memo) =
  let n = e.model.lineCount
  if n <= FullMeasureLines:
    for i in 0 ..< n: e.ensureLayout(i)
    if not e.fWrap:
      var w = 0'f32
      for i in 0 ..< n: w = max(w, e.layouts[i].width)
      e.fMaxW = w
      e.fMaxDirty = true            # counts are rebuilt when the text grows past this
    e.fSweep = n
    return
  let rh = e.rowH
  let vp = e.viewport
  let top = e.scrollPosY
  let r0 = max(int(floor((top - PadY) / rh)), 0)
  let r1 = int(ceil((top + float64(vp.h) - PadY) / rh)) + 1
  let l0 = e.lineAtRow(r0)
  let l1 = min(e.lineAtRow(r1), l0 + 300)
  for i in l0 .. l1: e.ensureLayout(i)
  e.ensureLayout(e.model.caret.line)
  if e.fMaxDirty and not e.fWrap: e.rescanMax()

proc kickSweep(e: Memo)

proc prepare(e: Memo) =
  ## Brings caches and the scroll range up to date for the current size,
  ## font, scroll position and text.
  if e.fPreparing: return
  e.fPreparing = true
  defer: e.fPreparing = false
  let meas = e.canMeasure
  let f = e.font
  let rh = e.rowH
  if meas != e.fLastMeasure or f.family != e.fLastFont.family or
     f.size != e.fLastFont.size or f.style != e.fLastFont.style or rh != e.fLastRowH:
    e.fLastMeasure = meas
    e.fLastFont = f
    e.fLastRowH = rh
    e.fMaxW = 0
    e.invalidateLayouts()
  for _ in 0 ..< 3:
    let w = e.wrapWidth
    if w != e.fWrapW:
      e.fWrapW = w
      e.invalidateLayouts()
    let bx = e.scrollPosX
    let by = e.scrollPosY
    e.measureVisible()
    let vp = e.viewport
    let cw = if e.fWrap: 0.0 else: float64(e.fMaxW) + 2 * float64(PadX) + 1
    let ch = float64(e.fTotalRows) * float64(rh) + 2 * float64(PadY)
    e.setContentSize(cw, ch)
    if e.wrapWidth == e.fWrapW and e.scrollPosX == bx and
       e.scrollPosY == by and e.viewport.h == vp.h:
      break
  e.kickSweep()

method scrollLineSize*(e: Memo): SizeF = sizeF(32, max(e.rowH, 1))

# ------------------------------------------------- background measurement

const
  SweepMs = 4                  ## timer interval of the background sweep
  SweepBudgetMs = 5.0          ## work per tick

proc sweepStep(e: Memo, budgetMs: float): bool =
  ## Measures unmeasured lines for about `budgetMs`; true when all are done.
  let n = e.model.lineCount
  if n <= FullMeasureLines:
    e.prepare()
    return true
  e.prepare()                            # current wrap width and viewport
  if e.fSweep >= n: return true
  let t0 = getMonoTime()
  let rh = float64(max(e.rowH, 1))
  # keep the text in view anchored when rows above it change (wrap mode)
  let anchor = e.lineAtRow(max(int(floor((e.scrollPosY - float64(PadY)) / rh)), 0))
  let r0 = e.rowStart(anchor)
  var i = e.fSweep
  var cnt = 0
  while i < n:
    e.ensureLayout(i)
    inc i
    inc cnt
    if (cnt and 31) == 0 and
       float((getMonoTime() - t0).inMicroseconds) > budgetMs * 1000: break
  e.fSweep = i
  if e.fMaxDirty and not e.fWrap: e.rescanMax()
  e.prepare()                            # new content size
  if e.fWrap:
    let dr = e.rowStart(anchor) - r0
    if dr != 0: e.scrollBy(0, float64(dr) * rh)
  i >= n

proc kickSweep(e: Memo) =
  ## Starts the background sweep when a big text has unmeasured lines.
  if e.model.lineCount <= FullMeasureLines or e.fSweep >= e.model.lineCount: return
  if e.sweeper == nil:
    e.sweeper = newTimer(nil, SweepMs)
    e.sweeper.onTimer = proc(t: Timer) =
      if e.sweepStep(SweepBudgetMs): t.enabled = false
  if not e.sweeper.enabled: e.sweeper.enabled = true

proc extentsExact*(e: Memo): bool =
  ## True when every line is measured, so the scroll range (widest line, or
  ## the visual row count with `wordWrap`) is exact. Always true up to 500
  ## lines; bigger texts converge in the background after loading, editing
  ## the first lines or resizing a wrapped memo.
  e.prepare()
  e.model.lineCount <= FullMeasureLines or e.fSweep >= e.model.lineCount

proc measureAll*(e: Memo) =
  ## Finishes the background measurement now (a million lines take about a
  ## second). Afterwards `extentsExact` is true.
  discard e.sweepStep(1e12)

method contentScrolled*(e: Memo) =
  procCall contentScrolled(ScrollingControl(e))
  if not e.fPreparing: e.prepare()

method doResize*(e: Memo) =
  procCall doResize(ScrollingControl(e))
  e.prepare()

proc caretDisplayCol(e: Memo): int =
  let c = e.model.caret
  if e.composition.len > 0 and c.line == e.compLine: e.compCol + e.compCursor
  else: c.col

proc rowAndX(e: Memo, line, col: int, eol: bool): (int, float32) =
  ## Visual row and x (from the text origin) of byte `col` of `line` (displayed text).
  e.ensureLayout(line)
  let text = e.lineText(line)
  var k = 0
  if e.fWrap:
    let br = e.layouts[line].breaks
    while k < br.len and int(br[k]) <= col: inc k
    if eol and k > 0 and int(br[k - 1]) == col: dec k
  let (a, _) = e.vlineBounds(line, k, text.len)
  (e.rowStart(line) + k, e.widthTabs(text, a, min(col, text.len)))

proc posAtRowX(e: Memo, row: int, x: float32): (MemoPos, bool) =
  ## Model position nearest to visual `row` and `x` (from the text origin).
  let r = clamp(row, 0, max(e.fTotalRows - 1, 0))
  let line = e.lineAtRow(r)
  let n = e.vlineCount(line)
  let k = clamp(r - e.rowStart(line), 0, n - 1)
  let text = e.model.line(line)
  let (a, b) = e.vlineBounds(line, k, text.len)
  var col = e.slotTabs(text, a, b, x)
  var eol = false
  if k < n - 1 and col >= b:
    col = b
    eol = true
  ((line, col), eol)

proc textOrigin(e: Memo): PointF =
  ## Origin of the text (row 0, x 0) in client coordinates. Use `rowTop` for
  ## the y of a row of a big text: it subtracts in float64.
  let vp = e.viewport
  pointF(vp.x + PadX - e.scrollPos.x, vp.y + PadY - e.scrollPos.y)

proc rowTop(e: Memo, row: int): float32 =
  ## Client y of visual row `row` (exact for millions of rows).
  e.viewport.y + float32(float64(PadY) + float64(row) * float64(e.rowH) - e.scrollPosY)

proc rowAtY(e: Memo, y: float32): int =
  ## Visual row under client y (float64 arithmetic).
  int(floor((float64(y - e.viewport.y) - float64(PadY) + e.scrollPosY) /
            float64(max(e.rowH, 1))))

proc posAtPoint*(e: Memo, x, y: float32): MemoPos =
  ## Model position a click at client (x, y) would put the caret on.
  e.prepare()
  let o = e.textOrigin
  e.posAtRowX(e.rowAtY(y), x - o.x)[0]

proc caretRect*(e: Memo): RectF =
  ## The caret in client coordinates (1 px wide, one text row tall).
  e.prepare()
  let c = e.model.caret
  let (row, x) = e.rowAndX(c.line, e.caretDisplayCol, e.fEol)
  let o = e.textOrigin
  rectF(o.x + x, e.rowTop(row), 1, e.rowH)

proc scrollCaretIntoView*(e: Memo) =
  ## Scrolls the minimum distance that shows the caret.
  e.prepare()
  let c = e.model.caret
  let (row, x) = e.rowAndX(c.line, e.caretDisplayCol, e.fEol)
  let m = min(24'f32, max(e.viewport.w / 4, 1))
  # the first/last row also reveal the padding above/below the text
  let rh = float64(e.rowH)
  let y0 = if row == 0: 0.0 else: float64(PadY) + float64(row) * rh
  let y1 = float64(PadY) + float64(row + 1) * rh +
           (if row >= e.fTotalRows - 1: float64(PadY) else: 0.0)
  e.scrollIntoView(float64(PadX + x - m), y0, float64(2 * m + 1), y1 - y0)

# ------------------------------------------------------------------ helpers

proc updateIme(e: Memo) =
  if e.focused:
    let h = e.host
    if h of UiRoot: UiRoot(h).updateTextInput()

proc resetBlink(e: Memo) =
  e.caretOn = true
  if e.blink != nil and e.blink.enabled:
    e.blink.enabled = false
    e.blink.enabled = true

proc touched(e: Memo, follow = true) =
  ## Text, selection, composition or size changed.
  e.resetBlink()
  e.prepare()
  if follow: e.scrollCaretIntoView()
  e.updateIme()
  e.invalidate()
  if e.fChanged:
    e.fChanged = false
    if e.onChange != nil: e.onChange(e)

proc stopDrag(e: Memo) =
  e.dragging = false
  if e.dragTimer != nil: e.dragTimer.enabled = false

proc modelChanged(e: Memo, first, oldN, newN: int) =
  e.fChanged = true
  e.fPristine = false
  for i in first ..< min(first + oldN, e.layouts.len): e.dropLayout(i)
  if oldN != newN:
    e.layouts.spliceSeq(first, oldN, newN)
    if e.fWrap:
      e.fRows.spliceSeq(first, oldN, newN)
      for i in first ..< first + newN: e.fRows[i] = 1
  e.fSweep = min(e.fSweep, first)
  for i in first + min(oldN, newN) ..< first + newN:
    e.layouts[i] = LineLayout()
  if oldN != newN: e.rebuildFen()
  if newN <= 16:                  # a small edit: measure it now, extents stay exact
    for i in first ..< min(first + newN, e.layouts.len): e.ensureLayout(i)

# ------------------------------------------------------------ construction

func borderStyle*(x: Memo): BorderStyle = x.fBorder
proc `borderStyle=`*(x: Memo, v: BorderStyle) =
  ## `bsSingle` (default): the usual border and focus ring; `bsNone`: none,
  ## so the control can sit flush in a panel.
  if v == x.fBorder: return
  x.fBorder = v
  x.invalidate()

proc initMemo*(e: Memo, owner: Component = nil) =
  e.initScrollingControl(owner)
  e.fBorder = bsSingle
  e.model = newMemoModel()
  e.layouts = @[LineLayout()]
  e.fFen = @[0'i32, 1]
  e.fRows = @[1'i32]
  e.fTotalRows = 1
  e.fWantReturns = true
  e.fPristine = true
  e.fScrollBars = msBoth
  e.fDesiredX = -1
  e.tabStop = true
  e.cursor = crIBeam
  e.padding = spacing(1)
  e.setBounds(0, 0, 240, 120)
  e.model.onChanged = proc(first, oldN, newN: int) = e.modelChanged(first, oldN, newN)

proc newMemo*(parent: Container = nil, text = "", left = 0'f32, top = 0'f32,
              width = -1'f32, height = -1'f32): Memo {.discardable.} =
  new result
  result.initMemo(parent)
  if text.len > 0: result.model.setText(text)
  placeControl(result, parent, left, top, width, height)

# -------------------------------------------------------------- properties

proc text*(e: Memo): string = e.model.text
proc `text=`*(e: Memo, v: string) =
  ## Replaces the text (caret to the start, undo history cleared, scrolled to
  ## the top). Fires `onChange` when the text differs.
  e.fMaxDirty = true
  let same = not e.model.setText(v)     # compared after sanitising / maxLength
  if same: e.fChanged = false
  e.fPristine = e.model.text.len == 0
  e.touched()

proc lineCount*(e: Memo): int = e.model.lineCount
proc lineAt*(e: Memo, i: int): string = e.model.line(i)

proc wordWrap*(e: Memo): bool = e.fWrap
proc `wordWrap=`*(e: Memo, v: bool) =
  if v == e.fWrap: return
  e.fWrap = v
  e.fEol = false
  e.fMaxW = 0
  e.fWrapW = -1
  e.fRows.setLen 0
  e.fRows.setLen e.model.lineCount
  e.rebuildFen()
  e.invalidateLayouts()
  e.prepare()
  e.touched()

proc readOnly*(e: Memo): bool = e.model.readOnly
proc `readOnly=`*(e: Memo, v: bool) =
  if v == e.model.readOnly: return
  e.model.readOnly = v
  if v: e.composition = ""
  e.updateIme()
  e.invalidate()

proc maxLength*(e: Memo): int = e.model.maxLength
proc `maxLength=`*(e: Memo, v: int) = e.model.maxLength = v

proc wantTabs*(e: Memo): bool = e.fWantTabs
proc `wantTabs=`*(e: Memo, v: bool) = e.fWantTabs = v
proc wantReturns*(e: Memo): bool = e.fWantReturns
proc `wantReturns=`*(e: Memo, v: bool) = e.fWantReturns = v

proc scrollBars*(e: Memo): MemoScrollBars = e.fScrollBars
proc `scrollBars=`*(e: Memo, v: MemoScrollBars) =
  e.fScrollBars = v
  e.hScrollMode = if v in {msHorizontal, msBoth}: sbmAuto else: sbmNever
  e.vScrollMode = if v in {msVertical, msBoth}: sbmAuto else: sbmNever
  e.prepare()

proc placeholder*(e: Memo): string = e.fPlaceholder
proc `placeholder=`*(e: Memo, v: string) =
  if v == e.fPlaceholder: return
  e.fPlaceholder = v
  e.invalidate()
proc textHint*(e: Memo): string = e.fPlaceholder
proc `textHint=`*(e: Memo, v: string) = e.placeholder = v

proc caretPos*(e: Memo): MemoPos = e.model.caret
proc `caretPos=`*(e: Memo, v: MemoPos) =
  e.fEol = false
  e.model.setCaret(v)
  e.touched()
proc caretLine*(e: Memo): int = e.model.caret.line
proc caretCol*(e: Memo): int = e.model.caret.col

proc selStart*(e: Memo): int = e.model.selStart
proc `selStart=`*(e: Memo, v: int) =
  e.fEol = false
  e.model.setCaret(e.model.posAtOffset(v))
  e.touched()
proc selLength*(e: Memo): int = e.model.selLength
proc `selLength=`*(e: Memo, v: int) =
  let a = e.model.selStartPos
  e.model.select(a, e.model.posAtOffset(e.model.offsetOf(a) + max(v, 0)))
  e.touched()
proc selText*(e: Memo): string = e.model.selectedText
proc select*(e: Memo, start, length: int) =
  let a = e.model.posAtOffset(start)
  e.model.select(a, e.model.posAtOffset(start + max(length, 0)))
  e.touched()
proc selectAll*(e: Memo) = e.model.selectAll(); e.touched()
proc clearSelection*(e: Memo) = e.model.setCaret(e.model.caret); e.touched()
proc clear*(e: Memo) = e.text = ""

proc canUndo*(e: Memo): bool = e.model.canUndo
proc canRedo*(e: Memo): bool = e.model.canRedo
proc undo*(e: Memo): bool {.discardable.} =
  result = e.model.undo()
  e.fEol = false
  e.touched()
proc redo*(e: Memo): bool {.discardable.} =
  result = e.model.redo()
  e.fEol = false
  e.touched()

proc copyToClipboard*(e: Memo) =
  if e.model.hasSelection: editClipboardSet(e.model.selectedText)

proc cutToClipboard*(e: Memo) =
  if e.readOnly or not e.model.hasSelection: return
  editClipboardSet(e.model.selectedText)
  discard e.model.deleteSelection()
  e.fEol = false
  e.fDesiredX = -1
  e.touched()

proc flattenBreaks(s: string): string =
  ## wantReturns = false: every line break (typed, IME or pasted) becomes a space.
  s.replace("\r\n", " ").replace('\n', ' ').replace('\r', ' ')

proc pasteFromClipboard*(e: Memo) =
  if e.readOnly: return
  let s = editClipboardGet()
  if s.len > 0:
    var t = s
    if not e.fWantReturns: t = flattenBreaks(t)
    discard e.model.insert(t)
    e.fEol = false
    e.fDesiredX = -1
    e.touched()

proc topLine*(e: Memo): int =
  ## The first (possibly partial) visible line.
  e.prepare()
  e.lineAtRow(max(int(floor((e.scrollPosY - float64(PadY)) / float64(max(e.rowH, 1)))), 0))

proc visualRowCount*(e: Memo): int =
  ## Visual rows of the (measured) text; equals `lineCount` without wrapping.
  e.prepare()
  e.fTotalRows

proc visualRowOfCaret*(e: Memo): int =
  e.prepare()
  let c = e.model.caret
  e.rowAndX(c.line, e.caretDisplayCol, e.fEol)[0]

proc rowHeight*(e: Memo): float32 = e.rowH

proc compositionText*(e: Memo): string = e.composition
proc showsPlaceholder*(e: Memo): bool =
  e.model.lineCount == 1 and e.model.line(0).len == 0 and e.composition.len == 0 and
    e.fPlaceholder.len > 0
proc caretVisible*(e: Memo): bool =
  let h = e.host
  e.caretOn and e.focused and e.isEnabled and
    not (h of UiRoot and UiRoot(h).windowInactive)

# -------------------------------------------------------------- lines view

func lines*(e: Memo): MemoLines = MemoLines(m: e)
proc count*(l: MemoLines): int = l.m.model.lineCount
proc len*(l: MemoLines): int = l.m.model.lineCount
proc `[]`*(l: MemoLines, i: int): string = l.m.model.line(i)
proc programmatic(e: Memo) = e.touched(follow = false)
proc `[]=`*(l: MemoLines, i: int, s: string) =
  l.m.model.setLine(i, s)
  l.m.programmatic()
proc insert*(l: MemoLines, i: int, s: string) =
  l.m.model.insertLine(i, s)
  l.m.programmatic()
proc add*(l: MemoLines, s: string) =
  let m = l.m.model
  if l.m.fPristine and m.lineCount == 1 and m.line(0).len == 0: m.setLine(0, s)
  else: m.insertLine(m.lineCount, s)
  l.m.programmatic()
proc delete*(l: MemoLines, i: int) =
  l.m.model.deleteLineAt(i)
  l.m.programmatic()
proc clear*(l: MemoLines) = l.m.text = ""
proc text*(l: MemoLines): string = l.m.text
proc `text=`*(l: MemoLines, s: string) = l.m.text = s
iterator items*(l: MemoLines): string =
  for i in 0 ..< l.m.model.lineCount: yield l.m.model.line(i)

# ------------------------------------------------------------------ methods

method canFocus*(e: Memo): bool = e.isVisible and e.isEnabled
method wantsTextInput*(e: Memo): bool = not e.model.readOnly
method textInputRect*(e: Memo): RectF = e.caretRect

method preferredSize*(e: Memo): SizeF = sizeF(e.width, e.height)

method doEnter*(e: Memo) =
  procCall doEnter(ScrollingControl(e))
  if e.blink == nil:
    e.blink = newTimer(nil, BlinkMs)
    e.blink.onTimer = proc(t: Timer) =
      let h = e.host
      if not e.focused or (h of UiRoot and UiRoot(h).windowInactive): return
      e.caretOn = not e.caretOn
      e.invalidate(e.caretRect.inflate(1, 1))   # only the caret area
  e.caretOn = true
  e.blink.enabled = true
  e.touched(follow = false)

method doExit*(e: Memo) =
  if e.composition.len > 0:
    e.composition = ""
    e.dropLayout(min(e.compLine, e.layouts.high))
  e.stopDrag()
  if e.blink != nil: e.blink.enabled = false
  e.caretOn = false
  procCall doExit(ScrollingControl(e))
  e.invalidate()

method doMouseDown*(e: Memo, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  procCall doMouseDown(Control(e), button, shift, x, y)
  if button != mbLeft or e.composition.len > 0: return
  let m = e.model
  let now = getMonoTime()
  e.fDesiredX = -1
  e.fEol = false
  if ssDouble in shift:
    m.selectWord(e.posAtPoint(x, y))
    e.lastDblAt = now
    e.lastDblX = x
    e.lastDblY = y
    e.stopDrag()
  elif (now - e.lastDblAt).inMilliseconds < 600 and abs(x - e.lastDblX) <= 4 and
       abs(y - e.lastDblY) <= 4:
    m.selectLine(e.posAtPoint(x, y).line)       # third click of a triple click
    e.lastDblAt = MonoTime()
    e.stopDrag()
  else:
    let p = e.model.snapPos(e.posAtPoint(x, y))
    m.setCaret(p, extend = ssShift in shift)
    # remember the visual-line side of a click at a wrap boundary
    e.prepare()
    let o = e.textOrigin
    e.fEol = e.posAtRowX(e.rowAtY(y), x - o.x)[1]
    e.dragging = true
    e.dragX = x
    e.dragY = y
  e.touched()

proc dragTo(e: Memo) =
  let o = e.textOrigin
  let (p, eol) = e.posAtRowX(e.rowAtY(e.dragY), e.dragX - o.x)
  e.model.setCaret(p, extend = true)
  e.fEol = eol

method doMouseMove*(e: Memo, shift: ShiftState, x, y: float32) =
  procCall doMouseMove(Control(e), shift, x, y)
  if not e.dragging: return
  if ssLeft notin shift:
    e.stopDrag()
    return
  e.dragX = x
  e.dragY = y
  e.prepare()
  e.dragTo()
  let vp = e.viewport
  let outside = y < vp.y or y > vp.bottom or (not e.fWrap and (x < vp.x or x > vp.right))
  if outside:
    if e.dragTimer == nil:
      e.dragTimer = newTimer(nil, DragScrollMs)
      e.dragTimer.onTimer = proc(t: Timer) =
        if not e.dragging: return
        let vp = e.viewport
        let rh = e.rowH
        if e.dragY < vp.y: e.scrollBy(0, -rh)
        elif e.dragY > vp.bottom: e.scrollBy(0, rh)
        if not e.fWrap:
          if e.dragX < vp.x: e.scrollBy(-20, 0)
          elif e.dragX > vp.right: e.scrollBy(20, 0)
        e.prepare()
        e.dragTo()
        e.touched(follow = false)
    e.dragTimer.enabled = true
  elif e.dragTimer != nil:
    e.dragTimer.enabled = false
  e.touched(follow = false)

method doMouseUp*(e: Memo, button: MouseButton, shift: ShiftState, x, y: float32) =
  procCall doMouseUp(Control(e), button, shift, x, y)
  if button == mbLeft: e.stopDrag()

proc moveVisual(e: Memo, delta: int, extend: bool) =
  ## Up/Down/PgUp/PgDn: by visual rows, keeping the pixel column.
  e.prepare()
  let c = e.model.caret
  let (row, x) = e.rowAndX(c.line, c.col, e.fEol)
  let want = if e.fDesiredX >= 0: e.fDesiredX else: x
  let target = row + delta
  if target < 0:
    e.model.setCaret((0, 0), extend)
    e.fEol = false
  elif target >= e.fTotalRows:
    e.model.setCaret(e.model.docEnd, extend)
    e.fEol = false
  else:
    let (p, eol) = e.posAtRowX(target, want)
    e.model.setCaret(p, extend)
    e.fEol = eol
  e.fDesiredX = want

proc visualHomeEnd(e: Memo, home, extend: bool) =
  e.prepare()
  let c = e.model.caret
  let n = e.vlineCount(c.line)
  var k = 0
  if e.fWrap:
    let br = e.layouts[c.line].breaks
    while k < br.len and int(br[k]) <= c.col: inc k
    if e.fEol and k > 0 and int(br[k - 1]) == c.col: dec k
  let (a, b) = e.vlineBounds(c.line, k, e.model.lineLen(c.line))
  if home:
    e.model.setCaret((c.line, a), extend)
    e.fEol = false
  else:
    e.model.setCaret((c.line, b), extend)
    e.fEol = k < n - 1

method doKeyDown*(e: Memo, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(e), key, shift)
  if key == Key(0): return
  let m = e.model
  let ctrl = ssCtrl in shift
  let shf = ssShift in shift
  if ssAlt in shift or ssSuper in shift: return
  let keepX = key in [keyUp, keyDown, keyPageUp, keyPageDown]
  let page = max(int(e.viewport.h / max(e.rowH, 1)) - 1, 1)
  var handled = true
  var follow = true
  if not keepX: e.fDesiredX = -1
  if key == keyLeft:
    e.fEol = false
    if ctrl: m.moveWordLeft(shf) else: m.moveLeft(shf)
  elif key == keyRight:
    e.fEol = false
    if ctrl: m.moveWordRight(shf) else: m.moveRight(shf)
  elif key == keyUp: e.moveVisual(-1, shf)
  elif key == keyDown: e.moveVisual(1, shf)
  elif key == keyPageUp:
    e.scrollBy(0, -float32(page) * e.rowH)
    e.moveVisual(-page, shf)
  elif key == keyPageDown:
    e.scrollBy(0, float32(page) * e.rowH)
    e.moveVisual(page, shf)
  elif key == keyHome:
    e.fEol = false
    if ctrl: m.moveDocStart(shf)
    elif e.fWrap: e.visualHomeEnd(true, shf)
    else: m.moveHome(shf)
  elif key == keyEnd:
    e.fEol = false
    if ctrl: m.moveDocEnd(shf)
    elif e.fWrap: e.visualHomeEnd(false, shf)
    else: m.moveEnd(shf)
  elif key == keyBackspace:
    e.fEol = false
    discard m.deleteBackward(word = ctrl)
  elif key == keyDelete:
    e.fEol = false
    if shf and not ctrl: e.cutToClipboard()
    else: discard m.deleteForward(word = ctrl)
  elif key == keyEnter and e.fWantReturns and not m.readOnly and not ctrl:
    e.fEol = false
    discard m.insert("\n")
  elif key == keyTab and e.fWantTabs and not m.readOnly and not ctrl and not shf:
    e.fEol = false
    discard m.insert("\t")
  elif key == keyInsert:
    if ctrl and not shf: e.copyToClipboard()
    elif shf and not ctrl: e.pasteFromClipboard()
    else: handled = false
  elif ctrl and key == 'a'.key: m.selectAll()
  elif ctrl and key == 'c'.key: e.copyToClipboard()
  elif ctrl and key == 'x'.key: e.cutToClipboard()
  elif ctrl and key == 'v'.key: e.pasteFromClipboard()
  elif ctrl and key == 'z'.key:
    e.fEol = false
    if shf: discard m.redo() else: discard m.undo()
  elif ctrl and key == 'y'.key:
    e.fEol = false
    discard m.redo()
  else: handled = false
  if handled:
    key = Key(0)
    e.touched(follow)

method doKeyPress*(e: Memo, text: var string) =
  procCall doKeyPress(Control(e), text)
  let had = e.composition.len > 0
  if had:
    e.composition = ""
    e.dropLayout(min(e.compLine, e.layouts.high))
  var t = text
  t = t.replace("\t", "")                     # Tab is a key, handled in doKeyDown
  if not e.fWantReturns: t = flattenBreaks(t)
  if t.len > 0 and not e.readOnly:
    e.fEol = false
    e.fDesiredX = -1
    discard e.model.insert(t)
  if had or t.len > 0: e.touched()

method doTextEditing*(e: Memo, text: string, cursor, selLen: int) =
  if e.readOnly: return
  if e.composition.len > 0 or text.len > 0:
    e.dropLayout(min(e.compLine, e.layouts.high))
  e.composition = text
  if text.len > 0:
    if not (e.compLine == e.model.caret.line and e.compCol == e.model.caret.col):
      e.compLine = e.model.caret.line
      e.compCol = e.model.caret.col
    let n = runeCount(text)
    let c = if cursor < 0: n else: min(cursor, n)
    var b = 0
    for _ in 0 ..< c: b = nextBoundary(text, b)
    e.compCursor = b
    e.dropLayout(e.compLine)
  e.touched()

# --------------------------------------------------------------------- paint

proc underline(c: Canvas, x0, x1, baseline: float32, thick: float32, col: Color) =
  let s = c.scale
  let h = max(round(thick * s), 1'f32) / s
  c.fillRect(rectF(x0, baseline, max(x1 - x0, 0), h), col)

proc drawRun(e: Memo, c: Canvas, text: string, a, b: int, x0, y: float32,
             col: Color) =
  ## Draws `text[a ..< b]` with its first byte at x0 (tabs skipped).
  if b <= a: return
  var i = a
  var x = x0
  let tab = e.tabW
  while i < b:
    let t = text.find('\t', i, b - 1)
    let stop = if t < 0: b else: t
    if stop > i:
      let seg = text[i ..< stop]
      c.drawText(seg, e.font, x, y, col)
      x += e.tw(seg)
    if t < 0: break
    x += tab
    i = t + 1

method paint*(e: Memo, c: Canvas) =
  e.prepare()
  let t = e.theme
  let enabled = e.isEnabled
  let foc = e.focused
  let r = e.clientRect
  let bg = e.fieldFill(t, enabled)
  let hot = e.host of UiRoot and UiRoot(e.host).hovered == Control(e)
  let bc =
    if not enabled: t.border
    elif foc: t.accent
    elif hot: t.borderStrong
    else: t.border
  c.fillFrame(r, t, e.fBorder, bg)
  c.strokeFrame(r, t, e.fBorder, bc, t.borderWidth)

  let vp = e.viewport
  let rh = e.rowH
  let font = e.font
  let fm = c.fontMetrics(font)
  let o = e.textOrigin
  let textCol = e.ink(t, bg, enabled)
  let model = e.model
  c.pushClip(vp)

  if e.showsPlaceholder:
    c.drawText(e.fPlaceholder, font, o.x, e.rowTop(0),
               if enabled: legible(t.textMuted, bg) else: t.textDisabled)
  else:
    let n = model.lineCount
    let firstRow = max(int(floor((e.scrollPosY - float64(PadY)) / float64(rh))), 0)
    var line = e.lineAtRow(firstRow)
    var k = firstRow - e.rowStart(line)
    var row = firstRow
    let selA = model.selStartPos
    let selB = model.selEndPos
    let composing = e.composition.len > 0
    let showSel = not composing and selA != selB and enabled
    let selCol = if foc: t.selection else: t.selectionInactive
    let selTxt = if foc: t.selectionText else: textCol
    while line < n and e.rowTop(row) < vp.bottom:
      e.ensureLayout(line)
      let text = e.lineText(line)
      let nv = if e.fWrap: e.layouts[line].breaks.len + 1 else: 1
      if k >= nv: k = nv - 1
      while k < nv and e.rowTop(row) < vp.bottom:
        let (a, b) = e.vlineBounds(line, k, text.len)
        let y = e.rowTop(row)
        if y + rh > vp.y:
          var lo = 0
          var hi = 0
          var brk = false
          if showSel and line >= selA.line and line <= selB.line:
            lo = if line == selA.line: selA.col else: 0
            hi = if line == selB.line: selB.col else: text.len
            lo = max(lo, a)
            hi = min(hi, b)
            brk = line < selB.line and k == nv - 1
          if showSel and (hi > lo or brk):
            let x0 = o.x + (if hi > lo: e.widthTabs(text, a, lo) else: e.widthTabs(text, a, b))
            var wsel = if hi > lo: e.widthTabs(text, lo, hi) else: 0'f32
            if brk: wsel += BreakMark
            c.fillRect(rectF(x0, y, wsel, rh), selCol)
            e.drawRun(c, text, a, lo, o.x, y, textCol)
            if hi > lo:
              e.drawRun(c, text, lo, hi, o.x + e.widthTabs(text, a, lo), y, selTxt)
              e.drawRun(c, text, hi, b, o.x + e.widthTabs(text, a, hi), y, textCol)
          elif b > a:
            e.drawRun(c, text, a, b, o.x, y, textCol)
          if composing and line == e.compLine:
            let ca = max(e.compCol, a)
            let cb = min(e.compCol + e.composition.len, b)
            if cb > ca:
              let base = y + fm.ascent + 1.5'f32
              underline(c, o.x + e.widthTabs(text, a, ca), o.x + e.widthTabs(text, a, cb),
                        base, 1, textCol)
              let sa = max(e.compCol + e.compCursor, a)
              if sa < cb:
                underline(c, o.x + e.widthTabs(text, a, sa), o.x + e.widthTabs(text, a, cb),
                          base, 2, t.accent)
        inc row
        inc k
      inc line
      k = 0

  if e.caretVisible:
    let s = c.scale
    let cr = e.caretRect
    let cw = max(round(s), 1'f32) / s
    c.fillRect(rectF(floor(cr.x * s) / s, cr.y, cw, cr.h), e.ink(t, bg))
  c.popClip()
  if foc and enabled:
    drawFocusRing(c, r, t)
  procCall paint(Control(e), c)
