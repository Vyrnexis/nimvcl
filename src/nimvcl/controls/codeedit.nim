## `CodeEdit`: a source code editor (Delphi's SynEdit) on top of
## `ScrollingControl`.
##
## The buffer is a `CodeModel` (lines, selection, undo, line endings), colours
## come from a `Highlighter`, regions from a `FoldMap`, search from a
## `Searcher`; this file adds the gutter, layout, drawing, mouse and keyboard
## handling, the caret, IME composition, the clipboard and the find bar.
##
## Positions are always `(line, col)`, both ZERO based; `col` is a BYTE index
## in the UTF-8 line. (The status bar of an editor shows `line + 1`.)
##
## Layout
## ------
## The default font is the theme's monospace font (bundled Noto Sans Mono).
## Because every ASCII character has the same advance, x positions are
## computed (`advance * visual column`, tabs jump to the next multiple of
## `tabWidth` cells); only non-ASCII runs are measured. Only the rows in view
## are laid out and painted, so the cost of a paint does not depend on the
## size of the file, and positions are float64, so millions of lines scroll to
## the exact pixel. `wordWrap` is NOT supported yet: long lines scroll
## horizontally.
##
## Gutter
## ------
## From the left: the marker column (shown when `markerColumn` is set or any
## marker exists), line numbers (`showLineNumbers`; the current line is
## emphasised; the width follows the number of lines), and the fold column
## (chevrons; click to fold or unfold). A click on the marker column or on a
## number raises `onGutterClick` and, when not handled, selects the line
## (drag to select several lines).
##
## Markers: `addMarker(line, kind)` puts an icon in the marker column (bookmark,
## breakpoint, error, warning, info, current execution line, four user kinds;
## `markerPainter` draws custom icons). Markers follow their line when lines
## above are inserted or removed.
##
## Highlighting
## ------------
## `highlighter` is the language (`newNimHighlighter()`, or any
## `Highlighter` subclass); `loadFromFile` / `fileName=` pick Nim for `.nim`,
## `.nims` and `.nimble` and plain text otherwise (`autoHighlighter`). Styles
## follow the theme (`syntaxStylesFor`), so switching light and dark repaints
## in the matching palette. The tokens of the lines in view are exact as long
## as the view is within 5000 lines of the exact-lexed frontier; a huge file
## whose view jumps further ahead is painted from an approximate lex of the
## visible lines (started 120 lines above them) until a background pass
## (documents up to 150k lines) reaches the view.
##
## Folding
## -------
## `foldKinds` chooses the sources (indentation, brackets, `#region`
## markers). Hidden lines never hold the caret: navigating into them, a
## search hit or `gotoLine` expands the folds first; folding with the caret
## inside moves it to the header. A collapsed header shows a "..." pill
## (click it to expand). Documents over 500,000 lines get no folding (the
## region scan is a full pass per edit). Ctrl+Shift+[ folds, Ctrl+Shift+]
## unfolds, Ctrl+K Ctrl+0 folds all, Ctrl+K Ctrl+J unfolds all.
##
## Keys
## ----
## Arrows, Ctrl+Left/Right (word), Home (first non-blank, then column 0), End,
## PgUp/PgDn, Ctrl+Home/End, Ctrl+Up/Down (scroll); Shift extends. Ctrl+A,
## Ctrl+Z, Ctrl+Y / Ctrl+Shift+Z, Ctrl+X/C/V (without a selection copy and cut
## the line), Ctrl+Insert, Shift+Insert, Shift+Delete, Ctrl+D (duplicate
## line), Ctrl+Shift+K (delete line), Alt+Up/Down (move lines), Tab and
## Shift+Tab (indent and outdent; spaces by default, `insertSpaces = false`
## for TABs), Backspace in the indentation removes back to the previous tab
## stop, Enter (auto-indent: keeps the indentation, one more level after a
## line ending in `:`, `=` or an open bracket, and a bracket pair is split
## over three lines), Ctrl+/ (toggle line comment), Ctrl+F / Ctrl+H (find /
## replace bar), F3 / Shift+F3, Ctrl+G (go to line, `gotoLineDialog`), Insert
## (overwrite mode with a block caret), Esc (closes the find bar).
##
## Mouse: click, Shift+click, double click (word), triple click (line; both
## extend by words or lines while dragging), drag with auto-scroll, wheel
## (Shift = horizontal). Attach a `PopupMenu` with `attachPopupMenu`; a
## right click first moves the caret unless it lands in the selection.
##
## Events: `onChange` (text), `onCaretMove(line, col)`, `onModifiedChanged`,
## `onOverwriteChange`, `onGutterClick`.
##
## IME: the composition is drawn inline at the caret and underlined; the commit
## arrives as text input. The clipboard hooks are those of `Edit`.

import std/[unicode, monotimes, times, strutils, algorithm, os]
import ../graphics/context
import ../core/[timer, form]
import ./[common, scrolling, edit, codemodel, highlight, nimlexer, folding,
          brackets, search, codecommands, findbar, dialogs]
export scrolling, findbar.FindBar
export codemodel.CodePos, codemodel.Selection, codemodel.LineEnding, codemodel.LoadReport,
       codemodel.CodeModel
export search.SearchOptions, search.Match, search.RegexError
export highlight.Highlighter, highlight.TokenKind, folding.FoldKind

type
  MarkerKind* = enum
    mkBookmark, mkInfo, mkWarning, mkBreakpoint, mkError, mkCurrent,
    mkUser0, mkUser1, mkUser2, mkUser3

  Marker* = object
    line*: int
    kind*: MarkerKind

  MarkerPainter* = proc(c: Canvas, r: RectF, kind: MarkerKind): bool {.closure.}
    ## Draws the icon of `kind` inside `r` (the marker cell of one row) and
    ## returns true, or returns false to get the built-in icon.

  GutterArea* = enum gaMarkers, gaNumbers

  GutterClickEvent* = proc(sender: Control, line: int, area: GutterArea,
                           button: MouseButton, handled: var bool)
  CaretMoveEvent* = proc(sender: Control, line, col: int)

  DragMode = enum dmChar, dmWord, dmLine, dmGutter

  CodeEdit* = ref object of ScrollingControl
    fBorder: BorderStyle
    fModel: CodeModel
    fHl: Highlighter
    fFold: FoldMap
    fFolding: bool
    fFoldKinds: set[FoldKind]
    fFoldKindsSet: bool
    fInsertSpaces, fShowWs, fShowNums, fShowGuides, fHiLine, fHiBrackets: bool
    fOverwrite, fMarkerCol, fAutoHl: bool
    fLineComment, fIndentAfter: string
    fLineCommentSet, fIndentAfterSet: bool
    fFileName: string
    fEnsureNewline: bool
    fMarkers: seq[Marker]
    fMarkerPainter: MarkerPainter
    fAdv, fRowH: float32
    fMetFamily: string
    fMetSize, fMetScale: float32
    fMaxLine, fMaxLen: int
    fMaxStale: bool
    fContentRows: int
    fDesiredV: int
    fChanged: bool
    fLastCaret: CodePos
    fLastModified, fLastOverwrite: bool
    caretOn: bool
    blink, dragTimer, warmTimer: Timer
    dragging: bool
    dragX, dragY: float32
    dragMode: DragMode
    dragA, dragB: CodePos
    composition: string
    compCursor: int
    compLine, compCol: int
    lastDblAt: MonoTime
    lastDblX, lastDblY: float32
    fStyles: SyntaxStyles
    fFonts: array[TokenKind, FontSpec]
    fStylesKey: tuple[theme: Theme, surface, text, muted, danger: Color, size: float32]
    fStylesInit: bool
    fWinLines: seq[int]
    fWinToks: seq[seq[Token]]
    fApprox: bool
    fBrCache: tuple[version: int, pos: CodePos, bm: BracketMatch, valid: bool]
    fBar: FindBar
    fFindText: string
    fFindOpts: SearchOptions
    fSearcher: Searcher
    fSearcherKey: string
    fSearchError: string
    fCountMatches: seq[Match]
    fCountKey: tuple[version: int, key: string]
    fChord: bool
    fGutterHot: bool
    fLineClip: string
    fSelDirty: bool
    onChange*: NotifyEvent
    onModifiedChanged*: NotifyEvent
    onOverwriteChange*: NotifyEvent
    onCaretMove*: CaretMoveEvent
    onGutterClick*: GutterClickEvent
    gotoLineDialog*: proc(e: CodeEdit)
      ## Ctrl+G; the default asks with `inputQuery`. Replace it to use your own UI.

const
  BlinkMs = 530
  DragScrollMs = 45
  PadX = 6'f32
  PadY = 4'f32
  MarkerColW = 18'f32
  FoldColW = 16'f32
  NumPadL = 6'f32
  NumPadR = 8'f32
  ExactAhead = 5000
  ApproxLead = 120
  WarmLimit = 150_000
  WarmStep = 4000
  FoldMaxLines* = 500_000
  MaxVisMatches = 4000
  FindCountCap = 10_000
  ChunkBytes = 256

# ------------------------------------------------------------------ metrics

