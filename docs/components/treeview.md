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
| `typeAheadTimeout` | int | Milliseconds before a typed prefix is forgotten (default 1000) |
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
* Keys: arrows, Left/Right to collapse and expand (Left on a collapsed node goes
  to its parent), `*` (expand everything below), `+` / `-`, Space, F2 to rename. Home, End, PageUp, PageDown and
  type-ahead (on the visible nodes' text; `typeAheadTimeout`, 1000 ms) work as
  in ListBox.

## At design time

`items` opens the items editor (`ItemsDlgForm` of `nimvcl/controls/propeditors`,
like Delphi's): the nodes with Add (a sibling), Add child, Delete (with the
sub-tree), Up, Down (past a sibling with its sub-tree), Indent and Outdent, and
for the selected node its text, image index, selected image index and check
state. In the form file the data is four string lists, applied in this order
(expansion is not stored):

```
items = (
  'Root'
  '  Child'                # two spaces per level
  'Second'
)
itemImages = (
  '0'                      # imageIndex per node, in outline order
  '1'
)
itemSelectedImages = (
  '-1'
  '2'                      # selectedIndex per node
)
checkedItems = (
  '1'                      # outline indexes of the checked nodes
)
```

In code: `nodeLines`, `itemImages`, `itemSelectedImages` and `checkedItems`. With
`propagateChecks`, a grayed parent is derived from its children and not listed.
The inspector lists only `items`; the other lists are edited by its dialog.

[Back to the index](../README.md)
