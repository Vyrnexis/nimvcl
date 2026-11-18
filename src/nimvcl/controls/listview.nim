## `ListView` (VCL TListView): items shown as a report (columns), a list, or
## icons.
##
## `viewStyle`
## -----------
## * `vsReport`: columns with a header (`columns.add("Name", 200)`); the
##   caption is column 0, `item.subItems[k]` is column k + 1. Header: click
##   fires `onColumnClick(sender, column)` (sorting is the application's job;
##   `sortItems(cmp)` / `sortByColumn` help, `sortColumn` / `sortOrder` only
##   control the arrow drawn in the header); dragging the border at the right
##   of a column resizes it (`onColumnResize`; `column.minWidth`, `maxWidth`,
##   `resizable`). `showHeader`, `gridLines`, `rowSelect` (default true: the
##   whole row is highlighted; false: only the caption cell, and clicks right
##   of it hit nothing).
## * `vsList`: small icon + caption, flowing down and then to the next column;
##   scrolls horizontally.
## * `vsSmallIcon`: the same in a grid that wraps at the width of the control.
## * `vsIcon`: large icon with the caption below, wrapped to two lines.
## `smallImages` / `largeImages` are `ImageList`s (`imageIndex` of an item).
## `cellWidth` (0 = automatic) sets the width of a cell / list column.
##
## Items
## -----
## `lv.items.add("caption", "sub 1", "sub 2")` returns the `ListItem`; also
## `insert`, `delete`, `clear`, `[]`, `count`. A `ListItem` has `caption`,
## `subItems`, `imageIndex`, `checked`, `selected`, `data` (RootRef), `tag` and
## `index`.
##
## Virtual mode: `ownerData = true`, `onData(sender, item)` and
## `itemsCount = N`. Items are never stored; `onData` fills `item.caption`,
## `item.subItems` (and `imageIndex`) of a scratch item whose `index` is the
## row, only for the rows that are painted (once per row and paint), hit-tested
## or searched by type-ahead. `items.add/insert/delete` and `sortItems` do
## nothing then; tell the view when the data changed with `refreshData()` (or
## `itemsCount =`). Selection and check state are kept by index in sets.
## Pixel positions are float32 (row positions are exact up to ~700,000 rows;
## beyond that scrolling is quantised, which is invisible for navigation).
##
## Selection (as ListBox)
## ----------------------
## `itemIndex` is the focused item (-1 none). Single mode: it is the
## selection. `multiSelect`: click selects one, Ctrl+click toggles, Shift+click /
## Shift+arrows select the range of indices from the anchor, Ctrl+arrows move
## the focus only, Ctrl+Space toggles (plain Space too without
## `extendedSelect`), Ctrl+A selects all, dragging selects
## (a rubber band is not implemented). `selected(i)`, `setSelected`,
## `selCount`, `selectedIndices`, `selectAll`, `clearSelection`.
## `onSelectItem(sender, item, selected)` fires per item whose selection
## changed (only when assigned), `onChange` once per change of the focus /
## selection, `onClick`, `onDblClick` are the usual mouse events.
## `onSelectionChanged(sender, added, removed)` is the batched form: it fires
## ONCE per selection change with the sorted indices that became selected and
## the ones that no longer are (also when selected items are removed from the
## list). Prefer it for big selections: Ctrl+A / `selectAll` / `clearSelection`
## / `setSelection` on 100,000 rows calls `onSelectItem` 100,000 times (each
## call may hit `onData` in virtual mode) but `onSelectionChanged` once. When
## both are assigned, the per-item calls come first, then
## `onSelectionChanged`, then `onChange`. Leave `onSelectItem` nil when you do
## not need it: nothing per item is computed or called then.
## `onItemDblClick(sender, index, column)` fires on a double click that hits an
## item (not the header, not empty space); `column` is the report-view column
## under the pointer (-1 in other views). `onDblClick` is unchanged. In any
## mouse handler `lastMousePos` is the client position of the last mouse
## event and `hitTestAt(lastMousePos)` tells the item and part under it.
##
## Setting the selection from code: `itemIndex = i` selects EXACTLY item `i`
## (clearing any other selection, moving focus and anchor, scrolling it into
## view); `setSelection(indices, focus)` replaces the whole selection in one
## step (multi-select; single mode keeps the first index) and `clearSelection()`
## empties it. Both are O(n) in the indices given, fire `onChange` ONCE, and
## call `onSelectItem` only for items whose state changed (only when assigned).
## Both are safe with 100,000 selected rows in virtual (`onData`) mode.
##
## Check boxes: `checkboxes = true`; click on the box or Space toggles
## (`onItemChecked`); `item.checked`, `itemChecked(i)`, `setChecked(i, v)`.
##
## Keys: arrows (2D in icon views: Left/Right = +-1, Up/Down = +-cells per
## row; in `vsList` Left/Right = +-a column; in the report Left/Right scroll
## horizontally), Home/End/PgUp/PgDn, Ctrl+A, Space, F2 (edit the caption),
## type-ahead on captions.
##
## Label editing: F2 or a second click on the caption of the selected item
## (after `slowClickDelay` ms) starts `beginEdit`; `readOnly` disables it;
## `onEditing(sender, item, allow)`, `onEdited(sender, item, text)` (may change
## the text; in virtual mode store it yourself), Enter / focus loss commit,
## Escape cancels.
##
## Drawing: `onCustomDrawItem(sender, canvas, item, rect, state, defaultDraw)`
## per painted item (`rect`: the row / cell in client coordinates), and in the
## report `onCustomDrawSubItem(sender, canvas, item, column, rect, state,
## defaultDraw)` per visible cell (column 0 = caption). Both run after the
## selection / hover background; set `defaultDraw = false` to replace the
## default content. `hotTrack` underlines the caption under the mouse.

import std/[sets, algorithm, strutils]
import ../graphics/context
import ../core/timer
import ./common, ./scrolling, ./edit, ./imagelist, ./viewsupport
export scrolling, imagelist, viewsupport.CheckBoxState, viewsupport.ItemState,
       viewsupport.ItemStates

type
  ListViewStyle* = enum vsIcon, vsSmallIcon, vsList, vsReport
  SortOrder* = enum soNone, soAscending, soDescending
  ListHit* = enum lhNone, lhItem, lhCheck, lhIcon, lhLabel

  ListColumn* = ref object of RootObj
    fView: ListView
    fCaption: string
    fWidth: float32
    minWidth*, maxWidth*: float32   ## maxWidth 0 = unlimited
    alignment*: HAlign
    resizable*: bool
    tag*: int

  ListItem* = ref object
    fView: ListView
    fIndex: int
    fCaption: string
    fChecked: bool
    fScratch: bool                  ## virtual-mode item handed to `onData`
    subItems*: seq[string]
    imageIndex*: int
    data*: RootRef
    tag*: int

  ListItemEvent* = proc(sender: Control, item: ListItem)
  ListSelectEvent* = proc(sender: Control, item: ListItem, selected: bool)
  ListSelectionEvent* = proc(sender: Control, added, removed: openArray[int])
  ListColumnEvent* = proc(sender: Control, column: ListColumn)
  ListItemDblClickEvent* = proc(sender: Control, index, column: int)
  ListAllowEvent* = proc(sender: Control, item: ListItem, allow: var bool)
  ListEditedEvent* = proc(sender: Control, item: ListItem, text: var string)
  ListDrawItemEvent* = proc(sender: Control, canvas: Canvas, item: ListItem,
                            rect: RectF, state: ItemStates, defaultDraw: var bool)
  ListDrawSubItemEvent* = proc(sender: Control, canvas: Canvas, item: ListItem,
                               column: int, rect: RectF, state: ItemStates,
                               defaultDraw: var bool)

  ListView* = ref object of ScrollingControl
    fBorder: BorderStyle
    fItems: seq[ListItem]
    fColumns: seq[ListColumn]
    fCount: int                      ## virtual item count
    fOwnerData: bool
    fSel, fChecks: HashSet[int]
    fIndex, fAnchor, fHot, fEditIdx, fSlowIdx, fDownIdx: int
    fVer: int
    fStyle: ListViewStyle
    fMulti, fExtended, fShowHeader, fGridLines, fRowSelect, fHotTrack: bool
    fCheckboxes, fReadOnly, fDragging, fMouseIn: bool
    fItemHeight, fLastIh, fCellW, fMouseX, fMouseY: float32
    fPer, fRpc: int                  ## icon views: cells per row; list: rows per column
    fSmall, fLarge: ImageList
    fSmallListener, fLargeListener: int
    fSortCol: int
    fSortOrder: SortOrder
    fHdrHot, fHdrDown, fResizeCol: int
    fResizeX0, fResizeW0: float32
    fHdrDownX: float32
    fEdit: Edit
    fSlowTimer: Timer
    fTypeBuf: string
    fTypeTime: int64
    slowClickDelay*: int
    typeAheadTimeout*: int
    onChange*: NotifyEvent
    onSelectItem*: ListSelectEvent
    onSelectionChanged*: ListSelectionEvent
    onItemChecked*: ListItemEvent
    onItemDblClick*: ListItemDblClickEvent
    onColumnClick*: ListColumnEvent
    onColumnResize*: ListColumnEvent
    onData*: ListItemEvent
    onEditing*: ListAllowEvent
    onEdited*: ListEditedEvent
    onCustomDrawItem*: ListDrawItemEvent
    onCustomDrawSubItem*: ListDrawSubItemEvent

  ListItems* = object
    lv: ListView
  ListColumns* = object
    lv: ListView

