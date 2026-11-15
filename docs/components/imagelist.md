# ImageList

A numbered set of same-size icons (Delphi `TImageList`). Share one list between
a toolbar, menus, a tree view and a list view.

## Quick example

```nim
let icons = newImageList(16, 16)               # logical size of every icon
let folder = icons.add(loadImage("folder.png"))   # returns index 0
let file = icons.add(loadImage("file.png"))

let tree = newTreeView(form, 16, 16, 220, 200)
tree.images = icons
let root = tree.items.addChild(nil, "Project")
root.imageIndex = folder
root.addChild("main.nim").imageIndex = file
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `width`, `height` | float32 | Logical size every icon is drawn at |
| `count` | int | Number of images |
| `version` | int | Goes up with every change (a cheap "did it change?" check) |
| `listenerCount` | int | How many change listeners are subscribed |

## Events

An ImageList has no event fields. Instead it tells anyone who is interested
when it changes (see below).

## Change listeners

Every change (`add`, `insert`, `delete`, `clear`, `list[i] = image`, `width =`,
`height =`) bumps `version` and calls the listeners. TreeView, ListView, ToolBar
and the menus subscribe while the list is assigned, so they repaint and
re-measure by themselves when you add icons later. You can subscribe too:

```nim
let id = icons.addListener(proc() = echo "icons changed, version ", icons.version)
icons.removeListener(id)        # let go when you no longer care
```

A listener is a closure, so the list keeps whatever the closure captured
alive. That is why a control that is thrown away should be released with
`control.free()` (see below), which unsubscribes it.

## Methods

| Method | Description |
|---|---|
| `add(image)` | Append and return the index |
| `insert(index, image)`, `delete(index)`, `clear()` | Edit the set |
| `image(i)` / `list[i]` | The raw `Image` |
| `addListener(proc())` / `removeListener(id)` | Subscribe to changes; `addListener` returns the id |
| `draw(canvas, index, x, y, enabled = true)` | Draw one icon; faded when disabled |

## Where it is used

| Control | Property |
|---|---|
| [TreeView](treeview.md) | `images`, `TreeNode.imageIndex`, `selectedIndex` |
| [ListView](listview.md) | `smallImages`, `largeImages`, `ListItem.imageIndex` |
| [ToolBar](toolbar.md) | `images`, `ToolButton.imageIndex` |
| [Menus](menus.md) | `MainMenu.images`, `PopupMenu.images`, `MenuItem.imageIndex` |
| [ActionList](../guide/actions.md) | `images`, `Action.imageIndex` |

## Tips

* Icons are stretched to `width` x `height`. Load them at 2x pixel size for
  crisp icons on a HiDPI display.
* -1 means "no image" wherever an index is expected.
* **Releasing**: a control that shows an ImageList stays subscribed to it. When
  you remove a control for good, call `control.free()`: it detaches the control
  (and its children), unlinks any [Action](../guide/actions.md) and drops its
  image list subscriptions. Without that, a long-lived shared list keeps the
  removed control alive. Setting `images = nil` unsubscribes one control by hand.
* It is not a control, so there is no `parent`. Keep it alive as long as its users.

[Back to the index](../README.md)
