## `ObjectInspector`: the Delphi Object Inspector. A property grid for one or
## several objects (controls, menu items, timers, ...), built on the property
## registry (`dsl/props.nim`, `dsl/props_std.nim`).
##
## Layout, top to bottom: a title line (`name: Class`, or "3 objects"), the tabs
## "Properties" / "Events" with a toggle between grouping by category and a flat
## alphabetical list, then the rows: `name | value`. Categories can be
## collapsed. A property that is a composite (`font`, `margins`, `padding`,
## `constraints`) or a set (`anchors`) expands into sub-rows; a set shows one
## check box per element.
##
## Values are edited in place. Click the value (or press Enter on the row):
##
## * strings and numbers: an `Edit`; Enter applies it, a number that does not
##   parse is rejected (the row stays in edit mode, `lastError` says why);
## * enums and bools: a drop-down `ComboBox` (double click cycles);
## * colours: an editable combo with a colour palette (hex text works too);
## * references to other objects (`focusControl`, `images`): a combo of the
##   objects of the same form;
## * string lists, images, image lists and collections (columns, panels, menu
##   items...): a "..." button calls `onEditExtra` (the application opens its
##   own dialog; `controls/propeditors.nim` has ready-made ones). Delete on an
##   image row clears it;
## * events: an editable combo of the existing handler names; double click
##   calls `onCreateHandler(target, event)` for a new handler name.
##
## Values that differ from a fresh instance of the class are drawn bold. With
## several targets the rows are the properties all of them have; a value shows
## when all agree (else the cell is blank) and an edit applies to every target.
##
## Keyboard: Up/Down/PageUp/PageDown/Home/End move, Enter edits, Esc cancels,
## Tab applies and edits the next row (Shift+Tab: previous), Left/Right
## collapse and expand, Space toggles a check box.
##
## Every change goes through the registry (`setProp`). Before it is applied
## `onPropertyChanging(sender, target, propName, newValue, accept, message)` can
## refuse it (the old value stays and the message shows in the error line);
## afterwards `onPropertyChanged(sender, target, propName)` is called. A
## sub-property is reported with its dotted name (`font.size`).
##
## This module is not part of the `import nimvcl` umbrella (it pulls in the
## property registry): `import nimvcl/controls/inspector`.

import std/[strutils, algorithm, sets, math]
import ./common, ./scrolling, ./edit, ./combobox, ./listbox, ./viewsupport
import ../core/form
import ./designsurface
import ../graphics/font
import ../graphics/image
import ../dsl/props_std
from ../dsl/nfmsyntax import formatNumber, validNfmName, isReservedFieldName
export props_std

type
  InspectorTab* = enum itProperties, itEvents

  RowKind = enum rkCategory, rkProp

  Row = object
    kind: RowKind
    cat: PropCategory
    info: PropInfo
    key: string               ## stable identity: "font.size", "cat:Layout"
    level: int
    expandable: bool
    expanded: bool
    shown: bool               ## `value`, `mixed`, `modified` are filled (cleared by `dropValueCache`)
    value: PropValue
    mixed: bool
    modified: bool
    overridden: bool          ## `isOverridden` said yes (filled with `modified`)

  EditKind = enum ekNone, ekText, ekCombo

  PropertyChangedEvent* = proc(sender: Control, target: Obj, prop: string)
  PropertyChangedExEvent* = proc(sender: Control, target: Obj, prop: string,
                                 oldValue, newValue: PropValue)
  PropertyChangingEvent* = proc(sender: Control, target: Obj, prop: string,
                                newValue: PropValue, accept: var bool,
                                message: var string)
  CreateHandlerEvent* = proc(sender: Control, target: Obj, event: string): string
  ExtraEditorEvent* = proc(sender: Control, target: Obj, prop: string)
  HandlerListEvent* = proc(sender: Control, target: Obj, event: string): seq[string]
  ChoicesEvent* = proc(sender: Control, target: Obj, prop: string): seq[Obj]
  FontFamiliesEvent* = proc(sender: Control, target: Obj): seq[string]
  ContextMenuEvent* = proc(sender: Control, prop: string, p: PointF)
  OverriddenEvent* = proc(prop: string): bool

  ObjectInspector* = ref object of ScrollingControl
    fTargets: seq[Obj]
    fTab: InspectorTab
    fFlat: bool
    fRows: seq[Row]
    fSel: int
    fOpen: HashSet[string]
    fClosedCats: set[PropCategory]
    fSplit: float32
    fHot: int
    fEditRow: int
    fEditKind: EditKind
    fEditText: Edit
    fEditCombo: ComboBox
    fEditStart: string          ## what the editor showed when it opened (see `editorState`)
    fChoices: seq[Obj]          ## objects behind the entries of an object combo
    fColorEdit: bool
    fDragSplit: bool
    fError: string
    fHandlers: seq[string]
    onPropertyChanged*: PropertyChangedEvent
      ## A value was changed through the inspector (after it was applied).
    onPropertyChangedEx*: PropertyChangedExEvent
      ## Like `onPropertyChanged`, also with the value before the edit and the
      ## one the property holds now (called right before `onPropertyChanged`).
    designer*: FormDesigner
      ## When set, edits go through `designer.setProps` so they are undoable
      ## (one step per edit, several targets one step) and the designer's
      ## `onModified` / `onPropertyChanged` fire. Unset: the property is set
      ## directly.
    onPropertyChanging*: PropertyChangingEvent
      ## Called for each target before an edit is applied. Set `accept = false`
      ## to refuse it: the old value stays and `message` (a default text when
      ## empty) becomes `lastError`, shown in the inspector's error line. No
      ## target changes when any of them refuses. `prop` is the dotted name
      ## (`font.size`); `newValue` is what would be set.
    onCreateHandler*: CreateHandlerEvent
      ## Double click on an event row without a handler: returns the name of a
      ## new handler (""): nothing happens. When nil, `<Name><Event>` is used.
    onEditExtra*: ExtraEditorEvent
      ## The "..." button of a string list, image, image list or collection
      ## property was pressed (`setValue` applies the result).
    onGetHandlers*: HandlerListEvent
      ## Handler names offered for an event (besides `knownHandlers`).
    onSelectionChanged*: NotifyEvent
      ## The selected row changed.
    onGetChoices*: ChoicesEvent
      ## The objects offered by an object reference property (`images`,
      ## `popupMenu`, `focusControl`...); only those of the property's class are
      ## shown. When nil the named objects of the target's form are offered
      ## (found by walking up from the target), which is wrong for a target
      ## shown inside a design surface: a designer supplies its form's objects.
    onContextMenu*: ContextMenuEvent
      ## A right click was released over the inspector. The row under the cursor
      ## was selected when the button went down; `prop` is its dotted property
      ## name ("" over a category, empty space or the header) and `p` the point
      ## in the inspector's client coordinates (`clientToForm` for a popup).
      ## Called before the control's own `popupMenu` is served, so the host can
      ## adjust that menu for the row.
    isOverridden*: OverriddenEvent
      ## Host predicate: the value of property `prop` (dotted) differs from the
      ## ancestor's (an inherited form). Such rows show their name in bold. The
      ## answer is cached per row until the next `refresh` / rebuild.
    onGetFontFamilies*: FontFamiliesEvent
      ## The family names of the host's project fonts, offered under "Project" in
      ## the `font.family` drop-down. When nil the families registered with
      ## `registerFontFamily*` are offered.

