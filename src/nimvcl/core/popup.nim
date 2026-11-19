## `PopupWindow`: a borderless window owned by a `Form`, hosting a `Container`
## tree (menus, drop-downs, tooltips).
##
## It is created with SDL_CreatePopupWindow, positioned relative to the owner's
## window (so it works with `xdg_popup` on Wayland, where an app cannot place
## its own windows). Where the video driver cannot make popups (SDL's
## `offscreen` driver, used by the tests) the platform layer falls back to a
## borderless always-on-top top-level window at the same place; nothing else
## changes, so the logic is the same everywhere.
##
## Each popup has its own `UiRoot` and `RenderContext` and paints like a form.
## `Application.dispatch` routes the events of a popup window to its popup
## (`handlePopupEvent`); popups of a form that is not allowed input (modal
## gating) are ignored, popups of the modal form work.
##
## Menu popups (`pkMenu`) form a chain per owner (menu, submenu, ...):
## * a mouse press anywhere else (in the owner form or another window of the
##   chain) closes the whole chain and is NOT delivered (Windows behaviour); the
##   matching release still is, so mouse capture is never left dangling;
## * keys go to the topmost popup's content first (`doKeyDown`), whatever
##   window SDL says has the keyboard focus (on Wayland that is the popup, on
##   X11 the owner); Esc that the content did not use closes the topmost;
## * the owner window losing the keyboard focus to something outside the
##   group closes all of them.
## Tooltips (`pkTooltip`) are outside the chain: they take no input and several
## can not exist per owner (a new one replaces the old).
##
## Placement is computed in the owner's logical coordinates and flips/slides to
## stay inside the display's usable bounds (`placePopup`). On Wayland the
## compositor constrains popups itself (the window position is unknown to
## clients), so only the anchor-relative position is used there.

import std/[monotimes, times]
import ../graphics/[geometry, context, canvas]
import ../platform/[window, events]
import ./types, ./control, ./layout, ./input, ./form

type
  PopupKind* = enum pkMenu, pkTooltip
  Placement* = enum
    plBelow,   ## under the anchor, left edges aligned (flips above)
    plAbove,   ## over the anchor (flips below)
    plRight,   ## right of the anchor, tops aligned (flips left); submenus
    plLeft

  PopupWindow* = ref object
    owner*: Form
    parent*: PopupWindow        ## previous popup of the chain (nil: first)
    kind*: PopupKind
    content*: Container
    ui*: UiRoot
    bounds*: RectF              ## in the owner's logical coordinates
    onClosed*: proc(p: PopupWindow)
    tag*: int
    fClosed: bool
    shownAt: MonoTime

var
  gPopups: seq[PopupWindow]
  popupFocusGrace* = 250      ## ms after a popup opened during which "focus lost, none gained" is ignored (focus hand-over races)
  focusIdProc*: proc(): uint32 = nil  ## test seam: replaces `keyboardFocusId`

# ------------------------------------------------------------- placement

func placePopup*(anchor: RectF, size: SizeF, bounds: RectF,
                 placement: Placement): RectF =
  ## Position of a popup of `size` next to `anchor`, kept inside `bounds`
  ## (all in the same coordinate space): the preferred side flips to the other
  ## when it does not fit but the other does, then the popup slides inside.
  ## An empty `bounds` means unconstrained.
  var x, y: float32
  let constrained = not bounds.isEmpty
  case placement
  of plBelow, plAbove:
    x = anchor.x
    let below = anchor.bottom
    let above = anchor.y - size.h
    var useBelow = placement == plBelow
    if constrained:
      if useBelow and below + size.h > bounds.bottom and above >= bounds.y: useBelow = false
      elif not useBelow and above < bounds.y and below + size.h <= bounds.bottom: useBelow = true
    y = if useBelow: below else: above
  of plRight, plLeft:
    y = anchor.y
    let rightX = anchor.right
    let leftX = anchor.x - size.w
    var useRight = placement == plRight
    if constrained:
      if useRight and rightX + size.w > bounds.right and leftX >= bounds.x: useRight = false
      elif not useRight and leftX < bounds.x and rightX + size.w <= bounds.right: useRight = true
    x = if useRight: rightX else: leftX
  if constrained:
    x = max(min(x, bounds.right - size.w), bounds.x)
    y = max(min(y, bounds.bottom - size.h), bounds.y)
  rectF(x, y, size.w, size.h)

# --------------------------------------------------------------- registry

proc findPopup*(windowId: uint32): PopupWindow =
  if windowId == 0: return nil
  for p in gPopups:
    if p.ui.win != nil and p.ui.win.id == windowId: return p