const
  PadX = 6'f32
  BorderGrab = 4'f32       ## header border hot zone (each side)
  DefaultColumnWidth = 100'f32
  NotNav = low(int)        ## navTarget: not a navigation key

# ----------------------------------------------------------------- basics

func count*(lv: ListView): int =
  if lv.fOwnerData: lv.fCount else: lv.fItems.len
func itemsCount*(lv: ListView): int = lv.count
func ownerData*(lv: ListView): bool = lv.fOwnerData
func itemIndex*(lv: ListView): int = lv.fIndex
func viewStyle*(lv: ListView): ListViewStyle = lv.fStyle
func multiSelect*(lv: ListView): bool = lv.fMulti
func extendedSelect*(lv: ListView): bool = lv.fExtended
func showHeader*(lv: ListView): bool = lv.fShowHeader
func gridLines*(lv: ListView): bool = lv.fGridLines
func rowSelect*(lv: ListView): bool = lv.fRowSelect
func hotTrack*(lv: ListView): bool = lv.fHotTrack
func checkboxes*(lv: ListView): bool = lv.fCheckboxes
func readOnly*(lv: ListView): bool = lv.fReadOnly
func smallImages*(lv: ListView): ImageList = lv.fSmall
func largeImages*(lv: ListView): ImageList = lv.fLarge
func cellWidth*(lv: ListView): float32 = lv.fCellW
func sortColumn*(lv: ListView): int = lv.fSortCol
func sortOrder*(lv: ListView): SortOrder = lv.fSortOrder
func isEditing*(lv: ListView): bool = lv.fEditIdx >= 0
func editingIndex*(lv: ListView): int = lv.fEditIdx
func editControl*(lv: ListView): Edit = lv.fEdit
func itemsPerRow*(lv: ListView): int = lv.fPer
  ## Icon views: cells per row (valid after layout).
func rowsPerColumn*(lv: ListView): int = lv.fRpc
  ## `vsList`: rows per column (valid after layout).

func caption*(c: ListColumn): string = c.fCaption
func width*(c: ListColumn): float32 = c.fWidth
func index*(c: ListColumn): int =
  if c.fView == nil: -1 else: c.fView.fColumns.find(c)
func index*(it: ListItem): int = it.fIndex

proc invalidateView(lv: ListView) = (if lv != nil: lv.invalidate())

proc refresh(lv: ListView)

proc `caption=`*(c: ListColumn, v: string) =
  c.fCaption = v
  c.fView.invalidateView()
proc `width=`*(c: ListColumn, v: float32) =
  var w = max(v, max(c.minWidth, 8))
  if c.maxWidth > 0: w = min(w, c.maxWidth)
  if w == c.fWidth: return
  c.fWidth = w
  if c.fView != nil: c.fView.refresh()

func itemsView(it: ListItem): ListView = it.fView

proc itemChecked*(lv: ListView, i: int): bool =
  if lv.fOwnerData: i in lv.fChecks
  elif i in 0 ..< lv.fItems.len: lv.fItems[i].fChecked
  else: false

proc caption*(it: ListItem): string = it.fCaption
proc `caption=`*(it: ListItem, v: string) =
  it.fCaption = v
  if not it.fScratch: it.fView.invalidateView()

proc checked*(it: ListItem): bool =
  if it.fView == nil: it.fChecked
  elif it.fScratch: it.fIndex in it.fView.fChecks
  else: it.fChecked
proc selected*(it: ListItem): bool =
  it.fView != nil and it.fIndex in it.fView.fSel

proc update*(it: ListItem) =
  ## Repaints after `subItems` were changed directly.
  if not it.fScratch: it.fView.invalidateView()

# -------------------------------------------------------------- metrics

proc lineH(lv: ListView): float32 =
  if lv.canMeasure: ceil(lv.renderCtx.fontMetrics(lv.font).lineHeight)
  else: 18

proc itemHeight*(lv: ListView): float32 =
  ## Row height in report / list / small icon views (automatic when not set).
  if lv.fItemHeight > 0: return lv.fItemHeight
  let icon = if lv.fSmall != nil: lv.fSmall.height + 4 else: 0'f32
  max(max(lv.lineH + 6, 20), icon)

proc headerHeight*(lv: ListView): float32 =
  ## Height of the column header (0 when not shown).
  if lv.fStyle == vsReport and lv.fShowHeader: max(lv.itemHeight + 2, 24) else: 0

func largeIconSize(lv: ListView): SizeF =
  if lv.fLarge != nil: sizeF(lv.fLarge.width, lv.fLarge.height) else: sizeF(32, 32)

proc cellW(lv: ListView): float32 =
  if lv.fCellW > 0 and lv.fStyle != vsReport: return lv.fCellW
  case lv.fStyle
  of vsIcon: max(84, lv.largeIconSize.w + 36)
  of vsSmallIcon: 150
  of vsList: 160
  of vsReport: 0

proc cellH(lv: ListView): float32 =
  if lv.fStyle == vsIcon: lv.largeIconSize.h + 2 * lv.lineH + 18
  else: lv.itemHeight

proc totalColumnWidth(lv: ListView): float32 =
  for c in lv.fColumns: result += c.fWidth

method scrollLineSize*(lv: ListView): SizeF =
  case lv.fStyle
  of vsReport: sizeF(24, lv.itemHeight)
  of vsIcon, vsSmallIcon: sizeF(20, lv.cellH)
  of vsList: sizeF(lv.cellW, 20)

# ------------------------------------------------------------ item access

proc getItem*(lv: ListView, i: int): ListItem =
  ## Item `i` (nil when out of range). Virtual mode: a scratch item filled by
  ## `onData` (one call per `getItem`).
  if i < 0 or i >= lv.count: return nil
  if lv.fOwnerData:
    result = ListItem(fView: lv, fIndex: i, imageIndex: -1, fScratch: true)
    if lv.onData != nil: lv.onData(lv, result)
  else:
    result = lv.fItems[i]

proc bareItem(lv: ListView, i: int): ListItem =
  ## For deselect notifications: the stored item, or (virtual mode) a scratch
  ## item with only its index set; `onData` is never asked, because the index
  ## may no longer exist in the application's data.
  if lv.fOwnerData:
    ListItem(fView: lv, fIndex: i, imageIndex: -1, fScratch: true)
  elif i in 0 ..< lv.fItems.len: lv.fItems[i]
  else: ListItem(fView: lv, fIndex: i, imageIndex: -1, fScratch: true)

proc itemCaption*(lv: ListView, i: int): string =
  if lv.fOwnerData:
    if i < 0 or i >= lv.fCount: "" else: lv.getItem(i).fCaption
  elif i in 0 ..< lv.fItems.len: lv.fItems[i].fCaption
  else: ""

# ---------------------------------------------------------------- geometry

proc computeLayoutCounts(lv: ListView) =
  let vp = lv.viewport
  case lv.fStyle
  of vsIcon, vsSmallIcon:
    lv.fPer = max(int(floor(vp.w / lv.cellW)), 1)
  of vsList:
    lv.fRpc = max(int(floor(vp.h / lv.cellH)), 1)
  of vsReport: discard

proc cellRect(lv: ListView, i: int): RectF =
  ## Item `i` in CONTENT coordinates.
  case lv.fStyle
  of vsReport:
    rectF(0, float32(float64(i) * float64(lv.itemHeight)),
          max(lv.totalColumnWidth, lv.viewport.w), lv.itemHeight)
  of vsIcon, vsSmallIcon:
    let per = max(lv.fPer, 1)
    rectF(float32(i mod per) * lv.cellW,
          float32(float64(i div per) * float64(lv.cellH)), lv.cellW, lv.cellH)
  of vsList:
    let rpc = max(lv.fRpc, 1)
    rectF(float32(i div rpc) * lv.cellW, float32(i mod rpc) * lv.cellH,
          lv.cellW, lv.cellH)

proc cellOrigin(lv: ListView, i: int): (float64, float64) =
  ## Top-left of item `i` in CONTENT coordinates, float64 (exact for millions
  ## of rows; `cellRect` rounds to float32).
  case lv.fStyle
  of vsReport: (0.0, float64(i) * float64(lv.itemHeight))
  of vsIcon, vsSmallIcon:
    let per = max(lv.fPer, 1)
    (float64(i mod per) * float64(lv.cellW),
     float64(i div per) * float64(lv.cellH))
  of vsList:
    let rpc = max(lv.fRpc, 1)
    (float64(i div rpc) * float64(lv.cellW), float64(i mod rpc) * float64(lv.cellH))

proc itemRect*(lv: ListView, i: int): RectF =
  ## Item `i` (a row / cell) in client coordinates, as currently scrolled.
  ## The subtraction of the scroll position is done in float64, so the result
  ## is exact however many rows there are.
  let vp = lv.viewport
  let c = lv.cellRect(i)
  let o = lv.cellOrigin(i)
  rectF(vp.x + float32(o[0] - lv.scrollPosX), vp.y + float32(o[1] - lv.scrollPosY),
        c.w, c.h)

