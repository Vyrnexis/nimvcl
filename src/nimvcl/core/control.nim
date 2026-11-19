## `Control` and `Container`: the VCL TControl / TWinControl analogues.
##
## Conventions
## -----------
## * Coordinates are logical pixels (float32). A control's `left`/`top` are
##   relative to its PARENT's client origin (the top-left of the parent's
##   `clientRect`, padding NOT subtracted). The root of a tree (no parent, a
##   Form in phase 2b) ignores its own left/top.
## * Properties are getter/setter procs with VCL names (`c.width = 10`).
##   Setters repaint (`invalidate`) and/or relayout as needed; both are no-ops
##   until a `RootHost` is attached to the tree's root.
## * Virtual behaviour is `method`. Two families:
##   - `doXxx` methods (`doClick`, `doMouseDown`, `doKeyDown`, `doResize`,
##     `doEnter`, ...) are the event dispatch points. The base implementation
##     just fires the matching `onXxx` field when it is not nil. Subclasses
##     override them, normally calling `procCall` of the base (or firing the
##     handler themselves) after their own work. The platform layer (2b) calls
##     only these.
##   - `paint`, `preferredSize`, `canFocus`, `hitTest` (and Container's
##     `customAlign`) are query/draw hooks.
##   `onXxx` event fields are public and nil by default.
## * Key events: handlers receive `key: var Key`; setting it to `Key(0)` swallows
##   the key (after `doKeyDown` returns, check `key != Key(0)` before acting).
##   `doKeyPress` works the same with an empty `text`.
## * Constructors: `newControl(owner)`. Subclasses written in other modules call
##   `initControl(self, owner)` (or `initContainer`) from their own `newXxx`;
##   a bare `Control()` has zeroed defaults.
## * Ownership (`Component.owner`) and the parent/child tree are independent.
##   The tree is `Container.children`; z-order = child index, last on top.
##   Layout order of same-`align` siblings is ALSO the child index (see
##   layout.nim), so `bringToFront` reorders stacking too.
## * Scrolling: a Container has a scroll offset (`scrollOffset`). Children with
##   `align == alNone` live in CONTENT coordinates: they are drawn and hit-tested
##   shifted by `-scrollOffset` and clipped to `viewportRect` (default: the whole
##   client rect). Aligned children (`align != alNone`) are laid out against the
##   viewport and are NOT scrolled (they stay put like a ScrollBox's scrollbars).
##   `left`/`top` of a child are always in content coordinates; use
##   `visualRect` for where it currently appears in the parent's client area.
## * `core` imports no SDL; it uses `graphics` (Canvas etc.) only.

import ../graphics/[geometry, color, font, canvas]
import ./types, ./component, ./theme
export types, component, theme

type
  Control* = ref object of Component
    popupMenuRef*: RootRef       ## the `PopupMenu` attached with `attachPopupMenu` (controls/menus.nim)
    # geometry (parent's client coordinates)
    fLeft, fTop, fWidth, fHeight: float32
    fAlign: Align
    fAnchors: Anchors
    fMargins: Spacing
    fConstraints: SizeConstraints
    fAutoSize: bool
    # state
    fVisible, fEnabled: bool
    fCaption, fHint: string
    fCursor: Cursor
    fFont: FontSpec
    fParentFont: bool
    fColor: Color
    fParentColor: bool
    fTabStop: bool
    fTabOrder: int
    fParent: Container
    fHost: RootHost
    # Anchor design baseline (see layout.nim): the child's rect when it was
    # last positioned explicitly, and the parent size that rect was relative
    # to (`designBaseSet` false = the parent's `designSize`).
    designRect*: RectF
    designBase*: SizeF
    designBaseSet*: bool
    # events
    onClick*, onDblClick*, onMouseEnter*, onMouseLeave*: NotifyEvent
    onEnter*, onExit*, onResize*: NotifyEvent
    onMouseDown*, onMouseUp*: MouseEvent
    onMouseMove*: MouseMoveEvent
    onMouseWheel*: MouseWheelEvent
    onKeyDown*, onKeyUp*: KeyEvent
    onKeyPress*: KeyPressEvent
    onPaint*: PaintEvent

  Container* = ref object of Control
    ## A control that holds children (TWinControl). Children are positioned by
    ## `layout` (layout.nim).
    fChildren: seq[Control]
    fPadding: Spacing
    # Layout bookkeeping, used by layout.nim. Treat as internal.
    needsLayout*: bool          ## own children must be re-aligned
    childNeedsLayout*: bool     ## some descendant container needs layout
    layouting*: bool            ## true while `layout` runs (suppresses feedback)
    lastLayoutSize*: SizeF      ## container size at the previous layout
    layoutInitialized*: bool    ## false until the first layout recorded a size
    designSize*: SizeF          ## size the anchored children were designed for
    designSet*: bool            ## `designSize` valid (explicit size or first layout)
    fScrollX, fScrollY: float32 ## scroll offset applied to alNone children
    onPaintOver*: PaintEvent    ## painted after the children (still clipped to
                                ## the client rect); used by the form designer
                                ## for its selection handles

  NotifyEvent* = proc(sender: Control)
  MouseEvent* = proc(sender: Control, button: MouseButton, shift: ShiftState,
                     x, y: float32)
  MouseMoveEvent* = proc(sender: Control, shift: ShiftState, x, y: float32)
  MouseWheelEvent* = proc(sender: Control, shift: ShiftState, dx, dy: float32,
                          handled: var bool)
  KeyEvent* = proc(sender: Control, key: var Key, shift: ShiftState)
  KeyPressEvent* = proc(sender: Control, text: var string)
  PaintEvent* = proc(sender: Control, canvas: Canvas)

  RootHost* = ref object of RootObj
    ## What a tree's root reports to (implemented by Form in phase 2b). All
    ## methods are no-ops here. They are called on the UI thread, and may be
    ## called many times per frame, so implementations should just set flags.
    theme*: Theme   ## per-window theme; nil means the global `currentTheme()`
    hidden*: bool   ## the window is not shown (Form sets it); see `isShowing`

