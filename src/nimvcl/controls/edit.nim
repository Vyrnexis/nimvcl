## `Edit`: a single-line text box (VCL TEdit).
##
## The text model lives in `editmodel.nim` (selection, undo, filters); this file
## adds drawing, mouse and keyboard handling, scrolling, the caret blink, IME
## composition and the clipboard.
##
## Geometry: the face fills the whole control (1 px border, ring painted inside
## it when focused); the text area is the face inset by the border and 6 px
## (2 px with `ebNone`). The text scrolls horizontally (`scrollOffset`) to keep
## the caret visible.
##
## Keys handled (all others, Tab, Enter, Esc, Up/Down included, are left alone):
## Left/Right/Home/End (Shift extends, Ctrl = word), Backspace/Delete (Ctrl =
## word), Ctrl+A/C/X/V/Z/Y, Ctrl+Shift+Z, Ctrl+Insert, Shift+Insert,
## Shift+Delete. Mouse: click, drag, Shift+click, double click (word), triple
## click (all); dragging outside the control keeps scrolling.
##
## IME: the uncommitted composition (`doTextEditing`) is drawn inline, underlined
## at the caret (replacing the selection visually) without touching the model;
## the commit arrives as text input. It is dropped when focus is lost.
##
## Indexes in the public API are byte indexes into the UTF-8 `text`.
##
## Programmatic editing: `insertText(s)` replaces the selection and
## `replaceRange(start, length, s)` replaces a byte range (both snap to
## characters, apply the model's filters, are one undo step and fire
## `onChange`); `text=` replaces everything and clears the undo history.

import std/[unicode, monotimes, times, math]
import ../graphics/[geometry, color, font, canvas, context]
import ../core/[types, control, theme, input, timer, form, application]
import ./editmodel, ./common
export editmodel.EditCharCase, editmodel.runeCount

type
  EditBorder* = enum ebSingle, ebNone

  Edit* = ref object of Control
    model: EditModel
    fPlaceholder: string
    fPasswordChar: Rune                ## Rune(0): not a password edit
    fBorderStyle: EditBorder
    fAutoSelect: bool
    fScroll: float32
    scrollDirty: bool
    caretOn: bool
    blink, dragTimer: Timer
    dragging: bool
    dragX: float32
    enterSelAt: MonoTime               ## when autoSelect last select-all'ed on focus
    keepSelPress: bool                 ## a press that focused an autoSelect edit keeps select-all
    pressX: float32
    composition: string
    compCursor, compSelEnd: int        ## bytes inside `composition`
    lastDblAt: MonoTime
    lastDblX: float32
    onChange*: NotifyEvent

  Shown = object
    ## What is drawn: the masked/composed text plus indexes into it.
    text: string
    selA, selB: int
    caret: int
    compA, compB: int
    compSelA, compSelB: int

const
  BlinkMs = 530
  DragScrollMs = 45
  TextPad = 6'f32
  TextPadNoBorder = 2'f32
  DefaultPasswordChar = Rune(0x2022)

var
  editClipboardGet*: proc(): string = proc(): string = Application.clipboard
  editClipboardSet*: proc(s: string) = proc(s: string) = Application.clipboard = s
    ## The clipboard Edit uses; tests replace them.

# ----------------------------------------------------------------- helpers

func isPassword*(e: Edit): bool = e.fPasswordChar != Rune(0)

proc canMeasureText(e: Edit): bool = e.canMeasure

proc textWidth(e: Edit, s: string): float32 =
  ## Logical width of `s`.
  if s.len == 0: return 0
  if e.canMeasureText:
    let ctx = e.renderCtx
    return ctx.measureDevice(s, e.font).w / ctx.scale
  float32(runeCount(s)) * e.font.size * 0.55'f32

proc lineHeight(e: Edit): float32 =
  if e.canMeasureText: e.renderCtx.fontMetrics(e.font).lineHeight
  else: e.font.size * 1.25'f32

func padX(e: Edit): float32 =
  if e.fBorderStyle == ebNone: TextPadNoBorder else: TextPad

proc borderW(e: Edit): float32 =
  if e.fBorderStyle == ebNone: 0'f32 else: e.theme.borderWidth

proc textArea(e: Edit): RectF =
  ## The area text is drawn in and clipped to (control client coordinates).
  let b = e.borderW
  let px = e.padX
  rectF(b + px, b, max(e.width - 2 * (b + px), 0), max(e.height - 2 * b, 0))

