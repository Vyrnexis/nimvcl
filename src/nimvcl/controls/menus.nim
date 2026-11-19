## Menus: `MenuItem`, `PopupMenu` and `MainMenu` (VCL TMenuItem, TPopupMenu,
## TMainMenu).
##
## ```nim
## let mm = newMainMenu(form)                     # same as `form.menu = mm`
## let file = mm.addItem("&File")
## file.addItem("&Open...", proc(s: MenuItem) = openIt(), shortcut("Ctrl+O"))
## file.addSeparator()
## file.addItem("E&xit", proc(s: MenuItem) = form.close(), shortcut("Alt+F4"))
##
## let pm = newPopupMenu(form)
## pm.addItem("Copy")
## attachPopupMenu(panel, pm)                     # right click, Shift+F10, Menu key
## ```
##
## Items: `caption` with an `&` mnemonic (`&&` is a literal `&`; "-" is a
## separator), `shortcut` (shown right-aligned, fires the item anywhere in the
## form), `checked`, `radioItem` + `groupIndex` (clicking checks the item and
## unchecks the others of its group), `autoCheck` (clicking toggles `checked`),
## `enabled`, `visible`, `onClick`, and sub-items (`add`, `insert`, `[]`).
##
## The dropdowns are popup windows (core/popup.nim), so a click outside closes
## them and is swallowed, and the keys go to the open menu:
## Up/Down move (skipping separators and disabled items, wrapping), Right opens
## a submenu (or moves to the next top menu), Left closes it (or moves to the
## previous one), Enter/Space activate, Esc closes the topmost, a letter picks
## the item with that mnemonic.
##
## MainMenu: hover switches between top menus while one is open; Alt+letter
## opens a menu; F10 opens the first one; while Alt is held the bar mnemonics
## are underlined (`UiRoot.altHeld`, `control.altHeld`). Pressing and releasing
## Alt alone does nothing (so Alt+Tab never opens a menu). Mnemonics inside
## open dropdowns are always underlined. The bar has priority over the `&`
## mnemonics of other controls (see common.nim `drawMnemonic`).
##
## Shortcuts, F10, Alt+letter and the context-menu keys are handled in the
## key-handler chain (`UiRoot.addKeyHandler`, id "menus"), i.e. only for
## keys the focused control did not use. Needs `import nimvcl/controls/menus`
## to be linked in (the umbrella does).

import std/[strutils, unicode]
import ../core/[form, popup, application, timer]
import ../graphics/context
import ./common, ./imagelist
export imagelist

type
  Shortcut* = object
    key*: Key
    shift*: ShiftState            ## only `ssShift`, `ssCtrl`, `ssAlt` count

  MenuItem* = ref object of Component
    fCaption: string
    fShortcut: Shortcut
    fChecked, fRadio, fAutoCheck, fDisabled, fHidden: bool
    fGroup: int
    fImageIndex: int
    fItems: seq[MenuItem]
    fParent: MenuItem
    fImages: ImageList          ## on a menu's root item: the menu's icons
    onClick*: MenuItemEvent

  MenuItemEvent* = proc(sender: MenuItem)
  PopupEvent* = proc(sender: PopupMenu)
    ## `PopupMenu.onPopup`: called just before the menu opens.

  PopupMenu* = ref object of Component
    fRoot: MenuItem
    fTargets: seq[Control]
    fShown: PopupWindow           # the last popup window this menu opened
    fImgListener: int             # id in the image list (0: none)
    onPopup*: PopupEvent

  MenuPanel = ref object of Container
    ## The content of one menu popup.
    root: MenuItem
    ownerForm: Form
    popup: PopupWindow
    entries: seq[MenuItem]
    rowY, rowH: seq[float32]
    gutter: float32
    images: ImageList
    hot: int
    pressed: bool
    sub: PopupWindow
    subItem: MenuItem
    delay: Timer
    navigate: proc(dir: int)
    altKey: proc(ch: Rune): bool

  MainMenu* = ref object of Control
    fRoot: MenuItem
    fOpen, fHot: int
    fDrop: PopupWindow
    fImgListener: int

var
  menuOpening*: proc()   ## called just before a dropdown/popup menu is built (actions refresh here)
  submenuDelay* = 150    ## ms a hovered submenu item waits before opening it (0: at once)

const
  noShortcut* = Shortcut()
  RowH = 26'f32
  SepH = 9'f32
  PadV = 4'f32
  Gutter = 30'f32
  ArrowW = 24'f32
  RightPad = 14'f32
  TextGap = 36'f32
  MinPanelW = 120'f32
  BarPadX = 10'f32

# --------------------------------------------------------------- shortcuts

func shortcut*(key: Key, shift: ShiftState = {}): Shortcut =
  Shortcut(key: key, shift: shift * {ssShift, ssCtrl, ssAlt})

func shortcut*(c: char, shift: ShiftState = {}): Shortcut =
  shortcut(key(c), shift)

func isSet*(s: Shortcut): bool = s.key != Key(0)

func `==`*(a, b: Shortcut): bool = a.key == b.key and a.shift == b.shift

func normalizeKey*(k: Key): Key =
  let v = uint32(k)
  if v >= uint32('A') and v <= uint32('Z'): Key(v + 32) else: k