# ------------------------------------------------------------- RootHost

method invalidate*(h: RootHost, rectInForm: RectF) {.base.} =
  ## Part of the form (root client coordinates) needs repainting.
  discard
method requestLayout*(h: RootHost) {.base.} =
  ## Some container has `needsLayout` set; run `layout(root)` before painting.
  discard
method controlLost*(h: RootHost, c: Control) {.base.} =
  ## `c` (and its subtree) is no longer a valid focus/hover/capture target: it
  ## was removed from the tree (still attached when this is called), hidden or
  ## disabled. The host drops focus, hover and mouse capture inside `c`.
  discard
method cursorChanged*(h: RootHost, c: Control) {.base.} =
  ## `c.cursor` changed; the host re-evaluates the cursor under the mouse.
  discard
method altChanged*(h: RootHost) {.base.} =
  ## The Alt key went down or up (mnemonic underlines change).
  discard
method scrollChanged*(h: RootHost, c: Container) {.base.} =
  ## The scroll offset of `c` changed: what is under the mouse may differ, so
  ## the host re-evaluates hover.
  discard

# ------------------------------------------------------------ construction

proc initControl*(c: Control, owner: Component = nil) =
  ## Sets VCL defaults (75x25, visible, enabled, anchors {akLeft, akTop},
  ## parentFont/parentColor true). Call from subclass constructors.
  c.initComponent(owner)
  c.fWidth = 75
  c.fHeight = 25
  c.fAnchors = DefaultAnchors
  c.fVisible = true
  c.fEnabled = true
  c.fParentFont = true
  c.fParentColor = true

proc newControl*(owner: Component = nil): Control {.discardable.} =
  new result
  result.initControl(owner)

proc initContainer*(c: Container, owner: Component = nil) =
  c.initControl(owner)
  c.needsLayout = true

proc newContainer*(owner: Component = nil): Container {.discardable.} =
  new result
  result.initContainer(owner)

# ------------------------------------------------------------------- tree

func parent*(c: Control): Container = c.fParent

func root*(c: Control): Control =
  ## Topmost ancestor (the "form"); `c` itself when it has no parent.
  result = c
  while result.fParent != nil: result = result.fParent

func children*(c: Container): lent seq[Control] =
  ## Children in z-order (last = topmost). Read-only view; change the tree with
  ## `insertControl`/`removeControl`/`parent=`.
  c.fChildren
template controls*(c: Container): lent seq[Control] = c.fChildren
func controlCount*(c: Container): int = c.fChildren.len
func `[]`*(c: Container, i: int): Control = c.fChildren[i]

func isAncestorOf*(a, b: Control): bool =
  ## True when `a` is a strict ancestor of `b`.
  var p = Control(b.fParent)
  while p != nil:
    if p == a: return true
    p = p.fParent
  false

func host*(c: Control): RootHost =
  ## The host of the tree `c` is in (stored on the root); nil when none.
  root(c).fHost
proc `host=`*(c: Control, h: RootHost) =
  ## Attach a host. Set it on the ROOT control of the tree.
  c.fHost = h

func isVisible*(c: Control): bool =
  ## `visible` of the control and all its ancestors.
  var x = c
  while x != nil:
    if not x.fVisible: return false
    x = x.fParent
  true

func isShowing*(c: Control): bool =
  ## `isVisible` and attached to a host whose window is shown.
  let h = c.host
  h != nil and not h.hidden and c.isVisible

func isEnabled*(c: Control): bool =
  ## `enabled` of the control and all its ancestors.
  var x = c
  while x != nil:
    if not x.fEnabled: return false
    x = x.fParent
  true

# ---------------------------------------------------------------- geometry