const
  FontGroupBundled* = "-- Bundled --"
  FontGroupProject* = "-- Project --"
  FontGroupSystem* = "-- System (may be missing on other machines) --"
    ## Group headers of the `font.family` drop-down; not selectable.

proc isFontGroupHeader*(s: string): bool =
  s in [FontGroupBundled, FontGroupProject, FontGroupSystem]

const
  ExtraKinds = {pkStrings, pkImage, pkImages, pkCollection}
    ## values edited in a dialog the application opens (`onEditExtra`)
  TitleH = 24'f32
  TabsH = 28'f32
  TopH = TitleH + TabsH
  RowH = 24'f32
  TabW = 92'f32
  ToggleW = 64'f32
  IndentW = 14'f32
  Palette = [
    ("black", Color(r: 0, g: 0, b: 0, a: 255)),
    ("white", Color(r: 255, g: 255, b: 255, a: 255)),
    ("gray", Color(r: 128, g: 128, b: 128, a: 255)),
    ("silver", Color(r: 192, g: 192, b: 192, a: 255)),
    ("red", Color(r: 220, g: 38, b: 38, a: 255)),
    ("maroon", Color(r: 128, g: 0, b: 0, a: 255)),
    ("orange", Color(r: 249, g: 115, b: 22, a: 255)),
    ("yellow", Color(r: 250, g: 204, b: 21, a: 255)),
    ("olive", Color(r: 128, g: 128, b: 0, a: 255)),
    ("lime", Color(r: 132, g: 204, b: 22, a: 255)),
    ("green", Color(r: 22, g: 163, b: 74, a: 255)),
    ("teal", Color(r: 13, g: 148, b: 136, a: 255)),
    ("aqua", Color(r: 6, g: 182, b: 212, a: 255)),
    ("blue", Color(r: 37, g: 99, b: 235, a: 255)),
    ("navy", Color(r: 30, g: 58, b: 138, a: 255)),
    ("purple", Color(r: 147, g: 51, b: 234, a: 255)),
    ("fuchsia", Color(r: 217, g: 70, b: 239, a: 255)),
    ("transparent", Color(r: 0, g: 0, b: 0, a: 0))]

# ----------------------------------------------------------- target values

func targets*(ins: ObjectInspector): seq[Obj] = ins.fTargets
func tab*(ins: ObjectInspector): InspectorTab = ins.fTab
func sortedFlat*(ins: ObjectInspector): bool = ins.fFlat
  ## True: one alphabetical list; false (default): grouped by category.
func lastError*(ins: ObjectInspector): string = ins.fError
func rowCount*(ins: ObjectInspector): int = ins.fRows.len
func selectedRow*(ins: ObjectInspector): int = ins.fSel
func splitX*(ins: ObjectInspector): float32 = ins.fSplit
func knownHandlers*(ins: ObjectInspector): seq[string] = ins.fHandlers
proc `knownHandlers=`*(ins: ObjectInspector, v: seq[string]) = ins.fHandlers = v
  ## Handler names offered by the events tab.

proc infoFor(o: Obj, name: string): PropInfo =
  let ci = classOf(o)
  if ci == nil: nil else: ci.findProp(name)

proc commonProps(ins: ObjectInspector): seq[PropInfo] =
  if ins.fTargets.len == 0: return
  let first = classOf(ins.fTargets[0])
  if first == nil: return
  for p in first.propsOf:
    if p.hidden: continue
    if p.name == "name" and ins.fTargets.len > 1: continue   # one name for several objects
    var ok = true
    for i in 1 ..< ins.fTargets.len:
      let q = infoFor(ins.fTargets[i], p.name)
      if q == nil or q.kind != p.kind or q.typeName != p.typeName:
        ok = false
        break
    if ok: result.add p

proc valueOf(ins: ObjectInspector, info: PropInfo): tuple[v: PropValue, mixed: bool] =
  ## The value of the row for the first target; `mixed` when targets disagree.
  for i, t in ins.fTargets:
    let q = if i == 0: info else: infoFor(t, info.name)
    if q == nil: continue
    var v: PropValue
    try: v = q.get(t)
    except CatchableError: continue
    if i == 0: result.v = v
    elif not (v == result.v): result.mixed = true

proc anyNonDefault(ins: ObjectInspector, info: PropInfo): bool =
  for t in ins.fTargets:
    let q = infoFor(t, info.name)
    if q != nil and not isDefault(t, q): return true

proc dropValueCache(ins: ObjectInspector) =
  ## The targets changed: the rows read their values again when next painted.
  for r in ins.fRows.mitems: r.shown = false

proc rowValue(ins: ObjectInspector, i: int): lent Row =
  ## Row `i` with its value, `mixed` and `modified` flags read from the targets.
  if not ins.fRows[i].shown:
    let info = ins.fRows[i].info
    let (v, mixed) = ins.valueOf(info)
    let modified = ins.anyNonDefault(info)
    ins.fRows[i].value = v
    ins.fRows[i].mixed = mixed
    ins.fRows[i].modified = modified
    ins.fRows[i].overridden = ins.isOverridden != nil and info.name.len > 0 and
                              ins.isOverridden(info.name)
    ins.fRows[i].shown = true
  ins.fRows[i]

# --------------------------------------------------------------- text forms

func catKey(c: PropCategory): string = "cat:" & categoryName(c)

proc objName(o: Obj): string =
  if o == nil: "(none)"
  else:
    let n = objectName(o)
    if n.len > 0: n else: "(" & (if classOf(o) != nil: classOf(o).name else: "object") & ")"

proc valueText(info: PropInfo, v: PropValue): string =
  case v.kind
  of pkBool: $v.b
  of pkInt: $v.i
  of pkFloat: formatNumber(v.f)
  of pkString: v.s
  of pkEnum: info.enumName(v.i)
  of pkSet:
    var parts: seq[string]
    for i, en in info.enumNames:
      if hasBit(v.bits, i): parts.add en
    "[" & parts.join(", ") & "]"
  of pkColor: v.color.toHex
  of pkFont:
    let fam = if v.font.family.len > 0: v.font.family else: "default"
    fam & ", " & formatNumber(float(v.font.size))
  of pkSpacing:
    "(" & formatNumber(float(v.spacing.left)) & ", " & formatNumber(float(v.spacing.top)) & ", " &
      formatNumber(float(v.spacing.right)) & ", " & formatNumber(float(v.spacing.bottom)) & ")"
  of pkConstraints:
    "(" & formatNumber(float(v.cons.minWidth)) & ", " & formatNumber(float(v.cons.minHeight)) & ", " &
      formatNumber(float(v.cons.maxWidth)) & ", " & formatNumber(float(v.cons.maxHeight)) & ")"
  of pkObject: objName(v.obj)
  of pkImage:
    if v.image == nil: "(none)"
    elif v.image.source.len > 0: v.image.source
    else: "(image)"
  of pkImages:
    if v.imgs.len == 0: "(none)"
    elif v.imgs.len == 1: "(1 image)"
    else: "(" & $v.imgs.len & " images)"
  of pkCollection:
    if v.i == 0: "(empty)"
    elif v.i == 1: "(1 item)"
    else: "(" & $v.i & " items)"
  of pkStrings:
    if v.strs.len == 0: "(empty)"
    elif v.strs.len == 1: "(1 line)"
    else: "(" & $v.strs.len & " lines)"
  of pkEvent: v.handler

