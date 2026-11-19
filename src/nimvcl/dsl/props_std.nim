## Registers the stock controls and components with the property registry
## (`props.nim`): every public control with its designer properties and events.
## Importing this module is enough; `nfm.nim` and the object inspector import it.
##
## Not registered (they have no sensible text form): `DockSite` and its panels
## (their layout is saved with `saveLayout`), owner-draw and virtual-mode
## hooks.
##
## Item data is stored as string lists:
##
## * `TreeView.items` is an indented outline (two spaces per level),
##   `ListView.items` has one line per item with its sub-items separated by
##   tabs, `StringGrid.cells` one line per row with its cells separated by tabs.
## * `ListView` and `TreeView` add `itemImages` (the image index of each item,
##   in order; `TreeView` also `itemSelectedImages`) and `checkedItems` (the
##   indexes of the checked items), applied after `items`. They are hidden in
##   the object inspector: the items editor sets them with `items`.
## * `DrawGrid.colWidths` / `rowHeights` are comma-separated sizes
##   ("64, 120, 64"), empty while every size is the default.

import std/[strutils, unicode]
import ../graphics/[color, font, image, canvas]
import ../core/[types, component, control, form, timer]
import ../controls/[common, label, button, checkbox, radiobutton, panel, paintbox,
                    bevel, imagectl, edit, frame, scrollbar, scrolling, scrollbox,
                    listbox, menus, progressbar, trackbar, spinedit, splitter,
                    statusbar, toolbar, pagecontrol, flowpanel, memo, combobox,
                    imagelist, treeview, listview, grids, actions, codeedit,
                    codemodel]
import ./props
export props

# ------------------------------------------------------ accessor helpers

proc getItems(c: ListBox): seq[string] =
  for s in c.items: result.add s
proc setItems(c: ListBox, v: seq[string]) = c.items = v
proc getItems(c: ComboBox): seq[string] =
  for s in c.items: result.add s
proc setItems(c: ComboBox, v: seq[string]) = c.items = v
proc getTabs(c: TabControl): seq[string] = c.tabs
proc setTabs(c: TabControl, v: seq[string]) = c.tabs = v
proc getLvItems(c: ListView): seq[string] = c.itemLines
proc setLvItems(c: ListView, v: seq[string]) = c.itemLines = v
proc getTvItems(c: TreeView): seq[string] = c.nodeLines
proc setTvItems(c: TreeView, v: seq[string]) = c.nodeLines = v
proc getLvImages(c: ListView): seq[string] = c.itemImages
proc setLvImages(c: ListView, v: seq[string]) = c.itemImages = v
proc getLvChecked(c: ListView): seq[string] = c.checkedItems
proc setLvChecked(c: ListView, v: seq[string]) = c.checkedItems = v
proc getTvImages(c: TreeView): seq[string] = c.itemImages
proc setTvImages(c: TreeView, v: seq[string]) = c.itemImages = v
proc getTvSelImages(c: TreeView): seq[string] = c.itemSelectedImages
proc setTvSelImages(c: TreeView, v: seq[string]) = c.itemSelectedImages = v
proc getTvChecked(c: TreeView): seq[string] = c.checkedItems
proc setTvChecked(c: TreeView, v: seq[string]) = c.checkedItems = v
proc getCells(g: StringGrid): seq[string] = g.cellLines
proc setCells(g: StringGrid, v: seq[string]) = g.cellLines = v
proc getColWidths(g: DrawGrid): string = g.colWidthsText
proc setColWidths(g: DrawGrid, v: string) = g.colWidthsText = v
proc getRowHeights(g: DrawGrid): string = g.rowHeightsText
proc setRowHeights(g: DrawGrid, v: string) = g.rowHeightsText = v
proc getPasswordChar(e: Edit): string = e.passwordCharText
proc setPasswordChar(e: Edit, v: string) = e.passwordChar = v
proc getLines(m: Memo): seq[string] = m.text.splitLines
proc setLines(m: Memo, v: seq[string]) = m.text = v.join("\n")

proc getCols(g: GridPanel): string = gridSizesToText(g.columns)
proc setCols(g: GridPanel, v: string) = g.columns = parseGridSizes(v)
proc getRows(g: GridPanel): string = gridSizesToText(g.rows)
proc setRows(g: GridPanel, v: string) = g.rows = parseGridSizes(v)