func left*(c: Control): float32 = c.fLeft
func top*(c: Control): float32 = c.fTop
func width*(c: Control): float32 = c.fWidth
func height*(c: Control): float32 = c.fHeight
func boundsRect*(c: Control): RectF = rectF(c.fLeft, c.fTop, c.fWidth, c.fHeight)
func clientRect*(c: Control): RectF = rectF(0, 0, c.fWidth, c.fHeight)
func align*(c: Control): Align = c.fAlign
func anchors*(c: Control): Anchors = c.fAnchors
func margins*(c: Control): Spacing = c.fMargins
func constraints*(c: Control): SizeConstraints = c.fConstraints
func autoSize*(c: Control): bool = c.fAutoSize
method padding*(c: Container): Spacing {.base.} =
  ## Space reserved inside the client area by `layout`. Subclasses that need
  ## a computed value (GroupBox: below the caption) override it.
  c.fPadding

func scrollOffset*(c: Container): PointF = pointF(c.fScrollX, c.fScrollY)

func originInParent(c: Control): PointF =
  ## Where `c`'s client origin is in its parent's client (viewport) coordinates:
  ## `left`/`top`, minus the parent's scroll offset for alNone children.
  if c.fParent != nil and c.fAlign == alNone:
    pointF(c.fLeft - c.fParent.fScrollX, c.fTop - c.fParent.fScrollY)
  else:
    pointF(c.fLeft, c.fTop)

func visualRect*(c: Control): RectF =
  ## Bounds of `c` in the parent's client coordinates as currently shown
  ## (`boundsRect` shifted by the parent's scroll offset for alNone children).
  let o = originInParent(c)
  rectF(o.x, o.y, c.fWidth, c.fHeight)

func clientToParent*(c: Control, p: PointF): PointF =
  let o = originInParent(c)
  pointF(p.x + o.x, p.y + o.y)
func clientToParent*(c: Control, r: RectF): RectF =
  let o = originInParent(c)
  r.offset(o.x, o.y)
func parentToClient*(c: Control, p: PointF): PointF =
  let o = originInParent(c)
  pointF(p.x - o.x, p.y - o.y)

func formOrigin*(c: Control): PointF =
  ## Origin of `c`'s client area in form (root client) coordinates (scroll
  ## offsets of the ancestors included).
  var x = c
  while x.fParent != nil:
    let o = originInParent(x)
    result.x += o.x
    result.y += o.y
    x = x.fParent

func rectInAncestor*(a: Container, c: Control): RectF =
  ## Bounds of the descendant `c` in `a`'s client coordinates as currently
  ## shown (scroll offsets of `a` and of the controls between included).
  ## `c` must be a descendant of `a`.
  var r = rectF(0, 0, c.fWidth, c.fHeight)
  var x = c
  while x != nil and x != Control(a):
    r = r.offset(originInParent(x).x, originInParent(x).y)
    x = x.fParent
  r

func clientToForm*(c: Control, p: PointF): PointF =
  let o = formOrigin(c)
  pointF(p.x + o.x, p.y + o.y)
func clientToForm*(c: Control, r: RectF): RectF =
  let o = formOrigin(c)
  r.offset(o.x, o.y)
func formToClient*(c: Control, p: PointF): PointF =
  let o = formOrigin(c)
  pointF(p.x - o.x, p.y - o.y)
func formToClient*(c: Control, r: RectF): RectF =
  let o = formOrigin(c)
  r.offset(-o.x, -o.y)

# ------------------------------------------------------- invalidate / layout

proc visibleInForm(c: Control, r: RectF): RectF
  # (defined below `viewportRect`)

var gPaintedControls*: int
  ## Number of controls `paintTree` has painted so far (test/diagnostic hook:
  ## compare before and after a frame to see how much a repaint touched).

proc invalidate*(c: Control, r: RectF) =
  ## Repaint `r` (client coordinates of `c`). The rect is clipped to what is
  ## visible (the client rects and scroll viewports of `c` and its ancestors);
  ## when nothing is left, nothing is invalidated. No-op without a host or when
  ## `c` is not visible. Prefer a small `r` when only a small area changed (a
  ## caret): the form then repaints only that region.
  let h = c.host
  if h == nil or not c.isVisible: return
  let v = c.visibleInForm(r)
  if v.isEmpty: return
  h.invalidate(v)

proc invalidateRect*(c: Control, r: RectF) =
  ## Same as `invalidate(c, r)`: repaint only `r` (client coordinates of `c`).
  c.invalidate(r)

proc invalidate*(c: Control) =
  ## Repaint the whole control.
  c.invalidate(c.clientRect)

proc invalidateInParent(c: Control, r: RectF) =
  ## `r` is in the parent's client coordinates (as shown).
  if c.fParent != nil: c.fParent.invalidate(r)
  else: c.invalidate()

proc markLayout(c: Container) =
  if c.layouting: return
  c.needsLayout = true
  var p = c.fParent
  while p != nil:
    p.childNeedsLayout = true
    p = p.fParent
  let h = c.host
  if h != nil: h.requestLayout()

