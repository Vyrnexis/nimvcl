# DockSite and DockPanel

An IDE-style docking area (Delphi docking, Visual Studio tool windows). A
`DockSite` holds panels in tab groups and splits; users drag tabs to dock,
float and rearrange them. See the [Docking guide](../guide/docking.md) for the
whole story.

## Quick example

```nim
let site = newDockSite(form)
site.align = alClient

let editor = newDockPanel(site, "editor", "main.nim", newMemo(nil, "echo 1"))
let tools = newDockPanel(site, "tools", "Tools", newListBox(nil))

site.dock(editor)
site.dock(tools, nil, dsLeft, 0.2)

tools.hide()
tools.show()                 # back at the left edge
let saved = site.saveLayout()
discard site.loadLayout(saved)
```

## DockSite properties

| Name | Type | Description |
|---|---|---|
| `panels` | `seq[DockPanel]` | Every panel, whatever its state |
| `activePanel` | `DockPanel` | The panel activated last |
| `rootNode` | `Control` | Top of the tree (`DockSplit` or `DockTabs`); nil when empty |
| `groups()` | `seq[DockTabs]` | The tab groups, left/top to right/bottom |
| `floatingSites` | `seq[DockSite]` | The sites of the floating windows |
| `isFloating` | bool | This site is inside a floating window |

## DockSite events

| Event | Description |
|---|---|
| `onDock(site, panel)` | A panel entered a group (docked or floating) |
| `onUndock(site, panel)` | A panel left its group (moved, floated, hidden) |
| `onClose(site, panel, allow: var bool)` | The user or `close()` wants to close a panel; veto with `allow = false` |
| `onActivate(site, panel)` | Another panel became the active one |
| `onLayoutChanged(sender)` | The arrangement changed |

## DockSite methods

| Method | Description |
|---|---|
| `newDockSite(parent, ...)` | Create the site (usually `align = alClient`) |
| `dock(panel, target = nil, side = dsCenter, size = 0, index = -1)` | Place a panel. `target` is a panel or group, nil for the site; `side` is `dsCenter` (tab), `dsLeft`, `dsRight`, `dsTop`, `dsBottom`; `size` is a fraction |
| `findPanel(name)` | Panel by name, nil if none |
| `saveLayout()` | The arrangement as JSON text |
| `loadLayout(text)` | Restore it; `false` and no change on bad text |
| `guideRect(group, side)` | The drop guide of a group (nil group: site edge), in site coordinates |
| `guidesVisible` | The drag overlay is showing |

## DockPanel

Created by `newDockPanel(site, name, caption = "", content = nil, closable = true)`.
It starts hidden.

| Name | Type | Description |
|---|---|---|
| `name` | string | Identifies the panel in layouts; must be unique in the site |
| `caption` | string | Tab text (and floating window title) |
| `content` | `Control` | The control shown in the panel; it fills it |
| `images`, `imageIndex` | `ImageList`, int | Icon on the tab |
| `closable` | bool | The tab has a close button and Ctrl+F4 works (default true) |
| `state` | `DockState` | `dpHidden`, `dpDocked`, `dpFloating` |
| `group` | `DockTabs` | Its tab group (nil when hidden) |
| `floatForm` | `Form` | Its window while floating |

| Method | Description |
|---|---|
| `show()` | Hidden: back to its remembered place. Otherwise: activate it |
| `hide()` | Leave the layout (remembers the place); does not ask `onClose` |
| `close()` | Ask `onClose`, then hide; returns whether it closed |
| `makeFloating(rect)` | Float in a window at `rect` (screen px; empty = near the main window) |
| `dockBack()` | Return to the last docked place |
| `activate(focus = false)` | Select its tab and make it the active panel; `focus` also focuses its content |
| `setSize(px)` | Set the width/height of its group inside its split |

## Tips

* Names matter: they are the keys of saved layouts, so keep them stable.
* Panels are created hidden. Call `dock` (or `show`) to place them.
* Drag a tab outside the window to float it; double click a tab to float or dock.
* Ctrl+Tab and Ctrl+Shift+Tab switch tabs, Ctrl+F4 closes the active panel.
* The method that floats a panel is `makeFloating`, because a proc named
  `float` would hide Nim's own `float(x)` conversion.

[Back to the index](../README.md)