func `$`*(s: Shortcut): string =
  ## "Ctrl+Shift+S", "F5", "Alt+Enter"; "" when unset.
  if not s.isSet: return ""
  if ssCtrl in s.shift: result.add "Ctrl+"
  if ssAlt in s.shift: result.add "Alt+"
  if ssShift in s.shift: result.add "Shift+"
  let k = $s.key
  result.add (if k.len == 1: k.toUpperAscii else: k)

proc parseShortcut*(text: string): Shortcut =
  ## "Ctrl+S", "Ctrl+Shift+Z", "Alt+F4", "F5", "Del", "Esc". Unknown text gives
  ## `noShortcut`.
  var shift: ShiftState
  var keyName = ""
  for part in text.split('+'):
    let p = part.strip
    case p.toLowerAscii
    of "ctrl", "control": shift.incl ssCtrl
    of "shift": shift.incl ssShift
    of "alt": shift.incl ssAlt
    of "": discard
    else: keyName = p
  if keyName.len == 0: return noShortcut
  if keyName.len == 1: return shortcut(key(keyName[0]), shift)
  let low = keyName.toLowerAscii
  case low
  of "del": return shortcut(keyDelete, shift)
  of "esc": return shortcut(keyEscape, shift)
  of "ins": return shortcut(keyInsert, shift)
  of "return": return shortcut(keyEnter, shift)
  else: discard
  for v in [keyBackspace, keyTab, keyEnter, keyEscape, keySpace, keyDelete,
            keyInsert, keyHome, keyPageUp, keyEnd, keyPageDown, keyRight, keyLeft,
            keyDown, keyUp, keyF1, keyF2, keyF3, keyF4, keyF5, keyF6, keyF7, keyF8,
            keyF9, keyF10, keyF11, keyF12]:
    if ($v).toLowerAscii == low: return shortcut(v, shift)
  noShortcut

proc shortcut*(text: string): Shortcut = parseShortcut(text)

# --------------------------------------------------------------- mnemonics

# --------------------------------------------------------------- MenuItem

proc initMenuItem*(m: MenuItem, owner: Component = nil) =
  m.initComponent(owner)
  m.fImageIndex = -1

proc newMenuItem*(caption = "", onClick: MenuItemEvent = nil,
                  shortcut = noShortcut, owner: Component = nil): MenuItem =
  new result
  result.initMenuItem(owner)
  result.fCaption = caption
  result.onClick = onClick
  result.fShortcut = shortcut

func caption*(m: MenuItem): string = m.fCaption
proc `caption=`*(m: MenuItem, v: string) = m.fCaption = v
func shortcut*(m: MenuItem): Shortcut = m.fShortcut
proc `shortcut=`*(m: MenuItem, v: Shortcut) = m.fShortcut = v
func imageIndex*(m: MenuItem): int = m.fImageIndex
  ## Icon index into the menu's `images` (-1: none).
proc `imageIndex=`*(m: MenuItem, v: int) = m.fImageIndex = v
func images*(m: MenuItem): ImageList =
  ## The icons used for this item: those of the nearest menu root up the chain.
  var x = m
  while x != nil:
    if x.fImages != nil: return x.fImages
    x = x.fParent
proc `images=`*(m: MenuItem, v: ImageList) = m.fImages = v
func checked*(m: MenuItem): bool = m.fChecked
proc `checked=`*(m: MenuItem, v: bool) = m.fChecked = v
func radioItem*(m: MenuItem): bool = m.fRadio
proc `radioItem=`*(m: MenuItem, v: bool) = m.fRadio = v
func groupIndex*(m: MenuItem): int = m.fGroup
proc `groupIndex=`*(m: MenuItem, v: int) = m.fGroup = v
func autoCheck*(m: MenuItem): bool = m.fAutoCheck
proc `autoCheck=`*(m: MenuItem, v: bool) = m.fAutoCheck = v
func enabled*(m: MenuItem): bool = not m.fDisabled
proc `enabled=`*(m: MenuItem, v: bool) = m.fDisabled = not v
func visible*(m: MenuItem): bool = not m.fHidden
proc `visible=`*(m: MenuItem, v: bool) = m.fHidden = not v
func isSeparator*(m: MenuItem): bool = m.fCaption == "-"
func parent*(m: MenuItem): MenuItem = m.fParent
func count*(m: MenuItem): int = m.fItems.len
func hasSubmenu*(m: MenuItem): bool = m.fItems.len > 0
func `[]`*(m: MenuItem, i: int): MenuItem =
  ## Sub-item `i`; nil when out of range.
  if i in 0 ..< m.fItems.len: m.fItems[i] else: nil
iterator items*(m: MenuItem): MenuItem =
  for it in m.fItems: yield it
func indexOf*(m, child: MenuItem): int = m.fItems.find(child)

proc insert*(m, child: MenuItem, index: int) =
  ## Inserts `child` as sub-item `index` (clamped).
  if child.fParent != nil:
    let i = child.fParent.fItems.find(child)
    if i >= 0: child.fParent.fItems.delete(i)
  child.fParent = m
  m.fItems.insert(child, clamp(index, 0, m.fItems.len))

proc add*(m, child: MenuItem): MenuItem {.discardable.} =
  m.insert(child, m.fItems.len)
  child

proc releaseLinks(m: MenuItem) =
  ## Unlinks the actions of `m` and its sub-items (a removed item is gone for
  ## good; an `Action` would otherwise keep it alive).
  if m.actionLink != nil: m.actionLink.release()
  for it in m.fItems: it.releaseLinks()