proc getShortcut(m: MenuItem): string = $m.shortcut
proc setShortcut(m: MenuItem, v: string) = m.shortcut = shortcut(v)
proc getShortcut(a: Action): string = $a.shortcut
proc setShortcut(a: Action, v: string) = a.shortcut = shortcut(v)

proc scrollKids(c: ScrollingControl): seq[Obj] =
  for ch in c.children:
    if Control(ch) != Control(c.hScrollBar) and Control(ch) != Control(c.vScrollBar):
      result.add Obj(ch)

proc menuKids(root: MenuItem): seq[Obj] =
  for it in root: result.add Obj(it)

proc attachMenuItem(parent, child: Obj) =
  let it = MenuItem(child)
  if parent of MenuItem: MenuItem(parent).add it
  elif parent of MainMenu: MainMenu(parent).add it
  elif parent of PopupMenu: PopupMenu(parent).add it
  else: raise newException(PropError, "a menu item needs a menu or a menu item as parent")

proc newPanelOf(parent: Obj): StatusPanel =
  if parent == nil or not (parent of StatusBar):
    raise newException(PropError, "a status panel needs a StatusBar as parent")
  StatusBar(parent).addPanel()

proc newColumnOf(parent: Obj): ListColumn =
  if parent == nil or not (parent of ListView):
    raise newException(PropError, "a list column needs a ListView as parent")
  ListView(parent).columns.add()

proc newActionOf(owner: Component, parent: Obj): Action =
  if parent != nil and parent of ActionList: newAction(ActionList(parent))
  else: newAction(owner)

proc actionKids(l: ActionList): seq[Obj] =
  for a in l.components:
    if a of Action: result.add Obj(a)

proc columnKids(lv: ListView): seq[Obj] =
  for c in lv.columns: result.add Obj(c)

# ----------------------------------------------------------------- base

registerClass(Component, parent = nil, abstract = true):
  category Behaviour:
    name: string

registerClass(Control, parent = Component, abstract = true):
  category Layout:
    left: float32
    top: float32
    width: float32
    height: float32
    align: Align
    anchors: Anchors
    margins: Spacing
    constraints: SizeConstraints
    autoSize: bool
  category Appearance:
    font: FontSpec
    parentFont: bool
    color: Color
    parentColor: bool
    cursor: Cursor
  category Behaviour:
    visible: bool
    enabled: bool
    hint: string
    tabOrder: int
    tabStop: bool
    tag: int
    popupMenu: PopupMenu
    action: Action
  category Events:
    onClick: NotifyEvent
    onDblClick: NotifyEvent
    onMouseEnter: NotifyEvent
    onMouseLeave: NotifyEvent
    onEnter: NotifyEvent
    onExit: NotifyEvent
    onResize: NotifyEvent
    onMouseDown: MouseEvent
    onMouseUp: MouseEvent
    onMouseMove: MouseMoveEvent
    onMouseWheel: MouseWheelEvent
    onKeyDown: KeyEvent
    onKeyUp: KeyEvent
    onKeyPress: KeyPressEvent
    onPaint: PaintEvent
  nostore parentFont, parentColor
  defaultWhen font, parentFont
  defaultWhen color, parentColor

registerClass(Container, parent = Control, abstract = true,
              kids = toObjs(self.children)):
  category Layout:
    padding: Spacing

registerClass(ScrollingControl, parent = Container, abstract = true,
              kids = scrollKids(self)):
  category Behaviour:
    hScrollMode: ScrollBarMode
    vScrollMode: ScrollBarMode
    wheelLines: int
  category Events:
    onScroll: NotifyEvent

# ----------------------------------------------------------------- form

registerClass(Form, parent = Container, create = newForm(owner)):
  category Appearance:
    caption: string
    position: FormPosition
    borderStyle: BorderStyle
    formStyle: FormStyle
    icon: Image
  category Behaviour:
    menu: MainMenu
  category Events:
    onShow: NotifyEvent
    onHide: NotifyEvent
    onActivate: NotifyEvent
    onDeactivate: NotifyEvent
    onClose: FormCloseEvent
    onCloseQuery: FormCloseQueryEvent
  # a MainMenu object in the form is its menu already (its constructor sets it)
  skipWhen menu, (self.menu != nil and self.menu.parent == Container(self))

