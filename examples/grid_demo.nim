# Phase 6 demo: StringGrid (200 rows, sortable headers, editing, TSV
# copy/paste) and an owner-drawn DrawGrid with 1,000,000 rows.
#
# Keys: arrows / PgUp / PgDn / Home / End, Tab, Enter or F2 or typing edits a
#       StringGrid cell (Enter commits and moves down, Esc cancels),
#       Shift+arrows / drag select a range, Ctrl+C / Ctrl+V copy / paste TSV,
#       click a header to sort, drag a header to move the column, drag a
#       header border to resize (double click auto-fits), wheel scrolls.
#       D toggles dark/light.
#
# Env:
#   NIMVCL_SCREENSHOT   lay out, render one frame to this BMP and exit
#   NIMVCL_SCALE        force the display scale (headless testing of 1.5x etc.)
#   NIMVCL_DARK=1       start with the dark theme
#
# Build: nim c --outdir:build examples/grid_demo.nim

import std/[os, strutils, math]
import nimvcl
import nimvcl/controls/grids

var status: Label

const
  First = ["Ada", "Alan", "Grace", "Linus", "Margaret", "Dennis", "Barbara",
           "Ken", "Edsger", "Donald", "Frances", "Tim", "Radia", "Guido"]
  Last = ["Lovelace", "Turing", "Hopper", "Torvalds", "Hamilton", "Ritchie",
          "Liskov", "Thompson", "Dijkstra", "Knuth", "Allen", "Berners-Lee",
          "Perlman", "van Rossum"]
  Dept = ["Engineering", "Research", "Sales", "Support", "Operations", "Design"]
  City = ["Amsterdam", "Berlin", "Copenhagen", "Dublin", "Edinburgh", "Lisbon",
          "Oslo", "Prague"]

proc say(s: string) =
  if status != nil: status.caption = s

proc caption(f: Form, text: string, x, y: float32) =
  let l = newLabel(f, text, x, y)
  l.font = l.font.bold

proc buildPeople(f: Form): StringGrid =
  let g = newStringGrid(f, 16, 34, 548, 400)
  g.name = "people"
  g.colCount = 6
  g.rowCount = 201
  g.fixedCols = 1
  g.fixedRows = 1
  g.options = g.options + {goRowSizing, goColMoving}
  g.colWidths[0] = 44
  g.colWidths[1] = 150
  g.colWidths[2] = 104
  g.colWidths[3] = 88
  g.colWidths[4] = 80
  g.colWidths[5] = 70
  for c, h in ["#", "Name", "Department", "City", "Salary", "Score"]:
    g.cells[c, 0] = h
  for r in 1 .. 200:
    let i = r - 1
    g.cells[0, r] = $r
    g.cells[1, r] = First[(i * 5 + i div 3) mod First.len] & " " & Last[(i * 3 + i div 4) mod Last.len]
    g.cells[2, r] = Dept[(i * 3 + i div 7) mod Dept.len]
    g.cells[3, r] = City[(i * 11 + i div 5) mod City.len]
    g.cells[4, r] = $(38_000 + ((i * 7919) mod 61) * 1_250)
    g.cells[5, r] = $((i * 37) mod 100)
  g.colAlignments[4] = taRight
  g.colAlignments[5] = taRight
  g.colAlignments[0] = taRight
  g.sortOnHeaderClick = true
  g.hotTrack = true
  g.onSelectionChanged = proc(s: Control) =
    let gg = StringGrid(s)
    let sel = gg.selection
    say "people: " & $(sel.right - sel.left + 1) & " x " &
        $(sel.bottom - sel.top + 1) & " cells selected, current (" &
        $gg.col & ", " & $gg.row & ")"
  g.onSetEditText = proc(s: Control, c, r: int, v: string) =
    say "edited (" & $c & ", " & $r & ") = " & v
  g.onHeaderClick = proc(s: Control, c: int) =
    say "sorted by " & StringGrid(s).cells[c, 0]
  g

proc barColor(t: Theme, v: int): Color =
  mix(t.accent, t.danger, float32(v) / 100)

proc buildHuge(f: Form): DrawGrid =
  let g = newDrawGrid(f, 592, 34, 376, 400)
  g.name = "huge"
  g.colCount = 5
  g.rowCount = 1_000_001
  g.fixedCols = 1
  g.fixedRows = 1
  g.options = g.options + {goRangeSelect, goColSizing}
  g.colWidths[0] = 70
  g.colWidths[1] = 60
  g.colWidths[2] = 70
  g.colWidths[3] = 90
  g.hotTrack = true
  const Heads = ["Row", "Value", "Square", "Level", "Hex"]
  g.onDrawCell = proc(s: Control, c: Canvas, col, row: int, r: RectF,
                      st: GridDrawStates) =
    let gg = DrawGrid(s)
    let t = gg.theme
    if row == 0:
      gg.drawCellText(c, r, Heads[col], st, if col == 0: taRight else: taLeft, bold = true)
      return
    let v = (row * 7919) mod 1000
    case col
    of 0: gg.drawCellText(c, r, $row, st, taRight)
    of 1: gg.drawCellText(c, r, $v, st, taRight)
    of 2: gg.drawCellText(c, r, formatFloat(sqrt(float(row)), ffDecimal, 3), st, taRight)
    of 3:
      let bar = rectF(r.x + 6, r.y + 5, max((r.w - 12) * float32(v mod 100) / 100, 1), r.h - 10)
      c.fillRoundRect(bar, 3, t.barColor(v mod 100))
    else: gg.drawCellText(c, r, toHex(row, 6), st)
  g.onSelectionChanged = proc(s: Control) =
    say "huge: row " & $DrawGrid(s).row & " of " & $(DrawGrid(s).rowCount - 1)
  g

proc buildMain(): Form =
  let f = newForm(nil, 984, 500)
  f.caption = "nimvcl grid demo"
  f.caption("StringGrid: 200 rows, click a header to sort, drag it to move, Enter / F2 / type to edit",
            16, 12)
  discard buildPeople(f)
  f.caption("DrawGrid: 1,000,000 rows, owner-drawn", 592, 12)
  discard buildHuge(f)
  status = newLabel(f, "", 16, 450)
  status.autoSize = false
  status.setBounds(16, 450, 950, 24)
  status.caption = "Click a cell"
  f.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
    if k == 'd'.key and sh * {ssCtrl, ssAlt} == {} and
       not (f.activeControl of DrawGrid) and not (f.activeControl of Edit):
      Application.theme = if currentTheme().name == "dark": themeLight() else: themeDark()
      k = Key(0)
  f

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let f = buildMain()
  if shot.len > 0:
    f.show()
    f.syncMetrics()
    discard f.paintIfDirty()
    for c in f.children:
      if c.name == "people":
        let g = StringGrid(c)
        g.sortByColumn(5, ascending = false)
        g.setSelection(2, 3, 4, 6)
        g.moveCurrent(4, 6, extend = true)
        f.activeControl = g
      elif c.name == "huge":
        let g = DrawGrid(c)
        g.moveCurrent(3, 500_000)
        g.topRow = 499_990
    if not f.screenshot(shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    Application.run(f)

main()