proc delete*(m: MenuItem, index: int) =
  ## Removes the sub-item for good: its action link is released (out of range:
  ## nothing happens).
  if index notin 0 ..< m.fItems.len: return
  let it = m.fItems[index]
  it.fParent = nil
  m.fItems.delete(index)
  it.releaseLinks()

proc clear*(m: MenuItem) =
  ## Removes every sub-item for good: their action links are released.
  let old = m.fItems
  for it in old: it.fParent = nil
  m.fItems.setLen(0)
  for it in old: it.releaseLinks()

proc addItem*(m: MenuItem, caption: string, onClick: MenuItemEvent = nil,
              shortcut = noShortcut): MenuItem {.discardable.} =
  ## Appends and returns a new sub-item.
  m.add newMenuItem(caption, onClick, shortcut)

proc addSeparator*(m: MenuItem): MenuItem {.discardable.} =
  m.add newMenuItem("-")

func effectivelyEnabled(m: MenuItem): bool =
  var x = m
  while x != nil:
    if x.fDisabled or x.fHidden: return false
    x = x.fParent
  true

proc click*(m: MenuItem) =
  ## Activates the item like a click: radio items check themselves (and
  ## uncheck their group), `autoCheck` items toggle, then `onClick` runs.
  ## Ignored when disabled or hidden (also through a parent), for separators
  ## and for items with a submenu.
  if m.isSeparator or m.hasSubmenu or not m.effectivelyEnabled: return
  if m.fRadio:
    if m.fParent != nil:
      for s in m.fParent.fItems:
        if s != m and s.fRadio and s.fGroup == m.fGroup: s.fChecked = false
    m.fChecked = true
  elif m.fAutoCheck:
    m.fChecked = not m.fChecked
  if m.onClick != nil: m.onClick(m)
  if m.actionLink != nil: m.actionLink.clientClicked()

method shortcutHandled*(l: ActionLinkBase): bool {.base.} =
  ## True when the linked action fires its shortcut itself (so the menu must
  ## not fire it a second time).
  false

proc findShortcut*(m: MenuItem, sc: Shortcut): MenuItem =
  ## First enabled, visible leaf item below `m` with this shortcut.
  for it in m.fItems:
    if it.fHidden or it.fDisabled: continue
    if it.hasSubmenu:
      result = it.findShortcut(sc)
      if result != nil: return
    elif it.fShortcut.isSet and it.fShortcut == sc and not it.isSeparator:
      if it.actionLink != nil and it.actionLink.shortcutHandled: continue
      return it

# ------------------------------------------------------------ measurement

proc textSize(ctx: RenderContext, text: string, f: FontSpec): SizeF =
  if text.len == 0: return sizeF(0, 0)
  if ctx == nil or ctx.isClosed: return sizeF(float32(text.len) * 7, 16)
  let (w, h) = ctx.measureDevice(text, f)
  sizeF(w / ctx.scale, h / ctx.scale)

# ---------------------------------------------------------------- panel

func selectable(p: MenuPanel, i: int): bool =
  i >= 0 and i < p.entries.len and not p.entries[i].isSeparator and
    p.entries[i].enabled

proc rowRect(p: MenuPanel, i: int): RectF =
  rectF(1, p.rowY[i], p.width - 2, p.rowH[i])

proc rowAt(p: MenuPanel, x, y: float32): int =
  result = -1
  if x < 0 or x >= p.width: return
  for i in 0 ..< p.entries.len:
    if y >= p.rowY[i] and y < p.rowY[i] + p.rowH[i]: return i

