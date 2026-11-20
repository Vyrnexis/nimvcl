# Actions

An `Action` is one command (Delphi `TAction`) that many controls can share: a
menu item, a toolbar button, a button, a check box, and a keyboard shortcut.
Caption, hint, icon, enabled and checked state live in the action, so you
write them once.

## Quick example

```nim
let acts = newActionList(form)            # owned by the form: shortcuts work
let save = newAction(acts, "&Save", shortcut = shortcut("Ctrl+S"))
save.hint = "Save the document"
save.onExecute = proc(a: Action) = echo "saving"

let menu = newMainMenu(form)
let file = menu.addItem("&File")
file.addItem("Save").action = save        # menu item

let btn = newButton(form, "", 16, 16, 90, 30)
btn.action = save                         # button: takes caption and hint
```

Now the menu item, the button and Ctrl+S all run `onExecute`. Disable the
action and all of them are disabled:

```nim
save.enabled = false
```

## ActionList

`newActionList(owner)` makes a list. Pass a `Form` (or a control inside one) as
owner: the list then installs one key handler in that form, so shortcuts work
even with no menu. `newAction(list, caption, onExecute, shortcut)` creates an
action in the list. Other members:

| Member | Description |
|---|---|
| `images = imageList` | Icons for `imageIndex`; toolbars and menus adopt them |
| `add(action)`, `count`, `list[i]`, `find(name)` | The actions |
| `onExecute(a, handled: var bool)` | Sees every action first |
| `onUpdate(a, handled)` | Called before each action's `onUpdate` |

## Action properties

| Name | Type | Description |
|---|---|---|
| `caption` | string | Text, with `&` mnemonic |
| `hint` | string | Tooltip for controls |
| `enabled`, `visible` | bool | Mirrored by every client |
| `checked` | bool | Check state (check box, check tool button, menu item) |
| `autoCheck` | bool | Executing toggles `checked` |
| `groupIndex` | int | `> 0`: radio group within the list |
| `shortcut` | Shortcut | Fires anywhere in the form |
| `secondaryShortcuts` | seq[Shortcut] | More shortcuts that fire the action (clients show only `shortcut`); streamed as a list of strings |
| `imageIndex` | int | Icon in `ActionList.images` |
| `onExecute`, `onUpdate` | `proc(sender: Action)` | Run and refresh |

`execute(a)` runs an action by hand. It returns false when disabled or unhandled.

## Linking a client

`client.action = a` works for a `MenuItem` and for any `Control`. The client
mirrors the action now and after every later change. A click on the client runs
the action. A `ToolButton` becomes a check button when the action is `autoCheck`
or grouped.

### Releasing a client

An action keeps its linked clients in a list, so a removed control or menu item
stays alive for as long as the action does. Release clients when you throw them
away:

| What you do | What happens to the link |
|---|---|
| `client.action = nil` | Unlinks that one client |
| `control.free()` | Removes the control and all its children from the form and unlinks their actions (and image list subscriptions) |
| `menuItem.delete(i)` / `menuItem.clear()` | The removed items (and their sub-items) are unlinked |
| `popupMenu.free()`, `mainMenu.free()` | Unlinks every item and drops the menu's image list subscription |
| `action.free()` | Unlinks every client (a tool button that became a check button for the action goes back to a plain one) and removes the action from its list |

Plain `parent = nil` or `removeControl` only detaches a control (it may come
back later), so it keeps the link: call `free()` when it is gone for good.

## Updating state on idle

`onUpdate` runs once after each batch of events and right before a menu opens,
never continuously. Only action lists that exist are visited (they are in a
registry), not every form, and an `onUpdate` handler may add or remove actions
or lists safely. Use it to compute `enabled` or `checked` from your state:

```nim
var dirty = false
save.onUpdate = proc(a: Action) =
  a.enabled = dirty
```

## Tips

* The action wins: a property you set on a client by hand sticks only until the
  action changes.
* Shortcuts fire from the list, not from menu items. Items only display them.
* Without a form owner, actions fire through their menu items only.

See [ToolBar](../components/toolbar.md) and [Menus](../components/menus.md).

[Back to the index](../README.md)