# ------------------------------------------------- text and buttons

registerClass(Label, parent = Control):
  category Appearance:
    caption: string
    alignment: HAlign
    layout: VAlign
    wordWrap: bool
    transparent: bool
    muted: bool
  category Behaviour:
    focusControl: Control

registerClass(Button, parent = Control):
  category Appearance:
    caption: string
    flat: bool
  category Behaviour:
    isDefault: bool
    isCancel: bool
    modalResult: ModalResult
  category Data:
    images: ImageList
    imageIndex: int
    imageAlignment: ImageAlignment

registerClass(CheckBox, parent = Control):
  category Appearance:
    caption: string
  category Behaviour:
    allowGrayed: bool
    state: CheckBoxState
    checked: bool
  category Events:
    onChange: NotifyEvent
  nostore checked

registerClass(RadioButton, parent = Control):
  category Appearance:
    caption: string
  category Behaviour:
    checked: bool
  category Events:
    onChange: NotifyEvent

# ---------------------------------------------- containers and layout

registerClass(Panel, parent = Container):
  category Appearance:
    caption: string
    borderStyle: PanelBorder
    alignment: HAlign

registerClass(GroupBox, parent = Container):
  category Appearance:
    caption: string

registerClass(Frame, parent = Panel)

registerClass(Bevel, parent = Control):
  category Appearance:
    shape: BevelShape

registerClass(PaintBox, parent = Control)

registerClass(ImageControl, parent = Control):
  category Appearance:
    stretch: bool
    proportional: bool
    center: bool
    transparent: bool
  category Data:
    picture: Image
addAlias("Image", "ImageControl")

registerClass(ScrollBox, parent = ScrollingControl):
  category Layout:
    autoContentSize: bool

registerClass(Splitter, parent = Control):
  category Behaviour:
    minSize: float32
  category Events:
    onMoved: NotifyEvent

registerClass(FlowPanel, parent = Panel):
  category Layout:
    flowStyle: FlowStyle
    hGap: float32
    vGap: float32

registerClass(GridPanel, parent = Panel):
  category Layout:
    prop columns, string, getCols, setCols
    prop rows, string, getRows, setRows

registerClass(StatusBar, parent = Control, kids = toObjs(self.panels)):
  category Appearance:
    simplePanel: bool
    simpleText: string
    sizeGrip: bool

registerClass(StatusPanel, parent = nil, create = newPanelOf(parent),
              protoParent = newStatusBar(nil)):
  category Appearance:
    text: string
    width: float32
    alignment: HAlign

registerClass(ToolBar, parent = Container):
  category Appearance:
    flat: bool
  category Data:
    images: ImageList

registerClass(ToolButton, parent = Control):
  category Appearance:
    caption: string
    showCaption: bool
    image: Image
  category Behaviour:
    kind: ToolButtonKind
    groupIndex: int
    allowAllUp: bool
    down: bool
  category Data:
    imageIndex: int

registerClass(TabBase, parent = Container, abstract = true):
  category Appearance:
    showTabs: bool
    tabPosition: TabPosition
  category Behaviour:
    tabIndex: int
  category Events:
    onChange: NotifyEvent
    onChanging: TabChangingEvent

registerClass(TabControl, parent = TabBase):
  category Data:
    prop tabs, seq[string], getTabs, setTabs
  after tabIndex, tabs

registerClass(PageControl, parent = TabBase)

registerClass(TabSheet, parent = Container):
  category Appearance:
    caption: string
    tabVisible: bool

# ----------------------------------------------------------- input

registerClass(Edit, parent = Control):
  category Appearance:
    borderStyle: EditBorder
    placeholder: string
  category Behaviour:
    password: bool
    prop passwordChar, string, getPasswordChar, setPasswordChar
    readOnly: bool
    maxLength: int
    charCase: EditCharCase
    numbersOnly: bool
    autoSelect: bool
  category Data:
    text: string
  category Events:
    onChange: NotifyEvent
  skipWhen password, (self.isPassword and self.passwordChar != DefaultPasswordChar)
  skipWhen passwordChar, (self.passwordChar == DefaultPasswordChar)

