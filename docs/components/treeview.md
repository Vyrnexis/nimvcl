# TreeView

A scrolling tree of nodes (Delphi `TTreeView`), fast with 100,000 nodes.

## Quick example

```nim
let tree = newTreeView(form, 16, 16, 240, 220)
let root = tree.items.addChild(nil, "Projects")      # nil parent = top level
let app = root.addChild("app")
app.addChild("main.nim")
app.addChild("util.nim")
root.addChild("docs")
root.expand()

tree.onChange = proc(sender: Control, node: TreeNode) =
  echo "selected ", node.text
```

## Common properties

TreeView:

| Name | Type | Description |
|---|---|---|
| `items` | `TreeItems` | `addChild(parent, text)`, `add(sibling, text)`, `insert(sibling, text)`, `delete(node)`, `clear`, `find(text)`, `count`, `top(i)` |
| `selected` | `TreeNode` | Focused node (nil = none). Settable |
| `images` | `ImageList` | Icons for `imageIndex` |
| `multiSelect`, `extendedSelect` | bool | Multiple selection |
| `checkboxes`, `propagateChecks` | bool | Check boxes on nodes |
| `showLines`, `showButtons`, `showRoot`, `rowSelect` | bool | Look |
| `indent`, `itemHeight` | float32 | Metrics (`itemHeight` 0 = automatic) |
| `readOnly` | bool | Disable in-place rename |
| `borderStyle` | `BorderStyle` | `bsSingle` (default) or `bsNone`: no border, no focus ring and square corners, so the control can sit flush in a panel |
| `color` | Color | Own background: the tree background; hover rows are a shade of it. Set it and `parentColor` turns off |
| `font.color` | Color | Text color (VCL `Font.Color`); alpha 0 (the default) uses the theme's text color. `fontColor` is a shortcut |

TreeNode: `text`, `data` (`RootRef`), `tag`, `imageIndex`, `selectedIndex`, `expanded`,
`hasChildren`, `checked`, `parent`, `level`, `index`, `children`, `childCount`.

## Events

| Event | Description |
|---|---|
| `onChange(sender, node)` | Selection moved |
| `onChanging(sender, node, allow: var bool)` | Veto a selection change |
| `onExpanding`, `onCollapsing` (`allow`), `onExpanded`, `onCollapsed` | Expand and collapse |
| `onEditing`, `onEdited(sender, node, text: var string)` | In-place rename |
| `onChecked(sender, node)` | A check box toggled |
| `onCustomDrawItem` | Owner draw |

## Methods

| Method | Description |
|---|---|
| `node.addChild(text)`, `node.insert(index, text)`, `node.delete()`, `node.clear()` | Edit the tree |
| `node.expand(recursive)`, `collapse`, `expandAll()`, `collapseAll()` | Open and close |
| `node.makeVisible()`, `tree.ensureVisible(node)` | Scroll into view |
| `beginUpdate()` / `endUpdate()` | Batch many changes |
| `beginEdit(node)` / `endEdit(cancel)` | Rename |
| `selectedNodes()`, `isSelected(node)` | Multi-select |
| `nodeAt(point)` | Hit test |

## Tips

* **Lazy children**: set `node.hasChildren = true` to show an expander, then add
  the real children in `onExpanding`. It fires on every expand, so check
  `node.childCount == 0`.
* Wrap bulk inserts in `beginUpdate` / `endUpdate`.
* Keep your own object in `node.data` (derive from `RootObj`) or an int in `tag`.
* Keys: arrows, Left/Right to collapse and expand, Space, type-ahead, F2 to rename.

## At design time

`items` is a string list holding an outline: one node per line, indented by two
spaces per level (`nodeLines` / `nodeLines =` in code). Node images, check
state and expansion are not stored in a form file.

[Back to the index](../README.md)