proc relayout*(c: Container) =
  ## The children of `c` must be re-aligned (sets `needsLayout`, notifies host).
  markLayout(c)

proc requestLayout*(c: Control) =
  ## A layout-relevant property of `c` changed: its PARENT (or `c` itself when
  ## it is a root container) must re-align.
  if c.fParent != nil: markLayout(c.fParent)
  elif c of Container: markLayout(Container(c))

proc parentLayouting(c: Control): bool {.inline.} =
  c.fParent != nil and c.fParent.layouting

# ------------------------------------------------------------ event methods

method doResize*(c: Control) {.base.} =
  let h = c.onResize     # copy: a handler may clear or replace itself
  if h != nil: h(c)
method doClick*(c: Control) {.base.} =
  let h = c.onClick
  if h != nil: h(c)
  let l = c.actionLink
  if l != nil: l.clientClicked()   # linked Action runs
method doDblClick*(c: Control) {.base.} =
  let h = c.onDblClick
  if h != nil: h(c)
method doMouseDown*(c: Control, button: MouseButton, shift: ShiftState,
                    x, y: float32) {.base.} =
  let h = c.onMouseDown
  if h != nil: h(c, button, shift, x, y)
method doMouseUp*(c: Control, button: MouseButton, shift: ShiftState,
                  x, y: float32) {.base.} =
  let h = c.onMouseUp
  if h != nil: h(c, button, shift, x, y)
method doMouseMove*(c: Control, shift: ShiftState, x, y: float32) {.base.} =
  let h = c.onMouseMove
  if h != nil: h(c, shift, x, y)
method doMouseEnter*(c: Control) {.base.} =
  let h = c.onMouseEnter
  if h != nil: h(c)
method doMouseLeave*(c: Control) {.base.} =
  let h = c.onMouseLeave
  if h != nil: h(c)
method doMouseWheel*(c: Control, shift: ShiftState, dx, dy: float32,
                     handled: var bool) {.base.} =
  let h = c.onMouseWheel
  if h != nil: h(c, shift, dx, dy, handled)
method doKeyDown*(c: Control, key: var Key, shift: ShiftState) {.base.} =
  let h = c.onKeyDown
  if h != nil: h(c, key, shift)
method doKeyUp*(c: Control, key: var Key, shift: ShiftState) {.base.} =
  let h = c.onKeyUp
  if h != nil: h(c, key, shift)
method doKeyPress*(c: Control, text: var string) {.base.} =
  let h = c.onKeyPress
  if h != nil: h(c, text)
method doTextEditing*(c: Control, text: string, cursor, selLen: int) {.base.} =
  ## IME composition (SDL TEXT_EDITING) while focused: `text` is the
  ## uncommitted composition ("" = cancelled/cleared), `cursor` the caret inside
  ## it and `selLen` the length of the selected clause (both in characters;
  ## `cursor` < 0 when the IME gave none). The composition is committed later
  ## through `doKeyPress`. Base: ignores it.
  discard
method doEnter*(c: Control) {.base.} =
  ## Gained keyboard focus.
  let h = c.onEnter
  if h != nil: h(c)
method doExit*(c: Control) {.base.} =
  ## Lost keyboard focus.
  let h = c.onExit
  if h != nil: h(c)

method captureLost*(c: Control) {.base.} =
  ## Mouse capture was taken away without a mouse-up (the window lost focus or
  ## was hidden, the control was hidden/disabled/removed, or `cancelInteraction`
  ## ran). Controls that track a drag or an auto-repeat reset it here.
  ## Base: nothing.
  discard

# --------------------------------------------------------- hook methods

method paint*(c: Control, canvas: Canvas) {.base.} =
  ## Draw the control. The canvas origin is the control's client origin and the
  ## clip is its client rect. Base: draws nothing (children are painted by
  ## `paintTree` afterwards).
  discard

method preferredSize*(c: Control): SizeF {.base.} =
  ## Natural size, used when `autoSize` is set. Base: the current size.
  sizeF(c.fWidth, c.fHeight)

method canFocus*(c: Control): bool {.base.} =
  ## Whether the control can take keyboard focus. Base: false. Focusable
  ## controls override this (typically `c.isVisible and c.isEnabled`).
  false

method focusTarget*(c: Control): Control {.base.} =
  ## The control that really takes the focus when `c` is asked to (`setFocus`,
  ## `activeControl =`, a Label's `focusControl`, a mnemonic). Base: `c`. A
  ## composite that is not focusable itself (an editable ComboBox, SpinEdit)
  ## forwards to its inner edit.
  c

method isTabStop*(c: Control): bool {.base.} =
  ## Whether Tab visits the control (combined with `canFocus` by the traversal).
  ## Base: the `tabStop` property. RadioButton overrides it (one stop per group).
  c.fTabStop

