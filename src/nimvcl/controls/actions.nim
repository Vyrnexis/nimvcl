## `Action` and `ActionList` (VCL TAction, TActionList): one command, shared by
## menu items, toolbar buttons, buttons, check boxes and keyboard shortcuts.
##
## ```nim
## let acts = newActionList(form)
## acts.images = icons
## let wrap = acts.add newAction(acts, "&Word wrap", shortcut = shortcut("Ctrl+W"))
## wrap.autoCheck = true
## wrap.hint = "Wrap long lines"
## wrap.imageIndex = 2
## wrap.onExecute = proc(a: Action) = memo.wordWrap = a.checked
## menuItem.action = wrap          # MenuItem
## toolButton.action = wrap        # ToolButton (kind becomes tbsCheck)
## checkBox.action = wrap          # CheckBox, Button, or any other Control
## ```
##
## Action properties: `caption` (with `&` mnemonic), `hint`, `enabled`,
## `visible`, `checked`, `autoCheck` (executing toggles `checked`), `groupIndex`
## (> 0: radio group within the ActionList; executing checks the action and
## unchecks the others), `shortcut`, `imageIndex` (into `ActionList.images`),
## `category`, and the events `onExecute(sender)` and `onUpdate(sender)`.
## `execute(a)` runs the action (false when disabled or nobody handled it);
## `ActionList.onExecute(a, handled)` sees it first and can set `handled`.
##
## Linking: `client.action = a` (MenuItem, or any Control; nil unlinks). The
## client mirrors caption, hint, enabled, visible, checked (CheckBox,
## ToolButton, MenuItem), imageIndex (ToolButton, MenuItem) and shortcut (shown
## in menus) immediately and again on every change of the action; the ACTION
## wins whenever it changes (a client property set by hand sticks only until
## then). A click on the client runs the action (after the client's own
## `onClick`). Check-style clients that toggle themselves (check box, check
## tool button, auto-check menu item) report their new state to the action, so
## every other client follows. ToolButtons of a `tbsButton` kind become
## `tbsCheck` when the action is `autoCheck` or grouped; toolbars and menus
## without `images` adopt the list's. ToolButton captions drop the `&`.
##
## Shortcuts: each ActionList whose owner (or an ancestor owner) is a Form
## installs ONE key handler in that form (`Form.addKeyHandler`), so shortcuts
## work without any menu item; linked menu items only DISPLAY the shortcut.
## Actions of a list without a form owner keep firing through their menu items.
##
## `onUpdate`: the application calls `updateActions()` (every ActionList owned
## by an open form) from an idle hook, i.e. once after each batch of events and
## right before a menu opens, never continuously. Use it to compute `enabled`
## or `checked` from application state. Setting a property to its current value
## costs nothing, so an `onUpdate` can assign unconditionally.
##
## Lifetime: links are strong references (action <-> client). Unlink with
## `client.action = nil`, or `free(action)` (unlinks all clients and removes it
## from its list), or `free(list)`.

import std/strutils
import ../core/[form, application]
import ./common, ./menus, ./toolbar, ./button, ./checkbox, ./imagelist

export menus, imagelist

type
  ActionEvent* = proc(sender: Action)
  ActionListEvent* = proc(sender: Action, handled: var bool)

  Action* = ref object of Component
    fCaption, fHint, fCategory: string
    fHidden, fDisabled, fChecked, fAutoCheck: bool
    fGroup, fImageIndex: int
    fShortcut: Shortcut
    fList: ActionList
    fLinks: seq[ActionLink]
    onExecute*, onUpdate*: ActionEvent

  ActionList* = ref object of Component
    fActions: seq[Action]
    fImages: ImageList
    fHooked: bool
    onExecute*, onUpdate*: ActionListEvent

  ActionLink = ref object of ActionLinkBase
    action: Action
    item: MenuItem
    ctl: Control
    origKind: ToolButtonKind   # a ToolButton's style before the action upgraded it
    upgraded: bool

# ------------------------------------------------------------------ links

proc apply(l: ActionLink)

proc notify(a: Action) =
  let links = a.fLinks   # callbacks may link/unlink while we iterate
  for l in links: l.apply()

proc images(a: Action): ImageList =
  if a.fList != nil: a.fList.fImages else: nil