proc shown(e: Edit): Shown =
  let m = e.model
  let masked = e.isPassword
  let base = if masked: m.displayText(e.fPasswordChar) else: m.text
  template disp(i: int): int =
    (if masked: m.toDisplayIndex(i, e.fPasswordChar) else: i)
  if e.composition.len > 0:
    let a = disp(m.selStart)
    let b = disp(m.selEnd)
    result.text = base[0 ..< a] & e.composition & base[b .. ^1]
    result.selA = a
    result.selB = a
    result.compA = a
    result.compB = a + e.composition.len
    result.compSelA = a + e.compCursor
    result.compSelB = a + e.compSelEnd
    result.caret = result.compSelA
  else:
    result.text = base
    result.selA = disp(m.selStart)
    result.selB = disp(m.selEnd)
    result.caret = disp(m.caret)
    result.compA = result.caret
    result.compB = result.caret
    result.compSelA = result.caret
    result.compSelB = result.caret

proc caretX(e: Edit, sh: Shown): float32 =
  ## Caret x relative to the text origin (scroll not applied).
  e.textWidth(sh.text[0 ..< sh.caret])

proc updateScroll(e: Edit) =
  ## Scrolls just enough to keep the caret visible (with a margin) and clamps
  ## the offset so the text never leaves a gap at the right.
  if not e.canMeasureText:
    e.scrollDirty = true
    return
  e.scrollDirty = false
  let ta = e.textArea
  if ta.w <= 0: return
  let sh = e.shown
  let cx = e.caretX(sh)
  let tw = e.textWidth(sh.text)
  let m = min(12'f32, ta.w / 4)
  var s = e.fScroll
  if cx - s < m: s = cx - m
  elif cx - s > ta.w - m: s = cx - ta.w + m
  s = clamp(s, 0'f32, max(0'f32, tw + 1 - ta.w))
  if s != e.fScroll:
    e.fScroll = s
    e.invalidate()

proc indexAtX(e: Edit, s: string, x: float32): int =
  ## Byte index in `s` of the caret slot nearest to `x` (relative to the text
  ## origin, logical px). Always on a rune boundary.
  if x <= 0 or s.len == 0: return 0
  if not e.canMeasureText:
    let per = max(e.font.size * 0.55'f32, 1'f32)
    var n = 0
    var i = 0
    while i < s.len and float32(n) + 0.5 < x / per:
      i = nextBoundary(s, i)
      inc n
    return i
  let ctx = e.renderCtx
  let xd = x * ctx.scale
  let n = snapIndex(s, ctx.fitPrefix(s, e.font, xd))
  if n >= s.len: return s.len
  let n2 = nextBoundary(s, n)
  let w1 = ctx.measureDevice(s[0 ..< n], e.font).w
  let w2 = ctx.measureDevice(s[0 ..< n2], e.font).w
  if xd - w1 < w2 - xd: n else: n2

proc modelIndexAt(e: Edit, x: float32): int =
  ## Model byte index for a client x (composition ignored).
  let m = e.model
  let ta = e.textArea
  let rel = x - ta.x + e.fScroll
  if e.isPassword:
    let d = e.indexAtX(m.displayText(e.fPasswordChar), rel)
    m.toModelIndex(d, e.fPasswordChar)
  else:
    e.indexAtX(m.text, rel)

proc updateIme(e: Edit) =
  if e.focused:
    let h = e.host
    if h of UiRoot: UiRoot(h).updateTextInput()

proc resetBlink(e: Edit) =
  e.caretOn = true
  if e.blink != nil and e.blink.enabled:
    e.blink.enabled = false
    e.blink.enabled = true

proc touched(e: Edit) =
  ## Text, selection, composition or size changed.
  e.resetBlink()
  e.updateScroll()
  e.updateIme()
  e.invalidate()

proc stopDrag(e: Edit) =
  e.dragging = false
  if e.dragTimer != nil: e.dragTimer.enabled = false

# ------------------------------------------------------------ construction

proc initEdit*(e: Edit, owner: Component = nil) =
  e.initControl(owner)
  e.model = newEditModel()
  e.fBorderStyle = ebSingle
  e.tabStop = true
  e.cursor = crIBeam
  e.setBounds(0, 0, 121, currentTheme().controlHeight)
  e.model.onChange = proc() =
    e.touched()
    if e.onChange != nil: e.onChange(e)

