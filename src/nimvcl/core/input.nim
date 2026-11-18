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

import std/[algorithm, os, math]
import ../graphics/[geometry, context, canvas]
import ../platform/[window, events, cursors]
import ./types, ./control, ./layout, ./design
export design

type
  KeyHook* = proc(key: var Key, shift: ShiftState)
    ## A handler for keys no control used. Sets `key` to `Key(0)` to consume it.

  UiRoot* = ref object of RootHost
    root*: Container
    win*: PlatformWindow
    ctx*: RenderContext
    dirty*: bool                 ## the whole tree needs repainting
    dirtyRects*: seq[RectF]      ## partial repaint: regions (form coordinates,
                                 ## device-pixel aligned, disjoint); used when
                                 ## `useBackbuffer` and `dirty` is false
    useBackbuffer*: bool         ## paint into a persistent per-window texture and
                                 ## repaint only the dirty regions (Form: true;
                                 ## Host and popups: false, they repaint fully)
    lastPaintFull*: bool         ## the last frame repainted everything
    lastPaintRects*: seq[RectF]  ## regions the last partial frame repainted
    keyPreview*: bool
    rootGetsMouse*: bool         ## the root itself is a mouse target (Form: true)
    autoSizeRoot*: bool          ## window size changes resize the root
    onUnhandledKey*: KeyHook     ## the application's own hook; runs before the chain
    fKeyHandlers: seq[tuple[id: string, hook: KeyHook]]
    fAlt: bool                   ## an Alt key is down (mnemonic underlines)
    keyRepeat*: bool             ## the key event being dispatched is an auto-repeat
    windowInactive*: bool        ## the window lost focus (set by the Form)
    revealOnFocus*: bool         ## focus changes scroll the control into view
                                 ## (default true; off while a mouse press focuses)
    designers*: seq[DesignHook] ## attached design hooks (see core/design.nim)
    fHovered, fCaptured, fFocused, fPressed: Control
    fDesignCap, fKeyDesigner: DesignHook
    fDesignCursor: bool
    buttons: set[MouseButton]
    lastPos: PointF
    mouseInside: bool
    hoverStale: bool
    cursorApplied: bool

func altHeld*(ui: UiRoot): bool = ui.fAlt

func keyIsRepeat*(c: Control): bool =
  ## True while `c` handles a key-down that is an auto-repeat (key held). A
  ## control that must act once per press (a Button's Enter) checks it.
  let h = c.host
  h of UiRoot and UiRoot(h).keyRepeat

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

const
  MaxDirtyRects = 6              ## more regions than this collapse to their bounding box
  FullRepaintShare = 0.85'f32    ## dirty area above this share of the form: repaint it all

type PopupHookKind* = enum
  phRegister     ## the control is about to get keys / mouse (focus, press, key)
  phMouseUp      ## a button was released over it (`p`: form coordinates)

var popupHook*: proc(c: Control, kind: PopupHookKind, button: MouseButton,
                     p: PointF) {.nimcall.}
  ## Set by controls/menus.nim: context menus (`Control.popupMenu`) are served
  ## from here, so the control's own event fields stay untouched.

var debugDirty = -1              # NIMVCL_DEBUG_DIRTY=1: outline the repainted regions
proc debugDirtyOn(): bool =
  if debugDirty < 0: debugDirty = (if getEnv("NIMVCL_DEBUG_DIRTY") == "1": 1 else: 0)
  debugDirty == 1

func touches(a, b: RectF): bool =
  ## Overlap or share an edge.
  a.x <= b.right and b.x <= a.right and a.y <= b.bottom and b.y <= a.bottom

func unionRect(a, b: RectF): RectF =
  let x0 = min(a.x, b.x)
  let y0 = min(a.y, b.y)
  rectF(x0, y0, max(a.right, b.right) - x0, max(a.bottom, b.bottom) - y0)

proc addDirtyRect*(list: var seq[RectF], r: RectF) =
  ## Adds `r` to a list of disjoint rects: rects that overlap or touch are
  ## merged into their bounding box, and more than `MaxDirtyRects` entries
  ## collapse into one bounding box.
  var cur = r
  var i = 0
  while i < list.len:
    if touches(list[i], cur):
      cur = unionRect(list[i], cur)
      list.delete(i)
      i = 0
    else:
      inc i
  list.add cur
  if list.len > MaxDirtyRects:
    var bb = list[0]
    for k in 1 .. list.high: bb = unionRect(bb, list[k])
    list.setLen 0
    list.add bb