# ----------------------------------------------------------------- rows

proc isSetElement(info: PropInfo): bool =
  info.kind == pkBool and not info.stored and '.' in info.name

proc composite(info: PropInfo): bool =
  info.kind in {pkFont, pkSpacing, pkConstraints, pkSet}

proc addPropRows(ins: ObjectInspector, info: PropInfo, level: int) =
  let ex = composite(info) and info.name in ins.fOpen
  ins.fRows.add Row(kind: rkProp, info: info, key: info.name, level: level,
                    expandable: composite(info), expanded: ex)
  if ex:
    for s in subProps(info): ins.addPropRows(s, level + 1)

proc findRowByKey(ins: ObjectInspector, key: string): int =
  for i, r in ins.fRows:
    if r.key == key: return i
  -1

func viewTop(ins: ObjectInspector): float32 = ins.viewport.y

proc updateContent(ins: ObjectInspector) =
  ins.setContentSize(0, float64(ins.fRows.len) * float64(RowH))

proc cancelEdit*(ins: ObjectInspector, refocus = true)

proc rebuild*(ins: ObjectInspector) =
  ## Recomputes the rows (after targets, tab or grouping changed).
  let selKey = if ins.fSel in 0 ..< ins.fRows.len: ins.fRows[ins.fSel].key else: ""
  ins.cancelEdit()
  ins.fRows.setLen 0
  var props: seq[PropInfo]
  for p in ins.commonProps:
    if (ins.fTab == itEvents) == (p.kind == pkEvent): props.add p
  if ins.fFlat:
    props.sort(proc(a, b: PropInfo): int = cmp(a.name.toLowerAscii, b.name.toLowerAscii))
    for p in props: ins.addPropRows(p, 0)
  else:
    for cat in PropCategory:
      var inCat: seq[PropInfo]
      for p in props:
        if p.category == cat: inCat.add p
      if inCat.len == 0: continue
      inCat.sort(proc(a, b: PropInfo): int = cmp(a.name.toLowerAscii, b.name.toLowerAscii))
      ins.fRows.add Row(kind: rkCategory, cat: cat, key: catKey(cat),
                        expandable: true, expanded: cat notin ins.fClosedCats)
      if cat in ins.fClosedCats: continue
      for p in inCat: ins.addPropRows(p, 0)
  ins.fSel = ins.findRowByKey(selKey)
  if ins.fSel < 0 and ins.fRows.len > 0:
    ins.fSel = 0
    for i, r in ins.fRows:
      if r.kind == rkProp:
        ins.fSel = i
        break
  ins.updateContent()
  ins.invalidate()

proc scrollRowIntoView(ins: ObjectInspector, i: int) =
  if i < 0 or i >= ins.fRows.len: return
  ins.scrollIntoView(0, float64(i) * float64(RowH), 1, float64(RowH))

# ---------------------------------------------------------------- public API

proc inspect*(ins: ObjectInspector, objs: openArray[Obj]) =
  ## Shows the properties of `objs` (several: the properties they have in
  ## common). An empty list clears the inspector.
  ins.fTargets = @objs
  ins.fHot = -1
  ins.fError = ""
  ins.rebuild()
  ins.scrollRowIntoView(ins.fSel)
  if ins.onSelectionChanged != nil: ins.onSelectionChanged(ins)

proc inspect*(ins: ObjectInspector, o: Obj) =
  if o == nil: ins.inspect(newSeq[Obj]())
  else: ins.inspect([o])

proc inspect*(ins: ObjectInspector, o: Component) = ins.inspect(Obj(o))

proc refresh*(ins: ObjectInspector) =
  ## Re-reads the values (after the target changed behind the inspector's back).
  ins.rebuild()

proc `tab=`*(ins: ObjectInspector, v: InspectorTab) =
  if v == ins.fTab: return
  ins.fTab = v
  ins.rebuild()
  ins.scrollTo(0, 0)

proc `sortedFlat=`*(ins: ObjectInspector, v: bool) =
  if v == ins.fFlat: return
  ins.fFlat = v
  ins.rebuild()

proc `splitX=`*(ins: ObjectInspector, v: float32) =
  ins.fSplit = clamp(v, 60, max(ins.width - 80, 60))
  ins.invalidate()

proc rowName*(ins: ObjectInspector, i: int): string =
  ## The property name of row `i` ("cat:Layout" for a category row).
  if i in 0 ..< ins.fRows.len: ins.fRows[i].key else: ""

proc indexOfProp*(ins: ObjectInspector, name: string): int =
  ins.findRowByKey(name)

proc rowRect*(ins: ObjectInspector, i: int): RectF =
  ## Row `i` in client coordinates (may lie outside the viewport).
  let vp = ins.viewport
  rectF(vp.x, vp.y + float32(i) * RowH - float32(ins.scrollPosY), vp.w, RowH)

proc nameRect*(ins: ObjectInspector, i: int): RectF =
  let r = ins.rowRect(i)
  rectF(r.x, r.y, ins.fSplit - r.x, r.h)

proc valueRect*(ins: ObjectInspector, i: int): RectF =
  ## The value cell of row `i` in client coordinates.
  let r = ins.rowRect(i)
  rectF(ins.fSplit, r.y, r.right - ins.fSplit, r.h)

proc tabRect*(ins: ObjectInspector, t: InspectorTab): RectF =
  rectF(4 + float32(ord(t)) * TabW, TitleH, TabW, TabsH)

proc toggleRect*(ins: ObjectInspector): RectF =
  rectF(ins.width - ToggleW - 6, TitleH + 4, ToggleW, TabsH - 8)

proc isExpanded*(ins: ObjectInspector, name: string): bool =
  if name.startsWith("cat:"):
    for c in PropCategory:
      if catKey(c) == name: return c notin ins.fClosedCats
  name in ins.fOpen

proc setExpanded*(ins: ObjectInspector, name: string, on: bool) =
  ## Expands or collapses a composite property or a category ("cat:Layout").
  if name.startsWith("cat:"):
    for c in PropCategory:
      if catKey(c) == name:
        if on: ins.fClosedCats.excl c else: ins.fClosedCats.incl c
  elif on: ins.fOpen.incl name
  else: ins.fOpen.excl name
  ins.rebuild()

proc selectRow*(ins: ObjectInspector, i: int) =
  if i < 0 or i >= ins.fRows.len or i == ins.fSel: return
  ins.cancelEdit()
  ins.fSel = i
  ins.scrollRowIntoView(i)
  ins.invalidate()
  if ins.onSelectionChanged != nil: ins.onSelectionChanged(ins)

proc selectProp*(ins: ObjectInspector, name: string): bool {.discardable.} =
  ## Selects the row of property `name`, expanding its parents; false when it
  ## is not shown on the current tab.
  let parts = name.split('.')
  var path = ""
  var expanded = false
  for i in 0 ..< parts.len - 1:
    path = if path.len == 0: parts[i] else: path & "." & parts[i]
    if path notin ins.fOpen:
      ins.fOpen.incl path
      expanded = true
  if expanded: ins.rebuild()
  let i = ins.findRowByKey(name)
  if i < 0: return false
  ins.selectRow i
  true

