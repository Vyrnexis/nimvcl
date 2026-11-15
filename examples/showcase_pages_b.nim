## Showcase pages 5 to 9: big data, layout, painting, dialogs and menus, the form macro.

import std/[strutils, algorithm, monotimes, times, math, os]
import nimvcl
import ./showcase_common, ./showcase_frame

# ============================================================ 5. big data

const
  FirstNames = ["Ada", "Alan", "Grace", "Linus", "Margaret", "Dennis", "Barbara", "Ken",
                "Edsger", "Donald", "Radia", "Tim", "Guido", "Anders", "Bjarne", "Yukihiro",
                "Rob", "Niklaus", "Hedy", "Katherine", "Claude", "John", "Frances", "Leslie",
                "Shafi", "Vint", "Lois", "Mary", "Jean", "Satoshi", "Andreas", "Elena",
                "Marcus", "Priya", "Chen", "Noor", "Mateo", "Ingrid", "Tariq", "Sofia"]
  LastNames = ["Lovelace", "Turing", "Hopper", "Torvalds", "Hamilton", "Ritchie", "Liskov",
               "Thompson", "Dijkstra", "Knuth", "Perlman", "Berners", "Rossum", "Hejlsberg",
               "Stroustrup", "Matsumoto", "Pike", "Wirth", "Lamarr", "Johnson", "Shannon",
               "McCarthy", "Allen", "Lamport", "Goldwasser", "Cerf", "Haibt", "Wilkes",
               "Sammet", "Nakamoto", "Rumpf", "Petrova", "Weber", "Sharma", "Wei", "Haddad",
               "Silva", "Larsen", "Aziz", "Rossi"]
  Cities = ["Amsterdam", "Berlin", "Boston", "Cairo", "Delhi", "Dublin", "Helsinki", "Istanbul",
            "Lagos", "Lima", "Lisbon", "London", "Madrid", "Mumbai", "Oslo", "Paris",
            "Prague", "Rome", "Seoul", "Sydney", "Tokyo", "Toronto", "Vienna", "Zurich"]
  Statuses = ["Active", "Pending", "Closed"]
  ColCaptions = ["#", "Name", "City", "Status", "Amount", "Date"]

type
  Row = object
    first, last, city, status: uint8
    amount: int32                        ## cents
    day: int16                           ## days since 2020-01-01