proc columnLeft*(lv: ListView, col: int): float32 =
  ## Left edge of column `col` in client coordinates (as scrolled).
  result = lv.viewport.x - lv.scrollPos.x
  for k in 0 ..< min(col, lv.fColumns.len): result += lv.fColumns[k].fWidth

proc captionRectIn(lv: ListView, i: int, cell: RectF): RectF =
  ## Caption area inside the item rect `cell`.
  case lv.fStyle
  of vsReport:
    var x = cell.x + PadX
    if lv.fCheckboxes: x += CheckSize + 4
    if lv.fSmall != nil: x += lv.fSmall.width + 4
    let w0 = if lv.fColumns.len > 0: lv.fColumns[0].fWidth else: cell.w
    rectF(x, cell.y, max(cell.x + w0 - PadX - x, 0), cell.h)
  of vsSmallIcon, vsList:
    var x = cell.x + 4
    if lv.fCheckboxes: x += CheckSize + 4
    if lv.fSmall != nil: x += lv.fSmall.width + 4
    rectF(x, cell.y, max(cell.right - 4 - x, 0), cell.h)
  of vsIcon:
    let top = cell.y + 6 + lv.largeIconSize.h + 4
    rectF(cell.x + 3, top, cell.w - 6, 2 * lv.lineH + 2)

proc captionRect*(lv: ListView, i: int): RectF =
  ## The caption area of item `i` in client coordinates.
  lv.captionRectIn(i, lv.itemRect(i))

proc iconRect*(lv: ListView, i: int): RectF =
  ## Where the icon of item `i` is drawn (empty when there is no image list).
  let cell = lv.itemRect(i)
  case lv.fStyle
  of vsIcon:
    if lv.fLarge == nil and lv.fSmall == nil: return rectF(0, 0, 0, 0)
    let s = lv.largeIconSize
    rectF(cell.x + floor((cell.w - s.w) / 2), cell.y + 6, s.w, s.h)
  else:
    if lv.fSmall == nil: return rectF(0, 0, 0, 0)
    var x = cell.x + (if lv.fStyle == vsReport: PadX else: 4)
    if lv.fCheckboxes: x += CheckSize + 4
    rectF(x, cell.y + floor((cell.h - lv.fSmall.height) / 2),
          lv.fSmall.width, lv.fSmall.height)

proc checkRect*(lv: ListView, i: int): RectF =
  ## The check box of item `i` in client coordinates (empty when none).
  if not lv.fCheckboxes: return rectF(0, 0, 0, 0)
  let cell = lv.itemRect(i)
  if lv.fStyle == vsIcon:
    rectF(cell.x + 4, cell.y + 4, CheckSize, CheckSize)
  else:
    rectF(cell.x + (if lv.fStyle == vsReport: PadX else: 4),
          cell.y + floor((cell.h - CheckSize) / 2), CheckSize, CheckSize)

proc rowRange(lv: ListView): (int, int) =
  ## Items [a, b) that intersect the viewport.
  let vp = lv.viewport
  let n = lv.count
  case lv.fStyle
  of vsReport:
    let ih = float64(lv.itemHeight)
    (max(int(floor(lv.scrollPosY / ih)), 0),
     min(int(ceil((lv.scrollPosY + float64(vp.h)) / ih)), n))
  of vsIcon, vsSmallIcon:
    let ch = float64(lv.cellH)
    let per = max(lv.fPer, 1)
    (max(int(floor(lv.scrollPosY / ch)), 0) * per,
     min(int(ceil((lv.scrollPosY + float64(vp.h)) / ch)) * per, n))
  of vsList:
    let cw = lv.cellW
    let rpc = max(lv.fRpc, 1)
    (max(int(floor(lv.scrollPosX / float64(cw))), 0) * rpc,
     min(int(ceil((lv.scrollPosX + float64(vp.w)) / float64(cw))) * rpc, n))

proc itemAt*(lv: ListView, p: PointF): int =
  ## Item under `p` (client coordinates); -1 where there is none.
  let vp = lv.viewport
  if not vp.contains(p): return -1
  let cx = float64(p.x - vp.x) + lv.scrollPosX
  let cy = float64(p.y - vp.y) + lv.scrollPosY
  var i = -1
  case lv.fStyle
  of vsReport:
    i = int(floor(cy / float64(lv.itemHeight)))
    if not lv.fRowSelect and lv.fColumns.len > 0 and
       cx >= float64(lv.fColumns[0].fWidth): return -1
  of vsIcon, vsSmallIcon:
    let col = int(floor(cx / float64(lv.cellW)))
    let per = max(lv.fPer, 1)
    if col >= per: return -1
    i = int(floor(cy / float64(lv.cellH))) * per + col
  of vsList:
    let rpc = max(lv.fRpc, 1)
    let row = int(floor(cy / float64(lv.cellH)))
    if row >= rpc: return -1
    i = int(floor(cx / float64(lv.cellW))) * rpc + row
  if i < 0 or i >= lv.count: -1 else: i

proc lastMousePos*(lv: ListView): PointF =
  ## Client position of the last mouse move / press (for `onDblClick` etc.).
  pointF(lv.fMouseX, lv.fMouseY)

proc hitTestAt*(lv: ListView, p: PointF): tuple[index: int, part: ListHit] =
  ## The item and the part of it under `p` (client coordinates).
  let i = lv.itemAt(p)
  if i < 0: return (-1, lhNone)
  result.index = i
  let cr = lv.checkRect(i)
  let ir = lv.iconRect(i)
  if cr.w > 0 and cr.inflate(2).contains(p): result.part = lhCheck
  elif ir.w > 0 and ir.contains(p): result.part = lhIcon
  else:
    let cap = lv.captionRect(i)
    if cap.contains(p): result.part = lhLabel
    else: result.part = lhItem

proc headerRect(lv: ListView): RectF =
  let hh = lv.headerHeight
  rectF(1, 1, max(lv.width - 2, 0), hh)

proc columnAt*(lv: ListView, p: PointF): int =
  ## Header cell under `p` (client coordinates); -1 when not on a column.
  let hh = lv.headerHeight
  if hh <= 0 or not lv.headerRect.contains(p): return -1
  if p.x < lv.viewport.x or p.x >= lv.viewport.right: return -1
  var x = lv.viewport.x - lv.scrollPos.x
  for k, c in lv.fColumns:
    if p.x >= x and p.x < x + c.fWidth: return k
    x += c.fWidth
  -1

proc columnBorderAt*(lv: ListView, p: PointF): int =
  ## The column whose right border is under `p` in the header; -1 for none.
  let hh = lv.headerHeight
  if hh <= 0 or not lv.headerRect.contains(p): return -1
  var x = lv.viewport.x - lv.scrollPos.x
  for k, c in lv.fColumns:
    x += c.fWidth
    if abs(p.x - x) <= BorderGrab and p.x >= lv.viewport.x and
       p.x <= lv.viewport.right and c.resizable: return k
  -1

# ---------------------------------------------------------------- refresh

proc refresh(lv: ListView) =
  let hh = lv.headerHeight
  let pad = spacing(1, 1 + hh, 1, 1)
  if lv.padding != pad: lv.padding = pad
  let ih = lv.itemHeight
  let n = lv.count
  var csW, csH = 0.0
  var oldPer = -1
  var oldRpc = -1
  let oldIh = lv.fLastIh
  for iter in 0 .. 2:
    lv.computeLayoutCounts()
    case lv.fStyle
    of vsReport:
      csW = float64(lv.totalColumnWidth)
      csH = float64(n) * float64(ih)
    of vsIcon, vsSmallIcon:
      csW = 0
      csH = float64((n + lv.fPer - 1) div lv.fPer) * float64(lv.cellH)
    of vsList:
      csW = float64((n + lv.fRpc - 1) div lv.fRpc) * float64(lv.cellW)
      csH = 0
    if lv.fStyle == vsReport and oldIh > 0 and ih != oldIh and iter == 0:
      let y = lv.scrollPosY / float64(oldIh) * float64(ih)
      lv.fLastIh = ih
      if ih < oldIh: lv.scrollTo(lv.scrollPosX, y)
      lv.setContentSize(csW, csH)
      if ih >= oldIh: lv.scrollTo(lv.scrollPosX, y)
    else:
      lv.setContentSize(csW, csH)
    if lv.fPer == oldPer and lv.fRpc == oldRpc: break
    oldPer = lv.fPer
    oldRpc = lv.fRpc
  lv.fLastIh = ih
  lv.invalidate()

method beforeLayout*(lv: ListView) =
  lv.refresh()
  procCall beforeLayout(ScrollingControl(lv))

method doResize*(lv: ListView) =
  procCall doResize(ScrollingControl(lv))

proc refreshData*(lv: ListView) =
  ## Virtual mode: the application's data changed (repaint, re-clamp).
  lv.refresh()
  lv.scrollBy(0, 0)

proc touch(lv: ListView) = inc lv.fVer

type SelSnap = object
  active: bool
  old: HashSet[int]

proc snap(lv: ListView): SelSnap =
  if lv.onSelectItem != nil or lv.onSelectionChanged != nil:
    SelSnap(active: true, old: lv.fSel)
  else: SelSnap()

