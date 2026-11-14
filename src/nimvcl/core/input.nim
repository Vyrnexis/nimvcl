## `UiRoot`: the input router and frame painter shared by `Form` (one per
## window) and `Host` (embedding into an existing SDL3 app).
##
## It is the `RootHost` of a control tree: it owns hover, mouse capture and
## keyboard focus state, turns `PlatformEvent`s into `doXxx` calls, tracks the
## dirty flag, and paints the tree through a `RenderContext`.
##
## Mouse: events are hit-tested with `controlAtPoint`; hover enter/leave go to
## the hovered control only (VCL style). A button press captures the pointer:
## until every button is up, moves and the release go to the pressed control
## (coordinates in its client space). `doClick` fires when the left button is
## released over the control it went down on. A double click (SDL clicks == 2)
## calls `doDblClick` after `doMouseDown` (`ssDouble` set). Wheel goes to the
## target and bubbles up the parents until `handled`. `dx`/`dy` are in wheel
## notches (SDL precise values, fractional on touchpads; dy > 0 = away from the
## user = scroll up). A scroller sets `handled` only when it actually moved, so
## a wheel over a list that is already at its limit keeps bubbling to the
## enclosing ScrollBox.
##
## Focus: when focus moves to a control (keyboard, `setFocus`; not a mouse
## press) every ancestor gets `revealControl` so scrolling containers can bring
## it into view.
##
## Keyboard: key events go to the focused control (or the root when none);
## they do not bubble. With `keyPreview` the root sees them first. Unhandled
## Tab / Shift+Tab move focus; anything still unhandled reaches
## `onUnhandledKey` (the application's own hook), then the key-handler chain
## (`addKeyHandler`: default/cancel buttons, menu shortcuts, PageControl
## Ctrl+Tab, ... in registration order; forms and hosts share it), then
## Alt+letter mnemonics (`&` captions). Menu bar mnemonics are in the chain, so
## they win over control mnemonics.
##
## Alt: `altHeld` follows the Alt key events (cleared on focus loss) and
## repaints the tree when it changes, so captions can underline their mnemonic.

import std/[algorithm, strutils]
import ../graphics/[geometry, context, canvas]
import ../platform/[window, events, cursors]
import ./types, ./control, ./layout

type
  KeyHook* = proc(key: var Key, shift: ShiftState)
    ## A handler for keys no control used. Sets `key` to `Key(0)` to consume it.

  UiRoot* = ref object of RootHost
    root*: Container
    win*: PlatformWindow
    ctx*: RenderContext
    dirty*: bool                 ## a repaint is needed
    keyPreview*: bool
    rootGetsMouse*: bool         ## the root itself is a mouse target (Form: true)
    autoSizeRoot*: bool          ## window size changes resize the root
    onUnhandledKey*: KeyHook     ## the application's own hook; runs before the chain
    fKeyHandlers: seq[tuple[id: string, hook: KeyHook]]
    fAlt: bool                   ## an Alt key is down (mnemonic underlines)
    windowInactive*: bool        ## the window lost focus (set by the Form)
    revealOnFocus*: bool         ## focus changes scroll the control into view
                                 ## (default true; off while a mouse press focuses)
    fHovered, fCaptured, fFocused, fPressed: Control
    buttons: set[MouseButton]
    lastPos: PointF
    mouseInside: bool
    hoverStale: bool
    cursorApplied: bool

func altHeld*(ui: UiRoot): bool = ui.fAlt

proc newUiRoot*(root: Container): UiRoot =
  result = UiRoot(root: root, dirty: true, revealOnFocus: true)
  root.host = result

func hovered*(ui: UiRoot): Control = ui.fHovered
func captured*(ui: UiRoot): Control = ui.fCaptured
func focusedControl*(ui: UiRoot): Control = ui.fFocused

func inside(a, b: Control): bool =
  ## `b` is `a` or one of its descendants.
  b != nil and (a == b or a.isAncestorOf(b))