func isOpen*(p: PopupWindow): bool = not p.fClosed

proc openPopups*(): seq[PopupWindow] = gPopups

proc menuChain*(owner: Form): seq[PopupWindow] =
  ## The open menu popups of `owner`, first to topmost.
  for p in gPopups:
    if p.owner == owner and p.kind == pkMenu: result.add p

proc topPopup*(owner: Form): PopupWindow =
  ## Topmost open menu popup of `owner`, or nil.
  for i in countdown(gPopups.high, 0):
    if gPopups[i].owner == owner and gPopups[i].kind == pkMenu: return gPopups[i]

proc tooltipOf*(owner: Form): PopupWindow =
  for p in gPopups:
    if p.owner == owner and p.kind == pkTooltip: return p

proc popupOwnerOf*(windowId: uint32): Form =
  ## The owner form when `windowId` is a popup window, else nil.
  let p = findPopup(windowId)
  if p != nil: p.owner else: nil

# ------------------------------------------------------------------ close

proc closePopup*(p: PopupWindow) =
  ## Closes `p` and, first, every popup above it in its chain (menus).
  if p == nil or p.fClosed: return
  if p.kind == pkMenu:
    var above: seq[PopupWindow]
    var seen = false
    for q in gPopups:
      if q == p: seen = true
      elif seen and q.owner == p.owner and q.kind == pkMenu: above.add q
    for i in countdown(above.high, 0): closePopup(above[i])
  if p.fClosed: return
  p.fClosed = true
  let i = gPopups.find(p)
  if i >= 0: gPopups.delete(i)
  let ui = p.ui
  ui.cancelInteraction()
  ui.focusControl(nil)
  ui.closeContext()
  if ui.win != nil:
    ui.win.destroy()
    ui.win = nil
  let h = p.onClosed        # copy: the handler may clear or replace itself
  if h != nil: h(p)

proc closeAllPopups*(owner: Form) =
  ## Closes every popup of `owner` (nil: of every form), tooltips included.
  var all: seq[PopupWindow]
  for p in gPopups:
    if owner == nil or p.owner == owner: all.add p
  for i in countdown(all.high, 0): closePopup(all[i])

proc closeTooltip*(owner: Form) =
  closePopup(tooltipOf(owner))

# ------------------------------------------------------------------- show

proc paintPopup(p: PopupWindow) =
  p.ui.paintFrame(clear = true, present = true)

proc showPopup*(owner: Form, content: Container, anchorRectInForm: RectF,
                placement = plBelow, kind = pkMenu,
                parent: PopupWindow = nil): PopupWindow =
  ## Opens `content` (sized by the caller: its `width`/`height`) in a popup
  ## next to `anchorRectInForm` (owner logical px). Menus: with `parent`, the
  ## popups above `parent` are closed and the new one extends the chain;
  ## without, any open chain of `owner` is replaced. The owner must be shown.
  if owner == nil or not owner.hasWindow or not owner.visible:
    raise newException(ValueError, "showPopup: the owner form is not shown")
  case kind
  of pkMenu:
    if parent != nil:
      let chain = menuChain(owner)
      let i = chain.find(parent)
      for j in countdown(chain.high, i + 1): closePopup(chain[j])
    else:
      for p in menuChain(owner): closePopup(p)
  of pkTooltip: closeTooltip(owner)
  let ow = owner.win
  let size = sizeF(max(content.width, 1), max(content.height, 1))
  var bounds = rectF(0, 0, 0, 0)
  if not isWaylandDriver():
    let d = ow.displayUsableBounds()
    if d.ok:
      let (px, py) = ow.position
      let s = if ow.forcedScale > 0: ow.forcedScale else: 1'f32
      bounds = rectF((d.x - float32(px)) / s, (d.y - float32(py)) / s, d.w / s, d.h / s)
  let r = placePopup(anchorRectInForm, size, bounds, placement)
  # A submenu is a child of the popup below it (xdg_popup needs the topmost
  # popup as parent); its offset is relative to that popup.
  let sdlParent = if parent != nil and parent.isOpen: parent.ui.win else: ow
  let (offX, offY) =
    if sdlParent == ow: (r.x, r.y) else: (r.x - parent.bounds.x, r.y - parent.bounds.y)
  let w = createPlatformPopup(sdlParent, offX, offY, r.w, r.h,
                              (if kind == pkMenu: psMenu else: psTooltip),
                              ow.forcedScale)
  result = PopupWindow(owner: owner, parent: parent, kind: kind, content: content,
                       bounds: r)
  let ui = newUiRoot(content)        # makes `ui` the host of `content`
  ui.rootGetsMouse = true
  ui.autoSizeRoot = false
  ui.win = w
  ui.theme = owner.ui.theme
  result.ui = ui
  try:
    ui.ctx = newRenderContext(w.renderer, w.scale)
    result.shownAt = getMonoTime()
    content.setBounds(0, 0, r.w, r.h)
    gPopups.add result
    w.show()
    paintPopup(result)
  except CatchableError:
    # unregister and let go of `content`, so the caller can reuse or free it
    result.fClosed = true
    let i = gPopups.find(result)
    if i >= 0: gPopups.delete(i)
    ui.closeContext()
    ui.win = nil
    w.destroy()
    content.host = nil
    raise