proc selectedProp*(ins: ObjectInspector): string =
  if ins.fSel in 0 ..< ins.fRows.len and ins.fRows[ins.fSel].kind == rkProp:
    ins.fRows[ins.fSel].key
  else: ""

proc valueTextOf*(ins: ObjectInspector, name: string): string =
  ## The text shown in the value cell of property `name` ("" when mixed or absent).
  let i = ins.findRowByKey(name)
  if i < 0 or ins.fRows[i].kind != rkProp: return ""
  let (v, mixed) = ins.valueOf(ins.fRows[i].info)
  if mixed: "" else: valueText(ins.fRows[i].info, v)

proc overridden*(ins: ObjectInspector, name: string): bool =
  ## Whether `isOverridden` flags property `name` (cached like the value).
  let i = ins.findRowByKey(name)
  i >= 0 and ins.fRows[i].kind == rkProp and ins.rowValue(i).overridden

proc isBold*(ins: ObjectInspector, name: string): bool =
  ## Whether the value of `name` differs from a fresh instance (drawn bold).
  let i = ins.findRowByKey(name)
  i >= 0 and ins.fRows[i].kind == rkProp and ins.anyNonDefault(ins.fRows[i].info)

# ------------------------------------------------------------------ applying

proc vetoed(ins: ObjectInspector, t: Obj, name: string, v: PropValue): bool =
  ## Asks `onPropertyChanging`; true (and `lastError` set) when it refuses.
  if name == "name" and t of Component and Component(t).inherited:
    ins.fError = "`" & Component(t).name & "` comes from the ancestor form and cannot be renamed"
    ins.invalidate()
    return true
  if ins.onPropertyChanging == nil: return false
  var accept = true
  var msg = ""
  ins.onPropertyChanging(ins, t, name, v, accept, msg)
  if accept: return false
  ins.fError = if msg.len > 0: msg else: "`" & name & "` cannot be changed"
  ins.invalidate()
  true

proc assign(ins: ObjectInspector, t: Obj, q: PropInfo, name: string, v: PropValue) =
  ## Sets one target (through the designer when there is one) and reports it.
  let wantOld = ins.onPropertyChangedEx != nil
  let old = if wantOld: q.get(t) else: PropValue()
  if ins.designer != nil: ins.designer.setProp(t, name, v)
  else: q.set(t, v)
  ins.dropValueCache()
  if wantOld: ins.onPropertyChangedEx(ins, t, name, old, q.get(t))
  if ins.onPropertyChanged != nil: ins.onPropertyChanged(ins, t, name)

proc applyValue(ins: ObjectInspector, row: Row, v: PropValue): bool =
  ## Sets `v` on every target; false (and `lastError`) when one refuses. Each
  ## target that took the value is reported through `onPropertyChanged` at once,
  ## so a failure on a later one does not hide the change of the earlier ones.
  let targets = ins.fTargets
  let name = row.info.name
  # a name the form file cannot hold (`end`, `a b`, empty...) is refused here, whoever asks
  if (name == "name" and v.kind == pkString and not validNfmName(v.s)) or
     (v.kind == pkEvent and v.handler.len > 0 and not validNfmName(v.handler)):
    let bad = if v.kind == pkEvent: v.handler else: v.s
    ins.fError = "`" & bad & "` is not a valid " &
                 (if v.kind == pkEvent: "handler" else: "component") & " name"
    ins.invalidate()
    return false
  # a child called like a member of Component/Control/Form would not compile in the form's source
  if name == "name" and v.kind == pkString and isReservedFieldName(v.s):
    for t in targets:
      if not (t of Form):
        ins.fError = "`" & v.s & "` is reserved (a field or property of Component, Control or Form)"
        ins.invalidate()
        return false
  for t in targets:
    let q = infoFor(t, name)
    if q != nil and ins.vetoed(t, name, v): return false
  ins.fError = ""
  result = true
  if ins.designer != nil: ins.designer.beginGroup()   # all targets: one undo step
  try:
    for t in targets:
      let q = infoFor(t, name)
      if q == nil: continue
      try: ins.assign(t, q, name, v)
      except CatchableError as e:
        ins.fError = e.msg
        result = false
        break
  finally:
    if ins.designer != nil: ins.designer.endGroup()
  ins.dropValueCache()
  ins.invalidate()

proc reportError*(ins: ObjectInspector, msg: string) =
  ## Shows `msg` in the error line (an editor dialog the application ran failed).
  ins.fError = msg
  ins.invalidate()

proc setValue*(ins: ObjectInspector, name: string, v: PropValue): bool {.discardable.} =
  ## Sets a property of all targets as if edited by the user (also one the
  ## inspector does not list, such as a hidden or an events-tab property).
  let i = ins.findRowByKey(name)
  if i >= 0 and ins.fRows[i].kind == rkProp:
    return ins.applyValue(ins.fRows[i], v)
  # not listed (a hidden property, another tab): still a property of the targets
  let info = if ins.fTargets.len > 0: infoFor(ins.fTargets[0], name) else: nil
  if info == nil: return false
  ins.applyValue(Row(kind: rkProp, info: info, key: name), v)

proc parseText(info: PropInfo, text: string, v: var PropValue): string =
  ## Parses edited text; returns an error message ("" when fine).
  let t = text.strip()
  case info.kind
  of pkString:
    v = pvString(text)
  of pkInt:
    try: v = pvInt(parseInt(t))
    except ValueError: return "`" & t & "` is not a whole number"
  of pkFloat:
    var f: float
    try: f = parseFloat(t)
    except ValueError: return "`" & t & "` is not a number"
    if classify(f) in {fcNan, fcInf, fcNegInf}: return "`" & t & "` is not a finite number"
    v = pvFloat(f)
  of pkColor:
    for (n, c) in Palette:
      if n == t.toLowerAscii:
        v = pvColor(c)
        return ""
    try: v = pvColor(parseColor(t))
    except ValueError: return "`" & t & "` is not a colour (#rrggbb or a palette name)"
  of pkEvent:
    if t.len > 0 and not validNfmName(t):
      return "`" & t & "` is not a valid handler name"
    v = pvEvent(t)
  else: return "this property is not edited as text"

# ----------------------------------------------------------------- editors

proc editorOf(ins: ObjectInspector): Control =
  case ins.fEditKind
  of ekText: Control(ins.fEditText)
  of ekCombo: Control(ins.fEditCombo)
  else: nil

proc editing*(ins: ObjectInspector): bool = ins.fEditKind != ekNone
func editRow*(ins: ObjectInspector): int = (if ins.fEditKind == ekNone: -1 else: ins.fEditRow)
func editText*(ins: ObjectInspector): Edit = ins.fEditText
  ## The in-place text editor (visible while a string or number is edited).
func editCombo*(ins: ObjectInspector): ComboBox = ins.fEditCombo
  ## The in-place combo (enums, bools, colours, objects, events).