proc invalidateAll*(ui: UiRoot) =
  ## The whole tree needs repainting.
  ui.dirty = true
  ui.dirtyRects.setLen 0

method invalidate*(ui: UiRoot, r: RectF) =
  if ui.dirty: return
  if not ui.useBackbuffer or ui.ctx == nil:
    ui.dirty = true
    return
  let s = ui.ctx.scale
  let form = ui.root.clientRect
  var x0 = floor(r.x * s) / s            # outwards to whole device pixels
  var y0 = floor(r.y * s) / s
  var x1 = ceil(r.right * s) / s
  var y1 = ceil(r.bottom * s) / s
  let c = intersect(rectF(x0, y0, x1 - x0, y1 - y0), form)
  if c.isEmpty: return
  ui.dirtyRects.addDirtyRect(c)
  var area = 0'f32
  for q in ui.dirtyRects: area += q.w * q.h
  if area >= FullRepaintShare * form.w * form.h: ui.invalidateAll()
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
  if ui.fDesignCap != nil and inside(c, ui.fDesignCap.scope):
    let d = ui.fDesignCap
    ui.fDesignCap = nil
    ui.buttons = {}
    d.designCancel()
  var lostCapture: Control
  if inside(c, ui.fCaptured):
    lostCapture = ui.fCaptured
    ui.fCaptured = nil
  if inside(c, ui.fPressed): ui.fPressed = nil
  if ui.fCaptured == nil and ui.buttons != {}:
    ui.buttons = {}              # nothing left to release
  if inside(c, ui.fFocused):
    let old = ui.fFocused
    ui.fFocused = nil
    old.doExit()
    ui.updateTextInput()
  if lostCapture != nil: lostCapture.captureLost()

# ------------------------------------------------------------------ focus

proc canTakeFocus*(c: Control): bool =
  c != nil and c.isVisible and c.isEnabled and c.canFocus()

proc focusControl*(ui: UiRoot, target: Control) =
  ## Moves keyboard focus to `target` (nil clears it), or to what it forwards
  ## the focus to (`focusTarget`). Controls that are hidden, disabled or not
  ## `canFocus` are refused.
  let c = if target == nil: nil else: target.focusTarget
  if c == ui.fFocused: return
  if c != nil and not canTakeFocus(c): return
  let old = ui.fFocused
  ui.fFocused = c
  if old != nil:
    old.invalidate()
    old.doExit()
  if c != nil and ui.fFocused == c:
    c.invalidate()
    if popupHook != nil: popupHook(c, phRegister, mbLeft, pointF(0, 0))
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

proc collectTabOrder(c: Container, acc: var seq[Control]) =
  ## Every visible, enabled descendant in tab order (parents before children).
  var order = newSeq[(int, int)](c.controlCount)   # (tabOrder, child index)
  for i in 0 ..< c.controlCount: order[i] = (c[i].tabOrder, i)
  order.sort()                                     # tuples: tabOrder, then index
  for (_, i) in order:
    let ch = c[i]
    if not ch.visible or not ch.enabled: continue
    acc.add ch
    if ch of Container: collectTabOrder(Container(ch), acc)

proc isStop(c: Control): bool = c.isTabStop() and c.canFocus()

proc tabStops*(root: Container): seq[Control] =
  ## Focusable controls in tab order: within each container by `tabOrder`, then
  ## child index; a container's own stop comes before its children.
  var all: seq[Control]
  collectTabOrder(root, all)
  for c in all:
    if c.isStop: result.add c

proc focusNext*(ui: UiRoot, forward = true) =
  ## Tab / Shift+Tab: next/previous tab stop, wrapping around. From a focused
  ## control that is not a tab stop itself, continues from its place in the tab
  ## order.
  var all: seq[Control]
  collectTabOrder(ui.root, all)
  var stops: seq[Control]
  for c in all:
    if c.isStop: stops.add c
  if stops.len == 0: return
  var n: int
  let i = stops.find(ui.fFocused)
  if i >= 0:
    n = if forward: (i + 1) mod stops.len else: (i + stops.len - 1) mod stops.len
  else:
    let pos = all.find(ui.fFocused)
    if pos < 0:
      n = if forward: 0 else: stops.high
    elif forward:
      n = 0                                  # wraps to the first when none follows
      for j in pos + 1 .. all.high:
        if all[j].isStop:
          n = stops.find(all[j])
          break
    else:
      n = stops.high
      for j in countdown(pos - 1, 0):
        if all[j].isStop:
          n = stops.find(all[j])
          break
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