registerClass(Memo, parent = ScrollingControl):
  category Appearance:
    borderStyle: BorderStyle
    scrollBars: MemoScrollBars
    placeholder: string
  category Behaviour:
    wordWrap: bool
    readOnly: bool
    maxLength: int
    wantTabs: bool
    wantReturns: bool
  category Data:
    prop lines, seq[string], getLines, setLines
  category Events:
    onChange: NotifyEvent

registerClass(SpinEdit, parent = Container, kids = noKids()):
  category Behaviour:
    minValue: int
    maxValue: int
    increment: int
    value: int
  category Events:
    onChange: NotifyEvent
  after value, minValue, maxValue

registerClass(ComboBox, parent = Container, kids = noKids()):
  category Appearance:
    style: ComboStyle
    dropDownCount: int
    dropDownWidth: float32
  category Behaviour:
    autoComplete: bool
    sorted: bool
  category Data:
    prop items, seq[string], getItems, setItems
    itemIndex: int
    text: string
  category Events:
    onChange: NotifyEvent
    onSelect: NotifyEvent
    onDropDown: NotifyEvent
    onCloseUp: NotifyEvent
  skipWhen text, (self.itemIndex >= 0)
  after itemIndex, items
  after text, itemIndex

registerClass(ListBox, parent = ScrollingControl, kids = noKids()):
  category Appearance:
    borderStyle: BorderStyle
    style: ListBoxStyle
    itemHeight: float32
    showFocusRect: bool
  category Behaviour:
    multiSelect: bool
    extendedSelect: bool
    sorted: bool
  category Data:
    prop items, seq[string], getItems, setItems
    itemIndex: int
  category Events:
    onChange: NotifyEvent
  after itemIndex, items

registerClass(TrackBar, parent = Control):
  category Behaviour:
    orientation: Orientation
    min: int
    max: int
    position: int
    frequency: int
    lineSize: int
    pageSize: int
  category Events:
    onChange: NotifyEvent
  after position, min, max

registerClass(ProgressBar, parent = Control):
  category Appearance:
    style: ProgressStyle
    orientation: Orientation
  category Behaviour:
    min: int
    max: int
    step: int
    position: int
  category Events:
    onChange: NotifyEvent
  after position, min, max

registerClass(ScrollBar, parent = Control):
  category Behaviour:
    kind: ScrollBarKind
    min: float32
    max: float32
    pageSize: float32
    position: float32
    smallChange: float32
    largeChange: float32
    showArrows: bool
  category Events:
    onChange: NotifyEvent
    onScroll: ScrollEvent
  after position, min, max, pageSize

# ------------------------------------------------------------ views

registerClass(TreeView, parent = ScrollingControl, kids = noKids()):
  category Appearance:
    borderStyle: BorderStyle
    showLines: bool
    showRoot: bool
    showButtons: bool
    rowSelect: bool
    hideSelection: bool
    checkboxes: bool
    indent: float32
    itemHeight: float32
  category Behaviour:
    readOnly: bool
    multiSelect: bool
    extendedSelect: bool
    propagateChecks: bool
  category Data:
    prop items, seq[string], getTvItems, setTvItems
    prop itemImages, seq[string], getTvImages, setTvImages
    prop itemSelectedImages, seq[string], getTvSelImages, setTvSelImages
    prop checkedItems, seq[string], getTvChecked, setTvChecked
    images: ImageList
  category Events:
    onChange: TreeNodeEvent
    onChanging: TreeAllowEvent
    onExpanding: TreeAllowEvent
    onCollapsing: TreeAllowEvent
    onExpanded: TreeNodeEvent
    onCollapsed: TreeNodeEvent
    onChecked: TreeNodeEvent
  hide itemImages, itemSelectedImages, checkedItems
  after itemImages, items
  after itemSelectedImages, items
  after checkedItems, items, propagateChecks, itemImages

registerClass(ListView, parent = ScrollingControl,
              kids = columnKids(self)):
  category Appearance:
    borderStyle: BorderStyle
    viewStyle: ListViewStyle
    showHeader: bool
    gridLines: bool
    rowSelect: bool
    hotTrack: bool
    checkboxes: bool
    itemHeight: float32
    cellWidth: float32
  category Behaviour:
    readOnly: bool
    multiSelect: bool
    extendedSelect: bool
    sortColumn: int
    sortOrder: SortOrder
  category Data:
    prop items, seq[string], getLvItems, setLvItems
    prop itemImages, seq[string], getLvImages, setLvImages
    prop checkedItems, seq[string], getLvChecked, setLvChecked
    smallImages: ImageList
    largeImages: ImageList
  category Events:
    onChange: NotifyEvent
    onSelectItem: ListSelectEvent
    onItemChecked: ListItemEvent
    onItemDblClick: ListItemDblClickEvent
    onColumnClick: ListColumnEvent
    onColumnResize: ListColumnEvent
  hide itemImages, checkedItems
  after itemImages, items
  after checkedItems, items, itemImages