proc layoutEditor(ins: ObjectInspector) =
  if ins.fEditKind == ekNone: return
  let r = ins.valueRect(ins.fEditRow)
  let e = ins.editorOf
  e.setBounds(r.x + 1, r.y + 1, max(r.w - 2, 20), r.h - 2)

proc endEditor(ins: ObjectInspector, refocus: bool) =
  ## Hides the editor. `refocus`: the inspector takes the focus back (the
  ## editor ended by a key or from code); false when the editor ended because
  ## the focus is already moving somewhere else.
  let e = ins.editorOf
  ins.fEditKind = ekNone
  ins.fEditRow = -1
  if e != nil:
    if ins.fEditCombo != nil and ins.fEditCombo.droppedDown: ins.fEditCombo.closeUp()
    e.visible = false
    if refocus: ins.setFocus()
  ins.invalidate()

proc cancelEdit*(ins: ObjectInspector, refocus = true) =
  ## Closes the editor without applying.
  if ins.fEditKind != ekNone:
    ins.endEditor(refocus)
    ins.fError = ""

proc editorState(ins: ObjectInspector): string =
  ## What the open editor shows (text and picked entry); compared with the state
  ## it opened with to tell whether the user changed anything.
  case ins.fEditKind
  of ekText: ins.fEditText.text
  of ekCombo: ins.fEditCombo.text & '\0' & $ins.fEditCombo.itemIndex
  else: ""

proc comboValue(ins: ObjectInspector, row: Row, v: var PropValue): string =
  ## The value picked in the combo for `row`; error text or "".
  let c = ins.fEditCombo
  case row.info.kind
  of pkBool:
    if c.itemIndex < 0: return "pick true or false"
    v = pvBool(c.itemIndex == 1)
  of pkEnum:
    if c.itemIndex < 0: return "pick one of the listed values"
    v = pvEnum(c.itemIndex)
  of pkObject:
    let i = c.itemIndex
    if i < 0 or i > ins.fChoices.len: return "pick an object from the list"
    v = if i == 0: pvObject(nil) else: pvObject(ins.fChoices[i - 1], objectName(ins.fChoices[i - 1]))
  of pkColor, pkEvent:
    return parseText(row.info, c.text, v)
  of pkString:
    if isFontGroupHeader(c.text): return "pick a font family, not a group"
    v = pvString(c.text.strip)
  else: return "unsupported editor"

proc commitEdit*(ins: ObjectInspector, refocus = true): bool {.discardable.} =
  ## Applies the editor's content and closes it; an editor the user did not
  ## change just closes (so leaving a cell never rewrites the values, which
  ## would blank a property the selected objects disagree on). When the content
  ## is invalid (`lastError` is set) nothing is applied and the editor stays
  ## open; false.
  if ins.fEditKind == ekNone: return true
  if ins.editorState == ins.fEditStart:
    ins.cancelEdit(refocus)
    return true
  let row = ins.fRows[ins.fEditRow]
  var v: PropValue
  var err = ""
  case ins.fEditKind
  of ekText: err = parseText(row.info, ins.fEditText.text, v)
  of ekCombo: err = ins.comboValue(row, v)
  else: discard
  if err.len > 0:
    ins.fError = err
    ins.invalidate()
    return false
  if not ins.applyValue(row, v): return false
  ins.endEditor(refocus)
  true

proc visitObjects(o: Obj, want: ClassInfo, seen: var HashSet[Obj], found: var seq[Obj]) =
  if o == nil or seen.containsOrIncl(o): return
  let ci = classOf(o)
  if ci != nil and objectName(o).len > 0 and (want == nil or ci.isA(want)):
    found.add o
  for k in kidsOf(o): visitObjects(k, want, seen, found)
  if o of Component:
    for c in Component(o).components: visitObjects(c, want, seen, found)

proc choicesFor(ins: ObjectInspector, info: PropInfo): seq[Obj] =
  ## Named objects of the form of the first target that can be assigned to `info`.
  if ins.fTargets.len == 0: return
  if ins.onGetChoices != nil:
    let want = classByName(info.typeName)
    var listed = initHashSet[Obj]()
    for o in ins.onGetChoices(ins, ins.fTargets[0], info.name):
      let ci = classOf(o)
      if o != nil and ci != nil and objectName(o).len > 0 and (want == nil or ci.isA(want)) and
         not listed.containsOrIncl(o):
        result.add o
    return
  var top: Obj = ins.fTargets[0]
  while top != nil and top of Control and Control(top).parent != nil:
    top = Control(top).parent
  while top != nil and top of Component and Component(top).owner != nil and
        not (top of Form):
    top = Component(top).owner
  var seen = initHashSet[Obj]()
  visitObjects(top, classByName(info.typeName), seen, result)

proc isFamilyProp(info: PropInfo): bool =
  info.kind == pkString and info.name.endsWith(".family")

proc fontFamilyItems*(ins: ObjectInspector): seq[string] =
  ## The entries of the `font.family` drop-down: the group headers
  ## (`FontGroupBundled`, `FontGroupProject`, `FontGroupSystem`) each followed
  ## by its families. A group without families has no header.
  result = @[FontGroupBundled, DefaultFamily, MonoFamily]
  var proj: seq[string]
  if ins.onGetFontFamilies != nil and ins.fTargets.len > 0:
    proj = ins.onGetFontFamilies(ins, ins.fTargets[0])
  else:
    proj = registeredFontFamilies()
  var seen = @[DefaultFamily, MonoFamily]
  var group: seq[string]
  for n in proj:
    if n.len > 0 and n.toLowerAscii notin seen:
      seen.add n.toLowerAscii
      group.add n
  if group.len > 0: result.add FontGroupProject; result.add group
  group.setLen 0
  for n in systemFontFamilies():
    if n.toLowerAscii notin seen: group.add n
  if group.len > 0: result.add FontGroupSystem; result.add group

proc paletteIndex(c: Color): int =
  for i, (_, p) in Palette:
    if p == c: return i
  -1

