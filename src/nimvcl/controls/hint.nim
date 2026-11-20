## Hints (tooltips): `Control.hint` shown in a small popup window after the
## mouse rests on a control.
##
## * `Application.showHint` (default true) turns them off globally;
##   `Application.hintPause` (default 600 ms) is the rest time before the first
##   hint; moving more than a few pixels, or onto another control, restarts it.
## * After a hint was visible, the next one for another control comes after
##   `hintShortPause` (100 ms) when it is requested within `hintRecentWindow`
##   (1000 ms) of the previous one being hidden.
## * A hint hides when the mouse leaves its control, on a click, wheel or key
##   press, when the window loses focus, and never shows while a menu is open.
## * The hint text is `hint` of the control under the mouse, else of its
##   nearest ancestor that has one.
##
## It works from `Application.addEventObserver` (no changes to the input
## router) and a `Timer`; importing this module is enough to enable it.
## Fonts and colours come from the form's theme (`tooltipBg`, `tooltipText`,
## `tooltipBorder`).

import std/[monotimes, times, strutils]
import ../graphics/context
import ../platform/[events, window]
import ../core/[form, popup, application, timer]
import ./common

type
  HintPanel* = ref object of Container
    text*: string
    wrapped*: bool           ## text is wrapped at the max width (else drawn line by line)

var
  gShowHint = true
  gHintPause = 600
  gHintShortPause* = 100          ## ms, after a recent hint
  gHintRecentWindow* = 1000       ## ms
  gHintMaxWidth* = 360'f32
  gTimer: Timer
  gForm: Form
  gCtrl: Control
  gAnchor, gMouse: PointF
  gPopup: PopupWindow
  gHiddenAt: MonoTime
  gHasHidden: bool
  gHasFallback: bool
  gFallbackAt: MonoTime
  hintLeaveHidesFallback* = false
    ## Where the video driver has no popup windows (SDL offscreen) the hint is a
    ## top-level window; showing it makes SDL report mouse-leave / focus-lost for
    ## the owner, which must not hide it. Tests set this to true to check leaving.

proc showHint*(a: TApplication): bool = gShowHint
proc `showHint=`*(a: TApplication, v: bool) =
  gShowHint = v
proc hintPause*(a: TApplication): int = gHintPause
proc `hintPause=`*(a: TApplication, ms: int) = gHintPause = max(ms, 0)

proc hintFor*(c: Control): string =
  ## Text a hint over `c` would show ("" when none).
  var x = c
  while x != nil:
    if x.hint.len > 0: return x.hint
    x = Control(x.parent)

proc hintTarget(f: Form, p: PointF): Control =
  ## The control a hint belongs to: the hovered one, except that a DISABLED
  ## control under the mouse (which never gets hover) wins when it has its own
  ## hint.
  result = f.ui.hovered
  # a hovered leaf with a hint of its own is the target: no second hit test
  if result != nil and result.hint.len > 0 and not (result of Container): return
  let d = f.ui.root.controlAtPoint(p, includeDisabled = true)
  if d != nil and d != result and not d.isEnabled and d.hint.len > 0: result = d

proc hintVisible*(): bool = gPopup != nil and gPopup.isOpen
proc hintForm*(): Form =
  ## The form of the pending or visible hint (nil when there is none; cleared on
  ## hide and when the form closes, so a closed form is never kept alive).
  gForm

proc hintText*(): string =
  ## Text of the visible hint ("" when none).
  if hintVisible(): HintPanel(gPopup.content).text else: ""

proc stopTimer() =
  if gTimer != nil: gTimer.enabled = false

proc hideHint*() =
  ## Hides the hint and cancels a pending one.
  stopTimer()
  gCtrl = nil
  gForm = nil          # never keep a (possibly closed) form alive
  if gPopup != nil:
    let p = gPopup
    gPopup = nil
    if p.isOpen:
      closePopup(p)
      gHiddenAt = getMonoTime()
      gHasHidden = true