proc designFor(ui: UiRoot, p: PointF): DesignHook =
  ## The design hook that owns the pointer at `p` (nil: normal routing).
  if ui.fDesignCap != nil: return ui.fDesignCap
  if ui.fCaptured != nil: return nil
  let h = ui.hitAt(p)
  for d in ui.designers:
    if d.scope == nil: continue
    if h != nil:
      if inside(d.scope, h): return d
    elif d.scope.isVisible and d.scope.clientToForm(d.scope.clientRect).contains(p):
      return d

proc hoverAt(ui: UiRoot, p: PointF): Control =
  ## The control to hover at `p`: none inside a designed container.
  if ui.designers.len > 0 and ui.designFor(p) != nil: return nil
  ui.hitAt(p)

proc addDesigner*(ui: UiRoot, d: DesignHook) =
  ## Attaches a design hook (see core/design.nim). The first one gets the keys.
  if d == nil or d in ui.designers: return
  ui.designers.add d
  if ui.fKeyDesigner == nil: ui.fKeyDesigner = d
  ui.hoverStale = true

proc removeDesigner*(ui: UiRoot, d: DesignHook) =
  let i = ui.designers.find(d)
  if i < 0: return
  if ui.fDesignCap == d:
    ui.fDesignCap = nil
    ui.buttons = {}
    d.designCancel()
  ui.designers.delete i
  if ui.fKeyDesigner == d:
    ui.fKeyDesigner = if ui.designers.len > 0: ui.designers[0] else: nil
  ui.hoverStale = true

proc cancelInteraction*(ui: UiRoot) =
  ## Drops mouse capture, pressed state and hover (window deactivated/hidden).
  let cap = ui.fCaptured
  let dcap = ui.fDesignCap
  ui.fDesignCap = nil
  if dcap != nil: dcap.designCancel()
  ui.buttons = {}
  ui.fCaptured = nil
  ui.fPressed = nil
  ui.setHover(nil)
  if cap != nil: cap.captureLost()

proc mouseMove(ui: UiRoot, p: PointF, shift: ShiftState): bool =
  ui.lastPos = p
  ui.mouseInside = true
  let shift = shift + ui.buttonShift
  var target: Control
  if ui.designers.len > 0:
    let d = ui.designFor(p)
    if d != nil:
      ui.setHover(nil)
      d.designMouseMove(d.scope.formToClient(p), shift)
      if ui.win != nil:
        setCursorShape(d.cursor)
        ui.cursorApplied = true
        ui.fDesignCursor = true
      return true
    if ui.fDesignCursor:
      ui.fDesignCursor = false
      ui.updateCursor()
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
  if ui.designers.len > 0:
    let d = ui.designFor(p)
    if d != nil:
      ui.setHover(nil)
      ui.focusControl(nil)         # the designer owns the keyboard now
      ui.fKeyDesigner = d
      ui.fDesignCap = d
      ui.buttons.incl button
      var sh = shift + ui.buttonShift
      if clicks == 2 and button == mbLeft: sh.incl ssDouble
      d.designMouseDown(d.scope.formToClient(p), button, sh, clicks)
      return true
  if ui.fCaptured == nil: ui.setHover(ui.hoverAt(p))
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
  # focusing may have run handlers (onExit/onEnter) that hid, disabled or
  # removed the target: do not deliver the press to a dead control
  if target.root != Control(ui.root) or not target.isVisible or
     not target.isEnabled:
    return true
  let lp = target.formToClient(p)
  if popupHook != nil: popupHook(target, phRegister, button, p)
  target.doMouseDown(button, sh, lp.x, lp.y)
  if dbl: target.doDblClick()
  true