# --------------------------------------------------------------- RootHost

method invalidate*(ui: UiRoot, r: RectF) = ui.dirty = true
method requestLayout*(ui: UiRoot) = ui.dirty = true

proc effectiveCursor(c: Control): Cursor =
  var x = c
  while x != nil:
    if x.cursor != crDefault: return x.cursor
    x = Control(x.parent)
  crArrow

proc updateCursor(ui: UiRoot) =
  if ui.win == nil: return
  if ui.fHovered != nil:
    setCursorShape(effectiveCursor(ui.fHovered))
    ui.cursorApplied = true
  elif ui.cursorApplied:
    setCursorShape(crArrow)
    ui.cursorApplied = false

method scrollChanged*(ui: UiRoot, c: Container) =
  ui.hoverStale = true
  ui.dirty = true

method cursorChanged*(ui: UiRoot, c: Control) =
  if ui.fHovered != nil and inside(c, ui.fHovered): ui.updateCursor()

proc updateTextInput*(ui: UiRoot) =
  ## Starts/stops SDL text input for the focused control and positions the IME
  ## area. Controls call this when their `textInputRect` moves.
  if ui.win == nil or ui.win.window == nil: return
  let f = ui.fFocused
  if f != nil and f.wantsTextInput():
    ui.win.startTextInput()
    ui.win.setTextInputArea(f.clientToForm(f.textInputRect()))
  else:
    ui.win.stopTextInput()

proc setHover(ui: UiRoot, c: Control) =
  if c == ui.fHovered: return
  let old = ui.fHovered
  ui.fHovered = c
  if old != nil: old.doMouseLeave()
  if c != nil and ui.fHovered == c: c.doMouseEnter()
  ui.updateCursor()

method controlLost*(ui: UiRoot, c: Control) =
  if inside(c, ui.fHovered):
    ui.hoverStale = true
    ui.dirty = true
    let old = ui.fHovered
    ui.fHovered = nil
    old.doMouseLeave()
    ui.updateCursor()
  if inside(c, ui.fCaptured): ui.fCaptured = nil
  if inside(c, ui.fPressed): ui.fPressed = nil
  if ui.fCaptured == nil and ui.buttons != {}:
    ui.buttons = {}              # nothing left to release
  if inside(c, ui.fFocused):
    let old = ui.fFocused
    ui.fFocused = nil
    old.doExit()
    ui.updateTextInput()

# ------------------------------------------------------------------ focus

proc canTakeFocus*(c: Control): bool =
  c != nil and c.isVisible and c.isEnabled and c.canFocus()

proc focusControl*(ui: UiRoot, c: Control) =
  ## Moves keyboard focus to `c` (nil clears it). Controls that are hidden,
  ## disabled or not `canFocus` are refused.
  if c == ui.fFocused: return
  if c != nil and not canTakeFocus(c): return
  let old = ui.fFocused
  ui.fFocused = c
  if old != nil:
    old.invalidate()
    old.doExit()
  if c != nil and ui.fFocused == c:
    c.invalidate()
    c.doEnter()
  ui.updateTextInput()
  if c != nil and ui.fFocused == c and ui.revealOnFocus:
    # scrolling ancestors (ScrollBox) bring the focused control into view
    var p = c.parent
    while p != nil:
      p.revealControl(c)
      p = p.parent

proc setFocus*(c: Control) =
  ## Focuses `c` in its form/host (no-op when detached or not focusable).
  let h = c.host
  if h of UiRoot: UiRoot(h).focusControl(c)

proc focused*(c: Control): bool =
  let h = c.host
  h of UiRoot and UiRoot(h).fFocused == c

# --------------------------------------------------------------- tab order

proc collectTabStops(c: Container, acc: var seq[Control]) =
  var order = newSeq[(int, int)](c.controlCount)   # (tabOrder, child index)
  for i in 0 ..< c.controlCount: order[i] = (c[i].tabOrder, i)
  order.sort()                                     # tuples: tabOrder, then index
  for (_, i) in order:
    let ch = c[i]
    if not ch.visible or not ch.enabled: continue
    if ch.isTabStop() and ch.canFocus(): acc.add ch
    if ch of Container: collectTabStops(Container(ch), acc)