method activateMnemonic*(c: Control, ch: Rune): bool {.base.} =
  ## Alt+`ch` (a lowercased character of any script, see `keyRune`) was pressed and no menu bar item took it. A
  ## control whose caption has the mnemonic `ch` activates itself and returns
  ## true. Only called for visible, enabled controls (see `UiRoot`). Base: false.
  false

method wantsTextInput*(c: Control): bool {.base.} =
  ## Whether the control edits text: the platform starts SDL text input
  ## (soft keyboard / IME) while it has focus. Base: false.
  false

method textInputRect*(c: Control): RectF {.base.} =
  ## IME candidate area in the control's client coordinates. Base: client rect.
  c.clientRect

method hitTest*(c: Control, p: PointF): bool {.base.} =
  ## `p` is inside the control's client area (already within its bounds).
  ## Override for non-rectangular or click-through controls.
  true

method customAlign*(c: Container, child: Control, available: RectF) {.base.} =
  ## Called by `layout` for every visible `alCustom` child, after all other
  ## alignment, with the rectangle left over (client area minus padding, minus
  ## space taken by aligned siblings). Base: leaves the child as is.
  discard

method viewportRect*(c: Container): RectF {.base.} =
  ## The part of the client area in which scrolling (alNone) children are shown
  ## and hit; they are clipped to it. Base: the whole client rect.
  c.clientRect

method beforeLayout*(c: Container) {.base.} =
  ## Called by `layout` before it positions the children (content size /
  ## scrollbar bookkeeping). Marking layout from here is harmless.
  discard

method afterLayout*(c: Container) {.base.} =
  ## Called by `layout` after the children were positioned.
  discard

method arrangeChildren*(c: Container, area: RectF): bool {.base.} =
  ## Layout-owner hook, called by `layout` after `beforeLayout` with the client
  ## area deflated by `padding`. A container that positions its children itself
  ## (FlowPanel, GridPanel) does so here and returns true: `layout` then skips
  ## the align passes (children keep their `align` untouched) but still
  ## recurses into child containers. Base: false (normal align layout).
  false

method visibilityChanged*(c: Control) {.base.} =
  ## The effective visibility of `c` may have changed: `visible` of `c` or an
  ## ancestor was toggled, `c` was inserted into / removed from a tree, or the
  ## form was shown / hidden. Query `isShowing` for the current state. Not
  ## called for controls that are themselves `visible = false` below a toggled
  ## ancestor (their state did not change). Base: nothing.
  discard

method childBoundsChanged*(c: Container, child: Control) {.base.} =
  ## `child` was added, removed, shown/hidden, resized, moved or re-aligned.
  ## Called even while `c` lays out. ScrollBox uses it to track its content.
  discard

method revealControl*(c: Container, descendant: Control) {.base.} =
  ## `descendant` (somewhere below `c`) took keyboard focus; scrolling
  ## containers bring it into view. Called for every ancestor, innermost first.
  discard

# ----------------------------------------------------------------- setters

func sameFont(a, b: FontSpec): bool =
  a.family == b.family and a.size == b.size and a.style == b.style and
    a.color.r == b.color.r and a.color.g == b.color.g and a.color.b == b.color.b and
    a.color.a == b.color.a
func sameColor(a, b: Color): bool =
  a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a

proc recordDesign(c: Control) =
  ## An explicit (non-layout) placement: it becomes the anchor baseline. A
  ## container's own explicit size is its design size until its first layout
  ## (window-manager resizes go through `setHostSize` and are excluded).
  c.designRect = rectF(c.fLeft, c.fTop, c.fWidth, c.fHeight)
  let p = c.fParent
  if p != nil:
    if p.layoutInitialized:
      c.designBase = sizeF(p.fWidth, p.fHeight)
      c.designBaseSet = true
    else:
      c.designBaseSet = false

proc applyBounds(c: Control, l, t, w, h: float32, explicit: bool) =
  ## `explicit`: the placement is the user's (it becomes the anchor baseline
  ## and a container's design size); false for layout passes and window sizes.
  let nw = c.fConstraints.clampWidth(max(w, 0))
  let nh = c.fConstraints.clampHeight(max(h, 0))
  if l == c.fLeft and t == c.fTop and nw == c.fWidth and nh == c.fHeight: return
  let old = c.visualRect
  let sizeChanged = nw != c.fWidth or nh != c.fHeight
  c.fLeft = l
  c.fTop = t
  c.fWidth = nw
  c.fHeight = nh
  let inLayout = c.parentLayouting   # the parent's layout relayouts once
  if not inLayout:
    c.recordDesign()
    if explicit and c of Container:
      let k = Container(c)
      if not k.layoutInitialized:
        k.designSize = sizeF(nw, nh)
        k.designSet = true
  c.invalidateInParent(old)
  c.invalidateInParent(c.visualRect)
  if sizeChanged and c of Container:
    if inLayout: Container(c).needsLayout = true
    else: markLayout(Container(c))
  if not inLayout and c.fAlign != alNone and c.fParent != nil:
    markLayout(c.fParent)
  if c.fParent != nil: c.fParent.childBoundsChanged(c)
  if sizeChanged: c.doResize()