proc notify(lv: ListView, ver: int, sn: SelSnap) =
  ## Fires the selection events once when the state changed since `ver`.
  if lv.fVer == ver: return
  lv.invalidate()
  if sn.active and (lv.onSelectItem != nil or lv.onSelectionChanged != nil):
    var gone, came: seq[int]
    for i in sn.old:
      if i notin lv.fSel: gone.add i
    for i in lv.fSel:
      if i notin sn.old: came.add i
    gone.sort()
    came.sort()
    if lv.onSelectItem != nil:
      for i in gone:
        let it = lv.getItem(i)
        if it != nil: lv.onSelectItem(lv, it, false)
      for i in came:
        let it = lv.getItem(i)
        if it != nil: lv.onSelectItem(lv, it, true)
    if lv.onSelectionChanged != nil and (gone.len > 0 or came.len > 0):
      lv.onSelectionChanged(lv, came, gone)
  if lv.onChange != nil: lv.onChange(lv)

proc selectOnly(lv: ListView, i: int) =
  if lv.fSel.len == 1 and i in lv.fSel: return
  lv.fSel.clear()
  if i >= 0: lv.fSel.incl i
  lv.touch()

proc selectRange(lv: ListView, a, b: int) =
  var s = initHashSet[int]()
  for j in min(a, b) .. max(a, b): s.incl j
  if s == lv.fSel: return
  lv.fSel = s
  lv.touch()

proc setFocusRow(lv: ListView, i: int) =
  if i != lv.fIndex:
    lv.fIndex = i
    lv.touch()

proc makeVisible*(lv: ListView, i: int) =
  ## Scrolls the minimum distance that shows item `i`.
  if i < 0 or i >= lv.count: return
  let r = lv.cellRect(i)
  let o = lv.cellOrigin(i)
  case lv.fStyle
  of vsReport, vsIcon, vsSmallIcon:
    lv.scrollIntoView(lv.scrollPosX, o[1], 1, float64(r.h))
  of vsList:
    lv.scrollIntoView(o[0], lv.scrollPosY, float64(r.w), 1)

proc layoutEdit(lv: ListView)

proc hotUpdate(lv: ListView) =
  var h = -1
  if lv.fMouseIn and lv.isEnabled and lv.fResizeCol < 0:
    h = lv.itemAt(pointF(lv.fMouseX, lv.fMouseY))
  if h != lv.fHot:
    lv.fHot = h
    lv.invalidate()

method contentScrolled*(lv: ListView) =
  procCall contentScrolled(ScrollingControl(lv))
  lv.fSlowIdx = -1
  lv.hotUpdate()
  lv.layoutEdit()

# --------------------------------------------------------------- selection

func selected*(lv: ListView, i: int): bool = i in lv.fSel
func selCount*(lv: ListView): int = lv.fSel.len

proc selectedIndices*(lv: ListView): seq[int] =
  for i in lv.fSel: result.add i
  result.sort()

proc `itemIndex=`*(lv: ListView, i: int) =
  ## Selects exactly item `i` (-1: nothing) and scrolls it into view.
  let v = lv.fVer
  let sn = lv.snap()
  let n = if i < 0 or i >= lv.count: -1 else: i
  lv.selectOnly(n)
  lv.setFocusRow(n)
  lv.fAnchor = n
  lv.makeVisible(n)
  lv.notify(v, sn)

proc setSelection*(lv: ListView, indices: openArray[int], focus = -1) =
  ## Replaces the selection with `indices` (out-of-range entries are ignored)
  ## in one step: one `onChange`, `onSelectItem` only for items that changed.
  ## `focus` becomes the focused item and anchor (-1: the first index given, or
  ## none); it is scrolled into view when it is valid. Single mode keeps only
  ## the first index. An empty list clears the selection.
  let v = lv.fVer
  let sn = lv.snap()
  var s = initHashSet[int]()
  var first = -1
  for i in indices:
    if i >= 0 and i < lv.count:
      if first < 0: first = i
      if not lv.fMulti and s.len == 1: break
      s.incl i
  if s != lv.fSel:
    lv.fSel = s
    lv.touch()
  var f = focus
  if f < 0 or f >= lv.count: f = first
  lv.setFocusRow(f)
  lv.fAnchor = f
  if f >= 0: lv.makeVisible(f)
  lv.notify(v, sn)

proc setSelected*(lv: ListView, i: int, v: bool) =
  ## Single mode: selecting moves `itemIndex`; clearing clears it.
  if i < 0 or i >= lv.count: return
  if not lv.fMulti:
    if v: lv.itemIndex = i
    elif i == lv.fIndex: lv.itemIndex = -1
    return
  if v == (i in lv.fSel): return
  let ver = lv.fVer
  let sn = lv.snap()
  if v: lv.fSel.incl i else: lv.fSel.excl i
  lv.touch()
  lv.notify(ver, sn)

proc `selected=`*(it: ListItem, v: bool) =
  if it.fView != nil: it.fView.setSelected(it.fIndex, v)

proc clearSelection*(lv: ListView) =
  if lv.fSel.len == 0: return
  let v = lv.fVer
  let sn = lv.snap()
  lv.fSel.clear()
  lv.touch()
  lv.notify(v, sn)

proc selectAll*(lv: ListView) =
  ## Multi-select only.
  if not lv.fMulti or lv.count == 0: return
  let v = lv.fVer
  let sn = lv.snap()
  lv.selectRange(0, lv.count - 1)
  lv.notify(v, sn)

proc `multiSelect=`*(lv: ListView, v: bool) =
  if v == lv.fMulti: return
  lv.fMulti = v
  if not v and lv.fSel.len > 1: lv.selectOnly(lv.fIndex)
  lv.invalidate()

proc `extendedSelect=`*(lv: ListView, v: bool) = lv.fExtended = v

# ------------------------------------------------------------------ checks

proc setChecked*(lv: ListView, i: int, v: bool) =
  ## Sets the check state of item `i` from code (no event).
  if i < 0 or i >= lv.count: return
  if lv.fOwnerData:
    if v: lv.fChecks.incl i else: lv.fChecks.excl i
  else:
    lv.fItems[i].fChecked = v
  lv.invalidate()

proc `checked=`*(it: ListItem, v: bool) =
  if it.fView == nil: it.fChecked = v
  elif it.fScratch: it.fView.setChecked(it.fIndex, v)
  else:
    it.fChecked = v
    it.fView.invalidate()

proc toggleCheck*(lv: ListView, i: int) =
  ## The user toggles the check box of item `i` (fires `onItemChecked`).
  if i < 0 or i >= lv.count: return
  lv.setChecked(i, not lv.itemChecked(i))
  if lv.onItemChecked != nil: lv.onItemChecked(lv, lv.getItem(i))

# ------------------------------------------------------------------- items

proc endEdit*(lv: ListView, cancel = false)

proc renumber(lv: ListView, from0 = 0) =
  for i in from0 ..< lv.fItems.len: lv.fItems[i].fIndex = i

proc shiftIndices(lv: ListView, at, delta: int) =
  ## Indices >= `at` move by `delta` (selection, focus, anchor).
  if lv.fSel.len > 0:
    var s = initHashSet[int]()
    for j in lv.fSel: s.incl(if j >= at: j + delta else: j)
    lv.fSel = s
  if lv.fIndex >= at: lv.fIndex += delta
  if lv.fAnchor >= at: lv.fAnchor += delta
  if lv.fEditIdx >= at: lv.fEditIdx += delta
  if lv.fDownIdx >= at: lv.fDownIdx += delta
  if lv.fSlowIdx >= at: lv.fSlowIdx += delta
  lv.fHot = -1

proc insertItem(lv: ListView, index: int, caption: string,
                sub: openArray[string]): ListItem =
  if lv.fOwnerData: return nil
  let i = min(max(index, 0), lv.fItems.len)
  result = ListItem(fView: lv, fIndex: i, fCaption: caption, imageIndex: -1,
                    subItems: @sub)
  lv.shiftIndices(i, 1)
  lv.fItems.insert(result, i)
  lv.renumber(i + 1)
  lv.refresh()
  lv.layoutEdit()                        # the edited item may have moved

proc deleteItem(lv: ListView, i: int) =
  if lv.fOwnerData or i < 0 or i >= lv.fItems.len: return
  if lv.fEditIdx >= 0: lv.endEdit(cancel = true)   # no edit on a vanishing item
  let v = lv.fVer
  let wasSel = i in lv.fSel
  # decide about item i BEFORE the later indices shift down onto it
  let wasFocus = lv.fIndex == i
  let wasAnchor = lv.fAnchor == i
  if lv.fDownIdx == i: lv.fDownIdx = -1
  if lv.fSlowIdx == i: lv.fSlowIdx = -1
  if wasSel and lv.onSelectItem != nil: lv.onSelectItem(lv, lv.fItems[i], false)
  if wasSel and lv.onSelectionChanged != nil:
    lv.onSelectionChanged(lv, [], [i])   # later indices shift down: not reported
  lv.fSel.excl i
  lv.shiftIndices(i + 1, -1)
  if wasFocus: lv.fIndex = -1
  if wasAnchor: lv.fAnchor = -1
  lv.fItems[i].fView = nil
  lv.fItems.delete(i)
  lv.renumber(i)
  if wasSel or lv.fIndex == -1: lv.touch()
  lv.refresh()
  lv.scrollBy(0, 0)
  lv.notify(v, SelSnap())