proc tabStops*(root: Container): seq[Control] =
  ## Focusable controls in tab order: within each container by `tabOrder`, then
  ## child index; a container's own stop comes before its children.
  collectTabStops(root, result)

proc focusNext*(ui: UiRoot, forward = true) =
  ## Tab / Shift+Tab: next/previous tab stop, wrapping around.
  let stops = tabStops(ui.root)
  if stops.len == 0: return
  let i = stops.find(ui.fFocused)
  let n =
    if i < 0: (if forward: 0 else: stops.high)
    elif forward: (i + 1) mod stops.len
    else: (i + stops.len - 1) mod stops.len
  ui.focusControl(stops[n])

# ----------------------------------------------------------------- mouse

proc buttonShift(ui: UiRoot): ShiftState =
  if mbLeft in ui.buttons: result.incl ssLeft
  if mbRight in ui.buttons: result.incl ssRight
  if mbMiddle in ui.buttons: result.incl ssMiddle

proc hitAt(ui: UiRoot, p: PointF): Control =
  result = ui.root.controlAtPoint(p)
  if result == nil and ui.rootGetsMouse and ui.root.clientRect.contains(p):
    result = ui.root

proc cancelInteraction*(ui: UiRoot) =
  ## Drops mouse capture, pressed state and hover (window deactivated/hidden).
  ui.buttons = {}
  ui.fCaptured = nil
  ui.fPressed = nil
  ui.setHover(nil)

proc mouseMove(ui: UiRoot, p: PointF, shift: ShiftState): bool =
  ui.lastPos = p
  ui.mouseInside = true
  let shift = shift + ui.buttonShift
  var target: Control
  if ui.fCaptured != nil:
    target = ui.fCaptured
    let over = target.clientRect.contains(target.formToClient(p))
    ui.setHover(if over: target else: nil)
  else:
    target = ui.hitAt(p)
    ui.setHover(target)
  if target == nil: return false
  let lp = target.formToClient(p)
  target.doMouseMove(shift, lp.x, lp.y)
  true

proc mouseDown(ui: UiRoot, p: PointF, button: MouseButton, shift: ShiftState,
               clicks: int): bool =
  ui.lastPos = p
  ui.mouseInside = true
  if ui.fCaptured == nil: ui.setHover(ui.hitAt(p))
  let target = if ui.fCaptured != nil: ui.fCaptured else: ui.hitAt(p)
  if target == nil: return false
  if ui.fCaptured == nil: ui.fCaptured = target
  if button == mbLeft: ui.fPressed = ui.fCaptured
  ui.buttons.incl button
  # focus first (VCL): the nearest focusable control from the target up
  var f = target
  while f != nil and not canTakeFocus(f): f = Control(f.parent)
  if f != nil:
    ui.revealOnFocus = false     # a press must not move the control under it
    ui.focusControl(f)
    ui.revealOnFocus = true
  var sh = shift + ui.buttonShift
  let dbl = clicks == 2 and button == mbLeft
  if dbl: sh.incl ssDouble
  let lp = target.formToClient(p)
  target.doMouseDown(button, sh, lp.x, lp.y)
  if dbl: target.doDblClick()
  true

proc mouseUp(ui: UiRoot, p: PointF, button: MouseButton, shift: ShiftState): bool =
  ui.lastPos = p
  let t = ui.fCaptured
  if t == nil: return false
  ui.buttons.excl button
  let lp = t.formToClient(p)
  let pressed = ui.fPressed
  if button == mbLeft: ui.fPressed = nil
  t.doMouseUp(button, shift + ui.buttonShift, lp.x, lp.y)
  if button == mbLeft and pressed == t and t.isVisible and t.isEnabled and
     t.clientRect.contains(t.formToClient(p)):
    t.doClick()
  if ui.buttons == {}:
    ui.fCaptured = nil
    ui.fPressed = nil
    ui.setHover(ui.hitAt(p))
  true