proc newEdit*(parent: Container = nil, text = "", left = 0'f32, top = 0'f32,
              width = -1'f32, height = -1'f32): Edit {.discardable.} =
  ## `parent` (also the owner) gets the control appended when non-nil.
  new result
  result.initEdit(parent)
  if text.len > 0: result.model.setText(text)
  placeControl(result, parent, left, top, width, height)

# -------------------------------------------------------------- properties

proc text*(e: Edit): string = e.model.text
proc `text=`*(e: Edit, v: string) =
  ## Replaces the text (caret to the end, undo history cleared). Fires
  ## `onChange` when the text differs.
  e.model.setText(v)
  e.touched()

proc placeholder*(e: Edit): string = e.fPlaceholder
proc `placeholder=`*(e: Edit, v: string) =
  if v == e.fPlaceholder: return
  e.fPlaceholder = v
  e.invalidate()
proc textHint*(e: Edit): string = e.fPlaceholder
proc `textHint=`*(e: Edit, v: string) = e.placeholder = v

proc passwordChar*(e: Edit): Rune = e.fPasswordChar
proc `passwordChar=`*(e: Edit, c: Rune) =
  ## The masking character; Rune(0) turns masking off.
  if c == e.fPasswordChar: return
  e.fPasswordChar = c
  e.touched()
proc `passwordChar=`*(e: Edit, c: char) = e.passwordChar = Rune(ord(c))
proc password*(e: Edit): bool = e.isPassword
proc `password=`*(e: Edit, v: bool) =
  ## `true` masks with a bullet.
  e.passwordChar = if v: DefaultPasswordChar else: Rune(0)

proc readOnly*(e: Edit): bool = e.model.readOnly
proc `readOnly=`*(e: Edit, v: bool) =
  if v == e.model.readOnly: return
  e.model.readOnly = v
  if v: e.composition = ""
  e.updateIme()
  e.invalidate()

proc maxLength*(e: Edit): int = e.model.maxLength
proc `maxLength=`*(e: Edit, v: int) = e.model.maxLength = v
proc charCase*(e: Edit): EditCharCase = e.model.charCase
proc `charCase=`*(e: Edit, v: EditCharCase) = e.model.charCase = v
proc numbersOnly*(e: Edit): bool = e.model.numbersOnly
proc `numbersOnly=`*(e: Edit, v: bool) = e.model.numbersOnly = v

proc autoSelect*(e: Edit): bool = e.fAutoSelect
proc `autoSelect=`*(e: Edit, v: bool) = e.fAutoSelect = v

proc borderStyle*(e: Edit): EditBorder = e.fBorderStyle
proc `borderStyle=`*(e: Edit, v: EditBorder) =
  ## ebSingle (default) or ebNone.
  let nv = v
  if nv == e.fBorderStyle: return
  e.fBorderStyle = nv
  e.touched()

proc selStart*(e: Edit): int = e.model.selStart
proc `selStart=`*(e: Edit, v: int) = e.model.selStart = v; e.touched()
proc selLength*(e: Edit): int = e.model.selLength
proc `selLength=`*(e: Edit, v: int) = e.model.selLength = v; e.touched()
proc selText*(e: Edit): string = e.model.selectedText
proc caretPos*(e: Edit): int = e.model.caret
proc `caretPos=`*(e: Edit, v: int) = e.model.setCaret(v); e.touched()
proc select*(e: Edit, start, length: int) = e.model.select(start, length); e.touched()
proc selectAll*(e: Edit) = e.model.selectAll(); e.touched()
proc clearSelection*(e: Edit) = e.model.setCaret(e.model.caret); e.touched()
proc clear*(e: Edit) = e.model.clear()

proc canUndo*(e: Edit): bool = e.model.canUndo
proc canRedo*(e: Edit): bool = e.model.canRedo
proc undo*(e: Edit): bool {.discardable.} = e.model.undo()
proc redo*(e: Edit): bool {.discardable.} = e.model.redo()

proc insertText*(e: Edit, s: string): bool {.discardable.} =
  ## Replaces the selection with `s` (caret after it) as one undo step, with the
  ## model's filters (`numbersOnly`, `charCase`, `maxLength`). Fires `onChange`.
  ## Returns false when nothing changed (read-only, everything filtered out).
  e.model.insert(s)

