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

## Events

None.

## Methods

| Method | Description |
|---|---|
| `add(image)` | Append and return the index |
| `insert(index, image)`, `delete(index)`, `clear()` | Edit the set |
| `image(i)` / `list[i]` | The raw `Image` |
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
* It is not a control, so there is no `parent`. Keep it alive as long as its users.

[Back to the index](../README.md)
