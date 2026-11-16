# Docking

Docking lets the user rearrange the parts of a window the way they do in Delphi
or in an IDE: a component palette on the left, an object inspector on the
right, editors in the middle, messages at the bottom. Tabs can be dragged to
another group, to the side of a group, to the edge of the window, or out of the
window into a floating one. The arrangement can be saved and loaded.

The pieces:

| Type | What it is |
|---|---|
| `DockSite` | The container you put on your form (usually `alClient`). It owns the layout |
| `DockPanel` | One titled panel: a caption, an optional icon, a close button, and your control as its content |
| `DockTabs` | A group of panels shown as tabs (created and removed for you) |
| `DockSplit` | A row or column of groups with draggable dividers (created and removed for you) |

You only create the site and the panels. Groups and splits appear and vanish by
themselves as panels are docked and removed.

## A first layout

```nim
import nimvcl

let form = newForm(nil, 900, 600)
let site = newDockSite(form)
site.align = alClient

# a panel needs a unique name; the content is any control
let editor = newDockPanel(site, "editor", "main.nim", newMemo(nil, "echo 1"))
let palette = newDockPanel(site, "palette", "Palette", newListBox(nil))
let inspector = newDockPanel(site, "inspector", "Inspector", newListView(nil))
let messages = newDockPanel(site, "messages", "Messages", newListBox(nil),
                            closable = false)

site.dock(editor)                          # the first panel fills the site
site.dock(palette, nil, dsLeft, 0.2)       # at the left edge, 20% of the width
site.dock(inspector, nil, dsRight, 0.2)    # at the right edge
site.dock(messages, editor, dsBottom, 0.3) # below the editor, 30% of its height
```

`newDockPanel` creates a panel that is *hidden* until you place it. `dock` takes:

* `target`: nil for the whole site, or a panel (or its group) to dock next to.
* `side`: `dsCenter` (as a tab of the target's group), `dsLeft`, `dsRight`,
  `dsTop` or `dsBottom`.
* `size`: the new part's share, a fraction between 0 and 1. For a group target
  it is the share of the target's space (default 0.5); for a site edge it is the
  share of the whole site (default 0.25).
* `index`: for `dsCenter`, the tab position (default last).

A second panel as a tab of the first:

```nim
let notes = newDockPanel(site, "notes", "notes.md", newMemo(nil, "- todo"))
site.dock(notes, editor, dsCenter)         # a tab next to main.nim
notes.activate()                           # select it
```

## What the user can do

* **Drag a tab** (press and move a few pixels). The group under the pointer shows
  five guides, and the window edges show four more. Drop on a guide to dock
  there; a translucent preview shows the result. Drop on a tab strip to put the
  tab at that place (this also reorders tabs). Press **Esc** to cancel.
* **Drag a tab out of the window** and drop it: the panel floats in its own
  window. Drag its tab back onto a guide to dock it again.
* **Double click a tab** to float a docked panel, or to dock a floating one
  back to where it was. The **right click** menu does the same and has Close.
* **Drag a divider** between two groups to resize. The proportions are kept when
  the window is resized, and no part gets smaller than 64 px.
* **Ctrl+Tab / Ctrl+Shift+Tab** switch tabs in the active group, and
  **Ctrl+F4** closes the active panel (when it is `closable`).

The group of the active panel has a highlighted tab strip. A panel becomes
active when you click it or focus a control inside it, when you pick its tab,
or when you dock it.

> On Wayland an application cannot know where its windows are, so a tab cannot
> be dragged from one window to another there. Use the double click or the
> context menu to dock a floating panel back. Everything else works.

## Panels in code

```nim
inspector.hide()          # leaves the layout, remembers where it was
inspector.show()          # comes back to the same place and size
inspector.close()         # like the close button: asks onClose first
inspector.makeFloating(rectF(900, 100, 320, 400))   # a window at that screen place
inspector.dockBack()      # to its last docked place
echo inspector.state      # dpHidden, dpDocked or dpFloating
```

`makeFloating` is the "float" operation (`float` would hide Nim's own
conversion). `show` on a hidden panel puts it back: as a tab at the same index
if its old group-mates are still docked, otherwise next to the panels it sat
beside (with the same share of the space), otherwise as a tab of the first
group. A panel that was floating floats again. The close button only exists
for `closable` panels; `closable` is about the user, so code can still call
`close()` or `hide()`.

Look up panels with `site.findPanel("inspector")` and `site.panels`. Panel
properties:

```nim
let icons = newImageList(16, 16)
icons.add newImage(32, 32, rgba(60, 120, 230, 255))   # a 16x16 icon at 2x
palette.images = icons
palette.imageIndex = 0       # icon on the tab
palette.caption = "Tools"    # the tab text; a floating window's title follows it
palette.closable = false
palette.content = newListBox(nil)   # swap the control it shows
```

## Events

The events are on the site. Floating windows forward theirs to the same site.

```nim
site.onDock = proc(s: DockSite, p: DockPanel) =
  echo p.name, " docked: ", p.state          # dpDocked or dpFloating
site.onUndock = proc(s: DockSite, p: DockPanel) =
  echo p.name, " left its place"             # moved, floated or hidden
site.onActivate = proc(s: DockSite, p: DockPanel) =
  echo "active: ", p.caption
site.onClose = proc(s: DockSite, p: DockPanel, allow: var bool) =
  if p.name == "editor": allow = false       # veto
site.onLayoutChanged = proc(sender: Control) =
  echo "arrangement changed"                 # a good moment to autosave
```

`onClose` runs for the close button, Ctrl+F4, the context menu, closing a
floating window and `panel.close()`. `hide()` does not ask.

## Saving and loading a layout

```nim
let text = site.saveLayout()      # JSON
writeFile("layout.json", text)

if site.loadLayout(readFile("layout.json")):
  echo "restored"
```

The text holds the splits with their proportions, the tab order, the active
tab of each group, the floating windows (position and size) and the hidden
panels with their remembered places, all by panel *name*:

* a name in the file that no panel has is ignored,
* a panel the file does not mention is added as a tab of the first group (so a
  newer version of your program can still load an old layout),
* text that is not a layout returns `false` and changes nothing.

`onDock` and `onUndock` fire for the panels whose state changed, and
`onLayoutChanged` once.

A "reset layout" command is just `loadLayout` of the text you saved after
building the default layout.

## How the tree stays tidy

* A group with no panels is removed.
* A split with one child is replaced by that child.
* A split inside a split of the same direction is merged into it.
* When a panel leaves, the space goes to the neighbour next to it.
* The last panel of a floating window closes that window.
* An empty site is allowed: it shows "Drop panels here", and docking into it
  makes the new group the whole layout.

## Floating windows and themes

A floating window is a normal `Form` with its own small `DockSite`, so several
panels can share one and be rearranged there. `panel.floatForm` is that form
(nil when the panel is not floating); `site.floatingSites` lists them. Themes
are global, so `Application.theme = themeDark()` restyles floating windows
too.

## Testing

Drags are ordinary mouse events, so you can test docking headless with
`Application.dispatch`. `site.guideRect(group, side)` gives the guide to aim at
(a nil group means the edge of the site), and `dockScreenOrigin` lets a test
decide where each window is on the screen:

```nim
dockScreenOrigin = proc(f: Form): PointF = pointF(f.left, f.top)
```

See `tests/tdock.nim` and `examples/dock_demo.nim`.

[Back to the index](../README.md)