proc mouseUp(ui: UiRoot, p: PointF, button: MouseButton, shift: ShiftState): bool =
  ui.lastPos = p
  let dc = ui.fDesignCap
  if dc != nil:
    ui.buttons.excl button
    if ui.buttons == {}: ui.fDesignCap = nil
    dc.designMouseUp(dc.scope.formToClient(p), button, shift + ui.buttonShift)
    if ui.buttons == {}: ui.setHover(ui.hoverAt(p))
    return true
  let t = ui.fCaptured
  if t == nil: return false
  ui.buttons.excl button
  let lp = t.formToClient(p)
  let pressed = ui.fPressed
  if button == mbLeft: ui.fPressed = nil
  t.doMouseUp(button, shift + ui.buttonShift, lp.x, lp.y)
  if button == mbRight and popupHook != nil and t.root == Control(ui.root):
    popupHook(t, phMouseUp, button, p)
  if button == mbLeft and pressed == t and t.isVisible and t.isEnabled and
     t.clientRect.contains(t.formToClient(p)):
    t.doClick()
  if ui.buttons == {}:
    ui.fCaptured = nil
    ui.fPressed = nil
    ui.setHover(ui.hoverAt(p))
  true

proc mouseWheel(ui: UiRoot, p: PointF, dx, dy: float32, shift: ShiftState): bool =
  if ui.designers.len > 0:
    let d = ui.designFor(p)
    if d != nil:
      if not d.designMouseWheel(d.scope.formToClient(p), shift + ui.buttonShift,
                                dx, dy):
        var handled = false
        var c = Control(d.scope)
        while c != nil and not handled:
          c.doMouseWheel(shift + ui.buttonShift, dx, dy, handled)
          c = Control(c.parent)
      return true
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

proc findMnemonic(c: Control, ch: Rune): bool =
  ## Depth-first: the first visible, enabled control that claims `ch`.
  if not c.visible or not c.enabled: return false
  if c.activateMnemonic(ch): return true
  if c of Container:
    for k in Container(c).children:
      if findMnemonic(k, ch): return true

proc runKeyChain(ui: UiRoot, k: var Key, shift: ShiftState) =
  let un = ui.onUnhandledKey
  if un != nil:
    un(k, shift)
    if k == Key(0): return
  let snapshot = ui.fKeyHandlers       # a handler may add or remove handlers
  for e in snapshot:
    if not ui.hasKeyHandler(e.id): continue          # removed meanwhile
    if ui.keyRepeat and e.id == "dialog": continue   # default/cancel: once per press
    e.hook(k, shift)
    if k == Key(0): return
  if shift * {ssCtrl, ssAlt, ssSuper} == {ssAlt}:
    let r = keyRune(k)
    if int(r) != 0:
      if findMnemonic(ui.root, r): k = Key(0)

proc setAlt*(ui: UiRoot, v: bool) =
  ## Records the state of the Alt key (the Application also feeds it with Alt
  ## events of popup windows, which never reach `handle`).
  if v == ui.fAlt: return
  ui.fAlt = v
  ui.dirty = true
  ui.altChanged()

proc keyDesigner(ui: UiRoot): DesignHook =
  ## The design hook that owns the keyboard now, if any: the one last pressed
  ## in, while focus is free or inside its scope.
  let d = ui.fKeyDesigner
  if d == nil or d.scope == nil or not d.scope.isVisible: return nil
  if ui.fFocused == nil or inside(d.scope, ui.fFocused): d else: nil

proc keyDown(ui: UiRoot, key: Key, shift: ShiftState, repeat = false): bool =
  if key == keyLAlt or key == keyRAlt: ui.setAlt(true)
  let wasRepeat = ui.keyRepeat
  ui.keyRepeat = repeat
  defer: ui.keyRepeat = wasRepeat
  var k = key
  let kd = ui.keyDesigner()
  if kd != nil:
    if kd.designKeyDown(k, shift): return true
    if ui.fFocused != nil:       # a control inside the design scope: no delivery
      ui.runKeyChain(k, shift)
      return true
  let target = if ui.fFocused != nil: ui.fFocused else: Control(ui.root)
  if ui.keyPreview and target != Control(ui.root):
    ui.root.doKeyDown(k, shift)
    if k == Key(0): return true
  if popupHook != nil: popupHook(target, phRegister, mbLeft, pointF(0, 0))
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
  let kd = ui.keyDesigner()
  if kd != nil:
    kd.designKeyUp(k, shift)
    return true
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
  let before = ui.ctx.scale
  ui.ctx.setScale(ui.win.scale)
  if ui.ctx.scale != before: ui.invalidateAll()