method paint*(h: HintPanel, c: Canvas) =
  let t = h.theme
  c.fillRect(h.clientRect, t.tooltipBg)
  c.frameRect(h.clientRect, t.tooltipBorder, 1)
  let r = h.clientRect.inflate(-6)
  if h.wrapped:
    c.textRect(h.text, h.font, r, t.tooltipText, taLeft, vaCenter, wrap = true)
  else:
    # explicit newlines only; SDL_ttf's word wrap can break a line that fits
    let lines = h.text.split('\n')
    let lh = r.h / float32(lines.len)
    for i, ln in lines:
      c.textRect(ln, h.font, rectF(r.x, r.y + lh * float32(i), r.w + 4, lh), t.tooltipText,
                 taLeft, vaCenter)

proc showNow() =
  if gForm == nil or gCtrl == nil or not gForm.visible or not gForm.hasWindow: return
  let text = hintFor(gCtrl)
  if text.len == 0 or topPopup(gForm) != nil: return
  let ctx = gForm.ctx
  let h = HintPanel(text: text)
  h.initContainer()
  h.font = Control(gForm).font
  let f = h.font
  var w = 120'f32
  var ht = 20'f32
  if ctx != nil and not ctx.isClosed:
    let maxPx = (gHintMaxWidth - 12) * ctx.scale
    var (tw, th) = ctx.measureDevice(text, f)          # natural size (explicit newlines kept)
    if tw > maxPx:
      h.wrapped = true
      let r = ctx.measureDevice(text, f, int(maxPx))
      tw = r[0]
      th = r[1]
    w = tw / ctx.scale
    ht = th / ctx.scale
  h.setBounds(0, 0, ceil(w) + 14, ceil(ht) + 9)
  let anchor = rectF(gMouse.x, gMouse.y - 2, 1, 22)
  try:
    gPopup = showPopup(gForm, h, anchor, plBelow, pkTooltip)
  except CatchableError:
    gPopup = nil
  if gPopup != nil:
    if gPopup.ui.win != nil and gPopup.ui.win.popupFallback:
      gHasFallback = true
      gFallbackAt = getMonoTime()
    gPopup.onClosed = proc(q: PopupWindow) =
      if gPopup == q: gPopup = nil

proc startTimer(ms: int) =
  if gTimer == nil:
    gTimer = newTimer(nil, ms)
    gTimer.onTimer = proc(t: Timer) =
      t.enabled = false
      if gForm != nil and gCtrl != nil and hintTarget(gForm, gMouse) == gCtrl: showNow()
  gTimer.enabled = false
  gTimer.interval = max(ms, 1)
  gTimer.enabled = true

proc recentlyHidden(): bool =
  gHasHidden and (getMonoTime() - gHiddenAt).inMilliseconds < gHintRecentWindow.int64

proc hintObserver(f: Form, pe: PlatformEvent) =
  if f == nil: return
  case pe.kind
  of ekMouseMove:
    if not f.hasWindow or pe.windowId != f.win.id:
      hideHint()
      return
    if not gShowHint:             # hints off: no hit test at all
      hideHint()
      return
    let p = pointF(f.win.toLogical(pe.x), f.win.toLogical(pe.y))
    let c = hintTarget(f, p)
    let text = if c == nil: "" else: hintFor(c)
    if text.len == 0 or topPopup(f) != nil:
      hideHint()
      return
    gMouse = p
    if hintVisible():
      if c == gCtrl: return
      hideHint()
    let moved = abs(p.x - gAnchor.x) > 6 or abs(p.y - gAnchor.y) > 6
    if c != gCtrl or f != gForm or moved:
      gCtrl = c
      gForm = f
      gAnchor = p
      startTimer(if recentlyHidden(): gHintShortPause else: gHintPause)
  of ekMouseDown, ekMouseWheel, ekKeyDown, ekWindowMouseLeave, ekWindowFocusLost,
     ekWindowClose, ekTextInput:
    if pe.kind in {ekWindowMouseLeave, ekWindowFocusLost} and gHasFallback and
       not hintLeaveHidesFallback and
       (getMonoTime() - gFallbackAt).inMilliseconds < 500:
      return
    if pe.kind == ekWindowMouseLeave and f.hasWindow and pe.windowId != f.win.id:
      return
    hideHint()
  else: discard

Application.addEventObserver(hintObserver)

# Form.close()/freeWindow() called from code send no platform event: drop the
# hint (and with it the reference to the form) once its form is gone.
Application.addIdleHook("hint", proc() =
  if gForm != nil and not (gForm.visible and gForm.hasWindow): hideHint())
