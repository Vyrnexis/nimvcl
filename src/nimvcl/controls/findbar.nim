## `FindBar`: the find and replace strip `CodeEdit` shows at the top right of
## its text area (a floating card, like most modern editors).
##
## Controls: the find field (Enter = next, Shift+Enter = previous), three
## option toggles (match case, whole word, regular expression; Alt+C, Alt+W,
## Alt+R), a result counter, previous / next / close buttons and, with the
## replace row open (Ctrl+H or the arrow at the left), the replace field with
## "Replace" and "All". Esc closes the bar. F3 and Shift+F3 step from either
## field.
##
## The bar owns no search logic: it reports through callbacks and `CodeEdit`
## answers by calling `setStatus`. It is a plain `Container`, so a program may
## also build one for its own use.

import ../graphics/[geometry, color, font, canvas]
import ../core/[types, control, theme]
import ./common, ./edit
export edit

type
  GlyphDraw* = proc(c: Canvas, r: RectF, col: Color) {.closure.}

  BarButtonKind* = enum bkIcon, bkChip, bkText

  BarButton* = ref object of Control
    ## A small flat button: an icon, a toggle chip ("Aa") or a text button.
    kind*: BarButtonKind
    glyph*: GlyphDraw
    on*: bool                      ## chips: the option is switched on
    fHot, fDown: bool

  BarKeyHook* = proc(key: var Key, shift: ShiftState) {.closure.}

  BarEdit* = ref object of Edit
    ## An `Edit` that offers Enter, Esc, F3 and Alt+letter to its bar first.
    keyHook*: BarKeyHook

  FindBar* = ref object of Container
    findEdit*, replaceEdit*: BarEdit
    caseBtn*, wordBtn*, regexBtn*: BarButton
    prevBtn*, nextBtn*, closeBtn*, expandBtn*: BarButton
    replaceBtn*, replaceAllBtn*: BarButton
    fReplace: bool
    fStatus: string
    fBad: bool
    fQuiet: bool                    ## programmatic text changes do not report
    onFindChange*: NotifyEvent      ## the find text changed
    onOptionsChange*: NotifyEvent   ## a toggle changed
    onStep*: proc(forward: bool) {.closure.}
    onReplace*, onReplaceAll*, onClose*: NotifyEvent

const
  RowH = 26'f32
  Pad = 6'f32
  Gap = 3'f32
  BtnW = 24'f32
  ChipW = 26'f32
  FindW = 190'f32
  CounterW = 74'f32
  Shadow = 4'f32                    ## room for the drop shadow around the card

# ---------------------------------------------------------------- glyphs

proc glyphChevron(down: bool): GlyphDraw =
  result = proc(c: Canvas, r: RectF, col: Color) =
    let cx = r.x + r.w / 2
    let cy = r.y + r.h / 2
    if down:
      c.line(cx - 3.5, cy - 1.5, cx, cy + 2, col, 1.5)
      c.line(cx, cy + 2, cx + 3.5, cy - 1.5, col, 1.5)
    else:
      c.line(cx - 1.5, cy - 3.5, cx + 2, cy, col, 1.5)
      c.line(cx + 2, cy, cx - 1.5, cy + 3.5, col, 1.5)

proc glyphArrow(up: bool): GlyphDraw =
  result = proc(c: Canvas, r: RectF, col: Color) =
    let cx = r.x + r.w / 2
    let cy = r.y + r.h / 2
    let s = if up: -1'f32 else: 1'f32
    c.line(cx, cy - 4 * s, cx, cy + 4 * s, col, 1.5)
    c.line(cx - 3.5, cy + 0.5 * s, cx, cy + 4 * s, col, 1.5)
    c.line(cx + 3.5, cy + 0.5 * s, cx, cy + 4 * s, col, 1.5)

proc glyphClose(c: Canvas, r: RectF, col: Color) =
  let cx = r.x + r.w / 2
  let cy = r.y + r.h / 2
  c.line(cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5, col, 1.5)
  c.line(cx - 3.5, cy + 3.5, cx + 3.5, cy - 3.5, col, 1.5)