proc clearItems(lv: ListView) =
  if lv.fEditIdx >= 0: lv.endEdit(cancel = true)
  let v = lv.fVer
  let had = lv.fSel.len > 0 or lv.fIndex >= 0
  if lv.onSelectItem != nil and lv.fSel.len > 0:
    for i in lv.selectedIndices: lv.onSelectItem(lv, lv.bareItem(i), false)
  if lv.onSelectionChanged != nil and lv.fSel.len > 0:
    lv.onSelectionChanged(lv, [], lv.selectedIndices)
  for it in lv.fItems: it.fView = nil
  lv.fItems.setLen(0)
  lv.fCount = 0
  lv.fSel.clear()
  lv.fChecks.clear()
  lv.fIndex = -1
  lv.fAnchor = -1
  lv.fHot = -1
  lv.fEditIdx = -1
  lv.fDownIdx = -1
  lv.fSlowIdx = -1
  if had: lv.touch()
  lv.refresh()
  lv.scrollTo(0, 0)
  lv.notify(v, SelSnap())

func items*(lv: ListView): ListItems = ListItems(lv: lv)
proc count*(l: ListItems): int = l.lv.count
proc len*(l: ListItems): int = l.lv.count
proc add*(l: ListItems, caption: string, sub: varargs[string]): ListItem {.discardable.} =
  l.lv.insertItem(l.lv.fItems.len, caption, sub)
proc insert*(l: ListItems, index: int, caption: string,
             sub: varargs[string]): ListItem {.discardable.} =
  l.lv.insertItem(index, caption, sub)
proc delete*(l: ListItems, i: int) = l.lv.deleteItem i
proc clear*(l: ListItems) = l.lv.clearItems()
proc `[]`*(l: ListItems, i: int): ListItem = l.lv.getItem(i)
proc indexOf*(l: ListItems, caption: string): int =
  for i in 0 ..< l.lv.count:
    if l.lv.itemCaption(i) == caption: return i
  -1
iterator items*(l: ListItems): ListItem =
  for i in 0 ..< l.lv.count: yield l.lv.getItem(i)

proc delete*(it: ListItem) =
  ## Removes a (non-virtual) item from its view.
  if it.fView != nil and not it.fScratch: it.fView.deleteItem(it.fIndex)

proc `ownerData=`*(lv: ListView, v: bool) =
  if v == lv.fOwnerData: return
  lv.clearItems()
  lv.fOwnerData = v
  lv.refresh()

proc `itemsCount=`*(lv: ListView, n: int) =
  ## Virtual mode: the number of items.
  let newCount = max(n, 0)
  if not lv.fOwnerData:
    lv.fCount = newCount
  else:
    let v = lv.fVer
    var changed = false
    var drop: seq[int]
    for j in lv.fSel:
      if j >= newCount: drop.add j
    drop.sort()
    if lv.fEditIdx >= newCount: lv.endEdit(cancel = true)
    for j in drop:                       # items that no longer exist: told first
      if lv.onSelectItem != nil: lv.onSelectItem(lv, lv.bareItem(j), false)
      lv.fSel.excl j
      changed = true
    if drop.len > 0 and lv.onSelectionChanged != nil:
      lv.onSelectionChanged(lv, [], drop)
    lv.fCount = newCount
    drop.setLen(0)
    for j in lv.fChecks:
      if j >= lv.fCount: drop.add j
    for j in drop: lv.fChecks.excl j
    if lv.fIndex >= lv.fCount:
      lv.fIndex = -1
      changed = true
    if lv.fAnchor >= lv.fCount: lv.fAnchor = -1
    if changed: lv.touch()
    lv.refresh()
    lv.scrollBy(0, 0)
    lv.notify(v, SelSnap())

proc sortItems*(lv: ListView, cmp: proc(a, b: ListItem): int) =
  ## Stable sort of the (non-virtual) items; selection, focus and anchor stay
  ## attached to their items. Virtual mode: sort your data and call
  ## `refreshData`.
  if lv.fOwnerData or lv.fItems.len < 2: return
  let old = lv.fItems
  var order = newSeq[int](old.len)
  for i in 0 ..< order.len: order[i] = i
  order.sort(proc(a, b: int): int =
    result = cmp(old[a], old[b])
    if result == 0: result = system.cmp(a, b))
  var pos = newSeq[int](order.len)            # old index -> new index
  for n, o in order:
    pos[o] = n
    lv.fItems[n] = old[o]
  lv.renumber()
  var s = initHashSet[int]()
  for j in lv.fSel: s.incl pos[j]
  lv.fSel = s
  if lv.fIndex >= 0: lv.fIndex = pos[lv.fIndex]
  if lv.fAnchor >= 0: lv.fAnchor = pos[lv.fAnchor]
  lv.fHot = -1
  lv.invalidate()
  if lv.fIndex >= 0: lv.makeVisible(lv.fIndex)

proc `sortColumn=`*(lv: ListView, v: int) =
  lv.fSortCol = v
  lv.invalidate()
proc `sortOrder=`*(lv: ListView, v: SortOrder) =
  lv.fSortOrder = v
  lv.invalidate()

proc columnText*(it: ListItem, col: int): string =
  ## Column 0 = caption, k = `subItems[k - 1]`.
  if col <= 0: it.fCaption
  elif col - 1 < it.subItems.len: it.subItems[col - 1]
  else: ""

proc sortByColumn*(lv: ListView, col: int, order = soAscending) =
  ## Sorts the items by the text of a column (case-insensitive) and shows the
  ## sort arrow on it. A convenience for `onColumnClick`.
  lv.fSortCol = col
  lv.fSortOrder = order
  lv.sortItems(proc(a, b: ListItem): int =
    result = cmpIgnoreCase(a.columnText(col), b.columnText(col))
    if order == soDescending: result = -result)

# ----------------------------------------------------------------- columns

func columns*(lv: ListView): ListColumns = ListColumns(lv: lv)
proc count*(l: ListColumns): int = l.lv.fColumns.len
proc len*(l: ListColumns): int = l.lv.fColumns.len
proc `[]`*(l: ListColumns, i: int): ListColumn =
  if i in 0 ..< l.lv.fColumns.len: l.lv.fColumns[i] else: nil
proc add*(l: ListColumns, caption = "", width = DefaultColumnWidth,
          alignment = taLeft): ListColumn {.discardable.} =
  result = ListColumn(fView: l.lv, fCaption: caption, minWidth: 20,
                      alignment: alignment, resizable: true)
  result.fWidth = max(width, 20)
  l.lv.fColumns.add result
  l.lv.refresh()
proc delete*(l: ListColumns, i: int) =
  if i in 0 ..< l.lv.fColumns.len:
    l.lv.fColumns[i].fView = nil
    l.lv.fColumns.delete(i)
    if l.lv.fSortCol == i: l.lv.fSortCol = -1
    elif l.lv.fSortCol > i: dec l.lv.fSortCol
    l.lv.refresh()
proc move*(l: ListColumns, from0, to0: int) =
  ## Moves column `from0` to index `to0` (the sort column follows).
  let n = l.lv.fColumns.len
  if from0 notin 0 ..< n or to0 notin 0 ..< n or from0 == to0: return
  let sc = if l.lv.fSortCol >= 0 and l.lv.fSortCol < n: l.lv.fColumns[l.lv.fSortCol] else: nil
  let c = l.lv.fColumns[from0]
  l.lv.fColumns.delete(from0)
  l.lv.fColumns.insert(c, to0)
  if sc != nil: l.lv.fSortCol = l.lv.fColumns.find(sc)
  l.lv.refresh()
proc clear*(l: ListColumns) =
  for c in l.lv.fColumns: c.fView = nil
  l.lv.fColumns.setLen(0)
  l.lv.fSortCol = -1
  l.lv.refresh()
iterator items*(l: ListColumns): ListColumn =
  for c in l.lv.fColumns: yield c

# ---------------------------------------------------------- property setters

proc `viewStyle=`*(lv: ListView, v: ListViewStyle) =
  lv.fStyle = v
  case v
  of vsReport:
    lv.hScrollMode = sbmAuto
    lv.vScrollMode = sbmAuto
  of vsIcon, vsSmallIcon:
    lv.hScrollMode = sbmNever
    lv.vScrollMode = sbmAuto
  of vsList:
    lv.hScrollMode = sbmAuto
    lv.vScrollMode = sbmNever
  lv.scrollTo(0, 0)
  lv.refresh()
  if lv.fIndex >= 0: lv.makeVisible(lv.fIndex)

proc watchImages(lv: ListView, old, v: ImageList, id: var int) =
  ## Re-subscribes to the image list so changes repaint / re-measure the view.
  if old != nil and id != 0: old.removeListener(id)
  id = 0
  if v != nil:
    id = v.addListener(proc() =
      lv.refresh()
      lv.invalidate())

proc `smallImages=`*(lv: ListView, v: ImageList) =
  lv.watchImages(lv.fSmall, v, lv.fSmallListener)
  lv.fSmall = v
  lv.refresh()