proc setBounds*(c: Control, l, t, w, h: float32) =
  ## Sets position and size. Width/height are clamped to >= 0 and to
  ## `constraints` (like VCL's ConstrainedResize). Fires `doResize` when the
  ## size changed.
  c.applyBounds(l, t, w, h, explicit = true)

proc setHostSize*(c: Container, w, h: float32) =
  ## The host (window) sets the size of a root container. Unlike `setBounds`
  ## this is not a design size: anchored children follow it, relative to the
  ## size the root was designed at.
  c.applyBounds(0, 0, w, h, explicit = false)

proc `left=`*(c: Control, v: float32) = c.setBounds(v, c.fTop, c.fWidth, c.fHeight)
proc `top=`*(c: Control, v: float32) = c.setBounds(c.fLeft, v, c.fWidth, c.fHeight)
proc `width=`*(c: Control, v: float32) = c.setBounds(c.fLeft, c.fTop, v, c.fHeight)
proc `height=`*(c: Control, v: float32) = c.setBounds(c.fLeft, c.fTop, c.fWidth, v)

proc `align=`*(c: Control, v: Align) =
  if v == c.fAlign: return
  c.fAlign = v
  c.requestLayout()
  if c.fParent != nil: c.fParent.childBoundsChanged(c)

proc `anchors=`*(c: Control, v: Anchors) =
  if v == c.fAnchors: return
  c.fAnchors = v
  c.requestLayout()

proc `margins=`*(c: Control, v: Spacing) =
  if v == c.fMargins: return
  c.fMargins = v
  c.requestLayout()

proc `padding=`*(c: Container, v: Spacing) =
  if v == c.fPadding: return
  c.fPadding = v
  markLayout(c)
  c.invalidate()

proc `constraints=`*(c: Control, v: SizeConstraints) =
  if v == c.fConstraints: return
  c.fConstraints = v
  c.setBounds(c.fLeft, c.fTop, c.fWidth, c.fHeight)  # re-clamp
  c.requestLayout()

proc `autoSize=`*(c: Control, v: bool) =
  if v == c.fAutoSize: return
  c.fAutoSize = v
  c.requestLayout()

proc notifyVisibility*(c: Control) =
  ## Calls `visibilityChanged` on `c` and its descendants that are `visible`
  ## themselves (see the method). The Form calls it when its window is shown or
  ## hidden.
  c.visibilityChanged()
  if c of Container:
    for ch in Container(c).fChildren:
      if ch.fVisible: notifyVisibility(ch)

# `visible`, `visible=`, `caption=` and `bringToFront` are methods: a `Form`
# overrides them (window shown, title, raise), so they behave the same when
# reached through a `Control` reference.
method visible*(c: Control): bool {.base.} = c.fVisible
method `visible=`*(c: Control, v: bool) {.base.} =
  if v == c.fVisible: return
  let h = c.host
  c.fVisible = v
  if c.fParent == nil or c.fParent.isVisible: c.notifyVisibility()
  if not v and h != nil: h.controlLost(c)
  # repaint the area it occupied/occupies in the parent
  if c.fParent != nil: c.fParent.invalidate(c.visualRect) else: c.invalidate()
  if c.fParent != nil:
    markLayout(c.fParent)
    c.fParent.childBoundsChanged(c)

func enabled*(c: Control): bool = c.fEnabled
proc `enabled=`*(c: Control, v: bool) =
  if v == c.fEnabled: return
  c.fEnabled = v
  let h = c.host
  if not v and h != nil: h.controlLost(c)
  c.invalidate()

func caption*(c: Control): string = c.fCaption
method `caption=`*(c: Control, v: string) {.base.} =
  if v == c.fCaption: return
  c.fCaption = v
  c.invalidate()
  if c.fAutoSize: c.requestLayout()
  if c of Container: markLayout(Container(c))   # computed padding may depend on it
func text*(c: Control): string = c.fCaption
proc `text=`*(c: Control, v: string) = c.caption = v

func hint*(c: Control): string = c.fHint
proc `hint=`*(c: Control, v: string) = c.fHint = v

func cursor*(c: Control): Cursor = c.fCursor
proc `cursor=`*(c: Control, v: Cursor) =
  if v == c.fCursor: return
  c.fCursor = v
  let h = c.host
  if h != nil: h.cursorChanged(c)

func tabStop*(c: Control): bool = c.fTabStop
proc `tabStop=`*(c: Control, v: bool) = c.fTabStop = v
# Tab order among siblings; equal values fall back to child order.
func tabOrder*(c: Control): int = c.fTabOrder
proc `tabOrder=`*(c: Control, v: int) = c.fTabOrder = v

# ------------------------------------------------------------- theme/font/color

proc theme*(c: Control): Theme =
  ## The effective theme: the root host's, else the global `currentTheme()`.
  let h = c.host
  if h != nil and h.theme != nil: h.theme else: currentTheme()