proc newPanel(owner: Form, root: MenuItem): MenuPanel =
  ## Builds the panel and sizes it with the owner's RenderContext.
  if menuOpening != nil: menuOpening()
  new result
  result.initContainer()
  result.ownerForm = owner
  result.root = root
  result.hot = -1
  let t = owner.theme
  result.color = t.menuBg
  result.font = Control(owner).font
  let f = result.font
  let ctx = owner.ctx
  var y = 1 + PadV
  var maxCap, maxSc = 0'f32
  var anySub = false
  result.images = root.images
  result.gutter = Gutter
  if result.images != nil:
    for it in root:
      if not it.fHidden and it.imageIndex >= 0:
        result.gutter = max(Gutter, ceil(result.images.width) + 14)
        break
  for it in root:
    if it.fHidden: continue
    result.entries.add it
    let h = if it.isSeparator: SepH else: RowH
    result.rowY.add y
    result.rowH.add h
    y += h
    if not it.isSeparator:
      maxCap = max(maxCap, textSize(ctx, parseMnemonic(it.caption).text, f).w)
      maxSc = max(maxSc, textSize(ctx, $it.shortcut, f).w)
      if it.hasSubmenu: anySub = true
  let w = 2 + result.gutter + maxCap + (if maxSc > 0: TextGap + maxSc else: 0'f32) +
          (if anySub: ArrowW else: RightPad)
  result.setBounds(0, 0, ceil(max(w, MinPanelW)), ceil(y + PadV + 1))

proc closeSub(p: MenuPanel) =
  if p.sub != nil:
    let s = p.sub
    p.sub = nil
    p.subItem = nil
    closePopup(s)

proc showPanel(owner: Form, root: MenuItem, anchor: RectF, placement: Placement,
               parent: PopupWindow, selectFirst: bool,
               navigate: proc(dir: int) = nil,
               altKey: proc(ch: Rune): bool = nil,
               onClosed: proc(q: PopupWindow) = nil): PopupWindow

proc setHot(p: MenuPanel, idx: int, fromMouse: bool)
proc step(p: MenuPanel, dir: int): int

proc openSub(p: MenuPanel, idx: int, selectFirst: bool) =
  if not p.selectable(idx) or not p.entries[idx].hasSubmenu or p.popup == nil: return
  let it = p.entries[idx]
  if p.sub != nil and p.subItem == it and p.sub.isOpen:
    if selectFirst:                      # already open: move into it
      let sp = MenuPanel(p.sub.content)
      sp.setHot(sp.step(1), false)
    return
  p.closeSub()
  let r = p.rowRect(idx)
  let b = p.popup.bounds
  # the submenu overlaps the panel by 2px and lines up with the row's top
  let anchor = rectF(b.x + 2, b.y + r.y - PadV, b.w - 4, r.h)
  let panel = p
  let sp = showPanel(p.ownerForm, it, anchor, plRight, p.popup, selectFirst,
    onClosed = proc(q: PopupWindow) =
      if panel.sub == q:
        panel.sub = nil
        panel.subItem = nil)
  p.sub = sp
  p.subItem = it

proc syncSub(p: MenuPanel) =
  ## The submenu follows the hot item: opens for one with sub-items, else closes.
  if p.selectable(p.hot) and p.entries[p.hot].hasSubmenu:
    p.openSub(p.hot, false)
  else:
    p.closeSub()

proc setHot(p: MenuPanel, idx: int, fromMouse: bool) =
  if idx == p.hot: return
  p.hot = idx
  p.invalidate()
  if not fromMouse:
    p.closeSub()
  elif submenuDelay <= 0:
    p.syncSub()
  else:
    if p.delay == nil:
      p.delay = newTimer(nil, submenuDelay)
      let pn = p
      p.delay.onTimer = proc(t: Timer) =
        t.enabled = false
        if pn.popup != nil and pn.popup.isOpen: pn.syncSub()
    p.delay.enabled = false
    p.delay.enabled = true

proc activate(p: MenuPanel, idx: int, viaKeyboard = false) =
  if not p.selectable(idx): return
  let it = p.entries[idx]
  if it.hasSubmenu:
    p.openSub(idx, viaKeyboard)
    return
  let chain = menuChain(p.ownerForm)
  if chain.len > 0: closePopup(chain[0])
  it.click()

proc step(p: MenuPanel, dir: int): int =
  let n = p.entries.len
  if n == 0: return -1
  var i = if p.hot >= 0: p.hot elif dir > 0: -1 else: n
  for _ in 0 ..< n:
    i = (i + dir + n) mod n
    if p.selectable(i): return i
  -1

proc hotMenuItem*(p: PopupWindow): MenuItem =
  ## The highlighted item of a menu popup (nil: none, or not a menu popup).
  if p != nil and p.content of MenuPanel:
    let m = MenuPanel(p.content)
    if m.hot >= 0 and m.hot < m.entries.len: return m.entries[m.hot]

proc menuItemRect*(p: PopupWindow, item: MenuItem): RectF =
  ## Row of `item` in the popup's own coordinates (empty when not listed).
  if p != nil and p.content of MenuPanel:
    let m = MenuPanel(p.content)
    let i = m.entries.find(item)
    if i >= 0: return m.rowRect(i)

method paint*(p: MenuPanel, c: Canvas) =
  let t = p.theme
  let f = p.font
  let w = p.width
  c.fillRect(p.clientRect, t.menuBg)
  for i, it in p.entries:
    let r = p.rowRect(i)
    if it.isSeparator:
      c.fillRect(rectF(r.x + 8, r.y + floor(r.h / 2), r.w - 16, 1), t.menuSeparator)
      continue
    let on = it.enabled
    let hot = i == p.hot and on
    if hot: c.fillRoundRect(r.inflate(-2), 3, t.menuHover)
    let col = if not on: t.textDisabled elif hot: t.menuHoverText else: t.text
    let midY = r.y + r.h / 2
    let g = p.gutter
    let hasIcon = p.images != nil and p.images.image(it.imageIndex) != nil
    if hasIcon:
      let iw = p.images.width
      let ih = p.images.height
      if it.checked:           # a checked icon item gets a sunken frame
        let fr = rectF(r.x + (g - iw) / 2 - 3, midY - ih / 2 - 3, iw + 6, ih + 6)
        c.fillRoundRect(fr, 3, mix(t.menuBg, t.accent, 0.22))
        c.strokeRoundRect(fr, 3, mix(t.menuBorder, t.accent, 0.6), 1)
      p.images.draw(c, it.imageIndex, floor(r.x + (g - iw) / 2),
                    floor(midY - ih / 2), on)
    elif it.checked:
      if it.radioItem:
        c.fillEllipse(rectF(r.x + g / 2 - 3.5, midY - 3.5, 7, 7), col)
      else:
        let cx = r.x + g / 2 - 1
        c.line(cx - 4, midY, cx - 1.5, midY + 3, col, 1.6)
        c.line(cx - 1.5, midY + 3, cx + 4, midY - 3.5, col, 1.6)
    drawMnemonic(c, it.caption, f, rectF(r.x + g, r.y, r.w - g, r.h), col, true)
    if it.hasSubmenu:
      let ax = w - ArrowW / 2 - 2
      c.fillPolygon([pointF(ax - 3, midY - 4), pointF(ax - 3, midY + 4),
                     pointF(ax + 2, midY)], col)
    elif it.shortcut.isSet:
      let sc = $it.shortcut
      let tc = if not on: t.textDisabled elif hot: t.menuHoverText else: t.textMuted
      c.textRect(sc, f, rectF(r.x, r.y, r.w - RightPad, r.h), tc, taRight, vaCenter)
  c.frameRect(p.clientRect, t.menuBorder, 1)
  # a soft edge on the lower right, standing in for a drop shadow
  c.fillRect(rectF(2, p.height - 2, p.width - 3, 1), t.shadow)
  c.fillRect(rectF(p.width - 2, 2, 1, p.height - 3), t.shadow)

method doMouseMove*(p: MenuPanel, shift: ShiftState, x, y: float32) =
  var i = p.rowAt(x, y)
  if not p.selectable(i): i = -1
  p.setHot(i, true)
  procCall doMouseMove(Container(p), shift, x, y)

method doMouseLeave*(p: MenuPanel) =
  if p.sub == nil or not p.sub.isOpen: p.setHot(-1, true)
  procCall doMouseLeave(Container(p))

method doMouseDown*(p: MenuPanel, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    p.pressed = true
    let i = p.rowAt(x, y)
    if p.selectable(i):
      p.setHot(i, true)
      if p.entries[i].hasSubmenu: p.openSub(i, false)
  procCall doMouseDown(Container(p), button, shift, x, y)

method doMouseUp*(p: MenuPanel, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  let was = p.pressed
  if button == mbLeft:
    p.pressed = false
    let i = p.rowAt(x, y)
    if was and p.selectable(i) and not p.entries[i].hasSubmenu:
      p.activate(i)
      return
  procCall doMouseUp(Container(p), button, shift, x, y)

method doKeyDown*(p: MenuPanel, key: var Key, shift: ShiftState) =
  let k = key
  let isTop = p.popup == nil or p.popup.parent == nil
  var used = true
  if k == keyDown: p.setHot(p.step(1), false)
  elif k == keyUp: p.setHot(p.step(-1), false)
  elif k == keyHome:
    p.setHot((if p.selectable(0): 0 else: p.step(1)), false)
  elif k == keyEnd:
    p.setHot((if p.selectable(p.entries.high): p.entries.high else: p.step(-1)), false)
  elif k == keyRight:
    if p.selectable(p.hot) and p.entries[p.hot].hasSubmenu: p.openSub(p.hot, true)
    elif isTop and p.navigate != nil: p.navigate(1)
  elif k == keyLeft:
    if not isTop: closePopup(p.popup)
    elif p.navigate != nil: p.navigate(-1)
  elif k == keyEnter or k == keySpace:
    if p.hot >= 0: p.activate(p.hot, true)
  elif shift * {ssCtrl} == {} and int(keyRune(k)) != 0:
    let ch = keyRune(k)
    if ssAlt in shift:
      used = p.altKey != nil and p.altKey(ch)
    else:
      var matches: seq[int]
      for i in 0 ..< p.entries.len:
        if p.selectable(i) and parseMnemonic(p.entries[i].caption).ch == ch:
          matches.add i
      if matches.len == 1:
        p.setHot(matches[0], false)
        p.activate(matches[0], true)
      elif matches.len > 1:
        let at = matches.find(p.hot)
        p.setHot(matches[(at + 1) mod matches.len], false)
      else: used = false
  else: used = false
  if used: key = Key(0)
  procCall doKeyDown(Container(p), key, shift)

proc showPanel(owner: Form, root: MenuItem, anchor: RectF, placement: Placement,
               parent: PopupWindow, selectFirst: bool,
               navigate: proc(dir: int) = nil,
               altKey: proc(ch: Rune): bool = nil,
               onClosed: proc(q: PopupWindow) = nil): PopupWindow =
  ## Opens one menu panel; `onClosed` runs after the panel's own cleanup.
  let panel = newPanel(owner, root)
  panel.navigate = navigate
  panel.altKey = altKey
  result = showPopup(owner, panel, anchor, placement, pkMenu, parent)
  panel.popup = result
  if selectFirst: panel.setHot(panel.step(1), false)
  result.onClosed = proc(q: PopupWindow) =
    if panel.delay != nil: panel.delay.free()
    if onClosed != nil: onClosed(q)

# ------------------------------------------------------------ registration

proc menuForm(c: Control): Form =
  let r = c.root
  if r of Form: Form(r) else: nil

proc popupMenuOfControl(f: Form, c: Control): PopupMenu
proc registerForm(f: Form)

# -------------------------------------------------------------- PopupMenu

proc initPopupMenu*(m: PopupMenu, owner: Component = nil) =
  m.initComponent(owner)
  m.fRoot = newMenuItem()

proc newPopupMenu*(owner: Component = nil): PopupMenu {.discardable.} =
  new result
  result.initPopupMenu(owner)

func items*(m: PopupMenu): MenuItem = m.fRoot
  ## The root item; its sub-items are the menu's entries.
func images*(m: PopupMenu): ImageList = m.fRoot.fImages
proc `images=`*(m: PopupMenu, v: ImageList) =
  ## Icons of the menu; the open popup repaints when the list changes.
  let old = m.fRoot.fImages
  if old != nil and m.fImgListener != 0: old.removeListener m.fImgListener
  m.fImgListener = 0
  m.fRoot.fImages = v
  if v != nil:
    m.fImgListener = v.addListener(proc() =
      if m.fShown != nil and m.fShown.isOpen: m.fShown.content.invalidate())
proc add*(m: PopupMenu, item: MenuItem): MenuItem {.discardable.} = m.fRoot.add item
proc addItem*(m: PopupMenu, caption: string, onClick: MenuItemEvent = nil,
              shortcut = noShortcut): MenuItem {.discardable.} =
  m.fRoot.addItem(caption, onClick, shortcut)
proc addSeparator*(m: PopupMenu): MenuItem {.discardable.} = m.fRoot.addSeparator()

proc close*(m: PopupMenu) =
  ## Closes the menu (and its open submenus) if it is open. Other menus, such
  ## as an open main-menu dropdown, are left alone.
  if m.fShown != nil:
    let p = m.fShown
    m.fShown = nil
    if p.isOpen: closePopup(p)

proc free*(m: PopupMenu) =
  ## Frees the menu for good: closes it, unlinks the actions of its items,
  ## drops its image list subscription and detaches it from its owner.
  m.close()
  m.images = nil
  m.fRoot.clear()                   # releases the action links; no shortcut fires
  for t in m.fTargets:
    if t.popupMenuRef == RootRef(m): t.popupMenuRef = nil
    let f = t.menuForm
    if f != nil:
      let i = f.popupMenus.find(RootRef(m))
      if i >= 0: f.popupMenus.delete(i)
  m.fTargets.setLen(0)
  if m.owner != nil: m.owner.removeComponent(m)

proc popup*(m: PopupMenu, form: Form, x, y: float32,
            selectFirst = false): PopupWindow {.discardable.} =
  ## Shows the menu with its top-left at (`x`, `y`) in the form's logical
  ## coordinates (it flips/slides to stay on screen). Returns nil when the
  ## form is not shown or the menu has no visible items.
  if form == nil or not form.visible or not form.hasWindow: return nil
  if m.onPopup != nil: m.onPopup(m)       # may add / show / hide items
  var any = false
  for it in m.fRoot:
    if not it.fHidden: any = true
  if not any: return nil
  if RootRef(m) notin form.popupMenus: form.popupMenus.add m
  registerForm(form)
  result = showPanel(form, m.fRoot, rectF(x, y, 0, 0), plBelow, nil, selectFirst)
  m.fShown = result

proc popupAt*(m: PopupMenu, c: Control, selectFirst = false): PopupWindow {.discardable.} =
  ## Shows the menu below the control (aligned to its left edge).
  let f = c.menuForm
  if f == nil: return nil
  let p = c.clientToForm(pointF(0, c.height))
  m.popup(f, p.x, p.y, selectFirst)

proc resolveMenu(m: PopupMenu, c: Control) =
  ## Registers `m` (its shortcuts, context-menu keys) in the form `c` is in;
  ## a no-op while `c` is not in a form.
  let f = c.menuForm
  if f != nil:
    if RootRef(m) notin f.popupMenus: f.popupMenus.add m
    registerForm(f)

proc attachPopupMenu*(c: Control, m: PopupMenu) =
  ## Makes `m` the context menu of `c`: right click (on release, after the
  ## control's own `onMouseUp`, which is left untouched), Shift+F10 and the Menu key while `c` or a
  ## control inside it has the focus. Also registers the menu's shortcuts in
  ## the form. A control can have several menus; the last attached wins.
  ## `c` need not be in a form yet: the menu registers itself with the form the
  ## first time `c` is entered, clicked or gets a key (and right away when `c`
  ## is already in a form).
  m.fTargets.add c
  c.popupMenuRef = m
  m.resolveMenu c

proc popupMenuOfControl(f: Form, c: Control): PopupMenu =
  ## The (last attached) popup menu of `c` or its nearest ancestor with one.
  if f == nil: return nil
  var x = c
  while x != nil:
    for i in countdown(f.popupMenus.high, 0):
      let pm = PopupMenu(f.popupMenus[i])
      if pm.fTargets.find(x) >= 0: return pm
    x = Control(x.parent)

proc popupMenuOf*(c: Control): PopupMenu = popupMenuOfControl(c.menuForm, c)

proc serveContextMenus(c: Control, kind: PopupHookKind, button: MouseButton,
                       p: PointF) {.nimcall.} =
  ## The library's own path for context menus (see `input.popupHook`): the
  ## nearest control up the parent chain with a menu registers it with the
  ## form (so its shortcuts and Shift+F10 / Menu key work), and a right-button
  ## release shows it. The control's event fields are not involved.
  var x = c
  while x != nil and x.popupMenuRef == nil: x = Control(x.parent)
  if x == nil: return
  let f = c.menuForm
  if f == nil: return
  PopupMenu(x.popupMenuRef).resolveMenu x
  if kind == phMouseUp and button == mbRight:
    let pm = popupMenuOfControl(f, c)
    if pm != nil: pm.popup(f, p.x, p.y)

popupHook = serveContextMenus

proc popupMenu*(c: Control): PopupMenu =
  ## The menu attached to `c` itself (`popupMenu = m`, `attachPopupMenu`); nil
  ## when none. (`popupMenuOf` also looks at the ancestors, in a form.)
  if c.popupMenuRef == nil: nil else: PopupMenu(c.popupMenuRef)

proc `popupMenu=`*(c: Control, m: PopupMenu) =
  ## Designer property: the context menu of `c` (nil removes it). Equivalent
  ## to `attachPopupMenu` (the old menu stops serving `c`).
  let old = c.popupMenu
  if old == m: return
  if old != nil:
    let i = old.fTargets.find(c)
    if i >= 0: old.fTargets.delete(i)
    c.popupMenuRef = nil
  if m != nil: c.attachPopupMenu(m)

# --------------------------------------------------------------- MainMenu

func visibleIndices(m: MainMenu): seq[int] =
  for i in 0 ..< m.fRoot.count:
    if not m.fRoot[i].fHidden: result.add i

proc itemRects(m: MainMenu): seq[tuple[idx: int, r: RectF]] =
  var x = 4'f32
  let f = m.font
  let ctx = m.renderCtx
  for i in m.visibleIndices:
    let w = ceil(textSize(ctx, parseMnemonic(m.fRoot[i].caption).text, f).w) + 2 * BarPadX
    result.add (i, rectF(x, 2, w, max(m.height - 4, 0)))
    x += w

proc initMainMenu*(m: MainMenu, owner: Component = nil) =
  m.initControl(owner)
  m.fRoot = newMenuItem()
  m.fOpen = -1
  m.fHot = -1
  m.setBounds(0, 0, 200, currentTheme().controlHeight)
  m.align = alTop

func items*(m: MainMenu): MenuItem = m.fRoot
func images*(m: MainMenu): ImageList = m.fRoot.fImages
proc `images=`*(m: MainMenu, v: ImageList) =
  ## Icons of the menu; the bar and an open dropdown repaint when the list
  ## changes.
  let old = m.fRoot.fImages
  if old != nil and m.fImgListener != 0: old.removeListener m.fImgListener
  m.fImgListener = 0
  m.fRoot.fImages = v
  if v != nil:
    m.fImgListener = v.addListener(proc() =
      m.invalidate()
      if m.fDrop != nil and m.fDrop.isOpen: m.fDrop.content.invalidate())
method releaseResources*(m: MainMenu) =
  m.images = nil
  m.fRoot.releaseLinks()
proc add*(m: MainMenu, item: MenuItem): MenuItem {.discardable.} = m.fRoot.add item
proc addItem*(m: MainMenu, caption: string, onClick: MenuItemEvent = nil,
              shortcut = noShortcut): MenuItem {.discardable.} =
  m.fRoot.addItem(caption, onClick, shortcut)

func openIndex*(m: MainMenu): int = m.fOpen
  ## Index (in `items`) of the top menu whose dropdown is open, or -1.

proc closeMenus*(m: MainMenu) =
  ## Closes an open dropdown.
  if m.fDrop != nil: closePopup(m.fDrop)

proc openDropdown*(m: MainMenu, idx: int, selectFirst = false) =
  ## Opens the dropdown of top item `idx` (replacing an open one).
  let f = m.menuForm
  if f == nil or not f.visible or idx < 0 or idx >= m.fRoot.count: return
  let it = m.fRoot[idx]
  if it.fHidden or it.fDisabled or not it.hasSubmenu: return
  var rect: RectF
  for e in m.itemRects:
    if e.idx == idx: rect = m.clientToForm(e.r)
  let mm = m
  let nav = proc(dir: int) =
    let v = mm.visibleIndices
    let at = v.find(mm.fOpen)
    if v.len == 0: return
    var n = at
    for _ in 0 ..< v.len:                     # next enabled one with a dropdown
      n = (n + dir + v.len) mod v.len
      let c = mm.fRoot[v[n]]
      if not c.fDisabled and c.hasSubmenu:
        mm.openDropdown(v[n], true)
        return
  let alt = proc(ch: Rune): bool =
    for i in mm.visibleIndices:
      let c = mm.fRoot[i]
      if not c.fDisabled and c.hasSubmenu and parseMnemonic(c.caption).ch == ch:
        mm.openDropdown(i, true)
        return true
  m.closeMenus()
  let p = showPanel(f, it, rect, plBelow, nil, selectFirst, nav, alt,
    onClosed = proc(q: PopupWindow) =
      if mm.fDrop == q:
        mm.fDrop = nil
        mm.fOpen = -1
        mm.invalidate())
  m.fDrop = p
  m.fOpen = idx
  m.invalidate()

proc openByMnemonic*(m: MainMenu, ch: Rune): bool =
  ## Opens the dropdown whose caption has the mnemonic `ch`.
  for i in m.visibleIndices:
    let c = m.fRoot[i]
    if not c.fDisabled and c.hasSubmenu and parseMnemonic(c.caption).ch == ch.toLower:
      m.openDropdown(i, true)
      return true

proc openFirst*(m: MainMenu): bool =
  for i in m.visibleIndices:
    let c = m.fRoot[i]
    if not c.fDisabled and c.hasSubmenu:
      m.openDropdown(i, true)
      return true

proc itemRect*(m: MainMenu, idx: int): RectF =
  ## Bar rectangle of top item `idx` in the control's coordinates (empty when hidden).
  for e in m.itemRects:
    if e.idx == idx: return e.r

proc itemAt(m: MainMenu, x, y: float32): int =
  result = -1
  for e in m.itemRects:
    if e.r.contains(pointF(x, y)): return e.idx

method paint*(m: MainMenu, c: Canvas) =
  let t = m.theme
  c.fillRect(m.clientRect, t.menuBg)
  c.fillRect(rectF(0, m.height - 1, m.width, 1), t.border)
  let underline = m.altHeld or m.fOpen >= 0
  for e in m.itemRects:
    let it = m.fRoot[e.idx]
    let on = not it.fDisabled
    let lit = e.idx == m.fOpen or (e.idx == m.fHot and on)
    if lit: c.fillRoundRect(e.r, t.radius, t.menuHover)
    let col = if not on: t.textDisabled elif lit: t.menuHoverText else: t.text
    drawMnemonic(c, it.caption, m.font, rectF(e.r.x + BarPadX, e.r.y,
                 e.r.w - 2 * BarPadX, e.r.h), col, underline)
  procCall paint(Control(m), c)

method preferredSize*(m: MainMenu): SizeF = sizeF(m.width, m.theme.controlHeight)

method doMouseMove*(m: MainMenu, shift: ShiftState, x, y: float32) =
  let i = m.itemAt(x, y)
  if i != m.fHot:
    m.fHot = i
    m.invalidate()
    if i >= 0 and m.fOpen >= 0 and i != m.fOpen: m.openDropdown(i)
  procCall doMouseMove(Control(m), shift, x, y)

method doMouseLeave*(m: MainMenu) =
  if m.fHot >= 0:
    m.fHot = -1
    m.invalidate()
  procCall doMouseLeave(Control(m))

method doMouseDown*(m: MainMenu, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    let i = m.itemAt(x, y)
    if i >= 0 and not m.fRoot[i].fDisabled:
      if m.fRoot[i].hasSubmenu: m.openDropdown(i)
      else: m.fRoot[i].click()
  procCall doMouseDown(Control(m), button, shift, x, y)

# ----------------------------------------------------------- form integration

proc menu*(f: Form): MainMenu =
  if f.menuBar != nil and f.menuBar of MainMenu: MainMenu(f.menuBar) else: nil

proc handleMenuKey(f: Form, key: var Key, shift: ShiftState) =
  let mods = shift * {ssShift, ssCtrl, ssAlt}
  let bar = f.menu
  let k = normalizeKey(key)
  if bar != nil and bar.isVisible:
    if k == keyF10 and mods == {}:
      if bar.openFirst(): key = Key(0)
      return
    if mods == {ssAlt} and int(keyRune(k)) != 0:
      if bar.openByMnemonic(keyRune(k)):
        key = Key(0)
        return
  if (k == keyApplication and mods == {}) or (k == keyF10 and mods == {ssShift}):
    let ac = f.activeControl
    let pm = popupMenuOfControl(f, if ac != nil: ac else: Control(f))
    if pm != nil:
      let target = if ac != nil: ac else: Control(f)
      pm.popupAt(target, true)
      key = Key(0)
      return
  if ssSuper in shift: return            # Super+key is never a menu shortcut
  if mods == {} and (uint32(k) < 0x20 or uint32(k) > 0x7e) and k notin [
      keyF1, keyF2, keyF3, keyF4, keyF5, keyF6, keyF7, keyF8, keyF9, keyF10, keyF11,
      keyF12, keyDelete, keyInsert, keyHome, keyEnd, keyPageUp, keyPageDown]:
    return
  let sc = shortcut(k, mods)
  var it: MenuItem
  if bar != nil: it = bar.fRoot.findShortcut(sc)
  if it == nil:
    for r in f.popupMenus:
      it = PopupMenu(r).fRoot.findShortcut(sc)
      if it != nil: break
  if it != nil:
    key = Key(0)
    it.click()

proc registerForm(f: Form) =
  f.addKeyHandler("menus", proc(key: var Key, shift: ShiftState) =
    handleMenuKey(f, key, shift))

proc `menu=`*(f: Form, m: MainMenu) =
  ## Installs `m` as the form's menu bar (at the top) and registers its
  ## shortcuts.
  if f.menuBar == Control(m): return
  if f.menuBar != nil and f.menuBar.parent == Container(f):
    f.removeControl f.menuBar
  f.menuBar = m
  if m == nil: return
  m.align = alTop
  if m.parent != Container(f): f.insertControl m
  m.sendToBack()
  registerForm(f)

proc newMainMenu*(parent: Container = nil): MainMenu {.discardable.} =
  ## With a `Form` as `parent` the menu becomes the form's `menu`; with another
  ## container it is just a control there (shortcuts work when the container's
  ## root is a Form that was given the menu with `form.menu = ...`).
  new result
  result.initMainMenu(parent)
  if parent != nil and parent of Form: Form(parent).menu = result
  elif parent != nil: parent.insertControl result

# `loadForm` (dsl/formload) builds objects that are not `newT(parent: Container)`
# controls with `nfmMake(T, parent)`, found in the scope of the calling module.

proc nfmMake*(T: typedesc[MenuItem], parent: MenuItem): MenuItem =
  result = newMenuItem(owner = parent)
  parent.add result

proc nfmMake*(T: typedesc[MenuItem], parent: MainMenu): MenuItem =
  result = newMenuItem(owner = parent)
  parent.add result

proc nfmMake*(T: typedesc[MenuItem], parent: PopupMenu): MenuItem =
  result = newMenuItem(owner = parent)
  parent.add result