proc beginEdit*(ins: ObjectInspector, row: int, openList = true): bool {.discardable.} =
  ## Starts editing the value of row `row` in place. Composite rows expand
  ## instead, set elements toggle, lists and images call `onEditExtra`.
  if row < 0 or row >= ins.fRows.len or ins.fTargets.len == 0: return false
  let r = ins.fRows[row]
  if r.kind != rkProp: return false
  ins.endEditor(refocus = true)
  ins.selectRow row
  ins.fError = ""
  let (v, mixed) = ins.valueOf(r.info)
  if r.expandable:
    ins.setExpanded(r.key, not r.expanded)
    return false
  if isSetElement(r.info):
    return ins.applyValue(r, pvBool(not (v.kind == pkBool and v.b)))
  if r.info.kind in ExtraKinds:
    if ins.onEditExtra != nil: ins.onEditExtra(ins, ins.fTargets[0], r.info.name)
    return false
  ins.fEditRow = row
  ins.scrollRowIntoView(row)
  if isFamilyProp(r.info):
    let c = ins.fEditCombo
    ins.fColorEdit = false
    c.dropStyle = lbStandard
    c.style = csDropDown
    var items = ins.fontFamilyItems
    c.items = items
    c.text = if mixed: "" else: v.s
    ins.fEditKind = ekCombo
    ins.fEditStart = ins.editorState
    ins.layoutEditor()
    c.visible = true
    c.setFocus()
    c.edit.selectAll()
    if openList: c.dropDown()
    ins.invalidate()
    return true
  case r.info.kind
  of pkString, pkInt, pkFloat:
    ins.fEditKind = ekText
    ins.fEditText.text = if mixed: "" else: valueText(r.info, v)
    ins.fEditStart = ins.editorState
    ins.layoutEditor()
    ins.fEditText.visible = true
    ins.fEditText.setFocus()
    ins.fEditText.selectAll()
  of pkBool, pkEnum, pkColor, pkObject, pkEvent:
    let c = ins.fEditCombo
    ins.fColorEdit = r.info.kind == pkColor
    c.dropStyle = if ins.fColorEdit: lbOwnerDraw else: lbStandard
    case r.info.kind
    of pkBool:
      c.style = csDropDownList
      c.items = ["false", "true"]
      c.itemIndex = if mixed: -1 else: (if v.b: 1 else: 0)
    of pkEnum:
      c.style = csDropDownList
      c.items = r.info.enumNames
      c.itemIndex = if mixed: -1 else: v.i
    of pkColor:
      c.style = csDropDown
      var names: seq[string]
      for (n, _) in Palette: names.add n
      c.items = names
      c.text = if mixed: "" else: v.color.toHex
    of pkObject:
      c.style = csDropDownList
      ins.fChoices = ins.choicesFor(r.info)
      var names = @["(none)"]
      for o in ins.fChoices: names.add objName(o)
      c.items = names
      var idx = -1
      if not mixed:
        idx = 0
        for i, o in ins.fChoices:
          if o == v.obj: idx = i + 1
      c.itemIndex = idx
    else: # pkEvent
      c.style = csDropDown
      var names = ins.fHandlers
      if ins.onGetHandlers != nil:
        for n in ins.onGetHandlers(ins, ins.fTargets[0], r.info.name):
          if n notin names: names.add n
      c.items = names
      c.text = if mixed: "" else: v.handler
    ins.fEditKind = ekCombo
    ins.fEditStart = ins.editorState
    ins.layoutEditor()
    c.visible = true
    c.setFocus()
    if r.info.kind notin {pkColor, pkEvent}:
      if openList: c.dropDown()
    else:
      c.edit.selectAll()
      if openList and r.info.kind == pkColor: c.dropDown()
  else:
    ins.fEditRow = -1
    return false
  ins.invalidate()
  true

proc beginEdit*(ins: ObjectInspector, name: string, openList = true): bool {.discardable.} =
  ins.beginEdit(ins.findRowByKey(name), openList)

proc nextEditable(ins: ObjectInspector, from0, step: int): int =
  var i = from0 + step
  while i in 0 ..< ins.fRows.len:
    let r = ins.fRows[i]
    if r.kind == rkProp and not r.expandable and
       r.info.kind notin ExtraKinds and not isSetElement(r.info):
      return i
    i += step
  -1

proc editorKey(ins: ObjectInspector, key: var Key, shift: ShiftState) =
  if ins.fEditKind == ekNone: return
  if key == keyEnter:
    key = Key(0)
    ins.commitEdit()
  elif key == keyEscape:
    key = Key(0)
    ins.cancelEdit()
  elif key == keyTab:
    key = Key(0)
    let cur = ins.fEditRow
    if ins.commitEdit():
      let n = ins.nextEditable(cur, if ssShift in shift: -1 else: 1)
      if n >= 0: ins.beginEdit(n, openList = false)

proc defaultHandlerName(target: Obj, event: string): string =
  let n = objectName(target)
  let ev = if event.startsWith("on") and event.len > 2: event[2 .. ^1] else: event
  (if n.len > 0: n else: "object") & ev

# ------------------------------------------------------------------- painting

proc boldFont(f: FontSpec): FontSpec =
  result = f
  result.style.incl fsBold

proc drawColorSwatch(c: Canvas, r: RectF, col: Color, t: Theme) =
  # checker for transparency
  c.fillRect(r, t.surface)
  if col.a < 255:
    let h = r.w / 2
    c.fillRect(rectF(r.x, r.y, h, r.h / 2), t.border)
    c.fillRect(rectF(r.x + h, r.y + r.h / 2, h, r.h / 2), t.border)
  c.fillRect(r, col)
  c.frameRect(r, t.borderStrong, 1)