proc mouseWheel(ui: UiRoot, p: PointF, dx, dy: float32, shift: ShiftState): bool =
  let target = if ui.fCaptured != nil: ui.fCaptured else: ui.hitAt(p)
  if target == nil: return false
  var handled = false
  var c = target
  while c != nil and not handled:
    c.doMouseWheel(shift + ui.buttonShift, dx, dy, handled)
    c = Control(c.parent)
  true

# -------------------------------------------------------------- keyboard

proc addKeyHandler*(ui: UiRoot, id: string, hook: KeyHook) =
  ## Registers a handler for keys that neither the focused control nor the
  ## root handled, in registration order. The same `id` replaces the earlier
  ## handler (keeping its place). Several features share the chain; a hook set
  ## on `onUnhandledKey` runs first.
  for e in ui.fKeyHandlers.mitems:
    if e.id == id:
      e.hook = hook
      return
  ui.fKeyHandlers.add (id, hook)

proc removeKeyHandler*(ui: UiRoot, id: string) =
  for i in 0 ..< ui.fKeyHandlers.len:
    if ui.fKeyHandlers[i].id == id:
      ui.fKeyHandlers.delete(i)
      return

func hasKeyHandler*(ui: UiRoot, id: string): bool =
  for e in ui.fKeyHandlers:
    if e.id == id: return true

proc findMnemonic(c: Control, ch: char): bool =
  ## Depth-first: the first visible, enabled control that claims `ch`.
  if not c.visible or not c.enabled: return false
  if c.activateMnemonic(ch): return true
  if c of Container:
    for k in Container(c).children:
      if findMnemonic(k, ch): return true

proc runKeyChain(ui: UiRoot, k: var Key, shift: ShiftState) =
  if ui.onUnhandledKey != nil:
    ui.onUnhandledKey(k, shift)
    if k == Key(0): return
  var i = 0
  while i < ui.fKeyHandlers.len:             # a handler may add handlers
    ui.fKeyHandlers[i].hook(k, shift)
    if k == Key(0): return
    inc i
  if shift * {ssCtrl, ssAlt, ssSuper} == {ssAlt}:
    let u = uint32(k)
    if u > 0x20 and u < 0x7f:
      if findMnemonic(ui.root, char(u).toLowerAscii): k = Key(0)

proc setAlt*(ui: UiRoot, v: bool) =
  ## Records the state of the Alt key (the Application also feeds it with Alt
  ## events of popup windows, which never reach `handle`).
  if v == ui.fAlt: return
  ui.fAlt = v
  ui.dirty = true
  ui.altChanged()

proc keyDown(ui: UiRoot, key: Key, shift: ShiftState): bool =
  if key == keyLAlt or key == keyRAlt: ui.setAlt(true)
  var k = key
  let target = if ui.fFocused != nil: ui.fFocused else: Control(ui.root)
  if ui.keyPreview and target != Control(ui.root):
    ui.root.doKeyDown(k, shift)
    if k == Key(0): return true
  target.doKeyDown(k, shift)
  if k == Key(0): return true
  if k == keyTab and shift * {ssCtrl, ssAlt} == {}:
    ui.focusNext(ssShift notin shift)
    return true
  ui.runKeyChain(k, shift)
  if k == Key(0): return true
  ui.fFocused != nil

proc keyUp(ui: UiRoot, key: Key, shift: ShiftState): bool =
  if key == keyLAlt or key == keyRAlt: ui.setAlt(false)
  var k = key
  let target = if ui.fFocused != nil: ui.fFocused else: Control(ui.root)
  if ui.keyPreview and target != Control(ui.root):
    ui.root.doKeyUp(k, shift)
    if k == Key(0): return true
  target.doKeyUp(k, shift)
  ui.fFocused != nil