proc font*(c: Control): FontSpec =
  ## Effective font: own when `parentFont` is false, else the parent's, else
  ## (at the root) `theme.font`.
  if not c.fParentFont: c.fFont
  elif c.fParent != nil: c.fParent.font
  else: c.theme.font

func parentFont*(c: Control): bool = c.fParentFont

proc fontChanged(c: Control) =
  ## The effective font of `c` changed: repaint, re-measure it when auto-sized,
  ## and do the same for every descendant that inherits the font.
  c.invalidate()
  if c.fAutoSize: c.requestLayout()
  if c of Container:
    markLayout(Container(c))
    for ch in Container(c).fChildren:
      if ch.fParentFont: ch.fontChanged()

proc `font=`*(c: Control, v: FontSpec) =
  ## Sets an own font (and clears `parentFont`, like VCL).
  if not c.fParentFont and sameFont(c.fFont, v): return
  c.fFont = v
  c.fParentFont = false
  c.fontChanged()

proc `parentFont=`*(c: Control, v: bool) =
  if v == c.fParentFont: return
  if not v: c.fFont = c.font      # freeze the inherited value
  c.fParentFont = v
  c.fontChanged()

proc fontColor*(c: Control): Color =
  ## Text colour of the effective font (VCL `Font.Color`); alpha 0 means the
  ## theme's text colour.
  c.font.color

proc `fontColor=`*(c: Control, v: Color) =
  ## Shortcut for `font.color = v`: sets an own font (ends `parentFont`) with
  ## that text colour. `clTransparent` goes back to the theme's text colour.
  var f = c.font
  f.color = v
  c.font = f

proc color*(c: Control): Color

method inheritedColor*(c: Control): Color {.base.} =
  ## What `color` resolves to while `parentColor` is true: the parent's
  ## effective colour, at the root `theme.window`. Panels override it to
  ## report the surface they fill with, so their children inherit it.
  if c.fParent != nil: c.fParent.color else: c.theme.window

proc color*(c: Control): Color =
  ## Effective color: own when `parentColor` is false, else `inheritedColor`.
  if not c.fParentColor: c.fColor else: c.inheritedColor()

func parentColor*(c: Control): bool = c.fParentColor

proc `color=`*(c: Control, v: Color) =
  ## Sets an own color (and clears `parentColor`).
  if not c.fParentColor and sameColor(c.fColor, v): return
  c.fColor = v
  c.fParentColor = false
  c.invalidate()

proc `parentColor=`*(c: Control, v: bool) =
  if v == c.fParentColor: return
  if not v: c.fColor = c.color
  c.fParentColor = v
  c.invalidate()

# ----------------------------------------------------------------- tree edit

proc removeControl*(c: Container, child: Control) =
  ## Detaches `child` from `c` (no-op when it is not a child).
  let i = c.fChildren.find(child)
  if i < 0: return
  let h = c.host
  if h != nil: h.controlLost(child)      # still attached here
  c.invalidate(child.visualRect)
  c.fChildren.delete(i)
  child.fParent = nil
  markLayout(c)
  c.childBoundsChanged(child)
  if child.fVisible: child.notifyVisibility()

proc insertControl*(c: Container, child: Control, index = -1) =
  ## Adds `child` at `index` (default: append = topmost), re-parenting it from
  ## its previous parent. Both containers are marked for relayout.
  if child == nil: return
  doAssert child != Control(c) and not child.isAncestorOf(c),
    "insertControl: would create a cycle"
  if child.fParent != nil: child.fParent.removeControl(child)
  let at = if index < 0 or index > c.fChildren.len: c.fChildren.len else: index
  c.fChildren.insert(child, at)
  child.fParent = c
  child.recordDesign()     # added later: positions are relative to NOW
  markLayout(c)
  c.invalidate(child.visualRect)
  c.childBoundsChanged(child)
  if child.fVisible: child.notifyVisibility()

proc releaseTree(c: Component) =
  ## Releases `c` and everything below it: child controls, then the components
  ## it owns that are not controls (timers, action lists, menus).
  if c of Container:
    for k in Container(c).fChildren: releaseTree(k)
  let owned = c.components              # copy: a release may edit the owner
  for x in owned:
    if not (x of Control): releaseTree(x)
  if c.actionLink != nil: c.actionLink.release()
  c.releaseResources()

proc free*(c: Control) =
  ## Frees `c` permanently (VCL `Free`): removes it from its parent and owner,
  ## unlinks the action of `c` and of every descendant, drops their image list
  ## subscriptions and stops the timers they own, so nothing outside keeps the
  ## subtree alive. Without it an `Action` (its client links) or an
  ## `ImageList` (its change listeners) holds on to a removed control. Do not use `c` afterwards; to
  ## only move a control use `parent=`. Forms are closed, not freed.
  if c.fParent != nil: c.fParent.removeControl(c)
  if c.owner != nil: c.owner.removeComponent(c)
  releaseTree(c)