registerClass(ListColumn, parent = nil, create = newColumnOf(parent),
              protoParent = newListView(nil)):
  category Appearance:
    caption: string
    width: float32
    minWidth: float32
    maxWidth: float32
    alignment: HAlign
    resizable: bool

registerClass(DrawGrid, parent = ScrollingControl, kids = noKids()):
  category Appearance:
    borderStyle: BorderStyle
    horzLines: bool
    vertLines: bool
    defaultColWidth: float32
    defaultRowHeight: float32
    prop colWidths, string, getColWidths, setColWidths
    prop rowHeights, string, getRowHeights, setRowHeights
  category Behaviour:
    colCount: int
    rowCount: int
    fixedCols: int
    fixedRows: int
    options: GridOptions
    hotTrack: bool
  category Events:
    onSelectCell: SelectCellEvent
    onDrawCell: DrawCellEvent
    onSelectionChanged: NotifyEvent
    onFixedCellClick: GridCellEvent
    onColWidthChanged: GridIndexEvent
    onRowHeightChanged: GridIndexEvent
  after colWidths, colCount, defaultColWidth
  after rowHeights, rowCount, defaultRowHeight

registerClass(StringGrid, parent = DrawGrid):
  category Behaviour:
    sortOnHeaderClick: bool
  category Data:
    prop cells, seq[string], getCells, setCells
  after cells, colCount, rowCount
  category Events:
    onHeaderClick: GridIndexEvent

registerClass(CodeEdit, parent = ScrollingControl, kids = noKids()):
  category Appearance:
    borderStyle: BorderStyle
    showLineNumbers: bool
    showWhitespace: bool
    showIndentGuides: bool
    highlightCurrentLine: bool
    highlightBrackets: bool
    markerColumn: bool
  category Behaviour:
    language: string
    readOnly: bool
    folding: bool
    tabWidth: int
    insertSpaces: bool
    lineEnding: LineEnding
    ensureTrailingNewline: bool
    autoHighlighter: bool
    fileName: string
  category Data:
    text: string
  category Events:
    onChange: NotifyEvent
    onModifiedChanged: NotifyEvent
    onCaretMove: CaretMoveEvent
    onGutterClick: GutterClickEvent

# ------------------------------------------------ non-visual components

registerClass(Timer, parent = Component):
  category Behaviour:
    interval: int
    enabled: bool
  category Events:
    onTimer: TimerEvent

registerClass(ImageList, parent = Component,
              create = newImageList(16, 16, asOwner(owner, parent))):
  category Appearance:
    width: float32
    height: float32
  category Data:
    images: seq[Image]

registerClass(MainMenu, parent = Control, kids = menuKids(self.items)):
  category Data:
    images: ImageList

registerClass(PopupMenu, parent = Component, kids = menuKids(self.items)):
  category Data:
    images: ImageList
  category Events:
    onPopup: PopupEvent

registerClass(MenuItem, parent = Component,
              create = newMenuItem(owner = asOwner(owner, parent)),
              attach = attachMenuItem(parent, child),
              kids = menuKids(self)):
  category Appearance:
    caption: string
    imageIndex: int
    prop shortcut, string, getShortcut, setShortcut
    action: Action
  category Behaviour:
    enabled: bool
    visible: bool
    checked: bool
    radioItem: bool
    groupIndex: int
    autoCheck: bool
  category Events:
    onClick: MenuItemEvent

registerClass(ActionList, parent = Component, kids = actionKids(self)):
  category Data:
    images: ImageList
  category Events:
    onExecute: ActionListEvent
    onUpdate: ActionListEvent