proc apply(l: ActionLink) =
  let a = l.action
  if l.item != nil:
    let m = l.item
    m.caption = a.fCaption
    m.enabled = not a.fDisabled
    m.visible = not a.fHidden
    m.shortcut = a.fShortcut
    m.imageIndex = a.fImageIndex
    m.radioItem = a.fGroup > 0
    m.groupIndex = a.fGroup
    m.autoCheck = a.fAutoCheck and a.fGroup == 0
    m.checked = a.fChecked
    var top = m
    while top.parent != nil: top = top.parent
    if top.images == nil and a.images != nil: top.images = a.images
  elif l.ctl != nil:
    let c = l.ctl
    c.hint = a.fHint
    c.enabled = not a.fDisabled
    c.visible = not a.fHidden
    if c of ToolButton:
      let b = ToolButton(c)
      b.caption = parseMnemonic(a.fCaption).text
      let wantsCheck = a.fAutoCheck or a.fGroup > 0
      if wantsCheck and b.kind == tbsButton:
        l.origKind = b.kind
        l.upgraded = true
        b.kind = tbsCheck
      elif not wantsCheck and l.upgraded:
        b.down = false
        b.kind = l.origKind
        l.upgraded = false
      if b.kind == tbsCheck:
        b.groupIndex = a.fGroup
        b.down = a.fChecked
      b.imageIndex = a.fImageIndex
      if b.parent != nil and b.parent of ToolBar:
        let bar = ToolBar(b.parent)
        if bar.images == nil and a.images != nil: bar.images = a.images
    else:
      c.caption = a.fCaption
      if c of CheckBox: CheckBox(c).checked = a.fChecked

# ----------------------------------------------------------------- Action

proc initAction*(a: Action, owner: Component = nil) =
  a.initComponent(owner)
  a.fImageIndex = -1

func caption*(a: Action): string = a.fCaption
proc `caption=`*(a: Action, v: string) =
  if v == a.fCaption: return
  a.fCaption = v
  a.notify()

func hint*(a: Action): string = a.fHint
proc `hint=`*(a: Action, v: string) =
  if v == a.fHint: return
  a.fHint = v
  a.notify()

func category*(a: Action): string = a.fCategory
proc `category=`*(a: Action, v: string) = a.fCategory = v

func enabled*(a: Action): bool = not a.fDisabled
proc `enabled=`*(a: Action, v: bool) =
  if v == not a.fDisabled: return
  a.fDisabled = not v
  a.notify()

func visible*(a: Action): bool = not a.fHidden
proc `visible=`*(a: Action, v: bool) =
  if v == not a.fHidden: return
  a.fHidden = not v
  a.notify()

func imageIndex*(a: Action): int = a.fImageIndex
proc `imageIndex=`*(a: Action, v: int) =
  if v == a.fImageIndex: return
  a.fImageIndex = v
  a.notify()

func shortcut*(a: Action): Shortcut = a.fShortcut
proc `shortcut=`*(a: Action, v: Shortcut) =
  if v == a.fShortcut: return
  a.fShortcut = v
  a.notify()

func autoCheck*(a: Action): bool = a.fAutoCheck
proc `autoCheck=`*(a: Action, v: bool) =
  if v == a.fAutoCheck: return
  a.fAutoCheck = v
  a.notify()

func groupIndex*(a: Action): int = a.fGroup
proc `groupIndex=`*(a: Action, v: int) =
  if v == a.fGroup: return
  a.fGroup = v
  a.notify()

func checked*(a: Action): bool = a.fChecked
proc `checked=`*(a: Action, v: bool) =
  ## Checking a grouped action unchecks the others of its list's group.
  if v == a.fChecked: return
  a.fChecked = v
  if v and a.fGroup > 0 and a.fList != nil:
    let others = a.fList.fActions
    for o in others:
      if o != a and o.fGroup == a.fGroup and o.fChecked:
        o.fChecked = false
        o.notify()
  a.notify()

func list*(a: Action): ActionList = a.fList
func clientCount*(a: Action): int = a.fLinks.len

proc run(a: Action): bool =
  ## The event chain (no auto-check): list hook, then `onExecute`.
  var handled = false
  if a.fList != nil and a.fList.onExecute != nil: a.fList.onExecute(a, handled)
  if not handled and a.onExecute != nil:
    a.onExecute(a)
    handled = true
  handled