proc `parent=`*(c: Control, p: Container) =
  ## Re-parents: removes from the old parent, appends to the new one (nil just
  ## detaches). Relayouts both.
  if p == c.fParent: return
  if p == nil: c.fParent.removeControl(c)
  else: p.insertControl(c)

method bringToFront*(c: Control) {.base.} =
  ## Moves `c` to the end of its parent's children (topmost; also last in
  ## layout order). A `Form` raises its window instead.
  let p = c.fParent
  if p == nil or p.fChildren[^1] == c: return
  p.fChildren.delete(p.fChildren.find(c))
  p.fChildren.add c
  markLayout(p)
  c.invalidateInParent(c.visualRect)

proc sendToBack*(c: Control) =
  let p = c.fParent
  if p == nil or p.fChildren[0] == c: return
  p.fChildren.delete(p.fChildren.find(c))
  p.fChildren.insert(c, 0)
  markLayout(p)
  c.invalidateInParent(c.visualRect)

# ------------------------------------------------------------------ scrolling

proc setScrollOffset*(c: Container, x, y: float32) =
  ## Sets the raw scroll offset (no clamping: scrolling controls clamp). The
  ## alNone children move by `-offset`; repaints and tells the host so hover is
  ## re-evaluated.
  if x == c.fScrollX and y == c.fScrollY: return
  c.fScrollX = x
  c.fScrollY = y
  c.invalidate()
  let h = c.host
  if h != nil: h.scrollChanged(c)

proc `scrollOffset=`*(c: Container, p: PointF) = c.setScrollOffset(p.x, p.y)

# ------------------------------------------------------------------ hit test

proc controlAtPoint*(c: Container, p: PointF, includeDisabled = false): Control =
  ## Deepest visible descendant under `p` (client coordinates of `c`), or nil.
  ## Topmost sibling (last child) wins. Points outside `c`'s client rect hit
  ## nothing (children are clipped). Invisible controls are skipped; disabled
  ## ones (with their subtree) too unless `includeDisabled`; a skipped control
  ## lets the hit fall through to whatever is below it.
  if not c.clientRect.contains(p): return nil
  let vp = c.viewportRect()
  let inView = vp.contains(p)
  for i in countdown(c.fChildren.high, 0):
    let ch = c.fChildren[i]
    if not ch.fVisible: continue
    if not includeDisabled and not ch.fEnabled: continue
    if ch.fAlign == alNone and not inView: continue   # clipped to the viewport
    let lp = ch.parentToClient(p)
    if not ch.clientRect.contains(lp) or not ch.hitTest(lp): continue
    if ch of Container:
      let deeper = controlAtPoint(Container(ch), lp, includeDisabled)
      if deeper != nil: return deeper
    return ch

# -------------------------------------------------------------------- paint

proc visibleInForm(c: Control, r: RectF): RectF =
  ## `r` (client coordinates of `c`) clipped through every ancestor, in form
  ## (root client) coordinates; empty when it is entirely clipped away.
  result = r
  var x = c
  while true:
    result = intersect(result, x.clientRect)
    if result.isEmpty: return
    let p = x.fParent
    if p == nil: return
    result = x.clientToParent(result)
    if x.fAlign == alNone:      # scrolling children are clipped to the viewport
      result = intersect(result, p.viewportRect())
      if result.isEmpty: return
    x = p

proc paintTree*(c: Control, canvas: Canvas) =
  ## Paints `c` and its visible children. The canvas must be positioned at the
  ## parent's client origin (for a root: at the form origin). For each control:
  ## translate to its origin, clip to its client rect, `paint`, then children
  ## in z-order. Controls whose rect is fully clipped out are skipped.
  if not c.fVisible: return
  let o = if c.fParent == nil: pointF(0, 0) else: originInParent(c)
  if canvas.isClippedOut(rectF(o.x, o.y, c.fWidth, c.fHeight)): return
  inc gPaintedControls
  # scrolling (alNone) children are clipped to the parent's viewport
  var clipVp = false
  if c.fParent != nil and c.fAlign == alNone:
    let vp = c.fParent.viewportRect()
    let pr = c.fParent.clientRect
    if vp.x != pr.x or vp.y != pr.y or vp.w != pr.w or vp.h != pr.h:
      clipVp = true
      canvas.pushClip(vp)
  canvas.pushTranslate(o.x, o.y)
  canvas.pushClip(c.clientRect)
  c.paint(canvas)
  if c of Container:
    for ch in Container(c).fChildren:
      ch.paintTree(canvas)
    let over = Container(c).onPaintOver
    if over != nil: over(c, canvas)
  canvas.popClip()
  canvas.popTranslate()
  if clipVp: canvas.popClip()

proc relayoutAll*(c: Control) =
  ## Marks `c` and every container below it for relayout (theme metric change).
  if c of Container:
    markLayout(Container(c))
    for ch in Container(c).fChildren: relayoutAll(ch)
