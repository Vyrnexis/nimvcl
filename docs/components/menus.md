# MainMenu, PopupMenu and MenuItem

The menu bar and context menus (Delphi `TMainMenu`, `TPopupMenu`,
`TMenuItem`). Menus open as real popup windows.

## Quick example

```nim
let menu = newMainMenu(form)                  # becomes form.menu
let file = menu.addItem("&File")
file.addItem("&Open...", proc(s: MenuItem) = echo "open", shortcut("Ctrl+O"))
file.addSeparator()
file.addItem("E&xit", proc(s: MenuItem) = form.close(), shortcut("Alt+F4"))

let ctx = newPopupMenu(form)                  # right click menu
ctx.addItem("Copy", proc(s: MenuItem) = echo "copy")
ctx.addItem("Paste")
let area = newPanel(form, "Right-click me", 16, 16, 240, 120)
attachPopupMenu(area, ctx)                    # right click, Shift+F10, Menu key
```

## MenuItem properties

| Name | Type | Description |
|---|---|---|
| `caption` | string | `&` mnemonic, `&&` is a literal `&`, `"-"` is a separator |
| `shortcut` | `Shortcut` | Shown right-aligned and fires the item anywhere in the form |
| `checked` | bool | Check mark |
| `autoCheck` | bool | A click toggles `checked` |
| `radioItem`, `groupIndex` | bool, int | Radio items: a click unchecks the others in the group |
| `enabled`, `visible` | bool | State |
| `imageIndex` | int | Icon from the menu's `images` ([ImageList](imagelist.md)) |
| `action` | Action | Link to an [Action](../guide/actions.md) |
| `count`, `item[i]`, `parent` | | Sub-items |

## Events

| Event | Description |
|---|---|
| `MenuItem.onClick(sender: MenuItem)` | The item was chosen |
| `PopupMenu.onPopup(sender)` | Just before the popup opens: enable, hide and fill items here |

## Methods

| Method | Description |
|---|---|
| `item.addItem(caption, onClick, shortcut)` | Add a sub-item and return it |
| `item.addSeparator()`, `add(item)`, `insert`, `delete`, `clear` | Edit the tree |
| `item.click()` | Run the item |
| `menu.images = list` | Icon column (MainMenu and PopupMenu) |
| `parseShortcut("Ctrl+S")` / `shortcut(...)` | Build a `Shortcut` |
| `attachPopupMenu(control, menu)` | Bind a popup menu to a control |
| `popup.popup(form, x, y)` / `popupAt(control)` | Open it by hand |
| `form.menu`, `form.menu = menu` | Get or set the form's main menu |

## Tips

* Menu items are components, not controls. Create loose ones with
  `newMenuItem(caption, onClick, shortcut)` and `add` them.
* Shortcuts, F10, Alt+letter and the context-menu keys run through the form's
  key-handler chain, so they only fire for keys the focused control did not use.
* Menu bar mnemonics win over control mnemonics.
* Keyboard: Up/Down, Left/Right for submenus, Enter or Space, Esc, letters.
* Clicking outside closes the menu and the click is swallowed.

More details: [Popups and menus](../popups-menus.md).

[Back to the index](../README.md)
