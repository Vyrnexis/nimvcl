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

## In a form file and in the designer

The `images` property of the list holds the image files, stored as paths
relative to the `.nfm` (like `ImageControl.picture`):

```
object icons: ImageList
  width = 24
  height = 24
  images = (
    'images/open.png'
    'images/save.png'
  )
end
object bar: ToolBar
  images = icons
end
```

`loadNfm` reads the files, `loadForm` embeds them. `il.images` / `il.images = v`
read and replace all images at once, `il.move(from, to)` reorders. Every image
is drawn stretched into `width` x `height`.

The Object Inspector's "..." button on `images` opens the image list dialog
(`ImageListDlgForm`, see [property editors](inspector.md#property-editor-dialogs)):
a list with thumbnails and Add (several files at once), Delete, Up and Down.
The controls that take a list (`ToolBar.images`, `TreeView.images`,
`ListView.smallImages` / `largeImages`, `Button.images`, `MainMenu.images`, `PopupMenu.images`,
`ActionList.images`) have a drop-down of the ImageLists of the form; the link is
saved as the list's name. `imageIndex` is a plain number property; the per-item
indexes of a `ListView` or `TreeView` are edited in its
[items editor](listview.md#at-design-time).

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

Controls that show a list hold it in an `ImageListRef` field
(`nimvcl/controls/imagelist`): `attach(list, onChange)` swaps the list and the
subscription in one step, `detach()` drops both (called from `releaseResources`
when the control is freed), and `list` reads it. Menus, ToolBar, TreeView,
ListView, Button and docking all use it, so a custom control that takes an
ImageList should too, instead of calling `addListener` itself.

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
| [Button](button.md) | `images`, `imageIndex`, `imageAlignment` |
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