proc `largeImages=`*(lv: ListView, v: ImageList) =
  lv.watchImages(lv.fLarge, v, lv.fLargeListener)
  lv.fLarge = v
  lv.refresh()
method releaseResources*(lv: ListView) =
  lv.smallImages = nil
  lv.largeImages = nil
proc `itemHeight=`*(lv: ListView, v: float32) =
  lv.fItemHeight = max(v, 0)
  lv.refresh()
proc `cellWidth=`*(lv: ListView, v: float32) =
  lv.fCellW = max(v, 0)
  lv.refresh()
proc `showHeader=`*(lv: ListView, v: bool) =
  lv.fShowHeader = v
  lv.refresh()
proc `gridLines=`*(lv: ListView, v: bool) = lv.fGridLines = v; lv.invalidate()
proc `rowSelect=`*(lv: ListView, v: bool) = lv.fRowSelect = v; lv.invalidate()
proc `hotTrack=`*(lv: ListView, v: bool) = lv.fHotTrack = v; lv.invalidate()
proc `checkboxes=`*(lv: ListView, v: bool) = lv.fCheckboxes = v; lv.invalidate()

# ----------------------------------------------------------------- editing

proc layoutEdit(lv: ListView) =
  if lv.fEditIdx < 0 or lv.fEdit == nil: return
  let r = lv.captionRect(lv.fEditIdx)
  let ih = lv.itemHeight
  let vp = lv.viewport
  var x = r.x - 3
  var w = max(r.w + 6, 80)
  var y = r.y
  var h = ih
  case lv.fStyle
  of vsIcon:
    x = r.x - 2
    w = r.w + 4
  of vsReport:
    y = r.y
    h = r.h
    w = max(w, 80)
    # keep inside the first column when it is wide enough
    if lv.fColumns.len > 0:
      let right = lv.columnLeft(0) + lv.fColumns[0].fWidth
      w = max(min(w, right - x), 40)
  else:
    y = r.y + (r.h - ih) / 2
  w = min(w, max(vp.right - x, 40))
  lv.fEdit.setBounds(x, y, w, h)

proc endEdit*(lv: ListView, cancel = false) =
  ## Ends the in-place edit: commits (`onEdited`) unless `cancel`.
  if lv.fEditIdx < 0: return
  let i = lv.fEditIdx
  lv.fEditIdx = -1
  var txt = lv.fEdit.text
  if lv.fEdit.focused: lv.setFocus()
  lv.fEdit.visible = false
  if not cancel and i < lv.count:
    let item = lv.getItem(i)
    if lv.onEdited != nil: lv.onEdited(lv, item, txt)
    if not lv.fOwnerData: item.fCaption = txt
  lv.invalidate()

proc beginEdit*(lv: ListView, i: int): bool {.discardable.} =
  ## Starts editing the caption of item `i` (F2). False when read-only,
  ## vetoed by `onEditing` or out of range.
  if lv.fReadOnly or i < 0 or i >= lv.count or not lv.isEnabled: return false
  if lv.fEditIdx >= 0: lv.endEdit()
  let item = lv.getItem(i)
  var allow = true
  if lv.onEditing != nil: lv.onEditing(lv, item, allow)
  if not allow: return false
  lv.makeVisible(i)
  if lv.fEdit == nil:
    let e = newEdit(lv)
    e.visible = false
    e.tabStop = false
    e.onKeyDown = proc(s: Control, key: var Key, shift: ShiftState) =
      if key == keyEnter: key = Key(0); lv.endEdit()
      elif key == keyEscape: key = Key(0); lv.endEdit(cancel = true)
    e.onExit = proc(s: Control) = lv.endEdit()
    lv.fEdit = e
  lv.fEditIdx = i
  lv.fEdit.text = item.fCaption
  lv.layoutEdit()
  lv.fEdit.visible = true
  lv.fEdit.setFocus()
  lv.fEdit.selectAll()
  lv.invalidate()
  true

proc `readOnly=`*(lv: ListView, v: bool) =
  lv.fReadOnly = v
  if v: lv.endEdit(cancel = true)

# ---------------------------------------------------------------- user input

proc cancelSlow(lv: ListView) =
  lv.fSlowIdx = -1
  if lv.fSlowTimer != nil: lv.fSlowTimer.enabled = false

proc armSlow(lv: ListView, i: int) =
  lv.fSlowIdx = i
  if lv.fSlowTimer == nil:
    let t = newTimer(nil, lv.slowClickDelay)
    t.onTimer = proc(s: Timer) =
      s.enabled = false
      let j = lv.fSlowIdx
      lv.fSlowIdx = -1
      if j >= 0 and j == lv.fIndex and lv.focused: lv.beginEdit(j)
    lv.fSlowTimer = t
  lv.fSlowTimer.enabled = false
  lv.fSlowTimer.interval = max(lv.slowClickDelay, 1)
  lv.fSlowTimer.enabled = true

method canFocus*(lv: ListView): bool = lv.isVisible and lv.isEnabled

method doMouseEnter*(lv: ListView) =
  lv.fMouseIn = true
  procCall doMouseEnter(Control(lv))

method doMouseLeave*(lv: ListView) =
  lv.fMouseIn = false
  lv.fHdrHot = -1
  lv.hotUpdate()
  lv.invalidate()
  procCall doMouseLeave(Control(lv))

proc applyClick(lv: ListView, i: int, shift: ShiftState) =
  if lv.fMulti:
    if lv.fExtended:
      if ssShift in shift and lv.fAnchor >= 0:
        lv.selectRange(lv.fAnchor, i)
      elif ssCtrl in shift:
        if i in lv.fSel: lv.fSel.excl i else: lv.fSel.incl i
        lv.touch()
        lv.fAnchor = i
      else:
        lv.selectOnly(i)
        lv.fAnchor = i
    else:
      if i in lv.fSel: lv.fSel.excl i else: lv.fSel.incl i
      lv.touch()
      lv.fAnchor = i
  else:
    lv.selectOnly(i)
    lv.fAnchor = i
  lv.setFocusRow(i)