# ---------------------------------------------------------------- events

proc focusId(): uint32 =
  if focusIdProc != nil: focusIdProc() else: keyboardFocusId()

proc focusMovedAway(owner: Form) =
  ## The owner or one of its popups lost the keyboard focus.
  let chain = menuChain(owner)
  if chain.len == 0: return
  let fid = focusId()
  if fid == 0 and popupFocusGrace > 0:
    if (getMonoTime() - chain[^1].shownAt).inMilliseconds < popupFocusGrace.int64: return
  if fid != 0:
    if owner.hasWindow and owner.win.id == fid: return
    for p in chain:
      if p.ui.win != nil and p.ui.win.id == fid: return
  closeAllPopups(owner)

proc routeKey(owner: Form, pe: PlatformEvent) =
  let top = topPopup(owner)
  if top == nil: return
  case pe.kind
  of ekKeyDown:
    var k = pe.key
    let ui = top.ui
    ui.withKeyRepeat(pe.repeat):
      top.content.doKeyDown(k, pe.shift)
    if k == keyEscape and top.isOpen: closePopup(top)
  of ekKeyUp:
    var k = pe.key
    top.content.doKeyUp(k, pe.shift)
  of ekTextInput:
    var s = pe.text
    top.content.doKeyPress(s)
  else: discard

proc handlePopupEvent*(pe: PlatformEvent): bool =
  ## Called by `Application.dispatch` first. True when the event belongs to a
  ## popup window or was swallowed because a menu is open; false: deliver it
  ## to the form as usual.
  let p = findPopup(pe.windowId)
  if p != nil:
    if p.kind == pkTooltip or not p.owner.acceptsInput: return true
    case pe.kind
    of ekMouseMove, ekMouseDown, ekMouseUp, ekMouseWheel, ekWindowMouseLeave,
       ekWindowResized, ekWindowPixelSize, ekWindowScale, ekWindowExposed:
      discard p.ui.handle(pe)
    of ekKeyDown, ekKeyUp, ekTextInput: routeKey(p.owner, pe)
    of ekWindowClose: closePopup(p)
    of ekWindowFocusLost: focusMovedAway(p.owner)
    else: discard
    return true
  let f = findForm(pe.windowId)
  if f == nil or topPopup(f) == nil: return false
  case pe.kind
  of ekMouseDown:
    closeAllPopups(f)
    true
  of ekMouseWheel: true
  of ekKeyDown, ekKeyUp, ekTextInput:
    routeKey(f, pe)
    true
  of ekWindowFocusLost:
    focusMovedAway(f)
    false
  else: false

proc paintPopups*(onError: proc(e: ref CatchableError) = nil) =
  ## Paints the popups that need it (over a copy of the list: painting may open
  ## or close popups). A popup whose paint raises goes to `onError`, when given
  ## (the others are still painted); without it the exception propagates.
  let all = gPopups
  for p in all:
    if p.fClosed: continue
    if p.ui.win != nil and p.ui.needsPaint:
      try: paintPopup(p)
      except CatchableError as e:
        if onError == nil: raise
        onError(e)

proc screenshotWithPopups*(f: Form, path: string): bool =
  ## Like `Form.screenshot`, with the form's open popups drawn over the form at
  ## their places (popups are separate windows, so a plain screenshot of the
  ## form shows none of them). The format follows the extension as for
  ## `Form.screenshot`. Headless/demo helper.
  f.show()
  f.syncMetrics()
  f.ui.paintFrame(clear = true, present = false)
  let cv = beginFrame(f.ctx)
  for p in gPopups:
    if p.owner != f: continue
    p.content.layoutIfNeeded()
    cv.pushTranslate(p.bounds.x, p.bounds.y)
    cv.pushClip(rectF(0, 0, p.bounds.w, p.bounds.h))
    p.content.paintTree(cv)
    cv.popClip()
    cv.popTranslate()
  cv.endFrame()
  f.win.writeImage(path)

closePopupsProc = proc(f: Form) = closeAllPopups(f)