proc replaceRange*(e: Edit, start, length: int, s: string): bool {.discardable.} =
  ## Replaces `length` bytes from `start` (snapped to characters) with `s`; the
  ## caret ends after the new text. `length` 0 inserts, empty `s` deletes.
  ## When nothing changes (filters reject the text, read-only) the previous
  ## selection is restored.
  let m = e.model
  let (a0, c0) = (m.anchor, m.caret)
  m.select(start, length)
  result = if s.len == 0: m.deleteSelection() else: m.insert(s)
  if not result:
    m.setCaret(a0)
    m.setCaret(c0, extend = true)
    e.touched()

proc copyToClipboard*(e: Edit) =
  ## Copies the selection (never for password edits).
  if e.isPassword or not e.model.hasSelection: return
  editClipboardSet(e.model.selectedText)

proc cutToClipboard*(e: Edit) =
  if e.isPassword or e.readOnly or not e.model.hasSelection: return
  editClipboardSet(e.model.selectedText)
  discard e.model.deleteSelection()

proc pasteFromClipboard*(e: Edit) =
  ## Inserts the clipboard text; line breaks and tabs become spaces (the
  ## single-line model drops other control characters).
  if e.readOnly: return
  var s = editClipboardGet()
  if s.len == 0: return
  var t = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] in {'\r', '\n', '\t'}:
      if s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n': inc i
      t.add ' '
    else: t.add s[i]
    inc i
  discard e.model.insert(t)

# --------------------------------------------------------------- state queries

proc scrollOffset*(e: Edit): float32 =
  ## Horizontal scroll of the text, in logical px.
  if e.scrollDirty: e.updateScroll()
  e.fScroll

proc isComposing*(e: Edit): bool = e.composition.len > 0
proc compositionText*(e: Edit): string = e.composition
proc showsPlaceholder*(e: Edit): bool =
  ## The placeholder is drawn: empty text, no composition, a placeholder set.
  e.model.text.len == 0 and e.composition.len == 0 and e.fPlaceholder.len > 0
proc caretVisible*(e: Edit): bool =
  ## The caret is drawn right now (focused, window active, blink phase on).
  let h = e.host
  e.caretOn and e.focused and e.isEnabled and
    not (h of UiRoot and UiRoot(h).windowInactive)

proc caretRect*(e: Edit): RectF =
  ## The caret in client coordinates (1 px wide, one text line tall).
  let ta = e.textArea
  let sh = e.shown
  let lh = e.lineHeight
  let x = ta.x - e.scrollOffset + e.caretX(sh)
  rectF(x, ta.y + floor((ta.h - lh) / 2), 1, lh)

proc caretPixelX*(e: Edit): float32 = e.caretRect.x

proc indexAtPoint*(e: Edit, x: float32): int =
  ## Model byte index a click at client x would put the caret on.
  e.modelIndexAt(x)

# ------------------------------------------------------------------ methods

method canFocus*(e: Edit): bool = e.isVisible and e.isEnabled
method wantsTextInput*(e: Edit): bool = not e.model.readOnly
method textInputRect*(e: Edit): RectF = e.caretRect

method preferredSize*(e: Edit): SizeF =
  if not e.canMeasureText: return sizeF(e.width, e.height)
  let t = e.theme
  let pad = if e.fBorderStyle == ebNone: 2'f32 else: t.borderWidth + 4
  sizeF(e.width, ceil(e.lineHeight) + 2 * pad)

method doResize*(e: Edit) =
  procCall doResize(Control(e))
  e.updateScroll()

method doEnter*(e: Edit) =
  procCall doEnter(Control(e))
  if e.blink == nil:
    e.blink = newTimer(nil, BlinkMs)
    e.blink.onTimer = proc(t: Timer) =
      let h = e.host
      if not e.isShowing:          # hidden form: no blinking, no repaints
        t.enabled = false
        return
      if not e.focused or (h of UiRoot and UiRoot(h).windowInactive): return
      e.caretOn = not e.caretOn
      e.invalidate()
  e.caretOn = true
  e.blink.enabled = e.isShowing
  e.keepSelPress = false
  e.enterSelAt = MonoTime()
  if e.fAutoSelect and e.model.len > 0:
    e.model.selectAll()
    e.enterSelAt = getMonoTime()   # a press focuses first, then calls doMouseDown
  e.touched()