# ------------------------------------------------------------- BarButton

method canFocus*(b: BarButton): bool = false

method doMouseEnter*(b: BarButton) =
  b.fHot = true
  b.invalidate()
  procCall doMouseEnter(Control(b))

method doMouseLeave*(b: BarButton) =
  b.fHot = false
  b.fDown = false
  b.invalidate()
  procCall doMouseLeave(Control(b))

method doMouseDown*(b: BarButton, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    b.fDown = true
    b.invalidate()
  procCall doMouseDown(Control(b), button, shift, x, y)

method doMouseUp*(b: BarButton, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft:
    b.fDown = false
    b.invalidate()
  procCall doMouseUp(Control(b), button, shift, x, y)

method paint*(b: BarButton, c: Canvas) =
  let t = b.theme
  let r = b.clientRect
  let enabled = b.isEnabled
  var fg = if enabled: t.text else: t.textDisabled
  case b.kind
  of bkChip:
    if b.on:
      c.fillRoundRect(r, t.radius, t.accent.withAlpha(48))
      c.strokeRoundRect(r, t.radius, t.accent, 1)
      fg = t.accent
    elif b.fDown: c.fillRoundRect(r, t.radius, t.pressed)
    elif b.fHot: c.fillRoundRect(r, t.radius, t.hover)
  of bkText:
    let face = if not enabled: t.surfaceAlt elif b.fDown: t.pressed
               elif b.fHot: t.hover else: t.surface
    c.fillRoundRect(r, t.radius, face)
    c.strokeRoundRect(r, t.radius, t.border, 1)
  of bkIcon:
    if enabled and b.fDown: c.fillRoundRect(r, t.radius, t.pressed)
    elif enabled and b.fHot: c.fillRoundRect(r, t.radius, t.hover)
    fg = if enabled: t.textMuted else: t.textDisabled
    if enabled and (b.fHot or b.fDown): fg = t.text
  if b.glyph != nil: b.glyph(c, r, fg)
  elif b.caption.len > 0:
    c.textRect(b.caption, b.font, r, fg, taCenter, vaCenter)
  procCall paint(Control(b), c)

proc newBarButton(parent: Container, kind: BarButtonKind, caption: string,
                  glyph: GlyphDraw, hint: string, w = BtnW): BarButton =
  new result
  result.initControl(parent)
  result.kind = kind
  result.glyph = glyph
  result.setBounds(0, 0, w, RowH)
  result.caption = caption
  result.hint = hint
  result.cursor = crArrow
  parent.insertControl result

# --------------------------------------------------------------- BarEdit

method doKeyDown*(e: BarEdit, key: var Key, shift: ShiftState) =
  if e.keyHook != nil: e.keyHook(key, shift)
  if key == Key(0): return
  procCall doKeyDown(Edit(e), key, shift)

proc newBarEdit(parent: Container, placeholder: string): BarEdit =
  new result
  result.initEdit(parent)
  result.placeholder = placeholder
  result.setBounds(0, 0, FindW, RowH)
  parent.insertControl result

# --------------------------------------------------------------- FindBar

proc barHeight*(b: FindBar): float32 =
  2 * Shadow + 2 * Pad + RowH + (if b.fReplace: Gap + RowH else: 0'f32)

proc barWidth*(b: FindBar): float32 =
  2 * Shadow + 2 * Pad + BtnW + Gap + FindW + 3 * (ChipW + 1) + CounterW + 3 * BtnW + 3 * Gap

func replaceMode*(b: FindBar): bool = b.fReplace
func status*(b: FindBar): string = b.fStatus
func statusBad*(b: FindBar): bool = b.fBad

proc layoutBar(b: FindBar) =
  ## Places the children inside the card (alNone children, fixed offsets).
  let x0 = Shadow + Pad
  var y = Shadow + Pad
  b.expandBtn.setBounds(x0, y, BtnW, RowH)
  var x = x0 + BtnW + Gap
  b.findEdit.setBounds(x, y, FindW, RowH)
  x += FindW + Gap + 1
  for ch in [b.caseBtn, b.wordBtn, b.regexBtn]:
    ch.setBounds(x, y, ChipW, RowH)
    x += ChipW + 1
  x += CounterW
  b.prevBtn.setBounds(x, y, BtnW, RowH)
  b.nextBtn.setBounds(x + BtnW + Gap, y, BtnW, RowH)
  b.closeBtn.setBounds(x + 2 * (BtnW + Gap), y, BtnW, RowH)
  b.replaceEdit.visible = b.fReplace
  b.replaceBtn.visible = b.fReplace
  b.replaceAllBtn.visible = b.fReplace
  if b.fReplace:
    y += RowH + Gap
    b.replaceEdit.setBounds(x0 + BtnW + Gap, y, FindW, RowH)
    let rx = x0 + BtnW + Gap + FindW + Gap + 1
    b.replaceBtn.setBounds(rx, y, 64, RowH)
    b.replaceAllBtn.setBounds(rx + 64 + Gap, y, 40, RowH)
  b.expandBtn.glyph = glyphChevron(b.fReplace)

proc `replaceMode=`*(b: FindBar, v: bool) =
  if v == b.fReplace: return
  b.fReplace = v
  let w = b.barWidth
  b.setBounds(b.left + b.width - w, b.top, w, b.barHeight)
  b.layoutBar()
  b.invalidate()

proc setStatus*(b: FindBar, text: string, bad = false) =
  ## The counter ("3 of 12", "No results"); `bad` colours it and the field red.
  if text == b.fStatus and bad == b.fBad: return
  b.fStatus = text
  b.fBad = bad
  b.invalidate()

proc findText*(b: FindBar): string = b.findEdit.text
proc replaceText*(b: FindBar): string = b.replaceEdit.text

proc setFindText*(b: FindBar, s: string, report = false) =
  ## Sets the find field; `report` tells whether `onFindChange` fires.
  b.fQuiet = not report
  b.findEdit.text = s
  b.fQuiet = false

proc matchCase*(b: FindBar): bool = b.caseBtn.on
proc wholeWord*(b: FindBar): bool = b.wordBtn.on
proc useRegex*(b: FindBar): bool = b.regexBtn.on

proc toggleOption(b: FindBar, btn: BarButton) =
  btn.on = not btn.on
  btn.invalidate()
  if b.onOptionsChange != nil: b.onOptionsChange(b)

proc setOptions*(b: FindBar, matchCase, wholeWord, regex: bool) =
  b.caseBtn.on = matchCase
  b.wordBtn.on = wholeWord
  b.regexBtn.on = regex
  b.invalidate()

proc step(b: FindBar, forward: bool) =
  if b.onStep != nil: b.onStep(forward)

proc handleKey(b: FindBar, sender: BarEdit, key: var Key, shift: ShiftState) =
  let plain = shift * {ssCtrl, ssAlt} == {}
  if key == keyEscape and shift == {}:
    key = Key(0)
    if b.onClose != nil: b.onClose(b)
  elif key == keyEnter and plain:
    key = Key(0)
    if sender == b.replaceEdit:
      if b.onReplace != nil: b.onReplace(b)
    else: b.step(ssShift notin shift)
  elif key == keyEnter and ssCtrl in shift and sender == b.replaceEdit:
    key = Key(0)
    if b.onReplaceAll != nil: b.onReplaceAll(b)
  elif key == keyF3 and shift * {ssCtrl, ssAlt} == {}:
    key = Key(0)
    b.step(ssShift notin shift)
  elif ssAlt in shift and ssCtrl notin shift and key == 'c'.key:
    key = Key(0)
    b.toggleOption(b.caseBtn)
  elif ssAlt in shift and ssCtrl notin shift and key == 'w'.key:
    key = Key(0)
    b.toggleOption(b.wordBtn)
  elif ssAlt in shift and ssCtrl notin shift and key == 'r'.key:
    key = Key(0)
    b.toggleOption(b.regexBtn)

method paint*(b: FindBar, c: Canvas) =
  let t = b.theme
  let card = rectF(Shadow, Shadow, b.width - 2 * Shadow, b.height - 2 * Shadow)
  c.fillRoundRect(card.offset(0, 2).inflate(1), t.radius + 2, t.shadow.withAlpha(46))
  c.fillRoundRect(card, t.radius + 2, t.surfaceAlt)
  c.strokeRoundRect(card, t.radius + 2, t.borderStrong, 1)
  let lab = rectF(card.x + Pad + BtnW + Gap + FindW + Gap + 1 + 3 * (ChipW + 1),
                  card.y + Pad, CounterW, RowH)
  if b.fStatus.len > 0:
    c.textRect(b.fStatus, b.font.withSize(12), lab.inflate(-2, 0),
               if b.fBad: t.danger else: t.textMuted, taCenter, vaCenter)
  procCall paint(Container(b), c)

proc initFindBar*(b: FindBar, owner: Component = nil) =
  b.initContainer(owner)
  b.tabStop = false
  b.cursor = crArrow
  b.expandBtn = newBarButton(b, bkIcon, "", glyphChevron(false), "Toggle replace (Ctrl+H)")
  b.findEdit = newBarEdit(b, "Find")
  b.caseBtn = newBarButton(b, bkChip, "Aa", nil, "Match case (Alt+C)", ChipW)
  b.wordBtn = newBarButton(b, bkChip, "ab", nil, "Whole word (Alt+W)", ChipW)
  b.regexBtn = newBarButton(b, bkChip, ".*", nil, "Regular expression (Alt+R)", ChipW)
  b.prevBtn = newBarButton(b, bkIcon, "", glyphArrow(true), "Previous match (Shift+F3)")
  b.nextBtn = newBarButton(b, bkIcon, "", glyphArrow(false), "Next match (F3)")
  b.closeBtn = newBarButton(b, bkIcon, "", glyphClose, "Close (Esc)")
  b.replaceEdit = newBarEdit(b, "Replace")
  b.replaceBtn = newBarButton(b, bkText, "Replace", nil, "Replace (Enter)", 64)
  b.replaceAllBtn = newBarButton(b, bkText, "All", nil, "Replace all (Ctrl+Enter)", 40)
  let fb = b
  b.findEdit.keyHook = proc(key: var Key, shift: ShiftState) =
    fb.handleKey(fb.findEdit, key, shift)
  b.replaceEdit.keyHook = proc(key: var Key, shift: ShiftState) =
    fb.handleKey(fb.replaceEdit, key, shift)
  b.findEdit.onChange = proc(s: Control) =
    if not fb.fQuiet and fb.onFindChange != nil: fb.onFindChange(fb)
  b.expandBtn.onClick = proc(s: Control) = fb.replaceMode = not fb.fReplace
  b.caseBtn.onClick = proc(s: Control) = fb.toggleOption(fb.caseBtn)
  b.wordBtn.onClick = proc(s: Control) = fb.toggleOption(fb.wordBtn)
  b.regexBtn.onClick = proc(s: Control) = fb.toggleOption(fb.regexBtn)
  b.prevBtn.onClick = proc(s: Control) = fb.step(false)
  b.nextBtn.onClick = proc(s: Control) = fb.step(true)
  b.closeBtn.onClick = proc(s: Control) =
    if fb.onClose != nil: fb.onClose(fb)
  b.replaceBtn.onClick = proc(s: Control) =
    if fb.onReplace != nil: fb.onReplace(fb)
  b.replaceAllBtn.onClick = proc(s: Control) =
    if fb.onReplaceAll != nil: fb.onReplaceAll(fb)
  b.setBounds(0, 0, b.barWidth, b.barHeight)
  b.layoutBar()

proc newFindBar*(parent: Container = nil, left = 0'f32, top = 0'f32): FindBar {.discardable.} =
  new result
  result.initFindBar(parent)
  result.setBounds(left, top, result.barWidth, result.barHeight)
  if parent != nil: parent.insertControl result