method paint*(ins: ObjectInspector, c: Canvas) =
  let t = ins.theme
  let enabled = ins.isEnabled
  let fnt = ins.font
  let bold = boldFont(fnt)
  let r = ins.clientRect
  c.fillRoundRect(r, t.radius, if enabled: t.surface else: t.surfaceAlt)
  let vp = ins.viewport
  # --- title
  var title = "(nothing selected)"
  if ins.fTargets.len == 1:
    let ci = classOf(ins.fTargets[0])
    title = (let n = objectName(ins.fTargets[0]); if n.len > 0: n else: "(unnamed)") &
            ": " & (if ci != nil: ci.name else: "?") &
            (if ins.fTargets[0] of Component and Component(ins.fTargets[0]).inherited:
               " (inherited)" else: "")
  elif ins.fTargets.len > 1:
    title = $ins.fTargets.len & " objects selected"
  c.fillRect(rectF(1, 1, r.w - 2, TitleH - 1), t.surfaceAlt)
  c.textRect(title, bold, rectF(8, 1, r.w - 16, TitleH - 1),
             if ins.fTargets.len > 0: t.text else: t.textMuted, taLeft, vaCenter)
  # --- tabs
  c.line(1, TopH, r.w - 1, TopH, t.border, 1)
  for tb in InspectorTab:
    let tr = ins.tabRect(tb)
    let active = tb == ins.fTab
    c.textRect(if tb == itProperties: "Properties" else: "Events", if active: bold else: fnt,
               tr, if active: t.text else: t.textMuted, taCenter, vaCenter)
    if active: c.fillRect(rectF(tr.x + 6, TopH - 2, tr.w - 12, 2), t.accent)
  let tg = ins.toggleRect
  c.fillRoundRect(tg, 4, if ins.fFlat: t.selection else: t.hover)
  c.textRect(if ins.fFlat: "A-Z" else: "Groups", fnt, tg,
             if ins.fFlat: t.selectionText else: t.text, taCenter, vaCenter)
  # --- rows
  c.pushClip(vp)
  let firstRow = max(int(floor(ins.scrollPosY / float64(RowH))), 0)
  let lastRow = min(int(ceil((ins.scrollPosY + float64(vp.h)) / float64(RowH))), ins.fRows.len)
  let focused = ins.focused or ins.fEditKind != ekNone
  for i in firstRow ..< lastRow:
    let row = ins.fRows[i]
    let rr = ins.rowRect(i)
    let sel = i == ins.fSel
    if row.kind == rkCategory:
      c.fillRect(rr, t.surfaceAlt)
      drawChevron(c, pointF(rr.x + 12, rr.y + rr.h / 2), row.expanded, t.textMuted)
      c.textRect(categoryName(row.cat), bold, rectF(rr.x + 24, rr.y, rr.w - 28, rr.h),
                 t.text, taLeft, vaCenter)
      if sel and focused:
        c.strokeRoundRect(rectF(rr.x + 1, rr.y, rr.w - 2, rr.h), 2, t.focusRing, 1)
    else:
      let nr = ins.nameRect(i)
      if sel:
        c.fillRect(rectF(nr.x, nr.y, nr.w, nr.h),
                   if focused and enabled: t.selection else: t.selectionInactive)
      elif i == ins.fHot:
        c.fillRect(rectF(nr.x, nr.y, nr.w, nr.h), t.hover)
      var nx = nr.x + 8 + float32(row.level) * 16
      if row.expandable:
        drawChevron(c, pointF(nx + 3, rr.y + rr.h / 2), row.expanded,
                    if sel and focused: t.selectionText else: t.textMuted)
      nx += IndentW
      let leafName = row.info.name[row.info.name.rfind('.') + 1 .. ^1]
      let nameFont = if ins.isOverridden != nil and ins.rowValue(i).overridden: bold else: fnt
      c.textRect(leafName, nameFont, rectF(nx, rr.y, max(nr.right - nx - 4, 0), rr.h),
                 if sel and focused and enabled: t.selectionText
                 elif not enabled: t.textDisabled else: t.text, taLeft, vaCenter)
      # value cell
      let vr = ins.valueRect(i)
      if not (ins.fEditKind != ekNone and ins.fEditRow == i):
        let rv = ins.rowValue(i)
        let v = rv.value
        let mixed = rv.mixed
        let vf = if rv.modified: bold else: fnt
        var tx = vr.x + 6
        if not mixed:
          if row.info.kind == pkColor:
            c.drawColorSwatch(rectF(tx, vr.y + 5, 14, vr.h - 10), v.color, t)
            tx += 20
          elif isSetElement(row.info):
            drawCheckGlyph(c, rectF(tx, vr.y + (vr.h - CheckSize) / 2, CheckSize, CheckSize),
                           if v.b: cbChecked else: cbUnchecked, t, enabled)
            tx += CheckSize + 6
          let extra = row.info.kind in ExtraKinds
          let txt = if isSetElement(row.info): (if v.b: "true" else: "false")
                    else: valueText(row.info, v)
          c.textRect(txt, vf, rectF(tx, vr.y, max(vr.right - tx - (if extra: 28 else: 4), 0), vr.h),
                     if row.info.kind in ExtraKinds and txt.startsWith("("): t.textMuted
                     else: t.text, taLeft, vaCenter)
        if row.info.kind in ExtraKinds:
          let br = rectF(vr.right - 24, vr.y + 3, 20, vr.h - 6)
          c.fillRoundRect(br, 3, t.hover)
          c.textRect("...", fnt, br, t.text, taCenter, vaCenter)
    c.line(rr.x, rr.bottom - 0.5, rr.right, rr.bottom - 0.5, t.border, 1)
    if row.kind == rkProp:
      c.line(ins.fSplit - 0.5, rr.y, ins.fSplit - 0.5, rr.bottom, t.border, 1)
  # the divider below the last row
  let endY = ins.rowRect(ins.fRows.len).y
  if endY < vp.bottom:
    c.line(ins.fSplit - 0.5, endY, ins.fSplit - 0.5, vp.bottom, t.border, 1)
  c.popClip()
  # --- error line
  if ins.fError.len > 0:
    if ins.fEditKind != ekNone:
      let er = ins.valueRect(ins.fEditRow)
      c.strokeRoundRect(rectF(er.x, er.y, er.w, er.h), 2, t.danger, 1.5)
    c.fillRect(rectF(1, r.h - 23, r.w - 2, 22), t.surface)
    c.textRect(ins.fError, fnt, rectF(8, r.h - 22, r.w - 16, 20), t.danger, taLeft, vaCenter)
  c.strokeRoundRect(r, t.radius, if ins.focused: t.focusRing else: t.borderStrong,
                    if ins.focused: t.focusRingWidth else: t.borderWidth)
  procCall paint(Control(ins), c)

# ----------------------------------------------------------------------- input

method canFocus*(ins: ObjectInspector): bool = ins.isVisible and ins.isEnabled

method scrollLineSize*(ins: ObjectInspector): SizeF = sizeF(20, RowH)

method contentScrolled*(ins: ObjectInspector) =
  procCall contentScrolled(ScrollingControl(ins))
  ins.layoutEditor()

method doResize*(ins: ObjectInspector) =
  procCall doResize(ScrollingControl(ins))
  ins.fSplit = clamp(ins.fSplit, 60, max(ins.width - 80, 60))
  ins.layoutEditor()

proc rowAt(ins: ObjectInspector, y: float32): int =
  let vp = ins.viewport
  if y < vp.y or y >= vp.bottom: return -1
  let i = int(floor((float64(y - vp.y) + ins.scrollPosY) / float64(RowH)))
  if i in 0 ..< ins.fRows.len: i else: -1

proc handleDouble(ins: ObjectInspector, i: int)