method visibilityChanged*(e: Edit) =
  procCall visibilityChanged(Control(e))
  if e.blink != nil and e.focused:
    e.blink.enabled = e.isShowing
    if e.isShowing: e.resetBlink()

method doExit*(e: Edit) =
  e.composition = ""
  e.stopDrag()
  e.keepSelPress = false
  if e.blink != nil: e.blink.enabled = false
  e.caretOn = false
  procCall doExit(Control(e))
  e.invalidate()

method doMouseEnter*(e: Edit) =
  procCall doMouseEnter(Control(e))
  e.invalidate()

method doMouseLeave*(e: Edit) =
  procCall doMouseLeave(Control(e))
  e.invalidate()

method doMouseDown*(e: Edit, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  procCall doMouseDown(Control(e), button, shift, x, y)
  if button != mbLeft or e.composition.len > 0: return
  let m = e.model
  let now = getMonoTime()
  e.keepSelPress = e.fAutoSelect and ssDouble notin shift and e.enterSelAt != MonoTime() and
                   (now - e.enterSelAt).inMilliseconds < 100
  e.enterSelAt = MonoTime()
  if e.keepSelPress:
    # this press focused an autoSelect edit: keep the select-all unless the
    # mouse drags (see doMouseMove)
    e.pressX = x
    e.dragging = true
    e.dragX = x
    e.touched()
    return
  if ssDouble in shift:
    if e.isPassword: m.selectAll() else: m.selectWord(e.modelIndexAt(x))
    e.lastDblAt = now
    e.lastDblX = x
    e.stopDrag()
  elif (now - e.lastDblAt).inMilliseconds < 600 and abs(x - e.lastDblX) <= 4:
    m.selectAll()                      # third click of a triple click
    e.lastDblAt = MonoTime()
    e.stopDrag()
  else:
    let idx = e.modelIndexAt(x)
    m.setCaret(idx, extend = ssShift in shift)
    e.dragging = true
    e.dragX = x
  e.touched()

method doMouseMove*(e: Edit, shift: ShiftState, x, y: float32) =
  procCall doMouseMove(Control(e), shift, x, y)
  if not e.dragging: return
  if ssLeft notin shift:
    e.stopDrag()
    return
  e.dragX = x
  if e.keepSelPress:
    if abs(x - e.pressX) < 3: return
    e.keepSelPress = false
    e.model.setCaret(e.modelIndexAt(e.pressX))   # a real drag starts at the press point
  let ta = e.textArea
  let outside = x < ta.x or x > ta.right
  e.model.setCaret(e.modelIndexAt(x), extend = true)
  if outside:
    if e.dragTimer == nil:
      e.dragTimer = newTimer(nil, DragScrollMs)
      e.dragTimer.onTimer = proc(t: Timer) =
        if not e.dragging: return
        let ta = e.textArea
        let m = e.model
        if e.dragX < ta.x: m.setCaret(m.prevRune(m.caret), extend = true)
        elif e.dragX > ta.right: m.setCaret(m.nextRune(m.caret), extend = true)
        e.touched()
    e.dragTimer.enabled = true
  elif e.dragTimer != nil:
    e.dragTimer.enabled = false
  e.touched()

method doMouseUp*(e: Edit, button: MouseButton, shift: ShiftState, x, y: float32) =
  procCall doMouseUp(Control(e), button, shift, x, y)
  if button == mbLeft:
    e.keepSelPress = false
    e.stopDrag()

method doKeyDown*(e: Edit, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(e), key, shift)
  if key == Key(0): return
  let m = e.model
  let ctrl = ssCtrl in shift
  let shf = ssShift in shift
  if ssAlt in shift or ssSuper in shift: return
  var handled = true
  if key == keyLeft:
    if ctrl: m.moveWordLeft(shf) else: m.moveLeft(shf)
  elif key == keyRight:
    if ctrl: m.moveWordRight(shf) else: m.moveRight(shf)
  elif key == keyHome: m.moveHome(shf)
  elif key == keyEnd: m.moveEnd(shf)
  elif key == keyBackspace: discard m.deleteBackward(word = ctrl)
  elif key == keyDelete:
    if shf and not ctrl: e.cutToClipboard()
    else: discard m.deleteForward(word = ctrl)
  elif key == keyInsert:
    if ctrl and not shf: e.copyToClipboard()
    elif shf and not ctrl: e.pasteFromClipboard()
    else: handled = false
  elif ctrl and key == 'a'.key: m.selectAll()
  elif ctrl and key == 'c'.key: e.copyToClipboard()
  elif ctrl and key == 'x'.key: e.cutToClipboard()
  elif ctrl and key == 'v'.key: e.pasteFromClipboard()
  elif ctrl and key == 'z'.key:
    if shf: discard m.redo() else: discard m.undo()
  elif ctrl and key == 'y'.key: discard m.redo()
  else: handled = false
  if handled:
    key = Key(0)
    e.touched()

method doKeyPress*(e: Edit, text: var string) =
  procCall doKeyPress(Control(e), text)
  let had = e.composition.len > 0
  e.composition = ""
  if text.len > 0 and not e.readOnly: discard e.model.insert(text)
  if had: e.touched()

method doTextEditing*(e: Edit, text: string, cursor, selLen: int) =
  if e.readOnly: return
  e.composition = text
  if text.len > 0:
    let n = runeCount(text)
    let c = if cursor < 0: n else: min(cursor, n)
    let s = min(c + max(selLen, 0), n)
    template byteOf(k: int): int =
      block:
        var b = 0
        for _ in 0 ..< k: b = nextBoundary(text, b)
        b
    e.compCursor = byteOf(c)
    e.compSelEnd = byteOf(s)
  e.touched()

# --------------------------------------------------------------------- paint

proc underline(c: Canvas, x0, x1, baseline: float32, thick: float32, col: Color) =
  let s = c.scale
  let h = max(round(thick * s), 1'f32) / s
  c.fillRect(rectF(x0, baseline, max(x1 - x0, 0), h), col)

method paint*(e: Edit, c: Canvas) =
  let t = e.theme
  let enabled = e.isEnabled
  let foc = e.focused
  let r = e.clientRect
  let bg = if enabled: t.surface else: t.surfaceAlt
  let hot = e.host of UiRoot and UiRoot(e.host).hovered == Control(e)
  let single = e.fBorderStyle == ebSingle
  if single:
    let bc =
      if not enabled: t.border
      elif foc: t.accent
      elif hot: t.borderStrong
      else: t.border
    c.fillRoundRect(r, t.radius, bg)
    c.strokeRoundRect(r, t.radius, bc, t.borderWidth)
  else:
    c.fillRect(r, bg)

  let ta = e.textArea
  let font = e.font
  let fm = c.fontMetrics(font)
  let lh = fm.lineHeight
  let ty = ta.y + floor((ta.h - lh) / 2)
  let tx = ta.x - e.scrollOffset
  let textCol = if enabled: t.text else: t.textDisabled
  c.pushClip(ta)

  let sh = e.shown
  if e.showsPlaceholder:
    c.drawText(e.fPlaceholder, font, ta.x, ty, if enabled: t.textMuted else: t.textDisabled)
  elif sh.text.len > 0:
    template xOf(i: int): float32 = tx + e.textWidth(sh.text[0 ..< i])
    if foc and enabled and sh.selA != sh.selB:
      let x0 = xOf(sh.selA)
      let x1 = xOf(sh.selB)
      c.fillRect(rectF(x0, ty, x1 - x0, lh), t.selection)
      c.drawText(sh.text[0 ..< sh.selA], font, tx, ty, textCol)
      c.drawText(sh.text[sh.selA ..< sh.selB], font, x0, ty, t.selectionText)
      c.drawText(sh.text[sh.selB .. ^1], font, x1, ty, textCol)
    else:
      c.drawText(sh.text, font, tx, ty, textCol)
    if sh.compA != sh.compB:
      let base = ty + fm.ascent + 1.5'f32
      let a = xOf(sh.compA)
      let b = xOf(sh.compB)
      underline(c, a, b, base, 1, textCol)
      if sh.compSelA != sh.compSelB:
        underline(c, xOf(sh.compSelA), xOf(sh.compSelB), base, 2, t.accent)

  if e.caretVisible:
    let s = c.scale
    let cw = max(round(s), 1'f32) / s
    let cx = floor((tx + e.textWidth(sh.text[0 ..< sh.caret])) * s) / s
    c.fillRect(rectF(cx, ty, cw, lh), t.text)
  c.popClip()

  if foc and enabled and single:
    drawFocusRing(c, r, t)