method doMouseDown*(lv: ListView, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  lv.cancelSlow()
  lv.fDownIdx = -1
  lv.fMouseX = x
  lv.fMouseY = y
  if button == mbLeft:
    let p = pointF(x, y)
    let hb = lv.columnBorderAt(p)
    if hb >= 0:
      lv.fResizeCol = hb
      lv.fResizeX0 = x
      lv.fResizeW0 = lv.fColumns[hb].fWidth
    elif lv.headerHeight > 0 and lv.headerRect.contains(p):
      lv.fHdrDown = lv.columnAt(p)
      lv.fHdrDownX = x
      lv.invalidate()
    else:
      let (i, part) = lv.hitTestAt(p)
      if i >= 0:
        lv.fDownIdx = i
        if part == lhCheck:
          lv.toggleCheck(i)
        else:
          let v = lv.fVer
          let sn = lv.snap()
          let wasOnly = i == lv.fIndex and lv.fSel.len == 1 and part == lhLabel and
                        shift * {ssShift, ssCtrl, ssDouble} == {}
          lv.applyClick(i, shift)
          # drag-select only after a plain click (Ctrl / Shift-click do not)
          lv.fDragging = lv.fMulti and lv.fExtended and
                         shift * {ssShift, ssCtrl} == {}
          lv.makeVisible(i)
          lv.notify(v, sn)
          if wasOnly and not lv.fReadOnly: lv.armSlow(i)
  procCall doMouseDown(Control(lv), button, shift, x, y)

method doMouseMove*(lv: ListView, shift: ShiftState, x, y: float32) =
  lv.fMouseIn = true
  lv.fMouseX = x
  lv.fMouseY = y
  let p = pointF(x, y)
  if lv.fResizeCol >= 0:
    if ssLeft in shift:
      let c = lv.fColumns[lv.fResizeCol]
      let before = c.fWidth
      c.width = lv.fResizeW0 + (x - lv.fResizeX0)
      if c.fWidth != before and lv.onColumnResize != nil: lv.onColumnResize(lv, c)
    else:
      lv.fResizeCol = -1
  elif lv.fDragging and ssLeft in shift and lv.count > 0:
    let i = lv.itemAt(p)
    if i >= 0 and i != lv.fIndex:
      let v = lv.fVer
      let sn = lv.snap()
      lv.selectRange(max(lv.fAnchor, 0), i)
      lv.setFocusRow(i)
      lv.makeVisible(i)
      lv.notify(v, sn)
  elif lv.fDragging and ssLeft notin shift:
    lv.fDragging = false
  # header hover / cursor
  if lv.headerHeight > 0:
    let hot = if lv.fResizeCol >= 0: -1 else: lv.columnAt(p)
    if hot != lv.fHdrHot:
      lv.fHdrHot = hot
      lv.invalidate()
    let onBorder = lv.fResizeCol >= 0 or lv.columnBorderAt(p) >= 0
    let want = if onBorder: crSizeWE else: crDefault
    if lv.cursor != want: lv.cursor = want
  lv.hotUpdate()
  procCall doMouseMove(Control(lv), shift, x, y)

method doMouseUp*(lv: ListView, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  if button == mbLeft:
    lv.fDragging = false
    lv.fResizeCol = -1
    if lv.fHdrDown >= 0:
      let down = lv.fHdrDown
      lv.fHdrDown = -1
      lv.invalidate()
      if lv.columnAt(pointF(x, y)) == down and down < lv.fColumns.len and
         lv.onColumnClick != nil:
        lv.onColumnClick(lv, lv.fColumns[down])
  procCall doMouseUp(Control(lv), button, shift, x, y)

proc reportColumnAtX(lv: ListView, px: float32): int =
  if lv.fStyle != vsReport: return -1
  var x = lv.viewport.x - lv.scrollPos.x
  for k, c in lv.fColumns:
    if px >= x and px < x + c.fWidth: return k
    x += c.fWidth
  -1

method doDblClick*(lv: ListView) =
  lv.cancelSlow()
  procCall doDblClick(Control(lv))
  if lv.onItemDblClick != nil:
    let p = lv.lastMousePos
    if not (lv.headerHeight > 0 and lv.headerRect.contains(p)):
      let i = lv.itemAt(p)
      if i >= 0: lv.onItemDblClick(lv, i, lv.reportColumnAtX(p.x))

proc moveFocus(lv: ListView, target: int, shift: ShiftState) =
  ## Keyboard navigation to item `target` (already clamped).
  let v = lv.fVer
  let sn = lv.snap()
  if lv.fMulti:
    if lv.fExtended and ssShift in shift:
      if lv.fAnchor < 0: lv.fAnchor = max(lv.fIndex, 0)
      lv.selectRange(lv.fAnchor, target)
    elif lv.fExtended and ssCtrl notin shift:
      lv.selectOnly(target)
      lv.fAnchor = target
  else:
    lv.selectOnly(target)
    lv.fAnchor = target
  lv.setFocusRow(target)
  lv.makeVisible(target)
  lv.notify(v, sn)

proc typeAhead(lv: ListView, ch: char) =
  let now = nowMs()
  if now - lv.fTypeTime > lv.typeAheadTimeout: lv.fTypeBuf.setLen(0)
  lv.fTypeTime = now
  lv.fTypeBuf.add toLowerAscii(ch)
  let n = lv.count
  if n == 0: return
  let start = if lv.fTypeBuf.len == 1: lv.fIndex + 1 else: max(lv.fIndex, 0)
  for k in 0 ..< n:
    let i = (start + k) mod n
    if prefixIC(lv.itemCaption(i), lv.fTypeBuf):
      let v = lv.fVer
      let sn = lv.snap()
      if lv.fMulti and not lv.fExtended: lv.setFocusRow(i)
      else:
        lv.selectOnly(i)
        lv.fAnchor = i
        lv.setFocusRow(i)
      lv.makeVisible(i)
      lv.notify(v, sn)
      break

proc firstFullRow(lv: ListView): int =
  int(ceil(lv.scrollPosY / float64(lv.itemHeight)))
proc lastFullRow(lv: ListView): int =
  min(int(floor((lv.scrollPosY + float64(lv.viewport.h)) /
                float64(lv.itemHeight))) - 1, lv.count - 1)

proc navTarget(lv: ListView, key: Key, cur: int): int =
  ## Target index of a navigation key; `NotNav` when `key` is not one.
  let n = lv.count
  result = NotNav
  if key == keyHome: return 0
  if key == keyEnd: return n - 1
  case lv.fStyle
  of vsReport:
    let span = max(lv.lastFullRow - lv.firstFullRow, 1)
    if key == keyUp: result = if cur < 0: 0 else: cur - 1
    elif key == keyDown: result = cur + 1
    elif key == keyPageDown:
      let lf = lv.lastFullRow
      result = if cur < lf: lf else: cur + span
    elif key == keyPageUp:
      let ff = lv.firstFullRow
      result = if cur > ff: ff else: cur - span
  of vsIcon, vsSmallIcon:
    let per = max(lv.fPer, 1)
    let rowsVisible = max(int(floor(lv.viewport.h / lv.cellH)), 1)
    if key == keyLeft: result = if cur < 0: 0 else: cur - 1
    elif key == keyRight: result = cur + 1
    elif key == keyUp:
      result = if cur < 0: 0 elif cur - per < 0: cur else: cur - per
    elif key == keyDown:
      if cur < 0: result = 0
      elif cur + per < n: result = cur + per
      elif cur div per < (n - 1) div per: result = n - 1     # partial last row
      else: result = cur
    elif key == keyPageDown: result = if cur < 0: 0 else: cur + per * rowsVisible
    elif key == keyPageUp: result = if cur < 0: 0 else: cur - per * rowsVisible
  of vsList:
    let rpc = max(lv.fRpc, 1)
    let colsVisible = max(int(floor(lv.viewport.w / lv.cellW)), 1)
    if key == keyUp: result = if cur < 0: 0 else: cur - 1
    elif key == keyDown: result = cur + 1
    elif key == keyLeft: result = if cur < 0: 0 elif cur - rpc < 0: cur else: cur - rpc
    elif key == keyRight:
      if cur < 0: result = 0
      elif cur + rpc < n: result = cur + rpc
      elif cur div rpc < (n - 1) div rpc: result = n - 1
      else: result = cur
    elif key == keyPageDown: result = if cur < 0: 0 else: cur + rpc * colsVisible
    elif key == keyPageUp: result = if cur < 0: 0 else: cur - rpc * colsVisible

method doKeyDown*(lv: ListView, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(lv), key, shift)
  if key == Key(0) or not lv.isEnabled or lv.fEditIdx >= 0: return
  lv.cancelSlow()
  if shift * {ssAlt} != {}: return
  let n = lv.count
  let target = lv.navTarget(key, lv.fIndex)
  if target != NotNav:
    key = Key(0)
    if n > 0: lv.moveFocus(min(max(target, 0), n - 1), shift)
    return
  if lv.fStyle == vsReport and (key == keyLeft or key == keyRight):
    lv.scrollBy(if key == keyLeft: -24 else: 24, 0)
    key = Key(0)
    return
  if key == keyF2 and lv.fIndex >= 0:
    key = Key(0)
    lv.beginEdit(lv.fIndex)
  elif key == keySpace and lv.fIndex >= 0 and (lv.fCheckboxes or
       (lv.fMulti and (ssCtrl in shift or not lv.fExtended))):
    key = Key(0)
    if lv.fMulti and (ssCtrl in shift or not lv.fCheckboxes):
      let v = lv.fVer
      let sn = lv.snap()
      lv.applyClick(lv.fIndex, {ssCtrl})
      lv.notify(v, sn)
    else:
      lv.toggleCheck(lv.fIndex)
  elif lv.fMulti and lv.fExtended and ssCtrl in shift and key == 'a'.key:
    key = Key(0)
    lv.selectAll()
  else:
    let ch = typeAheadChar(key, shift)
    if ch != '\0' and (ch != ' ' or lv.fTypeBuf.len > 0 and
                       nowMs() - lv.fTypeTime <= lv.typeAheadTimeout):
      key = Key(0)
      lv.typeAhead(ch)

method doExit*(lv: ListView) =
  lv.fDragging = false
  lv.fResizeCol = -1
  lv.fHdrDown = -1
  lv.cancelSlow()
  lv.invalidate()
  procCall doExit(Control(lv))

# -------------------------------------------------------------------- paint

proc fitLines(c: Canvas, text: string, f: FontSpec, w, lineH: float32,
              maxLines: int): string =
  ## `text` cut with an ellipsis so that it wraps to at most `maxLines` lines.
  if text.len == 0: return text
  if c.measureText(text, f, w).h <= lineH * float32(maxLines) + 1: return text
  var lo = 0
  var hi = text.len
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    var cut = mid
    while cut > 0 and cut < text.len and (uint8(text[cut]) and 0xC0) == 0x80: dec cut
    if c.measureText(text[0 ..< cut].strip(leading = false) & "…", f, w).h <=
       lineH * float32(maxLines) + 1: lo = mid
    else: hi = mid - 1
  var cut = lo
  while cut > 0 and cut < text.len and (uint8(text[cut]) and 0xC0) == 0x80: dec cut
  text[0 ..< cut].strip(leading = false) & "…"

proc stateOf(lv: ListView, i: int, focused, enabled: bool): ItemStates =
  if i in lv.fSel: result.incl isSelected
  if focused and i == lv.fIndex: result.incl isFocused
  if i == lv.fHot: result.incl isHot
  if not enabled: result.incl isDisabled

proc textColorOf(lv: ListView, st: ItemStates, focused: bool): Color =
  let t = lv.theme
  if isDisabled in st: t.textDisabled
  elif isSelected in st and focused: t.selectionText
  elif isSelected in st and not lv.ownColor: lv.ink(t, t.selectionInactive)
  else: lv.ink(t, lv.fieldFill(t, true))

proc subTextColor(lv: ListView, bg: Color): Color =
  ## Text of the other columns: softer than the item text.
  if lv.hasFontColor: mix(lv.font.color, bg, 0.25'f32)
  else: legible(lv.theme.textMuted, bg)

proc paintHeader(lv: ListView, c: Canvas) =
  let t = lv.theme
  let hr = lv.headerRect
  let vp = lv.viewport
  c.pushClip(hr)
  let bg = lv.fieldFill(t, true)
  let hbg = lv.headerFill(t, bg)
  let hink = lv.ink(t, hbg)
  c.fillRect(hr, hbg)
  var x = vp.x - lv.scrollPos.x
  let bold = lv.font.bold
  for k, col in lv.fColumns:
    let cell = rectF(x, hr.y, col.fWidth, hr.h)
    x += col.fWidth
    if cell.right < vp.x or cell.x > vp.right: continue
    c.pushClip(rectF(max(cell.x, vp.x), cell.y, min(cell.right, vp.right) - max(cell.x, vp.x), cell.h))
    if lv.fHdrDown == k and lv.columnAt(pointF(lv.fMouseX, lv.fMouseY)) == k:
      c.fillRect(cell, if lv.ownColor: shade(hbg, 0.14'f32) else: t.pressed)
    elif lv.fHdrHot == k and lv.fHdrDown < 0:
      c.fillRect(cell, if lv.ownColor: shade(hbg, 0.08'f32) else: t.hover)
    var tr = rectF(cell.x + PadX, cell.y, max(cell.w - 2 * PadX, 0), cell.h)
    if k == lv.fSortCol and lv.fSortOrder != soNone: tr.w = max(tr.w - 14, 0)
    c.textRect(col.fCaption, bold, tr, hink, col.alignment, vaCenter)
    if k == lv.fSortCol and lv.fSortOrder != soNone:
      drawArrow(c, pointF(cell.right - 11, cell.y + cell.h / 2), 3.5,
                if lv.fSortOrder == soAscending: adUp else: adDown, legible(t.textMuted, hbg))
    c.popClip()
    c.fillRect(rectF(cell.right - 1, cell.y + 4, 1, cell.h - 8), t.border)
  c.popClip()
  c.fillRect(rectF(hr.x, hr.bottom - 1, hr.w, 1), t.border)

proc drawCaptionAndIcon(lv: ListView, c: Canvas, item: ListItem, i: int,
                        cell: RectF, st: ItemStates, focused: bool,
                        rowTextColor: Color, align: HAlign) =
  ## Check box, icon and caption of an item (all view styles).
  let t = lv.theme
  let enabled = isDisabled notin st
  let cr = lv.checkRect(i)
  if cr.w > 0:
    drawCheckGlyph(c, cr, (if lv.itemChecked(i): cbChecked else: cbUnchecked), t, enabled)
  let ir = lv.iconRect(i)
  if ir.w > 0:
    let il = if lv.fStyle == vsIcon and lv.fLarge != nil: lv.fLarge else: lv.fSmall
    if il != nil: il.draw(c, item.imageIndex, ir.x, ir.y, enabled)
  let cap = lv.captionRectIn(i, cell)
  var f = lv.font
  if lv.fHotTrack and isHot in st: f = f.withStyle(f.style + {fsUnderline})
  if lv.fStyle == vsIcon:
    let txt = fitLines(c, item.fCaption, f, cap.w, lv.lineH, 2)
    c.textRect(txt, f, cap, rowTextColor, taCenter, vaTop, wrap = true)
  else:
    c.textRect(item.fCaption, f, cap, rowTextColor, align, vaCenter)

method paint*(lv: ListView, c: Canvas) =
  let t = lv.theme
  let enabled = lv.isEnabled
  let r = lv.clientRect
  let bg = lv.fieldFill(t, enabled)
  c.fillFrame(r, t, lv.fBorder, bg)
  let vp = lv.viewport
  let focused = lv.focused
  let rad = max(t.radius - 1, 2)
  let (first, last) = lv.rowRange
  c.pushClip(vp)
  var gridRows: seq[float32]
  for i in first ..< last:
    let item = lv.getItem(i)
    let st = lv.stateOf(i, focused, enabled)
    let cell = lv.itemRect(i)
    var box = rectF(cell.x + 2, cell.y + 1, cell.w - 4, cell.h - 2)
    if lv.fStyle == vsReport:
      if lv.fColumns.len > 0 and not lv.fRowSelect:
        box.w = lv.fColumns[0].fWidth - 4
    elif lv.fStyle == vsIcon:
      box = rectF(cell.x + 3, cell.y + 2, cell.w - 6, cell.h - 4)
    else:
      box = rectF(cell.x + 1, cell.y + 1, cell.w - 2, cell.h - 2)
    if isSelected in st:
      c.fillRoundRect(box, rad, if focused and enabled: t.selection
                                else: t.selectionInactive)
    elif isHot in st:
      c.fillRoundRect(box, rad, lv.rowHover(t, bg))
    if isFocused in st and lv.fMulti:
      c.strokeRoundRect(box, rad, t.focusRing, 1)
    var def = true
    if lv.onCustomDrawItem != nil: lv.onCustomDrawItem(lv, c, item, cell, st, def)
    if lv.fStyle == vsReport: gridRows.add cell.bottom - 1
    if not def: continue
    let col = lv.textColorOf(st, focused)
    if lv.fStyle != vsReport:
      lv.drawCaptionAndIcon(c, item, i, cell, st, focused, col, taLeft)
      continue
    # report: one cell per visible column
    if lv.fColumns.len == 0:
      lv.drawCaptionAndIcon(c, item, i, cell, st, focused, col, taLeft)
      continue
    var x = cell.x
    for k, column in lv.fColumns:
      let cr = rectF(x, cell.y, column.fWidth, cell.h)
      x += column.fWidth
      if cr.right < vp.x: continue
      if cr.x > vp.right: break
      var defCell = true
      if lv.onCustomDrawSubItem != nil:
        lv.onCustomDrawSubItem(lv, c, item, k, cr, st, defCell)
      if not defCell: continue
      if k == 0:
        lv.drawCaptionAndIcon(c, item, i, cell, st, focused, col, column.alignment)
      else:
        let tr = rectF(cr.x + PadX, cr.y, max(cr.w - 2 * PadX, 0), cr.h)
        let sc = if isDisabled in st: t.textDisabled
                 elif isSelected in st and focused: t.selectionText
                 else: lv.subTextColor(bg)
        c.textRect(item.columnText(k), lv.font, tr, sc, column.alignment, vaCenter)
  if lv.fStyle == vsReport and lv.fGridLines:
    let gc = t.border.withAlpha(150)
    for y in gridRows: c.fillRect(rectF(vp.x, y, vp.w, 1), gc)
    var x = vp.x - lv.scrollPos.x
    for column in lv.fColumns:
      x += column.fWidth
      if x >= vp.x and x <= vp.right: c.fillRect(rectF(x - 1, vp.y, 1, vp.h), gc)
  c.popClip()
  if lv.fStyle == vsReport and lv.headerHeight > 0: lv.paintHeader(c)
  let ring = focused
  c.strokeFrame(r, t, lv.fBorder, if ring: t.focusRing else: t.borderStrong,
                    if ring: t.focusRingWidth else: t.borderWidth)
  procCall paint(Control(lv), c)

# -------------------------------------------------------------------- init

func borderStyle*(x: ListView): BorderStyle = x.fBorder
proc `borderStyle=`*(x: ListView, v: BorderStyle) =
  ## `bsSingle` (default): the usual border and focus ring; `bsNone`: none,
  ## so the control can sit flush in a panel.
  if v == x.fBorder: return
  x.fBorder = v
  x.invalidate()

proc initListView*(lv: ListView, owner: Component = nil) =
  lv.initScrollingControl(owner)
  lv.fBorder = bsSingle
  lv.setBounds(0, 0, 360, 220)
  lv.tabStop = true
  lv.fIndex = -1
  lv.fAnchor = -1
  lv.fHot = -1
  lv.fEditIdx = -1
  lv.fSlowIdx = -1
  lv.fDownIdx = -1
  lv.fHdrHot = -1
  lv.fHdrDown = -1
  lv.fResizeCol = -1
  lv.fSortCol = -1
  lv.fExtended = true
  lv.fShowHeader = true
  lv.fRowSelect = true
  lv.fStyle = vsIcon
  lv.fPer = 1
  lv.fRpc = 1
  lv.slowClickDelay = 600
  lv.typeAheadTimeout = 1000
  lv.fSel = initHashSet[int]()
  lv.fChecks = initHashSet[int]()
  lv.padding = spacing(1)
  lv.viewStyle = vsReport

proc newListView*(parent: Container = nil, left = 0'f32, top = 0'f32,
                  width = -1'f32, height = -1'f32): ListView {.discardable.} =
  new result
  result.initListView(parent)
  result.placeControl(parent, left, top, width, height)

# --------------------------------------------------- design-time text form

proc itemLines*(lv: ListView): seq[string] =
  ## The items as text, one line per item: the caption, then the sub-items,
  ## separated by tab characters (what a form file stores for `items`). Empty
  ## in owner-data mode.
  if lv.fOwnerData: return
  for i in 0 ..< lv.count:
    let it = lv.getItem(i)
    var line = it.caption
    for s in it.subItems: line.add '\t' & s
    result.add line

proc `itemLines=`*(lv: ListView, v: seq[string]) =
  ## Replaces all items by the lines of `v` (see `itemLines`).
  if lv.fOwnerData: return
  lv.items.clear()
  for l in v:
    let p = l.split('\t')
    lv.items.add(p[0], p[1 .. ^1])