method doMouseDown*(ins: ObjectInspector, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  if button == mbLeft:
    if ins.fEditKind != ekNone:
      if not ins.commitEdit(): ins.cancelEdit()
    ins.setFocus()
    if y < TopH:
      for tb in InspectorTab:
        if ins.tabRect(tb).contains(pointF(x, y)): ins.tab = tb
      if ins.toggleRect.contains(pointF(x, y)): ins.sortedFlat = not ins.fFlat
    elif abs(x - ins.fSplit) <= 3 and y >= ins.viewport.y:
      ins.fDragSplit = true
    else:
      let i = ins.rowAt(y)
      if i >= 0:
        let r = ins.fRows[i]
        ins.selectRow i
        if r.kind == rkCategory:
          ins.setExpanded(r.key, not r.expanded)
        elif r.expandable and x < ins.nameRect(i).x + 8 + float32(r.level) * 16 + IndentW + 2:
          ins.setExpanded(r.key, not r.expanded)
        elif x >= ins.fSplit:
          let vr = ins.valueRect(i)
          if r.info.kind in ExtraKinds:
            if x >= vr.right - 28: ins.beginEdit(i)
          elif ssDouble in shift and r.info.kind in {pkBool, pkEnum, pkEvent}:
            ins.handleDouble(i)
          else:
            ins.beginEdit(i)
  elif button == mbRight:
    ins.setFocus()
    if ins.fEditKind != ekNone:
      if not ins.commitEdit(): ins.cancelEdit()
    if y >= TopH:
      let i = ins.rowAt(y)
      if i >= 0: ins.selectRow i
  procCall doMouseDown(Control(ins), button, shift, x, y)

proc cycleValue(ins: ObjectInspector, row: Row) =
  let (v, _) = ins.valueOf(row.info)
  case row.info.kind
  of pkBool: discard ins.applyValue(row, pvBool(not v.b))
  of pkEnum:
    discard ins.applyValue(row, pvEnum((v.i + 1) mod max(row.info.enumNames.len, 1)))
  else: discard

proc handleDouble(ins: ObjectInspector, i: int) =
  ## Double click on a row: cycle enums/bools, create a handler for events.
  let row = ins.fRows[i]
  if row.kind != rkProp: return
  case row.info.kind
  of pkBool, pkEnum:
    ins.endEditor(refocus = true)
    ins.cycleValue(row)
  of pkEvent:
    let (v, mixed) = ins.valueOf(row.info)
    if mixed or v.handler.len > 0: return
    ins.endEditor(refocus = true)
    for t in ins.fTargets:
      let q = infoFor(t, row.info.name)
      if q == nil: continue
      var name = ""
      if ins.onCreateHandler != nil: name = ins.onCreateHandler(ins, t, q.name)
      else: name = defaultHandlerName(t, q.name)
      if name.len == 0: continue
      if ins.vetoed(t, q.name, pvEvent(name)): continue
      try: ins.assign(t, q, q.name, pvEvent(name))
      except CatchableError as e: ins.fError = e.msg
    ins.dropValueCache()
    ins.invalidate()
  else: discard

method doMouseUp*(ins: ObjectInspector, button: MouseButton, shift: ShiftState,
                  x, y: float32) =
  ins.fDragSplit = false
  procCall doMouseUp(Control(ins), button, shift, x, y)
  if button == mbRight and ins.onContextMenu != nil:
    let i = if y >= TopH: ins.rowAt(y) else: -1
    ins.onContextMenu(ins, (if i >= 0 and ins.fRows[i].kind == rkProp: ins.fRows[i].key else: ""),
                      pointF(x, y))

method doMouseMove*(ins: ObjectInspector, shift: ShiftState, x, y: float32) =
  if ins.fDragSplit and ssLeft in shift:
    ins.splitX = x
    ins.layoutEditor()
  else:
    let h = ins.rowAt(y)
    if h != ins.fHot:
      ins.fHot = h
      ins.invalidate()
  procCall doMouseMove(Control(ins), shift, x, y)

method doMouseLeave*(ins: ObjectInspector) =
  if ins.fHot != -1:
    ins.fHot = -1
    ins.invalidate()
  procCall doMouseLeave(Control(ins))

method doKeyDown*(ins: ObjectInspector, key: var Key, shift: ShiftState) =
  procCall doKeyDown(Control(ins), key, shift)
  if key == Key(0) or ins.fEditKind != ekNone: return
  if shift * {ssCtrl, ssAlt, ssSuper} != {}: return
  let n = ins.fRows.len
  var handled = true
  if key == keyDown: ins.selectRow min(ins.fSel + 1, n - 1)
  elif key == keyUp: ins.selectRow max(ins.fSel - 1, 0)
  elif key == keyHome: ins.selectRow 0
  elif key == keyEnd: ins.selectRow n - 1
  elif key == keyPageDown:
    ins.selectRow min(ins.fSel + max(int(ins.viewport.h / RowH) - 1, 1), n - 1)
  elif key == keyPageUp:
    ins.selectRow max(ins.fSel - max(int(ins.viewport.h / RowH) - 1, 1), 0)
  elif key == keyDelete and ins.fSel in 0 ..< n and
       ins.fRows[ins.fSel].kind == rkProp and
       ins.fRows[ins.fSel].info.kind in {pkImage, pkImages}:
    # Delete clears a picture / an image list
    let r = ins.fRows[ins.fSel]
    discard ins.applyValue(r, if r.info.kind == pkImage: PropValue(kind: pkImage, image: nil)
                              else: PropValue(kind: pkImages, imgs: @[]))
  elif key == keyEnter or key == keySpace:
    if ins.fSel in 0 ..< n:
      let r = ins.fRows[ins.fSel]
      if r.kind == rkCategory: ins.setExpanded(r.key, not r.expanded)
      else: ins.beginEdit(ins.fSel)
  elif key == keyRight or key == keyLeft:
    if ins.fSel in 0 ..< n:
      let r = ins.fRows[ins.fSel]
      if r.expandable and r.expanded == (key == keyLeft):
        ins.setExpanded(r.key, key == keyRight)
      else: handled = false
  elif key == keyTab and ins.fSel in 0 ..< n:
    let nx = ins.nextEditable(ins.fSel, if ssShift in shift: -1 else: 1)
    if nx >= 0: ins.beginEdit(nx, openList = false)
    else: handled = false
  else: handled = false
  if handled: key = Key(0)

proc dispatchDouble*(ins: ObjectInspector, i: int) =
  ## What a double click on row `i` does (also callable from code).
  if i in 0 ..< ins.fRows.len: ins.handleDouble(i)

# ------------------------------------------------------------------- creation

proc initObjectInspector*(ins: ObjectInspector, owner: Component = nil) =
  ins.initScrollingControl(owner)
  ins.setBounds(0, 0, 300, 420)
  ins.tabStop = true
  ins.padding = spacing(0, TopH, 0, 0)
  ins.hScrollMode = sbmNever
  ins.fSplit = 130
  ins.fSel = -1
  ins.fHot = -1
  ins.fEditRow = -1
  ins.fOpen = initHashSet[string]()
  # editors (children, hidden until used)
  let e = newEdit(ins)
  e.visible = false
  e.tabStop = false
  e.onKeyDown = proc(s: Control, key: var Key, shift: ShiftState) =
    ins.editorKey(key, shift)
  e.onExit = proc(s: Control) =
    if ins.fEditKind == ekText:
      if not ins.commitEdit(refocus = false): ins.cancelEdit(refocus = false)
  ins.fEditText = e
  let cb = newComboBox(ins, csDropDownList)
  cb.visible = false
  cb.tabStop = false
  cb.edit.onKeyDown = proc(s: Control, key: var Key, shift: ShiftState) =
    ins.editorKey(key, shift)
  cb.onKeyDown = proc(s: Control, key: var Key, shift: ShiftState) =
    ins.editorKey(key, shift)
  cb.onSelect = proc(s: Control) =
    if ins.fEditKind == ekCombo: ins.commitEdit()
  cb.onExit = proc(s: Control) =
    if ins.fEditKind == ekCombo and not cb.droppedDown:
      if not ins.commitEdit(refocus = false): ins.cancelEdit(refocus = false)
  cb.onDrawItem = proc(s: Control, cv: Canvas, index: int, rect: RectF,
                                state: ItemStates) =
    if not ins.fColorEdit: return
    let t = ins.theme
    if isSelected in state: cv.fillRect(rect, t.selection)
    elif isHot in state: cv.fillRect(rect, t.hover)
    if index in 0 ..< Palette.len:
      cv.drawColorSwatch(rectF(rect.x + 6, rect.y + 4, 14, rect.h - 8), Palette[index][1], t)
      cv.textRect(Palette[index][0], ins.font, rectF(rect.x + 26, rect.y, rect.w - 30, rect.h),
                  if isSelected in state: t.selectionText else: t.text, taLeft, vaCenter)
  ins.fEditCombo = cb
  # a double click on an editor (it covers the value cell) acts on the row
  let dbl = proc(s: Control) =
    if ins.fEditKind == ekCombo:
      let row = ins.fEditRow
      ins.handleDouble(row)
  cb.onDblClick = dbl
  cb.edit.onDblClick = dbl

proc newObjectInspector*(parent: Container = nil, left = 0'f32, top = 0'f32,
                         width = -1'f32, height = -1'f32): ObjectInspector {.discardable.} =
  new result
  result.initObjectInspector(parent)
  result.placeControl(parent, left, top, width, height)
