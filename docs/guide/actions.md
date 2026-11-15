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
| `imageIndex` | int | Icon in `ActionList.images` |
| `onExecute`, `onUpdate` | `proc(sender: Action)` | Run and refresh |

`execute(a)` runs an action by hand. It returns false when disabled or unhandled.

## Linking a client

`client.action = a` works for a `MenuItem` and for any `Control`. The client
mirrors the action now and after every later change. A click on the client runs
the action. A `ToolButton` becomes a check button when the action is `autoCheck`
or grouped.

## Updating state on idle

`onUpdate` runs once after each batch of events and right before a menu opens,
never continuously. Use it to compute `enabled` or `checked` from your state:

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