proc resize*(ui: UiRoot, w, h: float32) =
  ## Sets the root's size (logical px) and relayouts.
  let r = ui.root
  let changed = r.width != w or r.height != h
  r.hostSized = true      # a window resize is not the design size
  try: r.setBounds(0, 0, w, h)
  finally: r.hostSized = false
  if changed: ui.invalidateAll()

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
  of ekKeyDown: ui.keyDown(pe.key, pe.shift, pe.repeat)
  of ekKeyUp: ui.keyUp(pe.key, pe.shift)
  of ekTextInput:
    if ui.fFocused == nil: return false
    if ui.designers.len > 0 and ui.keyDesigner() != nil: return true
    var s = pe.text
    ui.fFocused.doKeyPress(s)
    true
  of ekTextEditing:
    if ui.fFocused == nil: return false
    if ui.designers.len > 0 and ui.keyDesigner() != nil: return true
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

proc needsPaint*(ui: UiRoot): bool = ui.dirty or ui.dirtyRects.len > 0

proc resetBackbuffer*(ui: UiRoot) =
  ## The renderer lost its render targets (SDL_EVENT_RENDER_TARGETS_RESET /
  ## DEVICE_RESET): drops the backbuffer and repaints everything.
  if ui.win != nil: ui.win.dropBackbuffer()
  ui.invalidateAll()

proc paintRegions(ui: UiRoot, cv: Canvas, clear, full: bool,
                  rects: openArray[RectF]) =
  let root = ui.root
  if full:
    if clear: cv.clear(root.color)
    root.paintTree(cv)
  else:
    for r in rects:
      cv.pushClip(r)
      if clear: cv.clearRect(r, root.color)
      root.paintTree(cv)
      cv.popClip()

proc paintFrame*(ui: UiRoot, clear, present: bool) =
  ## Layout, then one frame: optional clear with the root colour, the tree,
  ## optional present. Clears the dirty state.
  ##
  ## With `useBackbuffer` the tree is drawn into the window's persistent
  ## backbuffer texture, only inside the dirty regions (all of it when `dirty`
  ## is set or the backbuffer was just (re)created); the backbuffer is then
  ## copied to the window. Otherwise the tree is drawn straight to the current
  ## target.
  if ui.ctx == nil: return
  ui.root.layoutIfNeeded()
  if ui.hoverStale:
    ui.hoverStale = false
    if ui.mouseInside and ui.fCaptured == nil: ui.setHover(ui.hoverAt(ui.lastPos))
    ui.root.layoutIfNeeded()
  var full = ui.dirty
  var bb = false
  if ui.useBackbuffer and ui.win != nil and ui.win.window != nil:
    if ui.win.ensureBackbuffer(): full = true
    bb = ui.win.hasBackbuffer
  let rects = ui.dirtyRects
  ui.dirty = false
  ui.dirtyRects.setLen 0
  if not bb:
    let cv = beginFrame(ui.ctx)
    try:
      if clear: cv.clear(ui.root.color)
      ui.root.paintTree(cv)
    finally:
      cv.endFrame()        # restores the renderer state even when a paint raised
    ui.lastPaintFull = true
    ui.lastPaintRects.setLen 0
    if present and ui.win != nil: ui.win.present()
    return
  ui.lastPaintFull = full
  ui.lastPaintRects = if full: @[] else: rects
  if full or rects.len > 0:
    ui.win.beginBackbuffer()
    try:
      let cv = beginFrame(ui.ctx)
      try: ui.paintRegions(cv, clear, full, rects)
      finally: cv.endFrame()
    finally:
      ui.win.endBackbuffer()
  else:
    ui.win.endBackbuffer()   # nothing to draw: just refresh the window copy
  if present:
    if debugDirtyOn():
      let s = ui.ctx.scale
      var dev: seq[tuple[x, y, w, h: int]]
      if full:
        dev.add (0, 0, int(round(ui.root.width * s)), int(round(ui.root.height * s)))
      else:
        for r in rects:
          dev.add (int(round(r.x * s)), int(round(r.y * s)),
                   int(round(r.w * s)), int(round(r.h * s)))
      ui.win.drawDebugRects(dev)
    ui.win.present()

proc closeContext*(ui: UiRoot) =
  ## Closes the RenderContext (before the renderer is destroyed).
  if ui.ctx != nil:
    ui.ctx.close()
    ui.ctx = nil