proc execute*(a: Action): bool {.discardable.} =
  ## Runs the action: ignored (false) while disabled; an `autoCheck` action
  ## toggles `checked` first; a grouped one (autoCheck or not) becomes checked. True when a
  ## handler ran.
  if a.fDisabled: return false
  if a.fAutoCheck or a.fGroup > 0:
    a.checked = if a.fGroup > 0: true else: not a.fChecked
  a.run()

proc update*(a: Action) =
  ## Runs the list's and the action's `onUpdate` (done by the idle hook).
  var handled = false
  if a.fList != nil and a.fList.onUpdate != nil: a.fList.onUpdate(a, handled)
  if not handled and a.onUpdate != nil: a.onUpdate(a)

# ------------------------------------------------------------- the links

method clientClicked(l: ActionLink) =
  let a = l.action
  if a == nil or a.fDisabled: return
  var checkable = false
  var state = false
  if l.item != nil:
    checkable = l.item.autoCheck or l.item.radioItem
    state = l.item.checked
  elif l.ctl of CheckBox:
    checkable = true
    state = CheckBox(l.ctl).checked or a.fGroup > 0   # a group member never unchecks itself
  elif l.ctl of ToolButton and ToolButton(l.ctl).kind == tbsCheck:
    checkable = true
    state = ToolButton(l.ctl).down
  if checkable:          # the client toggled itself: the action follows
    a.checked = state
    l.apply()            # resync a client that toggled against the action's state
    discard a.run()
  else:
    discard a.execute()

method shortcutHandled(l: ActionLink): bool =
  l.action != nil and l.action.fList != nil and l.action.fList.fHooked

proc detach(l: ActionLink) =
  if l.item != nil and l.item.actionLink == ActionLinkBase(l): l.item.actionLink = nil
  if l.ctl != nil and l.ctl.actionLink == ActionLinkBase(l): l.ctl.actionLink = nil

proc unlink(a: Action, l: ActionLink) =
  let i = a.fLinks.find(l)
  if i >= 0: a.fLinks.delete(i)

proc link(a: Action, l: ActionLink) =
  l.action = a
  a.fLinks.add l
  l.apply()

proc releaseClient(c: Component) =
  let old = c.actionLink
  if old != nil and old of ActionLink:
    let l = ActionLink(old)
    if l.upgraded and l.ctl != nil and l.ctl of ToolButton:
      ToolButton(l.ctl).down = false
      ToolButton(l.ctl).kind = l.origKind
      l.upgraded = false
    l.detach()
    if l.action != nil: l.action.unlink(l)
    l.action = nil

proc `action=`*(m: MenuItem, a: Action) =
  ## Links the item to `a` (nil unlinks; a previous link is replaced).
  if a != nil and m.actionLink != nil and m.actionLink of ActionLink and
     ActionLink(m.actionLink).action == a: return
  releaseClient(m)
  if a == nil: return
  let l = ActionLink(item: m)
  m.actionLink = l
  a.link l

proc `action=`*(c: Control, a: Action) =
  ## Links any control (Button, CheckBox, ToolButton, ...); see the module docs.
  if a != nil and c.actionLink != nil and c.actionLink of ActionLink and
     ActionLink(c.actionLink).action == a: return
  releaseClient(c)
  if a == nil: return
  let l = ActionLink(ctl: c)
  c.actionLink = l
  a.link l

proc action*(m: MenuItem): Action =
  if m.actionLink != nil and m.actionLink of ActionLink:
    result = ActionLink(m.actionLink).action

proc action*(c: Control): Action =
  if c.actionLink != nil and c.actionLink of ActionLink:
    result = ActionLink(c.actionLink).action

proc free*(a: Action) =
  ## Unlinks every client and removes the action from its list and owner.
  for l in a.fLinks:
    l.detach()
    l.action = nil
  a.fLinks.setLen(0)
  if a.fList != nil:
    let i = a.fList.fActions.find(a)
    if i >= 0: a.fList.fActions.delete(i)
    a.fList = nil
  if a.owner != nil: a.owner.removeComponent(a)

# --------------------------------------------------------------- ActionList

func images*(l: ActionList): ImageList = l.fImages
proc `images=`*(l: ActionList, v: ImageList) =
  l.fImages = v
  for a in l.fActions: a.notify()