registerClass(Action, parent = Component, create = newActionOf(owner, parent)):
  category Appearance:
    caption: string
    hint: string
    imageIndex: int
    prop shortcut, string, getShortcut, setShortcut
  category Behaviour:
    category: string
    enabled: bool
    visible: bool
    autoCheck: bool
    groupIndex: int
    checked: bool
  category Events:
    onExecute: ActionEvent
    onUpdate: ActionEvent

# ------------------------------------------------------------- collections
# The owned items a designer edits in a collection editor (Delphi's `Columns`,
# `Panels`, `Items`, pages, tool buttons). They are written to a form file as
# child objects; the `pkCollection` property only gives the inspector a "..."
# button and the editor the operations.

proc controlItems[T: Control](o: Obj): seq[Obj] =
  for c in Container(o).children:
    if c of T: result.add Obj(c)

proc controlOps[T: Control](cls: string): CollectionOps =
  CollectionOps(
    items: proc(o: Obj): seq[Obj] = controlItems[T](o),
    add: proc(o: Obj): Obj = classByName(cls).createObject(Component(o), o),
    remove: proc(o, child: Obj) = Control(child).free(),
    move: proc(o, child: Obj, newIndex: int) =
      let c = Container(o)
      let kids = controlItems[T](o)
      let old = kids.find(child)
      if old < 0 or newIndex notin 0 ..< kids.len or old == newIndex: return
      let target = Control(kids[newIndex])
      c.removeControl(Control(child))
      c.insertControl(Control(child), c.children.find(target) + (if newIndex > old: 1 else: 0)))

proc menuRootOf(o: Obj): MenuItem =
  if o of MenuItem: MenuItem(o)
  elif o of MainMenu: MainMenu(o).items
  else: PopupMenu(o).items

proc menuOps(): CollectionOps =
  CollectionOps(
    items: proc(o: Obj): seq[Obj] = menuKids(menuRootOf(o)),
    add: proc(o: Obj): Obj = classByName("MenuItem").createObject(Component(o), o),
    remove: proc(o, child: Obj) =
      let it = MenuItem(child)
      let par = it.parent
      if par != nil: par.delete(par.indexOf(it))
      if it.owner != nil: it.owner.removeComponent(it),
    move: proc(o, child: Obj, newIndex: int) =
      let par = MenuItem(child).parent
      if par != nil and newIndex in 0 ..< par.count: par.insert(MenuItem(child), newIndex))

proc panelOps(): CollectionOps =
  CollectionOps(
    items: proc(o: Obj): seq[Obj] = toObjs(StatusBar(o).panels),
    add: proc(o: Obj): Obj = classByName("StatusPanel").createObject(Component(o), o),
    remove: proc(o, child: Obj) =
      let b = StatusBar(o)
      b.deletePanel(b.panels.find(StatusPanel(child))),
    move: proc(o, child: Obj, newIndex: int) =
      let b = StatusBar(o)
      b.movePanel(b.panels.find(StatusPanel(child)), newIndex))

proc columnOps(): CollectionOps =
  CollectionOps(
    items: proc(o: Obj): seq[Obj] = columnKids(ListView(o)),
    add: proc(o: Obj): Obj = classByName("ListColumn").createObject(Component(o), o),
    remove: proc(o, child: Obj) = ListView(o).columns.delete(ListColumn(child).index),
    move: proc(o, child: Obj, newIndex: int) =
      ListView(o).columns.move(ListColumn(child).index, newIndex))

proc actionOps(): CollectionOps =
  CollectionOps(
    items: proc(o: Obj): seq[Obj] = actionKids(ActionList(o)),
    add: proc(o: Obj): Obj = classByName("Action").createObject(Component(o), o),
    remove: proc(o, child: Obj) = Action(child).free())

proc addColl(cls, name, childClass: string, ops: CollectionOps) =
  classByName(cls).addCollection(name, childClass, ops)

addColl "ListView", "columns", "ListColumn", columnOps()
addColl "StatusBar", "panels", "StatusPanel", panelOps()
addColl "MainMenu", "items", "MenuItem", menuOps()
addColl "PopupMenu", "items", "MenuItem", menuOps()
addColl "MenuItem", "items", "MenuItem", menuOps()
addColl "PageControl", "pages", "TabSheet", controlOps[TabSheet]("TabSheet")
addColl "ActionList", "actions", "Action", actionOps()
addColl "ToolBar", "buttons", "ToolButton", controlOps[ToolButton]("ToolButton")
