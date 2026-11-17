## Registers the stock controls and components with the property registry
## (`props.nim`): every public control with its designer properties and events.
## Importing this module is enough; `nfm.nim` and the object inspector import it.
##
## Not registered (they have no sensible text form): `DockSite` and its panels
## (their layout is saved with `saveLayout`), tree and list data (`TreeView`
## nodes, `ListView` items, grid cells), owner-draw and virtual-mode hooks.

import std/strutils
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
proc getLines(m: Memo): seq[string] = m.text.splitLines
proc setLines(m: Memo, v: seq[string]) = m.text = v.join("\n")

proc gridSizesToText*(v: seq[GridSize]): string =
  ## `"100, 50%, auto"`: absolute pixels, percent, or `auto`.
  var parts: seq[string]
  for g in v:
    case g.kind
    of gkAbsolute: parts.add $g.value
    of gkPercent: parts.add $g.value & "%"
    of gkAuto: parts.add "auto"
  parts.join(", ")

proc parseGridSizes*(s: string): seq[GridSize] =
  ## Inverse of `gridSizesToText`. Raises `ValueError` for a malformed entry.
  for part in s.split(','):
    let p = part.strip()
    if p.len == 0: continue
    if p == "auto": result.add gsAuto()
    elif p.endsWith("%"): result.add gsPercent(float32(parseFloat(p[0 ..< ^1])))
    else: result.add gsAbsolute(float32(parseFloat(p)))

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
  category Events:
    onShow: NotifyEvent
    onHide: NotifyEvent
    onActivate: NotifyEvent
    onDeactivate: NotifyEvent
    onClose: FormCloseEvent
    onCloseQuery: FormCloseQueryEvent

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
    readOnly: bool
    maxLength: int
    charCase: EditCharCase
    numbersOnly: bool
    autoSelect: bool
  category Data:
    text: string
  category Events:
    onChange: NotifyEvent

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
    images: ImageList
  category Events:
    onChange: TreeNodeEvent
    onChanging: TreeAllowEvent
    onExpanding: TreeAllowEvent
    onCollapsing: TreeAllowEvent
    onExpanded: TreeNodeEvent
    onCollapsed: TreeNodeEvent
    onChecked: TreeNodeEvent

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
    smallImages: ImageList
    largeImages: ImageList
  category Events:
    onChange: NotifyEvent
    onSelectItem: ListSelectEvent
    onItemChecked: ListItemEvent
    onItemDblClick: ListItemDblClickEvent
    onColumnClick: ListColumnEvent
    onColumnResize: ListColumnEvent

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

registerClass(StringGrid, parent = DrawGrid):
  category Behaviour:
    sortOnHeaderClick: bool
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