func count*(l: ActionList): int = l.fActions.len
func `[]`*(l: ActionList, i: int): Action = l.fActions[i]
iterator items*(l: ActionList): Action =
  for a in l.fActions: yield a

proc find*(l: ActionList, name: string): Action =
  ## The action with this component `name`, else nil.
  for a in l.fActions:
    if a.name == name: return a

proc formOf(c: Component): Form =
  var x = c
  while x != nil:
    if x of Form: return Form(x)
    x = x.owner

proc ensureHook(l: ActionList) =
  ## One key handler per list in the owner form (idempotent).
  if l.fHooked: return
  let f = formOf(l)
  if f == nil: return
  l.fHooked = true
  let list = l
  f.addKeyHandler("actions:" & $cast[uint](l), proc(key: var Key, shift: ShiftState) =
    if key == Key(0): return
    let mods = shift * {ssShift, ssCtrl, ssAlt}
    let k = normalizeKey(key)
    let ac = f.activeControl
    if mods * {ssCtrl, ssAlt} == {} and uint32(k) >= 0x20 and uint32(k) <= 0x7e and
       ac != nil and ac.wantsTextInput():
      return   # plain typing in an Edit/Memo is never a shortcut
    if mods == {} and (uint32(k) < 0x20 or uint32(k) > 0x7e) and k notin [
        keyF1, keyF2, keyF3, keyF4, keyF5, keyF6, keyF7, keyF8, keyF9, keyF10,
        keyF11, keyF12, keyDelete, keyInsert, keyHome, keyEnd, keyPageUp,
        keyPageDown]:
      return
    let sc = shortcut(k, mods)
    for a in list.fActions:
      if a.fShortcut.isSet and a.fShortcut == sc and not a.fDisabled and
         not a.fHidden:
        key = Key(0)
        a.execute()
        return)

proc add*(l: ActionList, a: Action): Action {.discardable.} =
  ## Adds `a` (moving it from another list).
  if a.fList == l: return a
  if a.fList != nil:
    let i = a.fList.fActions.find(a)
    if i >= 0: a.fList.fActions.delete(i)
  a.fList = l
  l.fActions.add a
  l.ensureHook()
  a.notify()
  a

proc initActionList*(l: ActionList, owner: Component = nil) =
  l.initComponent(owner)
  l.ensureHook()

proc newActionList*(owner: Component = nil): ActionList =
  new result
  result.initActionList(owner)

proc newAction*(owner: Component = nil, caption = "", onExecute: ActionEvent = nil,
                shortcut = noShortcut): Action =
  ## A standalone action (not in a list; no list-level shortcut handling).
  new result
  result.initAction(owner)
  result.fCaption = caption
  result.onExecute = onExecute
  result.fShortcut = shortcut

proc newAction*(list: ActionList, caption = "", onExecute: ActionEvent = nil,
                shortcut = noShortcut): Action =
  ## Creates an action owned by `list` and adds it.
  new result
  result.initAction(list)
  result.fCaption = caption
  result.onExecute = onExecute
  result.fShortcut = shortcut
  list.add result

proc update*(l: ActionList) =
  for a in l.fActions: a.update()

proc free*(l: ActionList) =
  ## Frees the list's actions (unlinking their clients) and removes the list's
  ## key handler.
  for a in l.fActions:
    for lk in a.fLinks:
      lk.detach()
      lk.action = nil
    a.fLinks.setLen(0)
    a.fList = nil
  l.fActions.setLen(0)
  if l.fHooked:
    let f = formOf(l)
    if f != nil: f.removeKeyHandler("actions:" & $cast[uint](l))
    l.fHooked = false
  if l.owner != nil: l.owner.removeComponent(l)

# --------------------------------------------------------------- idle update

proc updateIn(c: Component) =
  if c of ActionList: ActionList(c).update()
  for ch in c.components: updateIn(ch)

proc updateActions*() =
  ## Runs `onUpdate` of every action of every ActionList owned by an open
  ## form. Called by the application's idle hook and before menus open.
  for f in openForms(): updateIn(f)

Application.addIdleHook("actions", updateActions)
block:
  let prev = menus.menuOpening
  menus.menuOpening = proc() =
    if prev != nil: prev()
    updateActions()