# ------------------------------------------------------- metrics and events

proc setWindowActive*(ui: UiRoot, active: bool) =
  ## The window gained/lost focus: repaints the focused control (a caret hides
  ## while inactive).
  if ui.windowInactive == not active: return
  ui.windowInactive = not active
  if not active: ui.setAlt(false)
  if ui.fFocused != nil: ui.fFocused.invalidate()

proc syncScale*(ui: UiRoot) =
  ## Re-reads the window's pixel density and rebuilds font caches if it changed.
  if ui.win == nil or ui.ctx == nil: return
  ui.ctx.setScale(ui.win.scale)
  ui.dirty = true

proc resize*(ui: UiRoot, w, h: float32) =
  ## Sets the root's size (logical px) and relayouts.
  ui.root.setBounds(0, 0, w, h)
  ui.dirty = true

proc syncMetrics*(ui: UiRoot) =
  ## Scale and (when `autoSizeRoot`) root size from the window.
  ui.syncScale()
  if ui.autoSizeRoot and ui.win != nil and ui.win.window != nil:
    let s = ui.win.logicalSize
    ui.resize(s.w, s.h)

proc handle*(ui: UiRoot, pe: PlatformEvent): bool =
  ## Routes one event. Returns true when the UI consumed it: mouse events over
  ## a control (or during capture), keyboard and text events while a control
  ## has focus. Window geometry events update scale and size and return false.
  case pe.kind
  of ekMouseMove, ekMouseDown, ekMouseUp, ekMouseWheel:
    if ui.win == nil: return false
    let p = pointF(ui.win.toLogical(pe.x), ui.win.toLogical(pe.y))
    case pe.kind
    of ekMouseMove: ui.mouseMove(p, pe.shift)
    of ekMouseDown: ui.mouseDown(p, pe.button, pe.shift, pe.clicks)
    of ekMouseUp: ui.mouseUp(p, pe.button, pe.shift)
    else: ui.mouseWheel(p, pe.dx, pe.dy, pe.shift)
  of ekKeyDown: ui.keyDown(pe.key, pe.shift)
  of ekKeyUp: ui.keyUp(pe.key, pe.shift)
  of ekTextInput:
    if ui.fFocused == nil: return false
    var s = pe.text
    ui.fFocused.doKeyPress(s)
    true
  of ekTextEditing:
    if ui.fFocused == nil: return false
    ui.fFocused.doTextEditing(pe.text, pe.editStart, pe.editLength)
    true
  of ekWindowMouseLeave:
    ui.mouseInside = false
    ui.setHover(nil)
    false
  of ekWindowFocusLost:
    ui.cancelInteraction()
    ui.setAlt(false)
    false
  of ekWindowResized, ekWindowPixelSize, ekWindowScale:
    ui.syncMetrics()
    false
  of ekWindowExposed:
    ui.dirty = true
    false
  else: false

# ------------------------------------------------------------------ paint

proc needsPaint*(ui: UiRoot): bool = ui.dirty

proc paintFrame*(ui: UiRoot, clear, present: bool) =
  ## Layout, then one frame: optional clear with the root colour, the tree,
  ## optional present. Clears the dirty flag.
  if ui.ctx == nil: return
  ui.root.layoutIfNeeded()
  if ui.hoverStale:
    ui.hoverStale = false
    if ui.mouseInside and ui.fCaptured == nil: ui.setHover(ui.hitAt(ui.lastPos))
    ui.root.layoutIfNeeded()
  ui.dirty = false
  let cv = beginFrame(ui.ctx)
  if clear: cv.clear(ui.root.color)
  ui.root.paintTree(cv)
  cv.endFrame()
  if present and ui.win != nil: ui.win.present()

proc closeContext*(ui: UiRoot) =
  ## Closes the RenderContext (before the renderer is destroyed).
  if ui.ctx != nil:
    ui.ctx.close()
    ui.ctx = nil