proc makeRows(n: int): seq[Row] =
  result = newSeq[Row](n)
  var s = 0x9e3779b97f4a7c15'u64         # xorshift: deterministic data
  proc next(): uint64 =
    s = s xor (s shl 13)
    s = s xor (s shr 7)
    s = s xor (s shl 17)
    s
  for r in result.mitems:
    let x = next()
    r.first = uint8(x mod FirstNames.len.uint64)
    r.last = uint8((x shr 8) mod LastNames.len.uint64)
    r.city = uint8((x shr 16) mod Cities.len.uint64)
    r.status = uint8((x shr 24) mod 3)
    r.amount = int32((x shr 32) mod 2_000_000'u64) - 200_000
    r.day = int16((x shr 52) mod 2300'u64)

proc money(cents: int32): string =
  let c = abs(cents.int)
  result = (if cents < 0: "-" else: "") & thousands(c div 100) & "." & align($(c mod 100), 2, '0')

proc dateText(day: int16): string =
  (dateTime(2020, mJan, 1, zone = utc()) + days(day.int)).format("yyyy-MM-dd")

proc ranks(names: seq[string]): seq[int] =
  ## `result[i]` is the alphabetical position of `names[i]`.
  var order = newSeq[int](names.len)
  for i in 0 ..< order.len: order[i] = i
  order.sort(proc(a, b: int): int = cmp(names[a].toLowerAscii, names[b].toLowerAscii))
  result = newSeq[int](names.len)
  for pos, i in order: result[i] = pos

proc buildBigData*(ctx: Showcase, body: Container) =
  var nameList: seq[string]
  for f in FirstNames:
    for l in LastNames: nameList.add f & " " & l
  let nameRank = ranks(nameList)
  let cityRank = ranks(@Cities)
  let statusRank = ranks(@Statuses)
  var rows = makeRows(100_000)
  var view: seq[int32]
  var sortCol = -1
  var sortAsc = true
  let lv = newListView(body)
  lv.align = alClient
  lv.margins = spacing(0, 52, 0, 34)
  lv.viewStyle = vsReport
  lv.ownerData = true
  lv.readOnly = true
  lv.multiSelect = true
  lv.rowSelect = true
  lv.columns.add(ColCaptions[0], 90, taRight)
  lv.columns.add(ColCaptions[1], 220)
  lv.columns.add(ColCaptions[2], 140)
  lv.columns.add(ColCaptions[3], 100)
  lv.columns.add(ColCaptions[4], 130, taRight)
  lv.columns.add(ColCaptions[5], 110)
  lv.onData = proc(s: Control, item: ListItem) =
    let r = rows[view[item.index]]
    item.caption = thousands(view[item.index].int + 1)
    item.subItems = @[FirstNames[r.first] & " " & LastNames[r.last], Cities[r.city],
                      Statuses[r.status], money(r.amount), dateText(r.day)]

  # ---- toolbar row
  let bar = newPanel(body, "", 0, 0, 810, 44)
  bar.borderStyle = pbNone
  bar.anchors = {akLeft, akTop, akRight}
  discard newLabel(bar, "&Search", 0, 9)
  let search = newEdit(bar, "", 62, 4, 280)
  search.placeholder = "Try: tokyo, or ada closed"
  search.hint = "Filters as you type; the view is rebuilt from the whole table"
  discard newLabel(bar, "Status", 362, 9)
  let status = newComboBox(bar, csDropDownList, 414, 4, 120)
  status.items = ["All", "Active", "Pending", "Closed"]
  status.itemIndex = 0
  discard newLabel(bar, "Rows", 556, 9)
  let size = newComboBox(bar, csDropDownList, 598, 4, 140)
  size.items = ["1,000", "100,000", "1,000,000"]
  size.itemIndex = 1
  size.hint = "Virtual mode: only the visible rows are ever asked for text"

  # ---- footer
  let count = newLabel(body, "")
  count.anchors = {akLeft, akBottom}
  count.setBounds(0, 500, 400, 22)
  count.font = font(size = 14, style = {fsBold})
  let timing = ctx.mutedLabel(body, "", 410, 502, 400, 20)
  timing.anchors = {akRight, akBottom}
  timing.alignment = taRight
  timing.autoSize = false

  var tableMs = 0.0
  proc rebuild(measureRender: bool) =
    ## Filter, sort and refresh; then time one full frame of the window.
    let t0 = getMonoTime()
    let q = search.text.toLowerAscii.splitWhitespace
    let stSel = status.itemIndex - 1                      # -1 = all
    view.setLen(0)
    if q.len == 0 and stSel < 0:
      view.setLen(rows.len)
      for i in 0 ..< rows.len: view[i] = int32(i)
    else:
      # Per search word: one bit for every name, city and status that contains
      # it. A row matches when each word is found in its name, city or status.
      let full = (1 shl q.len) - 1
      var nameMask = newSeq[int](FirstNames.len * LastNames.len)
      var cityMask = newSeq[int](Cities.len)
      var statMask = newSeq[int](3)
      for k, w in q:
        for f in 0 ..< FirstNames.len:
          for l in 0 ..< LastNames.len:
            if w in (FirstNames[f] & " " & LastNames[l]).toLowerAscii:
              nameMask[f * LastNames.len + l] = nameMask[f * LastNames.len + l] or (1 shl k)
        for c in 0 ..< Cities.len:
          if w in Cities[c].toLowerAscii: cityMask[c] = cityMask[c] or (1 shl k)
        for st in 0 .. 2:
          if w in Statuses[st].toLowerAscii: statMask[st] = statMask[st] or (1 shl k)
      for i, r in rows:
        if (stSel < 0 or stSel == r.status.int) and
           (nameMask[r.first.int * LastNames.len + r.last.int] or cityMask[r.city.int] or
            statMask[r.status.int]) == full:
          view.add int32(i)
    if sortCol >= 0:
      # sort (rank shl 21) or row id as plain integers: fast even for a million rows
      var keys = newSeq[int64](view.len)
      for i, id in view:
        let r = rows[id]
        let rank = case sortCol
                   of 0: 0
                   of 1: nameRank[r.first.int * LastNames.len + r.last.int]
                   of 2: cityRank[r.city.int]
                   of 3: statusRank[r.status.int]
                   of 4: r.amount.int + 200_000
                   else: r.day.int
        keys[i] = (rank.int64 shl 21) or id.int64
      keys.sort()
      if not sortAsc: keys.reverse()
      for i, k in keys: view[i] = int32(k and 0x1fffff)
    lv.itemsCount = view.len
    lv.refreshData()
    tableMs = (getMonoTime() - t0).inNanoseconds.float / 1e6
    count.caption = thousands(view.len) & " of " & thousands(rows.len) & " rows" &
                    (if sortCol >= 0: "   sorted by " & ColCaptions[sortCol] &
                                      (if sortAsc: " up" else: " down") else: "")
    if measureRender and lv.root of Form:
      let t1 = getMonoTime()
      discard Form(lv.root).paintIfDirty()
      let renderMs = (getMonoTime() - t1).inNanoseconds.float / 1e6
      timing.caption = "table " & formatFloat(tableMs, ffDecimal, 1) & " ms, rendered in " &
                       formatFloat(renderMs, ffDecimal, 1) & " ms"
    else:
      timing.caption = "table " & formatFloat(tableMs, ffDecimal, 1) & " ms"
    ctx.say count.caption

  # debounce the typing: rebuild 120 ms after the last key
  let debounce = newTimer(body, 120)
  debounce.onTimer = proc(s: Timer) =
    debounce.enabled = false
    rebuild(true)
  search.onChange = proc(s: Control) =
    debounce.enabled = false
    debounce.enabled = true
  status.onChange = proc(s: Control) = rebuild(true)
  size.onChange = proc(s: Control) =
    rows = makeRows([1_000, 100_000, 1_000_000][size.itemIndex])
    sortCol = -1
    lv.sortColumn = -1
    lv.sortOrder = soNone
    rebuild(true)
  lv.onColumnClick = proc(s: Control, col: ListColumn) =
    sortAsc = if col.index == sortCol: not sortAsc else: true
    sortCol = col.index
    lv.sortColumn = sortCol
    lv.sortOrder = if sortAsc: soAscending else: soDescending
    rebuild(true)
  # the first build is not timed against a frame: the window is not shown yet
  rebuild(false)
  lv.itemIndex = 3
  var first = true
  ctx.addHook(4, proc(on: bool) =
    if on and first:
      first = false
      rebuild(true))

# ============================================================ 6. layout

proc buildLayout*(ctx: Showcase, body: Container) =
  # ---- FlowPanel
  let g1 = newGroupBox(body, "FlowPanel: children keep their size and wrap at the edge")
  g1.align = alTop
  g1.height = 120
  g1.margins = spacing(0, 0, 0, 12)
  let flow = newFlowPanel(g1)
  flow.align = alClient
  flow.borderStyle = pbNone
  flow.hGap = 8
  flow.vGap = 8
  flow.padding = spacing(10, 6)
  let words = ["New", "Open...", "Save", "Save As...", "Print", "Preview", "Undo", "Redo",
               "Cut", "Copy", "Paste", "Find", "Replace", "Zoom in", "Zoom out", "Settings"]
  for w in words:
    let b = newButton(flow, w, 0, 0, 30 + w.len.float32 * 9, 30)
    b.onClick = proc(s: Control) = ctx.say "FlowPanel button: " & s.caption

  # ---- GridPanel
  let g2 = newGroupBox(body, "GridPanel: absolute, auto and percent tracks, cell spans")
  g2.align = alTop
  g2.height = 150
  g2.margins = spacing(0, 0, 0, 12)
  let gp = newGridPanel(g2)
  gp.align = alClient
  gp.borderStyle = pbNone
  gp.padding = spacing(10, 4)
  gp.columns = @[gsAuto(), gsPercent(50), gsAuto(), gsPercent(50)]
  gp.rows = @[gsAbsolute(38), gsAbsolute(38), gsAbsolute(40)]
  proc lab(t: string, m = spacing(0, 0, 10, 0)): Label =
    result = newLabel(gp, t)
    result.autoSize = false
    result.layout = vaCenter
    result.margins = m
  discard lab("First name")
  let e1 = newEdit(gp, "Ada")
  e1.margins = spacing(0, 5, 18, 5)
  discard lab("Last name")
  let e2 = newEdit(gp, "Lovelace")
  e2.margins = spacing(0, 5, 0, 5)
  discard lab("Email")
  let e3 = newEdit(gp)
  e3.placeholder = "spans the remaining three columns"
  e3.margins = spacing(0, 5, 0, 5)
  gp.setCell(e3, 1, 1, colSpan = 3)
  let ok = newButton(gp, "Apply")
  ok.margins = spacing(0, 5, 18, 3)
  gp.setCell(ok, 2, 1)
  let cancel = newButton(gp, "Reset")
  cancel.margins = spacing(0, 5, 0, 3)
  gp.setCell(cancel, 2, 3)

  # ---- anchors and splitter
  let g3 = newGroupBox(body, "Anchors and Splitter: drag the divider, resize the window")
  g3.align = alClient
  let left = newPanel(g3, "alLeft panel", 0, 0, 220, 190)
  left.align = alLeft
  left.borderStyle = pbSingle
  left.margins = spacing(10, 4, 0, 10)
  left.constraints = constraints(minWidth = 120)
  let split = newSplitter(g3, alLeft)
  split.minSize = 120
  split.margins = spacing(0, 4, 0, 10)
  let right = newPanel(g3, "", 0, 0, 570, 190)
  right.align = alClient
  right.borderStyle = pbSingle
  right.margins = spacing(0, 4, 10, 10)
  let stretch = newEdit(right, "anchors = {akLeft, akTop, akRight}", 12, 12, 546)
  stretch.anchors = {akLeft, akTop, akRight}
  let bar = newProgressBar(right, 12, 52, 546, 16)
  bar.anchors = {akLeft, akTop, akRight}
  bar.position = 55
  let inner = newMemo(right, "anchors = all four sides:\nthis memo grows in both directions.", 12, 82, 546, 64)
  inner.anchors = {akLeft, akTop, akRight, akBottom}
  let br = newButton(right, "Bottom right", 448, 152, 110, 30)
  br.anchors = {akRight, akBottom}
  let bl = newButton(right, "Bottom left", 12, 152, 110, 30)
  bl.anchors = {akLeft, akBottom}

# ============================================================ 7. painting

proc mix(a, b: Color, t: float): Color =
  rgb(int(a.r.float + (b.r.float - a.r.float) * t), int(a.g.float + (b.g.float - a.g.float) * t),
      int(a.b.float + (b.b.float - a.b.float) * t))

proc star(cx, cy, r1, r2: float32, n = 5, rot = -PI / 2): seq[PointF] =
  for i in 0 ..< n * 2:
    let a = rot + i.float * PI / n.float
    let r = if i mod 2 == 0: r1 else: r2
    result.add pointF(cx + r * cos(a).float32, cy + r * sin(a).float32)

proc buildPainting*(ctx: Showcase, body: Container) =
  var phase = 0.0
  var trail: seq[PointF]
  let top = newPanel(body, "", 0, 0, 810, 34)
  top.align = alTop
  top.borderStyle = pbNone
  let animate = newCheckBox(top, "&Animate", false, 0, 4)
  animate.hint = "A Timer ticks every 30 ms and invalidates the PaintBox"
  let note = ctx.mutedLabel(top, "A PaintBox, redrawn on every resize and tick. Everything is anti-aliased and HiDPI aware.",
                            110, 6)
  let box = newPaintBox(body)
  box.align = alClient
  let tick = newTimer(body, 30)
  tick.onTimer = proc(s: Timer) =
    phase += 0.045
    box.invalidate()
  animate.onChange = proc(s: Control) = tick.enabled = animate.checked
  ctx.addHook(6, proc(on: bool) =
    if on and not ctx.shotMode: animate.checked = true
    elif not on: animate.checked = false
    tick.enabled = animate.checked)
  if ctx.shotMode: phase = 1.1

  box.onPaint = proc(s: Control, c: Canvas) =
    let t = s.theme
    let r = s.clientRect
    let gap = 14'f32
    let tw = (r.w - gap) / 2
    let th = (r.h - gap) / 2
    proc tile(i: int, title: string): RectF =
      let x = (i mod 2).float32 * (tw + gap)
      let y = (i div 2).float32 * (th + gap)
      let tr = rectF(x, y, tw, th)
      c.fillRoundRect(tr, 10, t.surface)
      c.strokeRoundRect(tr, 10, t.border, 1)
      c.drawText(title, font(size = 12, style = {fsBold}), x + 14, y + 10, t.textMuted)
      rectF(x + 14, y + 34, tw - 28, th - 48)         # the content area

    # ---- 0: gradient bands and glass
    block:
      let a = tile(0, "GRADIENT BANDS AND ALPHA")
      let steps = 48
      let c1 = rgb(0x4f, 0x46, 0xe5)
      let c2 = rgb(0x06, 0xb6, 0xd4)
      let c3 = rgb(0xf4, 0x72, 0xb6)
      c.pushClip(a)
      for i in 0 ..< steps:
        let f = i / (steps - 1)
        let col = if f < 0.5: mix(c1, c2, f * 2) else: mix(c2, c3, (f - 0.5) * 2)
        c.fillRect(rectF(a.x + a.w * i.float32 / steps.float32, a.y, a.w / steps.float32 + 1, a.h), col)
      c.popClip()
      for i in 0 .. 2:
        let rr = rectF(a.x + 24 + i.float32 * 70, a.y + 20 + i.float32 * 14, 110, 80)
        c.fillRoundRect(rr, 16, rgba(255, 255, 255, 70 + i * 25))
        c.strokeRoundRect(rr, 16, rgba(255, 255, 255, 200), 1.5)
      c.textRect("Glass", font(size = 20, style = {fsBold}), rectF(a.x, a.bottom - 52, a.w, 40),
                 clWhite, taCenter, vaCenter)

    # ---- 1: shapes
    block:
      let a = tile(1, "ANTI-ALIASED SHAPES")
      let radii = [0'f32, 8, 18, 34]
      for i, rad in radii:
        let rr = rectF(a.x + i.float32 * 76, a.y, 64, 64)
        c.fillRoundRect(rr, rad, t.accent)
        c.strokeRoundRect(rr.inflate(5), rad + 5, t.accent, 1)
      let y2 = a.y + 84
      c.fillEllipse(rectF(a.x, y2, 90, 50), rgb(0xf5, 0x9e, 0x0b))
      c.strokeEllipse(rectF(a.x + 100, y2, 90, 50), t.text, 2)
      c.fillPolygon(star(a.x + 250, y2 + 26, 32, 13), rgb(0xe1, 0x4d, 0x8a))
      for i in 0 .. 12:
        let ang = i.float * 0.12
        c.line(a.x, a.bottom - 8, a.x + a.w - 4, a.bottom - 8 - 70 * sin(ang).float32 - 2, mix(t.accent, rgb(0xe1, 0x4d, 0x8a), i / 12), 1.2)

    # ---- 2: text
    block:
      let a = tile(2, "TEXT STYLES")
      var y = a.y
      let tcol = t.text
      c.drawText("Regular 14", font(size = 14), a.x, y, tcol)
      c.drawText("Bold", font(size = 14, style = {fsBold}), a.x + 110, y, tcol)
      c.drawText("Italic", font(size = 14, style = {fsItalic}), a.x + 170, y, tcol)
      c.drawText("Underline", font(size = 14, style = {fsUnderline}), a.x + 235, y, tcol)
      c.drawText("Strike", font(size = 14, style = {fsStrikeOut}), a.x + 320, y, tcol)
      y += 28
      c.drawText("Large and bold 26", font(size = 26, style = {fsBold}), a.x, y, t.accent)
      y += 44
      c.drawText("Mixed scripts: Ωμέγα Ж ñ ß ç ø", font(size = 15), a.x, y, tcol)
      y += 30
      let box1 = rectF(a.x, y, a.w * 0.48, 26)
      c.fillRoundRect(box1, 6, t.surfaceAlt)
      c.textRect("An ellipsized line that is far too long to fit", font(size = 13), rectF(box1.x + 8, box1.y, box1.w - 16, box1.h),
                 tcol, taLeft, vaCenter, ellipsis = true)
      let box2 = rectF(a.x + a.w * 0.52, y, a.w * 0.48, 26)
      c.fillRoundRect(box2, 6, t.surfaceAlt)
      c.textRect("Right aligned", font(size = 13), rectF(box2.x + 8, box2.y, box2.w - 16, box2.h), tcol, taRight, vaCenter)
      y += 38
      c.textRect("Word-wrapped text flows inside its rectangle, is measured with measureText and clipped to it. Every glyph is anti-aliased and positioned at fractional scales.",
                 font(size = 13), rectF(a.x, y, a.w, a.bottom - y), t.textMuted, taLeft, vaTop, wrap = true)

    # ---- 3: animation
    block:
      let a = tile(3, if animate.checked: "ANIMATION (RUNNING)" else: "ANIMATION")
      let cx = a.x + a.w * 0.28
      let cy = a.y + a.h / 2
      c.fillEllipse(rectF(cx - 16, cy - 16, 32, 32), rgb(0xf5, 0x9e, 0x0b))
      for i, (orad, sz, spd, col) in [(46'f32, 8'f32, 1.0, rgb(0x4f, 0x46, 0xe5)),
                                      (72'f32, 11'f32, 0.6, rgb(0x06, 0xb6, 0xd4)),
                                      (98'f32, 7'f32, 0.35, rgb(0xe1, 0x4d, 0x8a))]:
        c.strokeEllipse(rectF(cx - orad, cy - orad, 2 * orad, 2 * orad), t.border, 1)
        let ang = phase * spd * 3 + i.float * 2
        let px = cx + orad * cos(ang).float32
        let py = cy + orad * sin(ang).float32
        c.fillEllipse(rectF(px - sz, py - sz, 2 * sz, 2 * sz), col)
      # a travelling sine wave on the right
      let wx = a.x + a.w * 0.56
      let ww = a.w * 0.44
      var prev = pointF(wx, cy)
      for i in 0 .. 60:
        let f = i / 60
        let p = pointF(wx + ww * f.float32, cy + 36 * sin(f * 9 - phase * 4).float32 * sin(f * PI).float32)
        if i > 0: c.line(prev.x, prev.y, p.x, p.y, t.accent, 2.5)
        prev = p
      let bx = wx + (ww - 24) * (0.5 + 0.5 * sin(phase * 1.3)).float32
      let by = a.bottom - 10 - 38 * abs(sin(phase * 2.6)).float32
      c.fillEllipse(rectF(wx, a.bottom - 6, ww, 6), t.surfaceAlt)
      c.fillEllipse(rectF(bx, by - 12, 24, 24), rgb(0x22, 0xa5, 0x5e))

# ============================================================ 8. dialogs and menus

proc buildDialogs*(ctx: Showcase, body: Container) =
  let msg = card(body, "Message dialogs", 0, 0, 396, 216, {akLeft, akTop, akRight})
  let result1 = newLabel(msg, "No dialog shown yet.", 16, 176)
  result1.font = font(size = 14, style = {fsBold})
  proc answer(r: ModalResult) =
    result1.caption = "Result: " & $r
    ctx.say "Dialog result: " & $r
  var y = 32'f32
  var x = 16'f32
  proc dlgButton(text: string, hintText: string, act: proc()): Button =
    result = newButton(msg, text, x, y, 170, 32)
    result.hint = hintText
    result.onClick = proc(s: Control) = act()
    if x > 100: (x = 16; y += 40) else: x += 186
  discard dlgButton("&Information", "messageDlg with mtInformation",
    proc() = answer(messageDlg("The backup finished without errors.", mtInformation, {mbOK})))
  discard dlgButton("&Warning", "Yes / No / Cancel",
    proc() = answer(messageDlg("Overwrite the existing file?", mtWarning, {mbYes, mbNo, mbCancel}, mbNo)))
  discard dlgButton("&Error", "Retry / Cancel",
    proc() = answer(messageDlg("The disk is not ready.", mtError, {mbRetry, mbCancel})))
  discard dlgButton("C&onfirmation", "Yes / No",
    proc() = answer(messageDlg("Delete 3 selected items?", mtConfirmation, {mbYes, mbNo}, mbNo)))
  discard dlgButton("&Plain message", "showMessage: OK only",
    proc() = showMessage("showMessage has an OK button and no icon."))
  discard dlgButton("In&put query", "inputQuery: ask for a line of text",
    proc() =
      var name = "nimvcl"
      if inputQuery("Rename", "New project name:", name):
        result1.caption = "You typed: " & name)

  # ---- file dialogs
  let files = card(body, "Native file dialogs", 414, 0, 396, 216, {akTop, akRight})
  let chosen = newLabel(files, "No file chosen.", 16, 112, 364, 90)
  chosen.autoSize = false
  chosen.wordWrap = true
  chosen.font = font(size = 13)
  proc report(prefix: string): proc(ok: bool, fs: seq[string]) =
    result = proc(ok: bool, fs: seq[string]) =
      chosen.caption = if ok and fs.len > 0: prefix & "\n" & fs.join("\n") else: "Cancelled."
      ctx.say chosen.caption.splitLines[0]
  let od = newOpenDialog(files)
  od.title = "Open a file"
  od.filters = @[("Nim sources", "nim;nims"), ("Images", "png;jpg"), ("All files", "*")]
  od.multiSelect = true
  let sd = newSaveDialog(files)
  sd.title = "Save as"
  let fd = newSelectFolderDialog(files)
  fd.title = "Choose a folder"
  let ob = newButton(files, "&Open files...", 16, 32, 170, 32)
  ob.onClick = proc(s: Control) = od.execute(report("Open:"))
  ctx.pickFile = proc() = od.execute(report("Open:"))
  let sb = newButton(files, "&Save as...", 200, 32, 170, 32)
  sb.onClick = proc(s: Control) = sd.execute(report("Save:"))
  let fb = newButton(files, "&Folder...", 16, 72, 170, 32)
  fb.onClick = proc(s: Control) = fd.execute(report("Folder:"))
  # the dialogs are native: the desktop draws them

  # ---- popup menu
  let pop = card(body, "PopupMenu: right-click the panel", 0, 232, 396, 280, {akLeft, akTop, akBottom})
  let area = newPanel(pop, "Right-click here (or Shift+F10)", 16, 32, 364, 230)
  area.anchors = {akLeft, akTop, akRight, akBottom}
  area.borderStyle = pbSingle
  area.font = font(size = 16)
  let menu = newPopupMenu(body)
  menu.images = ctx.icons
  ctx.popupMenu = menu
  let it1 = menu.addItem("Make text &large", proc(s: MenuItem) =
    area.font = font(size = if s.checked: 26 else: 16))
  it1.autoCheck = true
  it1.shortcut = shortcut("Ctrl+L")
  menu.addSeparator()
  let borders = menu.addItem("&Border")
  const borderStyles = [pbNone, pbSingle, pbRaised]
  for i, n in ["None", "Single", "Raised"]:
    let m = borders.addItem(n, proc(s: MenuItem) =
      area.borderStyle = borderStyles[s.tag]
      ctx.say "Border: " & s.caption)
    m.tag = i
    m.radioItem = true
    m.groupIndex = 1
    m.checked = i == 1
  let aligns = menu.addItem("&Alignment")
  const alignments = [taLeft, taCenter, taRight]
  for i, n in ["Left", "Center", "Right"]:
    let m = aligns.addItem(n, proc(s: MenuItem) =
      area.alignment = alignments[s.tag]
      ctx.say "Alignment: " & s.caption)
    m.tag = i
    m.radioItem = true
    m.groupIndex = 2
    m.checked = i == 1
  menu.addSeparator()
  let reset = menu.addItem("&Reset", proc(s: MenuItem) =
    area.font = font(size = 16)
    area.borderStyle = pbSingle
    area.alignment = taCenter
    it1.checked = false
    ctx.say "Panel reset")
  reset.imageIndex = icOpen
  let about = menu.addItem("&About this menu", proc(s: MenuItem) =
    showMessage("Popup menus are real popup windows: icons, shortcuts, checks, radio items and submenus."))
  about.imageIndex = icInfo
  attachPopupMenu(area, menu)

  # ---- hints and a custom modal form
  let hints = card(body, "Hints and a custom modal form", 414, 232, 396, 280, {akTop, akRight, akBottom})
  let h1 = newLabel(hints, "Rest the mouse on any of these:", 16, 32)
  let hb1 = newButton(hints, "Button", 16, 62, 110, 32)
  hb1.hint = "A button hint"
  let hb2 = newEdit(hints, "An edit", 136, 62, 110)
  hb2.hint = "Edits have hints too"
  let hb3 = newCheckBox(hints, "Check box", false, 262, 66)
  hb3.hint = "Hints are inherited by children when the child has none"
  discard h1
  let sep = newBevel(hints, bsTopLine, 16, 112, 364, 2)
  discard sep
  let modalInfo = ctx.mutedLabel(hints, "A Form of your own, shown with showModal:", 16, 124)
  let result2 = newLabel(hints, "", 16, 188, 364, 22)
  result2.font = font(size = 14, style = {fsBold})
  let mb = newButton(hints, "Open modal &form...", 16, 148, 200, 32)
  mb.onClick = proc(s: Control) =
    let d = newForm(nil, 380, 190)
    d.caption = "A modal form"
    d.borderStyle = bsSingle
    let l = newLabel(d, "Your favourite language:", 20, 20)
    discard l
    let e = newEdit(d, "Nim", 20, 48, 340)
    e.autoSelect = true
    let ok = newButton(d, "OK", 160, 130, 96, 32)
    ok.isDefault = true
    ok.modalResult = mrOk
    let cancel = newButton(d, "Cancel", 264, 130, 96, 32)
    cancel.isCancel = true
    cancel.modalResult = mrCancel
    d.activeControl = e
    let r = d.showModal()
    result2.caption = if r == mrOk: "You chose: " & e.text else: "Cancelled"
    d.freeWindow()
  discard modalInfo
  let tilesL = ctx.mutedLabel(hints, "Clickable tiles with hints:", 16, 216)
  discard tilesL
  const tileCols = [rgb(0x3b, 0x82, 0xf6), rgb(0x22, 0xa5, 0x5e), rgb(0xf5, 0x9e, 0x0b),
                    rgb(0xe1, 0x4d, 0x8a), rgb(0x8b, 0x5c, 0xf6)]
  const tileNames = ["Blue", "Green", "Amber", "Pink", "Violet"]
  for i in 0 ..< tileCols.len:
    let tile = newPaintBox(hints, 16 + i.float32 * 74, 242, 64, 24)
    tile.tag = i
    tile.cursor = crHand
    tile.hint = tileNames[i] & " tile: a PaintBox with a hint"
    tile.onPaint = proc(s: Control, c: Canvas) =
      c.fillRoundRect(s.clientRect, 6, tileCols[s.tag])
    tile.onClick = proc(s: Control) = ctx.say "You clicked the " & tileNames[s.tag] & " tile"

# ============================================================ 9. form macro

const
  here = currentSourcePath().parentDir
  FrameSource = staticRead(here / "showcase_frame.nim")

proc buildFormMacro*(ctx: Showcase, body: Container) =
  let src = card(body, "showcase_frame.nim (this file is compiled into the page)", 0, 0, 470, 520,
                 {akLeft, akTop, akBottom})
  let code = newMemo(src, FrameSource[FrameSource.find("import nimvcl") .. ^1].strip, 12, 30, 446, 478)
  code.anchors = {akLeft, akTop, akRight, akBottom}
  code.readOnly = true
  code.wordWrap = false
  code.font = currentTheme().monoFont
  code.font = font(family = code.font.family, size = 12)
  let live = card(body, "Two instances of ContactCard", 484, 0, 326, 520, {akTop, akRight, akBottom})
  let a = newContactCard(live, 16, 36)
  let b = newContactCard(live, 16, 266)
  a.fullName.text = "Ada Lovelace"
  a.email.text = "ada@example.org"
  b.title.caption = "Another contact"
  b.newsletter.checked = true