proc refreshMetrics(e: CodeEdit) =
  let f = e.font
  var sc = 1'f32
  if e.canMeasure: sc = e.renderCtx.scale
  if e.fAdv > 0 and e.fMetFamily == f.family and e.fMetSize == f.size and e.fMetScale == sc:
    return
  e.fMetFamily = f.family
  e.fMetSize = f.size
  e.fMetScale = sc
  if e.canMeasure:
    let ctx = e.renderCtx
    const probe = "MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM"
    e.fAdv = ctx.measureWidthDevice(probe, f) / float32(probe.len) / sc
    e.fRowH = ceil(ctx.fontMetrics(f).lineHeight * sc) / sc
  else:
    e.fAdv = f.size * 0.6'f32
    e.fRowH = ceil(f.size * 1.4'f32)

proc adv(e: CodeEdit): float32 = (e.refreshMetrics(); e.fAdv)
proc rowH(e: CodeEdit): float32 = (e.refreshMetrics(); max(e.fRowH, 1))

proc measureRun(e: CodeEdit, s: string): float32 =
  ## Width of a tab-free run (any characters).
  if s.len == 0: return 0
  if e.canMeasure:
    let ctx = e.renderCtx
    return ctx.measureWidthDevice(s, e.font) / ctx.scale
  float32(runeCount(s)) * e.fAdv

proc tabPx(e: CodeEdit): float32 = e.adv * float32(e.fModel.tabWidth)

type Walk = object
  i: int
  x: float32

proc walkTo(e: CodeEdit, text: string, w: var Walk, col: int) =
  ## Advances `w` (a byte index and the x of it from the text origin) to `col`.
  let stop = min(col, text.len)
  let tabW = e.tabPx
  let a = e.fAdv
  while w.i < stop:
    let ch = text[w.i]
    if ch == '\t':
      w.x = (floor(w.x / tabW + 0.001'f32) + 1) * tabW
      inc w.i
    elif ch < '\x80':
      var j = w.i + 1
      while j < stop and text[j] < '\x80' and text[j] != '\t': inc j
      w.x += a * float32(j - w.i)
      w.i = j
    else:
      var j = w.i + 1
      while j < stop and text[j] >= '\x80': inc j
      w.x += e.measureRun(text[w.i ..< j])
      w.i = j

proc xOfCol(e: CodeEdit, text: string, col: int): float32 =
  var w: Walk
  e.walkTo(text, w, col)
  w.x

proc colAtX(e: CodeEdit, text: string, x: float32): int =
  ## The caret slot (byte index) nearest to `x` from the text origin.
  if x <= 0 or text.len == 0: return 0
  let tabW = e.tabPx
  let a = e.adv
  var i = 0
  var cx = 0'f32
  while i < text.len:
    let ch = text[i]
    var w: float32
    var j: int
    if ch == '\t':
      w = (floor(cx / tabW + 0.001'f32) + 1) * tabW - cx
      j = i + 1
    elif ch < '\x80':
      w = a
      j = i + 1
    else:
      j = nextBoundary(text, i)
      w = e.measureRun(text[i ..< j])
    if x < cx + w:
      return if x - cx < w / 2: i else: j
    cx += w
    i = j
  text.len

# ----------------------------------------------------------- folded rows

proc foldActive(e: CodeEdit): bool = e.fFold != nil

proc rowCount(e: CodeEdit): int =
  if e.fFold == nil: e.fModel.lineCount else: e.fFold.visibleLineCount

proc lineRow(e: CodeEdit, line: int): int =
  if e.fFold == nil: line else: e.fFold.lineToRow(line)

proc rowLine(e: CodeEdit, row: int): int =
  if e.fFold == nil: clamp(row, 0, e.fModel.lineCount - 1)
  else: e.fFold.rowToLine(clamp(row, 0, max(e.fFold.visibleLineCount - 1, 0)))

proc nextVisible(e: CodeEdit, line: int): int =
  if e.fFold == nil: (if line + 1 < e.fModel.lineCount: line + 1 else: -1)
  else: e.fFold.nextVisibleLine(line)

proc isHidden(e: CodeEdit, line: int): bool =
  e.fFold != nil and e.fFold.isHidden(line)

proc isCollapsed(e: CodeEdit, line: int): bool =
  e.fFold != nil and e.fFold.isCollapsed(line) and e.fFold.canFold(line)

proc hiddenRangeOf(e: CodeEdit, line: int): (int, int) =
  if e.fFold != nil:
    for r in e.fFold.hiddenRanges:
      if r.a <= line and line <= r.b: return (r.a, r.b)
  (-1, -1)

proc fixHidden(e: CodeEdit, p: CodePos, forward: bool): CodePos =
  ## `p` itself, or - when it lies in a folded region - the end of the header
  ## (or, moving forward, the start of the line after the region).
  let (a, b) = e.hiddenRangeOf(p.line)
  if a < 0: return p
  if forward and b + 1 < e.fModel.lineCount: (b + 1, 0)
  else: (a - 1, e.fModel.lineLen(a - 1))

# ------------------------------------------------------------------ gutter

proc digitsOf(n: int): int =
  result = 1
  var v = n
  while v >= 10:
    v = v div 10
    inc result

proc markerColShown(e: CodeEdit): bool = e.fMarkerCol or e.fMarkers.len > 0

proc markerW(e: CodeEdit): float32 =
  if e.markerColShown: MarkerColW else: 0'f32
proc numbersW(e: CodeEdit): float32 =
  if not e.fShowNums: 0'f32
  else: float32(max(digitsOf(e.fModel.lineCount), 3)) * e.adv + NumPadL + NumPadR
proc foldW(e: CodeEdit): float32 =
  if e.fFold != nil: FoldColW else: 0'f32

proc gutterW(e: CodeEdit): float32 =
  e.markerW + e.numbersW + e.foldW

proc textX0(e: CodeEdit): float32 =
  ## Client x of column 0 of every line.
  e.viewport.x + e.gutterW + PadX - float32(e.scrollPosX)

proc rowTop(e: CodeEdit, row: int): float32 =
  e.viewport.y + float32(float64(PadY) + float64(row) * float64(e.rowH) - e.scrollPosY)

proc rowAtY(e: CodeEdit, y: float32): int =
  int(floor((float64(y - e.viewport.y) - float64(PadY) + e.scrollPosY) /
            float64(e.rowH)))

# ---------------------------------------------------------------- content

proc rescanMax(e: CodeEdit) =
  e.fMaxLine = 0
  e.fMaxLen = -1
  for i in 0 ..< e.fModel.lineCount:
    let n = e.fModel.lineLen(i)
    if n > e.fMaxLen:
      e.fMaxLen = n
      e.fMaxLine = i
  e.fMaxStale = false

proc syncContent(e: CodeEdit) =
  ## Content size from the rows and the widest line.
  if e.fMaxStale and e.fModel.lineCount <= 200_000: e.rescanMax()
  let m = e.fModel
  var maxCols = 0
  if e.fMaxLen > 0 and e.fMaxLine < m.lineCount:
    maxCols = visualWidth(m.line(e.fMaxLine), m.tabWidth)
  e.fContentRows = e.rowCount
  e.setContentSize(float64(e.gutterW + 2 * PadX) + float64(maxCols + 2) * float64(e.adv),
                   float64(2 * PadY) + float64(e.fContentRows) * float64(e.rowH))

# ----------------------------------------------------------------- styles

proc sameStyle(a, b: TokenStyle): bool =
  a.color == b.color and a.style == b.style

proc refreshStyles(e: CodeEdit) =
  let t = e.theme
  let f = e.font
  let key = (theme: t, surface: t.surface, text: t.text, muted: t.textMuted,
             danger: t.danger, size: f.size)
  if e.fStylesInit and e.fStylesKey == key: return
  e.fStylesKey = key
  e.fStylesInit = true
  e.fStyles = syntaxStylesFor(t)
  for k in TokenKind:
    e.fFonts[k] = f.withStyle(e.fStyles[k].style)

# ------------------------------------------------------------- tokens

let emptyTokens: seq[Token] = @[]

proc winIndex(e: CodeEdit, line: int): int =
  let k = e.fWinLines.lowerBound(line)
  if k < e.fWinLines.len and e.fWinLines[k] == line: k else: -1

proc prepareTokens(e: CodeEdit, lines: openArray[int]) =
  ## Decides between exact and approximate tokens for the visible `lines`.
  e.fApprox = false
  e.fWinLines.setLen 0
  e.fWinToks.setLen 0
  if e.fHl == nil or lines.len == 0: return
  if lines[0] <= e.fHl.cleanCount + ExactAhead: return
  e.fApprox = true
  let m = e.fModel
  var state = LexState(0)
  var scratch: seq[Token]
  for l in max(0, lines[0] - ApproxLead) ..< lines[0]:
    scratch.setLen 0
    state = e.fHl.lexLine(m.line(l), state, scratch)
  for l in lines:
    var toks: seq[Token]
    state = e.fHl.lexLine(m.line(l), state, toks)
    e.fWinLines.add l
    e.fWinToks.add toks

# ----------------------------------------------------------- caret / scroll

proc compActive(e: CodeEdit): bool = e.composition.len > 0

proc caretDisplayCol(e: CodeEdit): int =
  let c = e.fModel.caret
  if e.compActive and c.line == e.compLine: e.compCol + e.compCursor else: c.col

proc displayText(e: CodeEdit, line: int): string =
  ## The line with the IME composition inserted at its caret.
  let t = e.fModel.line(line)
  if e.compActive and line == e.compLine:
    let c = min(e.compCol, t.len)
    t[0 ..< c] & e.composition & t[c .. ^1]
  else: t

proc caretX(e: CodeEdit): float32 =
  ## Client x of the caret.
  let c = e.fModel.caret
  e.textX0 + e.xOfCol(e.displayText(c.line), e.caretDisplayCol)

proc caretRect*(e: CodeEdit): RectF =
  ## The caret in client coordinates (a block `advance` wide when overwriting).
  let c = e.fModel.caret
  let w = if e.fOverwrite: e.adv else: 2'f32
  rectF(e.caretX, e.rowTop(e.lineRow(c.line)), w, e.rowH)

proc scrollCaretIntoView*(e: CodeEdit) =
  ## Scrolls the minimum distance that shows the caret.
  let c = e.fModel.caret
  let row = e.lineRow(c.line)
  let x = e.xOfCol(e.displayText(c.line), e.caretDisplayCol)
  let m = min(24'f32, max(e.viewport.w / 4, 1))
  let rh = float64(e.rowH)
  let y0 = if row == 0: 0.0 else: float64(PadY) + float64(row) * rh
  let y1 = float64(PadY) + float64(row + 1) * rh +
           (if row >= e.fContentRows - 1: float64(PadY) else: 0.0)
  let cx = float64(PadX + x)
  # the gutter covers the left part of the viewport, the text area starts after it
  e.scrollIntoView(cx - float64(m), y0, float64(2 * m + 1 + e.gutterW), y1 - y0)

proc updateIme(e: CodeEdit) =
  if e.focused:
    let h = e.host
    if h of UiRoot: UiRoot(h).updateTextInput()

proc resetBlink(e: CodeEdit) =
  e.caretOn = true
  if e.blink != nil and e.blink.enabled:
    e.blink.enabled = false
    e.blink.enabled = true

# ------------------------------------------------------------- find helpers

proc ensureSearcher(e: CodeEdit): Searcher =
  let key = e.fFindText & "\0" & $e.fFindOpts.ignoreCase & $e.fFindOpts.wholeWord &
            $e.fFindOpts.regex
  if key == e.fSearcherKey and (e.fSearcher != nil or e.fSearchError.len > 0 or
                                e.fFindText.len == 0):
    return e.fSearcher
  e.fSearcherKey = key
  e.fSearcher = nil
  e.fSearchError = ""
  if e.fFindText.len > 0:
    try: e.fSearcher = newSearcher(e.fFindText, e.fFindOpts)
    except RegexError as ex: e.fSearchError = ex.msg
  e.fSearcher

proc findBarVisible*(e: CodeEdit): bool = e.fBar != nil and e.fBar.visible

proc updateFindStatus(e: CodeEdit, force = false) =
  if not e.findBarVisible: return
  let s = e.ensureSearcher()
  if s == nil:
    if e.fSearchError.len > 0: e.fBar.setStatus("Invalid pattern", true)
    else: e.fBar.setStatus("", false)
    return
  let key = (version: e.fModel.version, key: e.fSearcherKey)
  if key != e.fCountKey:
    # a huge document is not rescanned on every keystroke, only on find actions
    if not force and e.fModel.lineCount > 200_000 and e.fCountKey.key == key.key: return
    e.fCountKey = key
    e.fCountMatches.setLen 0
    for mt in s.matches(e.fModel):
      e.fCountMatches.add mt
      if e.fCountMatches.len >= FindCountCap: break
  let count = e.fCountMatches.len
  let sl = e.fModel.selection
  var idx = 0
  for i, mt in e.fCountMatches:
    if mt.a == sl.startPos and mt.b == sl.endPos:
      idx = i + 1
      break
  if count == 0: e.fBar.setStatus("No results", true)
  elif count >= FindCountCap: e.fBar.setStatus($FindCountCap & "+", false)
  elif idx > 0: e.fBar.setStatus($idx & " of " & $count, false)
  else: e.fBar.setStatus($count & " found", false)

# ----------------------------------------------------------------- touched

proc touched*(e: CodeEdit, follow = true) =
  ## Brings the view up to date after `model` was changed directly (text,
  ## selection): resyncs the content, repaints and fires `onChange`,
  ## `onCaretMove` and `onModifiedChanged` as needed. With `follow` the caret
  ## is scrolled into view. The editing methods of `CodeEdit` call it for you.
  e.resetBlink()
  e.syncContent()
  if follow: e.scrollCaretIntoView()
  e.updateIme()
  e.invalidate()
  if e.findBarVisible: e.updateFindStatus()
  if e.fChanged:
    e.fChanged = false
    if e.onChange != nil: e.onChange(e)
  let c = e.fModel.caret
  if c != e.fLastCaret:
    e.fLastCaret = c
    if e.onCaretMove != nil: e.onCaretMove(e, c.line, c.col)
  if e.fModel.modified != e.fLastModified:
    e.fLastModified = e.fModel.modified
    if e.onModifiedChanged != nil: e.onModifiedChanged(e)

proc stopDrag(e: CodeEdit) =
  e.dragging = false
  if e.dragTimer != nil: e.dragTimer.enabled = false

# ------------------------------------------------------------------ markers

func markerLess(a, b: Marker): int =
  if a.line != b.line: cmp(a.line, b.line) else: cmp(ord(a.kind), ord(b.kind))

proc markersChanged(e: CodeEdit, first, oldN, newN: int) =
  ## Markers below the change shift; those on lines that were merged away
  ## move to the last surviving line of the change.
  if e.fMarkers.len == 0: return
  var moved: seq[Marker]
  var changed = false
  for m in e.fMarkers:
    var mk = m
    if m.line >= first + oldN: mk.line = m.line + newN - oldN
    elif m.line >= first + newN: mk.line = first + max(newN, 1) - 1
    if mk.line != m.line: changed = true
    moved.add mk
  if not changed: return
  moved.sort(markerLess)
  e.fMarkers.setLen 0
  for mk in moved:
    if e.fMarkers.len == 0 or markerLess(e.fMarkers[^1], mk) != 0: e.fMarkers.add mk

proc hasMarker*(e: CodeEdit, line: int, kind: MarkerKind): bool =
  for m in e.fMarkers:
    if m.line == line and m.kind == kind: return true
    if m.line > line: break

proc addMarker*(e: CodeEdit, line: int, kind = mkBookmark) =
  ## Puts an icon of `kind` in the marker column of `line` (one per kind and
  ## line).
  if line < 0 or line >= e.fModel.lineCount or e.hasMarker(line, kind): return
  let mk = Marker(line: line, kind: kind)
  let k = e.fMarkers.lowerBound(mk, markerLess)
  e.fMarkers.insert(mk, k)
  e.syncContent()
  e.invalidate()

proc removeMarker*(e: CodeEdit, line: int, kind: MarkerKind) =
  for i in 0 ..< e.fMarkers.len:
    if e.fMarkers[i].line == line and e.fMarkers[i].kind == kind:
      e.fMarkers.delete i
      e.syncContent()
      e.invalidate()
      return

proc toggleMarker*(e: CodeEdit, line: int, kind = mkBookmark): bool {.discardable.} =
  ## Adds the marker or removes it; true when it is there afterwards.
  if e.hasMarker(line, kind):
    e.removeMarker(line, kind)
    false
  else:
    e.addMarker(line, kind)
    true

proc clearMarkers*(e: CodeEdit) =
  e.fMarkers.setLen 0
  e.syncContent()
  e.invalidate()

proc clearMarkers*(e: CodeEdit, kind: MarkerKind) =
  var keep: seq[Marker]
  for m in e.fMarkers:
    if m.kind != kind: keep.add m
  e.fMarkers = keep
  e.syncContent()
  e.invalidate()

proc markerLines*(e: CodeEdit, kind: MarkerKind): seq[int] =
  for m in e.fMarkers:
    if m.kind == kind: result.add m.line

proc markers*(e: CodeEdit): seq[Marker] = e.fMarkers

proc `markerColumn=`*(e: CodeEdit, v: bool) =
  e.fMarkerCol = v
  e.syncContent()
  e.invalidate()
proc markerColumn*(e: CodeEdit): bool = e.fMarkerCol

proc markerPainter*(e: CodeEdit): MarkerPainter = e.fMarkerPainter
proc `markerPainter=`*(e: CodeEdit, p: MarkerPainter) =
  e.fMarkerPainter = p
  e.invalidate()

proc nextMarker*(e: CodeEdit, kind: MarkerKind, fromLine: int, forward = true): int =
  ## The line of the next marker of `kind` after (before) `fromLine`, wrapping
  ## around; -1 when there is none.
  let ls = e.markerLines(kind)
  if ls.len == 0: return -1
  if forward:
    for l in ls:
      if l > fromLine: return l
    ls[0]
  else:
    for i in countdown(ls.high, 0):
      if ls[i] < fromLine: return ls[i]
    ls[^1]

# ---------------------------------------------------------------- fold map

proc rebuildFold(e: CodeEdit) =
  if e.fFold != nil:
    e.fFold.detach()
    e.fFold = nil
  if not e.fFolding or e.fModel.lineCount > FoldMaxLines: return
  var kinds = e.fFoldKinds
  if not e.fFoldKindsSet:
    kinds = if e.fHl != nil and e.fHl.languageName == "nim": {fkIndent, fkMarkers}
            else: {fkBrackets, fkMarkers}
  e.fFold = newFoldMap(e.fModel, e.fHl, kinds)
  e.fFold.onChanged = proc() =
    e.syncContent()
    e.invalidate()

proc ensureWarm(e: CodeEdit) =
  if e.fHl == nil or e.fModel.lineCount > WarmLimit or
     e.fHl.cleanCount >= e.fModel.lineCount:
    if e.warmTimer != nil: e.warmTimer.enabled = false
    return
  if e.warmTimer == nil:
    e.warmTimer = newTimer(nil, 25)
    e.warmTimer.onTimer = proc(t: Timer) =
      if e.fHl == nil or not e.isShowing:
        t.enabled = false
        return
      let n = e.fModel.lineCount
      discard e.fHl.tokens(min(e.fHl.cleanCount + WarmStep, n - 1))
      if e.fHl.cleanCount >= n: t.enabled = false
      if e.fApprox: e.invalidate()
  e.warmTimer.enabled = e.isShowing

# ------------------------------------------------------------- model hooks

proc modelChanged(e: CodeEdit, first, oldN, newN: int) =
  e.fChanged = true
  e.markersChanged(first, oldN, newN)
  # widest line bookkeeping: when the widest line itself changed the figure is
  # only an upper bound until `syncContent` rescans (documents up to 200k lines)
  let m = e.fModel
  if e.fMaxLine >= first + oldN:
    e.fMaxLine += newN - oldN
  elif e.fMaxLine >= first:
    e.fMaxStale = true
  for i in first ..< min(first + newN, m.lineCount):
    if m.lineLen(i) > e.fMaxLen:
      e.fMaxLen = m.lineLen(i)
      e.fMaxLine = i
  e.fBrCache.valid = false

proc selectionChanged(e: CodeEdit) =
  e.fSelDirty = true
  if e.fFold != nil:
    let c = e.fModel.caret
    if e.fFold.isHidden(c.line): e.fFold.expandTo(c.line)

# -------------------------------------------------------------- properties

proc model*(e: CodeEdit): CodeModel = e.fModel
proc highlighter*(e: CodeEdit): Highlighter = e.fHl
proc foldMap*(e: CodeEdit): FoldMap = e.fFold

proc `highlighter=`*(e: CodeEdit, h: Highlighter) =
  ## Sets the language (nil: plain text). The highlighter is attached to the
  ## editor's model; do not share one between editors.
  if h == e.fHl: return
  if e.fHl != nil: e.fHl.detach()
  e.fHl = h
  if h != nil: h.attach(e.fModel)
  e.rebuildFold()
  e.fBrCache.valid = false
  e.ensureWarm()
  e.syncContent()
  e.invalidate()

proc language*(e: CodeEdit): string =
  if e.fHl == nil: "text" else: e.fHl.languageName

proc `language=`*(e: CodeEdit, name: string) =
  ## "nim" selects the Nim highlighter, anything else plain text.
  if name.toLowerAscii == "nim": e.highlighter = newNimHighlighter()
  else: e.highlighter = nil

proc guessHighlighter*(path: string): Highlighter =
  ## The highlighter for a file name: Nim for `.nim`, `.nims`, `.nimble`;
  ## nil (plain text) otherwise.
  case splitFile(path).ext.toLowerAscii
  of ".nim", ".nims", ".nimble": newNimHighlighter()
  else: nil

proc autoHighlighter*(e: CodeEdit): bool = e.fAutoHl
proc `autoHighlighter=`*(e: CodeEdit, v: bool) = e.fAutoHl = v

proc text*(e: CodeEdit): string = e.fModel.text
proc `text=`*(e: CodeEdit, v: string) =
  ## Replaces everything: clears the undo history and the markers and scrolls
  ## to the top. Works when `readOnly`.
  e.stopDrag()
  e.composition = ""
  e.fModel.setText(v)
  e.fMarkers.setLen 0
  e.rebuildFold()
  e.fMaxStale = true
  e.rescanMax()
  e.fDesiredV = -1
  e.fLastCaret = (-1, -1)
  e.scrollTo(0, 0)
  e.ensureWarm()
  e.touched(follow = false)

proc lineCount*(e: CodeEdit): int = e.fModel.lineCount
proc lineAt*(e: CodeEdit, i: int): string = e.fModel.line(i)
proc readOnly*(e: CodeEdit): bool = e.fModel.readOnly
proc `readOnly=`*(e: CodeEdit, v: bool) =
  e.fModel.readOnly = v
  e.updateIme()
  e.invalidate()
proc modified*(e: CodeEdit): bool = e.fModel.modified
proc markSaved*(e: CodeEdit) =
  ## Declares the current text saved (`modified` becomes false).
  e.fModel.markSaved()
  e.touched(follow = false)
proc canUndo*(e: CodeEdit): bool = e.fModel.canUndo
proc canRedo*(e: CodeEdit): bool = e.fModel.canRedo
proc hasSelection*(e: CodeEdit): bool = e.fModel.hasSelection
proc selectedText*(e: CodeEdit): string = e.fModel.selectedText

proc fileName*(e: CodeEdit): string = e.fFileName
proc `fileName=`*(e: CodeEdit, v: string) =
  ## Remembers the name (the editor does not touch the file); with
  ## `autoHighlighter` the language follows the extension.
  e.fFileName = v
  if e.fAutoHl and v.len > 0:
    let h = guessHighlighter(v)
    if (h == nil) != (e.fHl == nil) or (h != nil and h.languageName != e.language):
      e.highlighter = h

proc encoding*(e: CodeEdit): string = "UTF-8"
proc lineEnding*(e: CodeEdit): LineEnding = e.fModel.lineEnding
proc `lineEnding=`*(e: CodeEdit, v: LineEnding) =
  e.fModel.setLineEnding(v)
  e.touched(follow = false)
proc ensureTrailingNewline*(e: CodeEdit): bool = e.fEnsureNewline
proc `ensureTrailingNewline=`*(e: CodeEdit, v: bool) = e.fEnsureNewline = v

proc tabWidth*(e: CodeEdit): int = e.fModel.tabWidth
proc `tabWidth=`*(e: CodeEdit, v: int) =
  e.fModel.tabWidth = v
  if e.fFold != nil: e.fFold.invalidateAll()
  e.syncContent()
  e.invalidate()
proc insertSpaces*(e: CodeEdit): bool = e.fInsertSpaces
proc `insertSpaces=`*(e: CodeEdit, v: bool) = e.fInsertSpaces = v
proc showWhitespace*(e: CodeEdit): bool = e.fShowWs
proc `showWhitespace=`*(e: CodeEdit, v: bool) =
  e.fShowWs = v
  e.invalidate()
proc showLineNumbers*(e: CodeEdit): bool = e.fShowNums
proc `showLineNumbers=`*(e: CodeEdit, v: bool) =
  e.fShowNums = v
  e.syncContent()
  e.invalidate()
proc showIndentGuides*(e: CodeEdit): bool = e.fShowGuides
proc `showIndentGuides=`*(e: CodeEdit, v: bool) =
  e.fShowGuides = v
  e.invalidate()
proc highlightCurrentLine*(e: CodeEdit): bool = e.fHiLine
proc `highlightCurrentLine=`*(e: CodeEdit, v: bool) =
  e.fHiLine = v
  e.invalidate()
proc highlightBrackets*(e: CodeEdit): bool = e.fHiBrackets
proc `highlightBrackets=`*(e: CodeEdit, v: bool) =
  e.fHiBrackets = v
  e.invalidate()
proc folding*(e: CodeEdit): bool = e.fFolding
proc `folding=`*(e: CodeEdit, v: bool) =
  ## Shows the fold column and allows folding (default true).
  e.fFolding = v
  e.rebuildFold()
  e.syncContent()
  e.invalidate()
proc foldKinds*(e: CodeEdit): set[FoldKind] =
  if e.fFold != nil: e.fFold.kinds else: e.fFoldKinds
proc `foldKinds=`*(e: CodeEdit, k: set[FoldKind]) =
  e.fFoldKinds = k
  e.fFoldKindsSet = true
  e.rebuildFold()
  e.syncContent()
  e.invalidate()
proc overwrite*(e: CodeEdit): bool = e.fOverwrite
proc `overwrite=`*(e: CodeEdit, v: bool) =
  if v == e.fOverwrite: return
  e.fOverwrite = v
  e.resetBlink()
  e.invalidate()
  if e.onOverwriteChange != nil: e.onOverwriteChange(e)

proc lineComment*(e: CodeEdit): string =
  ## The prefix of "toggle comment": `lineComment=` if set, else the
  ## highlighter's `commentToken`.
  if e.fLineCommentSet: e.fLineComment
  elif e.fHl != nil: e.fHl.commentToken
  else: ""
proc `lineComment=`*(e: CodeEdit, v: string) =
  e.fLineComment = v
  e.fLineCommentSet = true

proc indentAfter*(e: CodeEdit): string =
  ## Characters that make Enter indent one more level when they end a line.
  if e.fIndentAfterSet: e.fIndentAfter
  elif e.fHl != nil and e.fHl.languageName == "nim": ":=([{"
  else: "([{"
proc `indentAfter=`*(e: CodeEdit, v: string) =
  e.fIndentAfter = v
  e.fIndentAfterSet = true

proc caretPos*(e: CodeEdit): CodePos = e.fModel.caret
proc caretLine*(e: CodeEdit): int = e.fModel.caret.line
proc caretCol*(e: CodeEdit): int = e.fModel.caret.col
proc selection*(e: CodeEdit): Selection = e.fModel.selection

proc topLine*(e: CodeEdit): int =
  ## The first document line in view.
  e.rowLine(max(int(floor((e.scrollPosY - float64(PadY)) / float64(e.rowH))), 0))
proc visibleRowCount*(e: CodeEdit): int =
  ## Rows (folded lines count once) that fit the viewport, rounded up.
  int(ceil(e.viewport.h / e.rowH))
proc rowHeight*(e: CodeEdit): float32 = e.rowH
proc charWidth*(e: CodeEdit): float32 = e.adv
proc gutterWidth*(e: CodeEdit): float32 = e.gutterW
  ## Width of the gutter: `markerWidth + numbersWidth + foldWidth`.
proc markerWidth*(e: CodeEdit): float32 = e.markerW
proc numbersWidth*(e: CodeEdit): float32 = e.numbersW
proc foldWidth*(e: CodeEdit): float32 = e.foldW
proc caretVisible*(e: CodeEdit): bool = e.caretOn and e.focused
proc isComposing*(e: CodeEdit): bool = e.compActive
proc compositionText*(e: CodeEdit): string = e.composition
proc approximateHighlight*(e: CodeEdit): bool = e.fApprox
  ## True when the last paint used the approximate lexer (huge file, far jump).

proc posAtPoint*(e: CodeEdit, x, y: float32): CodePos =
  ## The caret position a click at client (x, y) would give.
  let row = clamp(e.rowAtY(y), 0, max(e.rowCount - 1, 0))
  let line = e.rowLine(row)
  (line, e.colAtX(e.fModel.line(line), x - e.textX0))

proc pointOfPos*(e: CodeEdit, p: CodePos): PointF =
  ## Client coordinates of the top-left of the character at `p` (hidden
  ## lines map to their header's row).
  let pos = e.fModel.snapPos(p)
  pointF(e.textX0 + e.xOfCol(e.fModel.line(pos.line), pos.col),
         e.rowTop(e.lineRow(pos.line)))

# ----------------------------------------------------------------- scrolling

proc ensureVisible*(e: CodeEdit, line: int, col = 0, center = false) =
  ## Expands the folds hiding `line` and scrolls so that (line, col) is in
  ## view (`center` puts its row in the middle of the view when it was not
  ## visible).
  let l = clamp(line, 0, e.fModel.lineCount - 1)
  if e.fFold != nil: e.fFold.expandTo(l)
  e.syncContent()
  let row = e.lineRow(l)
  let rh = float64(e.rowH)
  let top = float64(PadY) + float64(row) * rh
  let vp = e.viewport
  let wasVisible = top >= e.scrollPosY and top + rh <= e.scrollPosY + float64(vp.h)
  if center and not wasVisible:
    e.scrollTo(e.scrollPosX, top + rh / 2 - float64(vp.h) / 2)
  else:
    e.scrollIntoView(0, (if row == 0: 0.0 else: top), 1, rh + (if row == 0: top else: 0.0))
  let x = e.xOfCol(e.fModel.line(l), min(col, e.fModel.lineLen(l)))
  let m = min(24'f32, max(vp.w / 4, 1))
  e.scrollIntoView(float64(PadX + x - m), top, float64(2 * m + 1 + e.gutterW), rh)
  e.invalidate()

proc gotoLine*(e: CodeEdit, line: int, col = 0) =
  ## Puts the caret at (line, col), both zero based and clamped, expanding
  ## folds and scrolling the line into view.
  let l = clamp(line, 0, e.fModel.lineCount - 1)
  if e.fFold != nil: e.fFold.expandTo(l)
  e.fModel.setCaret((l, col))
  e.fDesiredV = -1
  e.ensureVisible(l, col, center = true)     # before `touched`, which would scroll minimally
  e.touched(follow = false)

proc `caretPos=`*(e: CodeEdit, p: CodePos) =
  e.fDesiredV = -1
  if e.fFold != nil: e.fFold.expandTo(clamp(p.line, 0, e.fModel.lineCount - 1))
  e.fModel.setCaret(p)
  e.touched()

proc `selection=`*(e: CodeEdit, s: Selection) =
  e.fDesiredV = -1
  e.fModel.setSelection(s)
  e.touched()

proc select*(e: CodeEdit, a, b: CodePos) =
  ## Selects from `a` (anchor) to `b` (caret).
  e.selection = sel(a, b)

proc replaceRange*(e: CodeEdit, a, b: CodePos, text: string,
                   keepSelection = false): bool {.discardable.} =
  ## Replaces the text from `a` up to `b` (either order; positions are
  ## clamped) with `text`, the way the user's own edit would: one undo step
  ## (inside `beginUndoGroup` it joins the group), the view repaints and
  ## `onChange` fires. By default the caret ends after the inserted text; with
  ## `keepSelection` the selection stays where it was (adjusted to the new
  ## text). False when read-only or when the text does not change.
  e.fDesiredV = -1
  if not keepSelection:
    result = e.fModel.replace(a, b, text)
  else:
    var a = e.fModel.snapPos(a)
    var b = e.fModel.snapPos(b)
    if b < a: swap a, b
    let before = e.fModel.selection
    result = e.fModel.replaceInGroup(a, b, text)
    if result:
      # carry the selection along: positions after the edit shift with it,
      # positions inside the replaced range go to the end of the new text
      let stop = endOfInsert(a, text.replace("\r\n", "\n").replace('\r', '\n'))
      proc carry(p: CodePos): CodePos =
        if p <= a: p
        elif p < b: stop
        elif p.line == b.line: (stop.line, stop.col + p.col - b.col)
        else: (p.line + stop.line - b.line, p.col)
      e.fModel.setSelection(sel(carry(before.anchor), carry(before.caret)))
  e.touched(follow = not keepSelection)

proc insertAt*(e: CodeEdit, p: CodePos, text: string,
               keepSelection = false): bool {.discardable.} =
  ## `replaceRange(p, p, text)`.
  e.replaceRange(p, p, text, keepSelection)

proc beginUndoGroup*(e: CodeEdit) =
  ## Every edit until the matching `endUndoGroup` becomes one undo step
  ## (groups nest).
  e.fModel.beginGroup()

proc endUndoGroup*(e: CodeEdit) =
  e.fModel.endGroup()
  e.touched(follow = false)

proc selectAll*(e: CodeEdit) =
  e.fModel.selectAll()
  e.fDesiredV = -1
  e.touched()

# ------------------------------------------------------------------- commands

proc indentUnit(e: CodeEdit): string = indentUnit(e.fInsertSpaces, e.fModel.tabWidth)

proc undo*(e: CodeEdit): bool {.discardable.} =
  result = e.fModel.undo()
  e.fDesiredV = -1
  e.touched()

proc redo*(e: CodeEdit): bool {.discardable.} =
  result = e.fModel.redo()
  e.fDesiredV = -1
  e.touched()

proc copyToClipboard*(e: CodeEdit) =
  ## Copies the selection, or the whole line when nothing is selected.
  let m = e.fModel
  if m.hasSelection: editClipboardSet(m.selectedText)
  else:
    e.fLineClip = m.line(m.caret.line) & "\n"
    editClipboardSet(e.fLineClip)

proc deleteLine*(e: CodeEdit) =
  ## Deletes the selected lines (the caret line without a selection) and the
  ## markers on them.
  let (f, l) = selectedLines(e.fModel)
  var last = l
  for ln in f .. l:
    if e.isCollapsed(ln): last = max(last, e.fFold.foldEnd(ln))
  var keep: seq[Marker]
  for mk in e.fMarkers:
    if mk.line < f or mk.line > last: keep.add mk
  let before = e.fMarkers
  e.fMarkers = keep
  if not deleteLines(e.fModel, f, last): e.fMarkers = before
  else:
    e.fDesiredV = -1
    e.touched()

proc cutToClipboard*(e: CodeEdit) =
  if e.readOnly: return
  let m = e.fModel
  if m.hasSelection:
    editClipboardSet(m.selectedText)
    discard m.deleteSelection()
    e.fDesiredV = -1
    e.touched()
  else:
    e.copyToClipboard()
    e.deleteLine()

proc pasteFromClipboard*(e: CodeEdit) =
  if e.readOnly: return
  let s = editClipboardGet()
  if s.len == 0: return
  let m = e.fModel
  e.fDesiredV = -1
  if s == e.fLineClip and not m.hasSelection:
    # a line copied without selection pastes as a whole line above the caret
    let c = m.caret
    m.beginGroup()
    discard m.replaceInGroup((c.line, 0), (c.line, 0), s)
    m.setCaret((c.line + 1, c.col))
    m.endGroup()
  else:
    discard m.typeText(s)
  e.touched()

proc indent*(e: CodeEdit) =
  ## Indents the selected lines (the caret line without a selection).
  let (f, l) = selectedLines(e.fModel)
  if indentLines(e.fModel, f, l, e.indentUnit):
    e.touched()

proc outdent*(e: CodeEdit) =
  let (f, l) = selectedLines(e.fModel)
  if outdentLines(e.fModel, f, l, e.fModel.tabWidth):
    e.touched()

proc toggleComment*(e: CodeEdit) =
  ## Comments or uncomments the selected lines with `lineComment`.
  let (f, l) = selectedLines(e.fModel)
  if toggleLineComment(e.fModel, f, l, e.lineComment):
    e.touched()

proc duplicateLine*(e: CodeEdit) =
  let (f, l) = selectedLines(e.fModel)
  var last = l
  for ln in f .. l:
    if e.isCollapsed(ln): last = max(last, e.fFold.foldEnd(ln))
  if duplicateLines(e.fModel, f, last):
    e.fDesiredV = -1
    e.touched()

proc moveLines(e: CodeEdit, up: bool) =
  let m = e.fModel
  var (f, l) = selectedLines(m)
  for ln in f .. l:
    if e.isCollapsed(ln): l = max(l, e.fFold.foldEnd(ln))
  var nf = -1
  var nl = -1
  if up:
    nf = if e.fFold == nil: f - 1 else: e.fFold.prevVisibleLine(f)
    if nf < 0: return
    nl = f - 1
  else:
    nf = l + 1
    if nf >= m.lineCount: return
    nl = if e.isCollapsed(nf): e.fFold.foldEnd(nf) else: nf
  if moveLines(m, f, l, up, nf, nl):
    e.touched()

proc moveLineUp*(e: CodeEdit) = e.moveLines(true)
proc moveLineDown*(e: CodeEdit) = e.moveLines(false)

# ------------------------------------------------------------------ folding

proc foldRegionAround(e: CodeEdit, line: int): int =
  ## Header line of the innermost expanded region containing `line` (or
  ## headed by it); -1 when none.
  if e.fFold == nil: return -1
  result = -1
  for r in e.fFold.regions:
    if r.startLine > line: break
    if r.endLine >= line and not e.fFold.isCollapsed(r.startLine): result = r.startLine

proc fixCaretAfterFold(e: CodeEdit) =
  let m = e.fModel
  let s = m.selection
  let c = e.fixHidden(s.caret, false)
  let a = if e.isHidden(s.anchor.line): e.fixHidden(s.anchor, false) else: s.anchor
  if c != s.caret or a != s.anchor: m.setSelection(sel(a, c))

proc toggleFold*(e: CodeEdit, line: int) =
  ## Folds or unfolds the region headed by `line`.
  if e.fFold == nil or not e.fFold.canFold(line): return
  e.fFold.toggle(line)
  e.fixCaretAfterFold()
  e.touched(follow = false)

proc foldCaret*(e: CodeEdit) =
  ## Folds the innermost region around the caret.
  let h = e.foldRegionAround(e.fModel.caret.line)
  if h >= 0:
    discard e.fFold.collapse(h)
    e.fixCaretAfterFold()
    e.touched()

proc unfoldCaret*(e: CodeEdit) =
  ## Unfolds the region headed by the caret line (or the one hiding it).
  if e.fFold == nil: return
  let l = e.fModel.caret.line
  if e.fFold.isCollapsed(l): e.fFold.expand(l)
  else: e.fFold.expandTo(l)
  e.touched()

proc foldAll*(e: CodeEdit) =
  if e.fFold == nil: return
  e.fFold.collapseAll()
  e.fixCaretAfterFold()
  e.touched()

proc unfoldAll*(e: CodeEdit) =
  if e.fFold == nil: return
  e.fFold.expandAll()
  e.touched(follow = false)

proc isFolded*(e: CodeEdit, line: int): bool = e.isCollapsed(line)
proc canFold*(e: CodeEdit, line: int): bool = e.fFold != nil and e.fFold.canFold(line)
proc isLineVisible*(e: CodeEdit, line: int): bool = not e.isHidden(line)

# --------------------------------------------------------------- find/replace

proc findText*(e: CodeEdit): string = e.fFindText
proc searchOptions*(e: CodeEdit): SearchOptions = e.fFindOpts

proc setSearch*(e: CodeEdit, pattern: string, opts = SearchOptions()) =
  ## Sets what F3 / `findNext` look for (and the find bar's fields).
  e.fFindText = pattern
  e.fFindOpts = opts
  if e.fBar != nil:
    e.fBar.setFindText(pattern)
    e.fBar.setOptions(not opts.ignoreCase, opts.wholeWord, opts.regex)
  e.updateFindStatus(true)
  e.invalidate()

proc selectMatch(e: CodeEdit, mt: Match) =
  if e.fFold != nil: e.fFold.expandTo(mt.a.line)
  e.fModel.setSelection(sel(mt.a, mt.b))
  e.fDesiredV = -1
  e.touched(follow = false)
  e.ensureVisible(mt.b.line, mt.b.col, center = true)

proc findStep*(e: CodeEdit, forward: bool, fromStart = false): bool {.discardable.} =
  ## Selects the next (previous) match of the current search, wrapping around.
  ## `fromStart` searches from the start of the selection (used while typing
  ## a pattern, so the match under the caret stays).
  let s = e.ensureSearcher()
  if s == nil: return false
  let sl = e.fModel.selection
  var found: Match
  var ok: bool
  if forward:
    let from0 = if fromStart: sl.startPos else: sl.endPos
    ok = s.findNext(e.fModel, from0, found)
  else:
    ok = s.findPrev(e.fModel, sl.startPos, found)
  if ok: e.selectMatch(found)
  elif e.findBarVisible: e.updateFindStatus(true)
  ok

proc findNext*(e: CodeEdit): bool {.discardable.} = e.findStep(true)
proc findPrev*(e: CodeEdit): bool {.discardable.} = e.findStep(false)

proc find*(e: CodeEdit, pattern: string, opts = SearchOptions(),
           forward = true): bool {.discardable.} =
  ## Searches from the caret and selects the match; false when there is none
  ## (or the pattern is an invalid regex).
  e.setSearch(pattern, opts)
  e.findStep(forward)

proc replaceCurrent*(e: CodeEdit, replacement: string): bool {.discardable.} =
  ## Replaces the selected match (when the selection is a match of the
  ## current search) and moves on to the next one.
  if e.readOnly: return false
  let s = e.ensureSearcher()
  if s == nil: return false
  let sl = e.fModel.selection
  var mt: Match
  if not sl.isEmpty and s.findNext(e.fModel, sl.startPos, mt, wrap = false) and
     mt.a == sl.startPos and mt.b == sl.endPos:
    result = s.replaceMatch(e.fModel, mt, replacement)
    e.touched()
  e.findStep(true)

proc replaceAll*(e: CodeEdit, pattern, replacement: string,
                 opts = SearchOptions()): int {.discardable.} =
  ## Replaces every match as ONE undo step; returns how many.
  if e.readOnly: return 0
  e.setSearch(pattern, opts)
  let s = e.ensureSearcher()
  if s == nil: return 0
  result = s.replaceAll(e.fModel, replacement)
  e.fDesiredV = -1
  e.touched(follow = false)

proc positionBar(e: CodeEdit) =
  if e.fBar == nil: return
  let vp = e.viewport
  e.fBar.setBounds(vp.right - e.fBar.width + 2, vp.y - 2, e.fBar.width, e.fBar.height)

proc hideFindBar*(e: CodeEdit) =
  ## Closes the find bar and gives the focus back to the text.
  if e.fBar == nil or not e.fBar.visible: return
  e.fBar.visible = false
  e.setFocus()
  e.invalidate()

proc ensureBar(e: CodeEdit) =
  if e.fBar != nil: return
  let bar = newFindBar(e)
  e.fBar = bar
  bar.visible = false
  bar.setOptions(not e.fFindOpts.ignoreCase, e.fFindOpts.wholeWord, e.fFindOpts.regex)
  let ed = e
  bar.onClose = proc(s: Control) = ed.hideFindBar()
  bar.onStep = proc(forward: bool) = ed.findStep(forward)
  bar.onFindChange = proc(s: Control) =
    ed.fFindText = ed.fBar.findText
    discard ed.ensureSearcher()
    ed.findStep(true, fromStart = true)
    ed.updateFindStatus(true)
    ed.invalidate()
  bar.onOptionsChange = proc(s: Control) =
    ed.fFindOpts = SearchOptions(ignoreCase: not ed.fBar.matchCase,
                                 wholeWord: ed.fBar.wholeWord, regex: ed.fBar.useRegex)
    ed.findStep(true, fromStart = true)
    ed.updateFindStatus(true)
    ed.invalidate()
  bar.onReplace = proc(s: Control) = ed.replaceCurrent(ed.fBar.replaceText)
  bar.onReplaceAll = proc(s: Control) =
    let n = ed.replaceAll(ed.fFindText, ed.fBar.replaceText, ed.fFindOpts)
    ed.fBar.setStatus($n & " replaced", false)
  if e.fFindText.len > 0: bar.setFindText(e.fFindText)

proc showFindBar*(e: CodeEdit, replace = false) =
  ## Opens the find bar (with the replace row when `replace`), seeds it with a
  ## single-line selection and focuses the find field.
  e.ensureBar()
  let m = e.fModel
  if m.hasSelection and m.selection.anchor.line == m.selection.caret.line and
     not e.findBarVisible:
    let t = m.selectedText
    if t.len > 0 and t.len < 200:
      e.fFindText = t
      e.fBar.setFindText(t)
  elif m.hasSelection and m.selection.anchor.line == m.selection.caret.line:
    let t = m.selectedText
    if t.len > 0 and t.len < 200 and t != e.fFindText:
      e.fFindText = t
      e.fBar.setFindText(t)
  e.fBar.visible = true
  if replace: e.fBar.replaceMode = true
  e.positionBar()
  e.fBar.bringToFront
  e.updateFindStatus(true)
  e.fBar.findEdit.setFocus()
  e.fBar.findEdit.selectAll()
  e.invalidate()

proc findBar*(e: CodeEdit): FindBar = e.fBar

# ------------------------------------------------------------------- moves

proc moveHoriz(e: CodeEdit, forward, word, extend: bool) =
  let m = e.fModel
  let c = m.caret
  var p: CodePos
  if not extend and not word and m.hasSelection:
    p = if forward: m.selection.endPos else: m.selection.startPos
  else:
    p = if forward: (if word: m.wordRightPos(c) else: m.nextPos(c))
        else: (if word: m.wordLeftPos(c) else: m.prevPos(c))
    p = e.fixHidden(p, forward)
  m.setCaret(p, extend)

proc moveRows(e: CodeEdit, delta: int, extend: bool) =
  let m = e.fModel
  let c = m.caret
  if e.fDesiredV < 0: e.fDesiredV = visualCol(m.line(c.line), c.col, m.tabWidth)
  let row = e.lineRow(c.line)
  let target = row + delta
  if target < 0: m.setCaret((0, 0), extend)
  elif target >= e.rowCount: m.setCaret(m.docEnd, extend)
  else:
    let l = e.rowLine(target)
    m.setCaret((l, colAtVisual(m.line(l), e.fDesiredV, m.tabWidth, true)), extend)

proc pageRows(e: CodeEdit): int = max(int(e.viewport.h / e.rowH) - 1, 1)

# --------------------------------------------------------------- typing

proc insertNewline(e: CodeEdit) =
  let m = e.fModel
  if m.readOnly: return
  let s = m.selection
  let start = s.startPos
  let ni = newlineInsert(m, e.fHl, start, e.indentUnit, e.indentAfter)
  if m.replace(start, s.endPos, ni.text) and ni.text.len != ni.caretOffset:
    m.setCaret((start.line + 1, ni.caretOffset - 1))

proc insertTab(e: CodeEdit, shift: bool) =
  let m = e.fModel
  if m.readOnly: return
  let (f, l) = selectedLines(m)
  if shift:
    discard outdentLines(m, f, l, m.tabWidth)
  elif m.hasSelection and f != l:
    discard indentLines(m, f, l, e.indentUnit)
  elif e.fInsertSpaces:
    let c = m.caret
    let v = visualCol(m.line(c.line), c.col, m.tabWidth)
    discard m.typeText(' '.repeat(m.tabWidth - v mod m.tabWidth))
  else:
    discard m.typeText("\t")

proc backspace(e: CodeEdit, word: bool) =
  let m = e.fModel
  let c = m.caret
  if not word and not m.hasSelection and e.fInsertSpaces and c.col > 0:
    let ln = m.line(c.line)
    var spaces = true
    for i in 0 ..< c.col:
      if ln[i] != ' ':
        spaces = false
        break
    if spaces:
      var n = c.col mod m.tabWidth
      if n == 0: n = m.tabWidth
      n = min(n, c.col)
      discard m.replace((c.line, c.col - n), c, "", ekDelBack)
      return
  discard m.deleteBackward(word)

proc deleteForward(e: CodeEdit, word: bool) =
  let m = e.fModel
  let c = m.caret
  if not m.hasSelection and c.col >= m.lineLen(c.line) and e.isCollapsed(c.line):
    e.fFold.expand(c.line)
  discard m.deleteForward(word)

proc typeChars(e: CodeEdit, t: string) =
  let m = e.fModel
  if e.fOverwrite and not m.hasSelection and t.find({'\n', '\r'}) < 0:
    # every typed character replaces the one after the caret (not at the line end)
    for r in t.runes:
      let c = m.caret
      let s = $r
      if c.col < m.lineLen(c.line):
        discard m.replace(c, (c.line, nextBoundary(m.line(c.line), c.col)), s, ekTyping)
      else:
        discard m.replace(c, c, s, ekTyping)
    return
  discard m.typeText(t)

# ------------------------------------------------------------------- methods

method canFocus*(e: CodeEdit): bool = e.isVisible and e.isEnabled
method wantsTextInput*(e: CodeEdit): bool = not e.fModel.readOnly
method textInputRect*(e: CodeEdit): RectF = e.caretRect
method preferredSize*(e: CodeEdit): SizeF = sizeF(e.width, e.height)

method scrollLineSize*(e: CodeEdit): SizeF = sizeF(e.adv * 4, e.rowH)

method doResize*(e: CodeEdit) =
  procCall doResize(ScrollingControl(e))
  e.positionBar()
  e.syncContent()

method doEnter*(e: CodeEdit) =
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

method doExit*(e: CodeEdit) =
  if e.composition.len > 0: e.composition = ""
  e.stopDrag()
  e.fChord = false
  if e.blink != nil: e.blink.enabled = false
  e.caretOn = false
  procCall doExit(ScrollingControl(e))
  e.invalidate()

proc gutterAreaAt(e: CodeEdit, x: float32): int =
  ## 0 marker column, 1 numbers, 2 fold column, -1 text.
  let rel = x - e.viewport.x
  if rel >= e.gutterW: return -1
  if rel < e.markerW: 0
  elif rel < e.markerW + e.numbersW: 1
  else: 2

proc pillRect(e: CodeEdit, line: int): RectF =
  let y = e.rowTop(e.lineRow(line))
  let x = e.textX0 + e.xOfCol(e.fModel.line(line), e.fModel.lineLen(line)) + e.adv * 0.8'f32
  rectF(x, y + 3, e.adv * 3.2'f32, e.rowH - 6)

proc selectLineRange(e: CodeEdit, a, b: int, extend: bool) =
  ## Selects whole lines a ..< b+1 (anchor at the start of `a`).
  let m = e.fModel
  let lo = min(a, b)
  let hi = max(a, b)
  let endPos: CodePos = if hi + 1 < m.lineCount: (hi + 1, 0) else: (hi, m.lineLen(hi))
  if extend and m.hasSelection:
    let s = m.selection
    if hi >= s.anchor.line: m.setSelection(sel(s.anchor, endPos))
    else: m.setSelection(sel(s.anchor, (lo, 0)))
  else:
    m.setSelection(sel((lo, 0), endPos))

proc setDragRange(e: CodeEdit, p: CodePos, mode: DragMode) =
  let m = e.fModel
  case mode
  of dmWord:
    let (a, b) = wordRangeIn(m.line(p.line), p.col)
    e.dragA = (p.line, a)
    e.dragB = (p.line, b)
  of dmLine:
    e.dragA = (p.line, 0)
    e.dragB = if p.line + 1 < m.lineCount: (p.line + 1, 0) else: (p.line, m.lineLen(p.line))
  else:
    e.dragA = p
    e.dragB = p
  e.dragMode = mode

method doMouseDown*(e: CodeEdit, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  procCall doMouseDown(Control(e), button, shift, x, y)
  if e.composition.len > 0: return
  if button == mbMiddle: return
  let m = e.fModel
  e.fDesiredV = -1
  let p = e.posAtPoint(x, y)
  if button == mbRight:
    let s = m.selection
    if s.isEmpty or p < s.startPos or s.endPos < p:
      m.setCaret(p)
      e.touched()
    return
  if button != mbLeft: return
  let area = e.gutterAreaAt(x)
  if area >= 0:
    let row = e.rowAtY(y)
    if row < 0 or row >= e.rowCount: return
    let line = e.rowLine(row)
    if area == 2:
      if e.fFold != nil and e.fFold.canFold(line): e.toggleFold(line)
      return
    var handled = false
    if e.onGutterClick != nil:
      e.onGutterClick(e, line, if area == 0: gaMarkers else: gaNumbers, button, handled)
    if handled: return
    e.selectLineRange(line, line, ssShift in shift)
    e.dragMode = dmGutter
    e.dragA = (line, 0)
    e.dragging = true
    e.dragX = x
    e.dragY = y
    e.touched()
    return
  # a click on the "..." pill of a folded header expands it
  let line = p.line
  if e.isCollapsed(line) and pillRect(e, line).contains(pointF(x, y)):
    e.fFold.expand(line)
    e.touched(follow = false)
    return
  let now = getMonoTime()
  if ssDouble in shift:
    e.setDragRange(p, dmWord)
    m.setSelection(sel(e.dragA, e.dragB))
    e.lastDblAt = now
    e.lastDblX = x
    e.lastDblY = y
    e.dragging = true
    e.dragX = x
    e.dragY = y
  elif (now - e.lastDblAt).inMilliseconds < 600 and abs(x - e.lastDblX) <= 4 and
       abs(y - e.lastDblY) <= 4:
    e.setDragRange(p, dmLine)
    m.setSelection(sel(e.dragA, e.dragB))
    e.lastDblAt = MonoTime()
    e.dragging = true
    e.dragX = x
    e.dragY = y
  else:
    m.setCaret(p, extend = ssShift in shift)
    e.dragMode = dmChar
    e.dragging = true
    e.dragX = x
    e.dragY = y
  e.touched()

proc dragTo(e: CodeEdit) =
  let m = e.fModel
  let p = e.posAtPoint(e.dragX, e.dragY)
  case e.dragMode
  of dmChar: m.setCaret(p, extend = true)
  of dmGutter:
    let row = clamp(e.rowAtY(e.dragY), 0, max(e.rowCount - 1, 0))
    let line = e.rowLine(row)
    let lo = min(line, e.dragA.line)
    let hi = max(line, e.dragA.line)
    let endPos: CodePos = if hi + 1 < m.lineCount: (hi + 1, 0) else: (hi, m.lineLen(hi))
    if line >= e.dragA.line: m.setSelection(sel((lo, 0), endPos))
    else: m.setSelection(sel(endPos, (lo, 0)))
  of dmWord, dmLine:
    var a, b: CodePos
    if e.dragMode == dmWord:
      let (wa, wb) = wordRangeIn(m.line(p.line), p.col)
      a = (p.line, wa)
      b = (p.line, wb)
    else:
      a = (p.line, 0)
      b = if p.line + 1 < m.lineCount: (p.line + 1, 0) else: (p.line, m.lineLen(p.line))
    if p < e.dragA: m.setSelection(sel(e.dragB, a))
    else: m.setSelection(sel(e.dragA, b))

method doMouseMove*(e: CodeEdit, shift: ShiftState, x, y: float32) =
  procCall doMouseMove(Control(e), shift, x, y)
  let want = if e.gutterAreaAt(x) >= 0: crArrow else: crIBeam
  if e.cursor != want: e.cursor = want
  let hot = e.gutterAreaAt(x) >= 0
  if hot != e.fGutterHot:
    e.fGutterHot = hot
    e.invalidate(rectF(e.viewport.x, e.viewport.y, e.gutterW, e.viewport.h))
  if not e.dragging: return
  if ssLeft notin shift:
    e.stopDrag()
    return
  e.dragX = x
  e.dragY = y
  e.dragTo()
  let vp = e.viewport
  let outside = y < vp.y or y > vp.bottom or x < vp.x + e.gutterW or x > vp.right
  if outside:
    if e.dragTimer == nil:
      e.dragTimer = newTimer(nil, DragScrollMs)
      e.dragTimer.onTimer = proc(t: Timer) =
        if not e.dragging: return
        let vp = e.viewport
        let rh = e.rowH
        if e.dragY < vp.y: e.scrollBy(0, -rh)
        elif e.dragY > vp.bottom: e.scrollBy(0, rh)
        if e.dragX < vp.x + e.gutterW: e.scrollBy(-20, 0)
        elif e.dragX > vp.right: e.scrollBy(20, 0)
        e.dragTo()
        e.touched(follow = false)
    e.dragTimer.enabled = true
  elif e.dragTimer != nil:
    e.dragTimer.enabled = false
  e.touched(follow = false)

method doMouseLeave*(e: CodeEdit) =
  procCall doMouseLeave(ScrollingControl(e))
  if e.fGutterHot:
    e.fGutterHot = false
    e.invalidate(rectF(e.viewport.x, e.viewport.y, e.gutterW, e.viewport.h))

method doMouseUp*(e: CodeEdit, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  procCall doMouseUp(Control(e), button, shift, x, y)
  if button == mbLeft: e.stopDrag()

proc chordKey(e: CodeEdit, key: var Key, shift: ShiftState): bool =
  ## The key after Ctrl+K. Returns true when it was part of a chord.
  if key in [keyLCtrl, keyRCtrl, keyLShift, keyRShift, keyLAlt, keyRAlt]: return true
  e.fChord = false
  if ssCtrl notin shift: return false
  if key == '0'.key: e.foldAll()
  elif key == 'j'.key: e.unfoldAll()
  elif key == 'c'.key:
    let tok = e.lineComment
    let (f, l) = selectedLines(e.fModel)
    var all = true
    for i in f .. l:
      let ln = e.fModel.line(i)
      if firstNonBlank(ln) < ln.len and not ln.continuesWith(tok, firstNonBlank(ln)): all = false
    if not all or tok.len == 0: e.toggleComment()
  elif key == 'u'.key:
    let tok = e.lineComment
    let (f, l) = selectedLines(e.fModel)
    var all = true
    for i in f .. l:
      let ln = e.fModel.line(i)
      if firstNonBlank(ln) < ln.len and not ln.continuesWith(tok, firstNonBlank(ln)): all = false
    if all and tok.len > 0: e.toggleComment()
  else: return false
  key = Key(0)
  true

method doKeyDown*(e: CodeEdit, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(e), key, shift)
  if key == Key(0): return
  if ssSuper in shift: return
  let m = e.fModel
  let ctrl = ssCtrl in shift
  let shf = ssShift in shift
  let alt = ssAlt in shift
  if e.fChord:
    if e.chordKey(key, shift):
      if key == Key(0) or key in [keyLCtrl, keyRCtrl, keyLShift, keyRShift]:
        key = Key(0)
        return
  if alt:
    if ctrl: return
    if key == keyUp: e.moveLineUp()
    elif key == keyDown: e.moveLineDown()
    else: return
    key = Key(0)
    return
  let keepV = key in [keyUp, keyDown, keyPageUp, keyPageDown]
  var handled = true
  var follow = true
  var touchedAlready = false
  if not keepV: e.fDesiredV = -1
  if key == keyLeft: e.moveHoriz(false, ctrl, shf)
  elif key == keyRight: e.moveHoriz(true, ctrl, shf)
  elif key == keyUp and ctrl and not shf:
    e.scrollBy(0, -float64(e.rowH))
    follow = false
  elif key == keyDown and ctrl and not shf:
    e.scrollBy(0, float64(e.rowH))
    follow = false
  elif key == keyUp: e.moveRows(-1, shf)
  elif key == keyDown: e.moveRows(1, shf)
  elif key == keyPageUp:
    e.scrollBy(0, -float64(e.pageRows) * float64(e.rowH))
    e.moveRows(-e.pageRows, shf)
  elif key == keyPageDown:
    e.scrollBy(0, float64(e.pageRows) * float64(e.rowH))
    e.moveRows(e.pageRows, shf)
  elif key == keyHome:
    if ctrl: m.setCaret((0, 0), shf)
    else:
      let c = m.caret
      m.setCaret((c.line, smartHomeCol(m.line(c.line), c.col)), shf)
  elif key == keyEnd:
    if ctrl: m.setCaret(m.docEnd, shf)
    else: m.setCaret((m.caret.line, m.lineLen(m.caret.line)), shf)
  elif key == keyBackspace and not shf: e.backspace(ctrl)
  elif key == keyBackspace and shf and not ctrl: e.backspace(false)
  elif key == keyDelete:
    if shf and not ctrl: e.cutToClipboard(); touchedAlready = true
    else: e.deleteForward(ctrl)
  elif key == keyEnter and not m.readOnly and not (ctrl and shf):
    if ctrl: # Ctrl+Enter: a new line below, whatever the caret column
      m.setCaret((m.caret.line, m.lineLen(m.caret.line)))
    e.insertNewline()
  elif key == keyTab and not ctrl:
    if m.readOnly: handled = false
    else: e.insertTab(shf)
  elif key == keyInsert:
    if ctrl and not shf: e.copyToClipboard()
    elif shf and not ctrl: e.pasteFromClipboard(); touchedAlready = true
    elif not ctrl and not shf: e.overwrite = not e.fOverwrite
    else: handled = false
  elif key == keyEscape:
    if e.findBarVisible: e.hideFindBar()
    else: handled = false
  elif key == keyF3 and not ctrl and not alt:
    e.findStep(not shf)
    touchedAlready = true
  elif ctrl and shf and (key == '['.key or key == '{'.key): e.foldCaret(); touchedAlready = true
  elif ctrl and shf and (key == ']'.key or key == '}'.key): e.unfoldCaret(); touchedAlready = true
  elif ctrl and shf and key == 'k'.key: e.deleteLine(); touchedAlready = true
  elif ctrl and not shf and key == 'k'.key: e.fChord = true
  elif ctrl and key == 'a'.key: m.selectAll()
  elif ctrl and key == 'c'.key: e.copyToClipboard(); touchedAlready = true
  elif ctrl and key == 'x'.key: e.cutToClipboard(); touchedAlready = true
  elif ctrl and key == 'v'.key: e.pasteFromClipboard(); touchedAlready = true
  elif ctrl and key == 'z'.key:
    if shf: discard m.redo() else: discard m.undo()
  elif ctrl and key == 'y'.key: discard m.redo()
  elif ctrl and key == 'd'.key: e.duplicateLine(); touchedAlready = true
  elif ctrl and (key == '/'.key or key == '?'.key): e.toggleComment(); touchedAlready = true
  elif ctrl and key == 'f'.key: e.showFindBar(false); touchedAlready = true
  elif ctrl and key == 'h'.key: e.showFindBar(true); touchedAlready = true
  elif ctrl and key == 'g'.key:
    touchedAlready = true
    if e.gotoLineDialog != nil: e.gotoLineDialog(e)
  else: handled = false
  if handled:
    key = Key(0)
    if not touchedAlready: e.touched(follow)

method doKeyPress*(e: CodeEdit, text: var string) =
  procCall doKeyPress(Control(e), text)
  let had = e.composition.len > 0
  if had: e.composition = ""
  var t = text
  t = t.replace("\t", "")                     # Tab is a key, handled in doKeyDown
  if t.len > 0 and not e.readOnly:
    e.fDesiredV = -1
    e.typeChars(t)
  if had or t.len > 0: e.touched()

method doTextEditing*(e: CodeEdit, text: string, cursor, selLen: int) =
  if e.readOnly: return
  e.composition = text
  if text.len > 0:
    e.compLine = e.fModel.caret.line
    e.compCol = e.fModel.caret.col
    let n = runeCount(text)
    let c = if cursor < 0: n else: min(cursor, n)
    var b = 0
    for _ in 0 ..< c: b = nextBoundary(text, b)
    e.compCursor = b
  e.touched()

# --------------------------------------------------------------------- paint

proc drawMarkerIcon(e: CodeEdit, c: Canvas, r: RectF, kind: MarkerKind) =
  if e.fMarkerPainter != nil and e.fMarkerPainter(c, r, kind): return
  let t = e.theme
  let s = min(r.w, r.h) - 6
  let cx = r.x + r.w / 2
  let cy = r.y + r.h / 2
  let box = rectF(cx - s / 2, cy - s / 2, s, s)
  case kind
  of mkBookmark:
    let x0 = cx - s * 0.32
    let x1 = cx + s * 0.32
    let y0 = cy - s * 0.5
    let y1 = cy + s * 0.5
    c.fillPolygon([pointF(x0, y0), pointF(x1, y0), pointF(x1, y1), pointF(cx, y1 - s * 0.28),
                   pointF(x0, y1)], t.accent)
  of mkBreakpoint:
    c.fillEllipse(box, hex"#e5484d")
  of mkError:
    c.fillEllipse(box, t.danger)
    c.line(cx - s * 0.2, cy - s * 0.2, cx + s * 0.2, cy + s * 0.2, clWhite, 1.4)
    c.line(cx - s * 0.2, cy + s * 0.2, cx + s * 0.2, cy - s * 0.2, clWhite, 1.4)
  of mkWarning:
    c.fillPolygon([pointF(cx, cy - s * 0.55), pointF(cx + s * 0.6, cy + s * 0.45),
                   pointF(cx - s * 0.6, cy + s * 0.45)], hex"#f59e0b")
  of mkInfo:
    c.fillEllipse(box, hex"#3b82f6")
    c.line(cx, cy - s * 0.05, cx, cy + s * 0.25, clWhite, 1.4)
    c.fillRect(rectF(cx - 0.7, cy - s * 0.27, 1.4, 1.4), clWhite)
  of mkCurrent:
    c.fillPolygon([pointF(cx - s * 0.5, cy - s * 0.28), pointF(cx + s * 0.05, cy - s * 0.28),
                   pointF(cx + s * 0.05, cy - s * 0.5), pointF(cx + s * 0.55, cy),
                   pointF(cx + s * 0.05, cy + s * 0.5), pointF(cx + s * 0.05, cy + s * 0.28),
                   pointF(cx - s * 0.5, cy + s * 0.28)], hex"#eab308")
  of mkUser0: c.fillRoundRect(box.inflate(-1), 2, hex"#a855f7")
  of mkUser1: c.fillRoundRect(box.inflate(-1), 2, hex"#14b8a6")
  of mkUser2: c.fillRoundRect(box.inflate(-1), 2, hex"#f97316")
  of mkUser3: c.fillRoundRect(box.inflate(-1), 2, hex"#64748b")

proc drawChevron(c: Canvas, r: RectF, open: bool, col: Color) =
  let cx = r.x + r.w / 2
  let cy = r.y + r.h / 2
  if open:
    c.line(cx - 3.5, cy - 1.5, cx, cy + 2, col, 1.4)
    c.line(cx, cy + 2, cx + 3.5, cy - 1.5, col, 1.4)
  else:
    c.line(cx - 1.5, cy - 3.5, cx + 2, cy, col, 1.4)
    c.line(cx + 2, cy, cx - 1.5, cy + 3.5, col, 1.4)

proc underline(c: Canvas, x0, x1, baseline: float32, thick: float32, col: Color) =
  let s = c.scale
  let h = max(round(thick * s), 1'f32) / s
  c.fillRect(rectF(x0, baseline, max(x1 - x0, 0), h), col)

func charStrings(): array[128, string] =
  for i in 0 .. 127: result[i] = $char(i)
let singleChars = charStrings()

proc drawPiece(e: CodeEdit, c: Canvas, text: string, a, b: int, x0, y: float32,
               font: FontSpec, col: Color, left, right: float32, ws: bool): float32 =
  ## Draws the tab-free `text[a ..< b]` with its first byte at x0 and returns
  ## its width. Only chunks inside [left, right] are drawn; blank pieces are
  ## drawn as nothing (or as dots with `ws`).
  var i = a
  var x = x0
  let adv = e.fAdv
  while i < b:
    var j = min(i + ChunkBytes, b)
    while j < b and (text[j].uint8 and 0xC0) == 0x80: inc j     # keep codepoints whole
    var w: float32
    var ascii = true
    for k in i ..< j:
      if text[k] >= '\x80':
        ascii = false
        break
    if ascii: w = adv * float32(j - i)
    else: w = e.measureRun(text[i ..< j])
    if x + w >= left and x <= right:
      var blank = true
      for k in i ..< j:
        if text[k] != ' ':
          blank = false
          break
      if blank: discard
      elif ascii and fsBold in font.style:
        # synthetic bold widens every glyph: keep each one on its cell
        for k in i ..< j:
          if text[k] != ' ':
            c.drawText(singleChars[ord(text[k])], font, x + adv * float32(k - i), y, col)
      else: c.drawText(text[i ..< j], font, x, y, col)
    x += w
    i = j
  discard ws
  x - x0

proc matchingBracket(e: CodeEdit): BracketMatch =
  let m = e.fModel
  let cv = (version: m.version, pos: m.caret)
  if e.fBrCache.valid and e.fBrCache.version == cv.version and e.fBrCache.pos == cv.pos:
    return e.fBrCache.bm
  var hl = e.fHl
  if hl != nil and m.caret.line > hl.cleanCount + ExactAhead: hl = nil
  result = findMatchingBracket(m, hl, m.caret, maxLines = if hl == nil: 2000 else: 20000)
  e.fBrCache = (version: cv.version, pos: cv.pos, bm: result, valid: true)

proc visibleMatches(e: CodeEdit, first, last: int): seq[Match] =
  if not e.findBarVisible: return
  let s = e.ensureSearcher()
  if s == nil: return
  let m = e.fModel
  for mt in s.matches(m, (first, 0), (last, m.lineLen(last))):
    result.add mt
    if result.len >= MaxVisMatches: break

proc drawTokens(e: CodeEdit, c: Canvas, text: string, toks: openArray[Token],
                x0, ty: float32, enabled: bool, textArea: RectF) =
  ## Draws one row from its tokens: neighbours of the same style are merged
  ## and drawn piece by piece (split at tabs).
  let t = e.theme
  let bg = e.fieldFill(t, enabled)
  var w: Walk
  var i = 0
  while i < toks.len:
    var j = i + 1
    let st = e.fStyles[toks[i].kind]
    while j < toks.len and sameStyle(e.fStyles[toks[j].kind], st): inc j
    let a = toks[i].start
    let b = toks[j - 1].stop
    let font = e.fFonts[toks[i].kind]
    i = j
    e.walkTo(text, w, a)
    var p = a
    while p < b:
      var q = text.find('\t', p, b - 1)
      if q < 0: q = b
      if q > p:
        let pw = e.drawPiece(c, text, p, q, x0 + w.x, ty, font,
                             if not enabled: t.textDisabled
                             elif st.color == t.text: e.ink(t, bg)   # plain text: `font.color`
                             elif e.ownColor: legible(st.color, bg)
                             else: st.color,
                             textArea.x - 4, textArea.right + 4, false)
        w.x += pw
        w.i = q
      if q < b: e.walkTo(text, w, q + 1)
      p = q + 1
    if w.x + x0 > textArea.right + 4: break

method paint*(e: CodeEdit, c: Canvas) =
  e.refreshMetrics()
  e.refreshStyles()
  e.syncContent()
  let t = e.theme
  let enabled = e.isEnabled
  let foc = e.focused
  let r = e.clientRect
  let hot = e.host of UiRoot and UiRoot(e.host).hovered == Control(e)
  let bg = e.fieldFill(t, enabled)
  let ink = e.ink(t, bg, enabled)
  let bc =
    if not enabled: t.border
    elif foc: t.accent
    elif hot: t.borderStrong
    else: t.border
  c.fillFrame(r, t, e.fBorder, bg)

  let vp = e.viewport
  let rh = e.rowH
  let adv = e.fAdv
  let gw = e.gutterW
  let m = e.fModel
  let textArea = rectF(vp.x + gw, vp.y, max(vp.w - gw, 0), vp.h)
  let x0 = e.textX0
  let fm = c.fontMetrics(e.font)
  let baseOff = max(floor((rh - (fm.ascent + fm.descent)) / 2), 0)
  let nRows = e.rowCount
  let firstRow = max(int(floor((e.scrollPosY - float64(PadY)) / float64(rh))), 0)

  # the visible rows
  var rowLines: seq[int]
  var rowTops: seq[float32]
  if firstRow < nRows:
    var line = e.rowLine(firstRow)
    var row = firstRow
    while line >= 0 and e.rowTop(row) < vp.bottom:
      rowLines.add line
      rowTops.add e.rowTop(row)
      inc row
      line = e.nextVisible(line)
  e.prepareTokens(rowLines)
  let sel0 = m.selection
  let selA = sel0.startPos
  let selB = sel0.endPos
  let composing = e.compActive
  let showSel = not composing and not sel0.isEmpty and enabled
  # the selection keeps its colour while the find bar has the focus
  let selFoc = foc or (e.findBarVisible and
                       (e.fBar.findEdit.focused or e.fBar.replaceEdit.focused))
  let selCol = if selFoc: t.selection else: t.selectionInactive
  let caretLine = m.caret.line
  let bm = if e.fHiBrackets and enabled: e.matchingBracket() else: BracketMatch()
  let matches = if rowLines.len > 0: e.visibleMatches(rowLines[0], rowLines[^1]) else: @[]
  var mi = 0
  let lineHi = mix(bg, t.accent, 0.07'f32)
  let guideCol = mix(bg, ink, 0.12'f32)
  let wsCol = mix(bg, ink, 0.30'f32)
  let matchCol = hex"#f59e0b"

  c.pushClip(textArea)
  for ri in 0 ..< rowLines.len:
    let line = rowLines[ri]
    let y = rowTops[ri]
    let rowRect = rectF(textArea.x, y, textArea.w, rh)
    if c.isClippedOut(rowRect): continue
    let text = e.displayText(line)
    let plainText = m.line(line)
    # current line
    if e.fHiLine and line == caretLine and enabled and (not showSel or selFoc):
      c.fillRect(rowRect, lineHi)
    elif e.hasMarker(line, mkCurrent):
      c.fillRect(rowRect, hex"#eab308".withAlpha(46))
    # matches of the find bar
    while mi < matches.len and matches[mi].a.line < line: inc mi
    var mj = mi
    while mj < matches.len and matches[mj].a.line == line:
      let mt = matches[mj]
      let xa = x0 + e.xOfCol(plainText, mt.a.col)
      let xb = x0 + e.xOfCol(plainText, mt.b.col)
      c.fillRect(rectF(xa, y + 1, max(xb - xa, 2), rh - 2), matchCol.withAlpha(70))
      c.frameRect(rectF(xa, y + 1, max(xb - xa, 2), rh - 2), matchCol.withAlpha(150), 1)
      inc mj
    # selection
    if showSel and line >= selA.line and line <= selB.line:
      let lo = if line == selA.line: selA.col else: 0
      let hi = if line == selB.line: selB.col else: plainText.len
      let xa = x0 + e.xOfCol(plainText, lo)
      var xb = x0 + e.xOfCol(plainText, hi)
      if line < selB.line: xb += adv * 0.7'f32          # the selected line break
      if xb > xa: c.fillRect(rectF(xa, y, xb - xa, rh), selCol)
    # bracket match
    if bm.found:
      for p in [bm.a, bm.b]:
        if p.line == line:
          let xa = x0 + e.xOfCol(plainText, p.col)
          let xb = x0 + e.xOfCol(plainText, nextBoundary(plainText, p.col))
          c.fillRect(rectF(xa, y + 1, xb - xa, rh - 2), t.accent.withAlpha(46))
          c.frameRect(rectF(xa, y + 1, xb - xa, rh - 2), t.accent.withAlpha(150), 1)
    # indent guides
    if e.fShowGuides and plainText.len > 0:
      let iw = indentWidth(plainText, m.tabWidth)
      if iw > 0:
        var k = 0
        while (k + 1) * m.tabWidth <= iw:
          let gx = x0 + float32(k * m.tabWidth) * adv
          c.fillRect(rectF(gx, y, 1, rh), guideCol)
          inc k
    # text
    let ty = y + baseOff
    if text.len > 0:
      let useTokens = e.fHl != nil and not (composing and line == e.compLine)
      if not useTokens:
        discard e.drawPiece(c, text, 0, text.len, x0, ty, e.font, ink,
                            textArea.x - 4, textArea.right + 4, false)
      else:
        if e.fApprox:
          let k = e.winIndex(line)
          if k >= 0:
            e.drawTokens(c, text, e.fWinToks[k], x0, ty, enabled, textArea)
          else:
            e.drawTokens(c, text, emptyTokens, x0, ty, enabled, textArea)
        else:
          e.drawTokens(c, text, e.fHl.tokens(line), x0, ty, enabled, textArea)
    # whitespace marks
    if e.fShowWs and text.len > 0:
      var w: Walk
      var i = 0
      while i < text.len:
        let ch = text[i]
        if ch == ' ' or ch == '\t':
          e.walkTo(text, w, i)
          let xs = x0 + w.x
          if xs > textArea.right: break
          if ch == ' ':
            let d = max(rh * 0.09'f32, 1.4'f32)
            c.fillRect(rectF(xs + adv / 2 - d / 2, y + rh / 2 - d / 2, d, d), wsCol)
          else:
            let xe = x0 + e.xOfCol(text, i + 1)
            let cy = y + rh / 2
            c.line(xs + 2, cy, xe - 3, cy, wsCol, 1)
            c.line(xe - 6, cy - 3, xe - 3, cy, wsCol, 1)
            c.line(xe - 6, cy + 3, xe - 3, cy, wsCol, 1)
        inc i
    # the folded pill
    if e.isCollapsed(line):
      let pr = e.pillRect(line)
      c.fillRoundRect(pr, 3, mix(bg, ink, 0.10'f32))
      c.strokeRoundRect(pr, 3, mix(bg, ink, 0.22'f32), 1)
      let cy = pr.y + pr.h / 2 + 2
      for k in -1 .. 1:
        c.fillRect(rectF(pr.x + pr.w / 2 + float32(k) * 4.5 - 1, cy - 1.5, 2, 2), t.textMuted)
    # IME underline
    if composing and line == e.compLine:
      let ca = e.xOfCol(text, e.compCol)
      let cb = e.xOfCol(text, e.compCol + e.composition.len)
      let base = y + baseOff + fm.ascent + 1.5'f32
      underline(c, x0 + ca, x0 + cb, base, 1, ink)
      let sa = e.xOfCol(text, e.compCol + e.compCursor)
      if sa < cb: underline(c, x0 + sa, x0 + cb, base, 2, t.accent)

  # caret
  if e.caretOn and foc and enabled and rowLines.len > 0 and not e.isHidden(caretLine):
    let cr = e.caretRect
    if cr.y + cr.h > vp.y and cr.y < vp.bottom:
      let s = c.scale
      if e.fOverwrite:
        c.fillRect(rectF(floor(cr.x * s) / s, cr.y, cr.w, cr.h), ink.withAlpha(90))
        c.frameRect(rectF(floor(cr.x * s) / s, cr.y, cr.w, cr.h), ink, 1)
      else:
        c.fillRect(rectF(floor(cr.x * s) / s, cr.y, max(round(1.5'f32 * s), 1'f32) / s, cr.h),
                   ink)
  c.popClip()

  # gutter
  if gw > 0:
    let gutterRect = rectF(vp.x, vp.y, gw, vp.h)
    c.pushClip(gutterRect)
    let gbg = if e.ownColor: e.headerFill(t, bg) else: mix(bg, t.surfaceAlt, 0.55'f32)
    c.fillRect(gutterRect, gbg)
    c.fillRect(rectF(gutterRect.right - 1, vp.y, 1, vp.h), t.border)
    let mw = e.markerW
    let nw = e.numbersW
    let numFont = e.font
    let numMuted = mix(gbg, (if e.ownColor: legible(t.textMuted, gbg) else: t.textMuted), 0.85'f32)
    for ri in 0 ..< rowLines.len:
      let line = rowLines[ri]
      let y = rowTops[ri]
      if c.isClippedOut(rectF(vp.x, y, gw, rh)): continue
      # markers
      if e.fMarkers.len > 0:
        let cell = rectF(vp.x, y, mw, rh)
        let k0 = e.fMarkers.lowerBound(Marker(line: line, kind: mkBookmark), markerLess)
        var k = k0
        while k < e.fMarkers.len and e.fMarkers[k].line == line:
          e.drawMarkerIcon(c, cell, e.fMarkers[k].kind)
          inc k
      # number
      if nw > 0:
        let s = $(line + 1)
        let right = vp.x + mw + nw - NumPadR
        let col = if line == caretLine: ink else: numMuted
        c.drawText(s, numFont, right - float32(s.len) * adv, y + baseOff, col)
      # fold chevron
      if e.fFold != nil and e.fFold.canFold(line):
        let cell = rectF(vp.x + mw + nw, y, FoldColW, rh)
        let folded = e.fFold.isCollapsed(line)
        let col = if folded: ink elif e.fGutterHot: t.textMuted else: numMuted
        drawChevron(c, cell, not folded, col)
    c.popClip()

  # border over everything inside
  c.strokeFrame(r, t, e.fBorder, bc, t.borderWidth)
  if foc and enabled and e.fBorder != bsNone: drawFocusRing(c, r, t)
  procCall paint(Control(e), c)

# ------------------------------------------------------------ construction

proc defaultGotoLine(e: CodeEdit) =
  var v = $(e.caretLine + 1)
  if inputQuery("Go to line", "Line number (1 - " & $e.lineCount & "), or line:column:", v):
    let parts = v.strip.split(':')
    try:
      let l = parseInt(parts[0].strip) - 1
      let col = if parts.len > 1: max(parseInt(parts[1].strip) - 1, 0) else: 0
      e.gotoLine(l, col)
    except ValueError: discard

func borderStyle*(x: CodeEdit): BorderStyle = x.fBorder
proc `borderStyle=`*(x: CodeEdit, v: BorderStyle) =
  ## `bsSingle` (default): the usual border and focus ring; `bsNone`: none,
  ## so the control can sit flush in a panel.
  if v == x.fBorder: return
  x.fBorder = v
  x.invalidate()

proc initCodeEdit*(e: CodeEdit, owner: Component = nil) =
  e.initScrollingControl(owner)
  e.fBorder = bsSingle
  e.fModel = newCodeModel()
  e.fFolding = true
  e.fInsertSpaces = true
  e.fShowNums = true
  e.fShowGuides = true
  e.fHiLine = true
  e.fHiBrackets = true
  e.fAutoHl = true
  e.fDesiredV = -1
  e.fFindOpts = SearchOptions(ignoreCase: true)
  e.fLastCaret = (0, 0)
  e.fMaxLen = 0
  e.tabStop = true
  e.cursor = crIBeam
  e.padding = spacing(1)
  e.font = currentTheme().monoFont
  e.hScrollMode = sbmAuto
  e.vScrollMode = sbmAuto
  e.gotoLineDialog = defaultGotoLine
  e.setBounds(0, 0, 480, 320)
  e.rebuildFold()
  let ed = e
  discard e.fModel.addChangeListener(proc(first, oldN, newN: int) =
    ed.modelChanged(first, oldN, newN))
  e.fModel.onSelection = proc() = ed.selectionChanged()

proc newCodeEdit*(parent: Container = nil, text = "", left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): CodeEdit {.discardable.} =
  new result
  result.initCodeEdit(parent)
  if text.len > 0: result.text = text
  placeControl(result, parent, left, top, width, height)

proc loadFromFile*(e: CodeEdit, path: string): LoadReport {.discardable.} =
  ## Reads `path` (IOError if unreadable), remembers it as `fileName` and
  ## picks the language by extension (`autoHighlighter`). Line endings,
  ## the trailing newline and invalid bytes are reported in the result and
  ## preserved by `saveToFile` (except that mixed endings become the dominant
  ## one).
  e.stopDrag()
  e.composition = ""
  e.fFileName = path
  if e.fAutoHl:
    let h = guessHighlighter(path)
    if (h == nil) != (e.fHl == nil) or (h != nil and h.languageName != e.language):
      if e.fHl != nil: e.fHl.detach()
      e.fHl = h
      if h != nil: h.attach(e.fModel)
  result = e.fModel.loadFile(path)
  e.fMarkers.setLen 0
  e.rebuildFold()
  e.fMaxStale = true
  e.rescanMax()
  e.fDesiredV = -1
  e.fLastCaret = (-1, -1)
  e.scrollTo(0, 0)
  e.ensureWarm()
  e.touched(follow = false)

proc saveToFile*(e: CodeEdit, path = "") =
  ## Writes the text with its line endings (UTF-8, no BOM), marks it saved and
  ## remembers `path` (default: `fileName`) as the file name.
  let p = if path.len > 0: path else: e.fFileName
  if p.len == 0: raise newException(IOError, "CodeEdit.saveToFile: no file name")
  e.fModel.saveFile(p, e.fEnsureNewline)
  e.fFileName = p
  e.touched(follow = false)
