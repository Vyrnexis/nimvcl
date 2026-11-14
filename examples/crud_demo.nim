# Phase 6 exit criterion: a CRUD application over 100,000 rows in a virtual
# ListView that scrolls smoothly. Written with the `form` macro and
# `import nimvcl` only; the data model is in crud_model.nim.
#
# Customers: search (name, email, city; debounced 150 ms), country and
# active-only filters, click a column header to sort (again to reverse), New /
# Edit / Delete / Refresh from the toolbar, menu or keys.
#
# Keys: Ctrl+N new, Enter / Ctrl+E / double click edit, Delete delete the
#       selection (Shift/Ctrl+click, Shift+arrows, Ctrl+A multi-select),
#       F5 refresh, Ctrl+F focus the search box, Esc in the search box clears
#       it, Ctrl+Q exit. In the edit dialog: Enter = OK, Esc = Cancel.
#
# Env (headless screenshot mode):
#   NIMVCL_SCREENSHOT=path.png   lay out, render one frame and exit (BMP when
#                                the name does not end in .png)
#   NIMVCL_SCALE=1.5             force the display scale
#   NIMVCL_DARK=1                dark theme
#   NIMVCL_SEARCH=text           type this into the search box (applied at once)
#   NIMVCL_SORT=1 / NIMVCL_SORT=1d   sort by column 1 ascending / descending
#   NIMVCL_ROW=n                 scroll so that row n is at the top, select 3 rows
#   NIMVCL_EDIT=1                the screenshot is of the edit dialog instead
#
# Build: nim c --outdir:build examples/crud_demo.nim

import std/[os, strutils, sets, times]
import nimvcl
import ./crud_model
export crud_model

const
  TotalRows* = 100_000
  Seed* = 12345'u64
  DebounceMs* = 150

# ------------------------------------------------------------ edit dialog

form CustomerDlg:
  caption = "Customer"
  width = 460; height = 372
  borderStyle = bsSingle
  position = poScreenCenter
  var created: int32
  var id: int32
  Label nameLbl:
    caption = "&Name"; left = 20; top = 16
    focusControl = self.nameEdit
  Edit nameEdit:
    left = 20; top = 38; width = 420
    placeholder = "Full name (required)"
  Label emailLbl:
    caption = "E&mail"; left = 20; top = 76
    focusControl = self.emailEdit
  Edit emailEdit:
    left = 20; top = 98; width = 420
    placeholder = "name@example.com"
  Label cityLbl:
    caption = "C&ity"; left = 20; top = 136
    focusControl = self.cityEdit
  Edit cityEdit:
    left = 20; top = 158; width = 200
  Label countryLbl:
    caption = "C&ountry"; left = 240; top = 136
    focusControl = self.countryBox
  ComboBox countryBox:
    style = csDropDownList
    left = 240; top = 158; width = 200
  Label balanceLbl:
    caption = "&Balance"; left = 20; top = 196
    focusControl = self.balanceEdit
  Edit balanceEdit:
    left = 20; top = 218; width = 200
    placeholder = "0.00"
  Label createdLbl:
    caption = "Created"; left = 240; top = 196
  Label createdValue:
    left = 240; top = 224
  CheckBox activeBox:
    caption = "&Active customer"; left = 20; top = 260
  Label errorLbl:
    left = 20; top = 290
    textColor = rgb(224, 49, 49)
  Button okBtn:
    caption = "OK"; isDefault = true
    left = 252; top = 322; width = 88
  Button cancelBtn:
    caption = "Cancel"; isCancel = true; modalResult = mrCancel
    left = 352; top = 322; width = 88

  proc load*(self: CustomerDlg, c: Customer) =
    self.id = c.id
    self.created = c.created
    self.nameEdit.text = c.name
    self.emailEdit.text = c.email
    self.cityEdit.text = c.city
    self.countryBox.itemIndex = max(self.countryBox.items.indexOf(c.country), 0)
    self.balanceEdit.text = formatMoney(c.balance).replace(",", "")
    self.createdValue.caption = formatDate(c.created)
    self.activeBox.checked = c.active
    self.errorLbl.caption = ""

  proc customer*(self: CustomerDlg): Customer =
    ## The edited values (call after a successful `validate`).
    var cents: int64
    discard parseMoney(self.balanceEdit.text, cents)
    Customer(id: self.id, name: self.nameEdit.text.strip(),
             email: self.emailEdit.text.strip(), city: self.cityEdit.text.strip(),
             country: self.countryBox.text, balance: cents, created: self.created,
             active: self.activeBox.checked)

  proc fail(self: CustomerDlg, field: Edit, msg: string): bool =
    self.errorLbl.caption = msg
    self.activeControl = field
    field.selectAll()
    false

  proc validate*(self: CustomerDlg): bool =
    ## Name required, e-mail must contain '@', balance must be a number. On the
    ## first problem: message in `errorLbl`, focus on the bad field.
    var cents: int64
    if self.nameEdit.text.strip().len == 0:
      self.fail(self.nameEdit, "The name is required.")
    elif '@' notin self.emailEdit.text:
      self.fail(self.emailEdit, "The e-mail address must contain an @.")
    elif not parseMoney(self.balanceEdit.text, cents):
      self.fail(self.balanceEdit, "The balance must be a number such as 1234.50.")
    else:
      self.errorLbl.caption = ""
      true

  init:
    for c in Countries: self.countryBox.items.add c
    self.countryBox.itemIndex = 0
    self.okBtn.onClick = proc(s: Control) =
      if self.validate(): self.modalResult = mrOk
    self.onShow = proc(s: Control) = self.activeControl = self.nameEdit

proc newCustomerDialog*(c: Customer, title: string): CustomerDlg =
  ## The dialog form, loaded and not yet shown (modal use: `runCustomerDialog`).
  result = newCustomerDlg()
  result.caption = title
  result.load(c)

proc runCustomerDialog*(c: var Customer, title: string): bool =
  ## Shows the dialog modally; true (and `c` updated) when OK passed validation.
  let d = newCustomerDialog(c, title)
  if d.showModal() == mrOk:
    c = d.customer
    result = true
  d.freeWindow()

# ---------------------------------------------------------------- toolbar glyphs

proc glyphNew(c: Canvas, r: RectF, col: Color) =
  c.line(r.x + r.w / 2, r.y + 3, r.x + r.w / 2, r.bottom - 3, col, 1.8)
  c.line(r.x + 3, r.y + r.h / 2, r.right - 3, r.y + r.h / 2, col, 1.8)

proc glyphEdit(c: Canvas, r: RectF, col: Color) =
  c.line(r.x + 3, r.bottom - 3, r.right - 4, r.y + 4, col, 2.4)
  c.line(r.x + 3, r.bottom - 3, r.x + 3, r.bottom - 6, col, 1.5)
  c.line(r.x + 3, r.bottom - 3, r.x + 6, r.bottom - 3, col, 1.5)

proc glyphDelete(c: Canvas, r: RectF, col: Color) =
  c.line(r.x + 4, r.y + 4, r.right - 4, r.bottom - 4, col, 1.8)
  c.line(r.right - 4, r.y + 4, r.x + 4, r.bottom - 4, col, 1.8)

proc glyphRefresh(c: Canvas, r: RectF, col: Color) =
  c.strokeEllipse(rectF(r.x + 3, r.y + 3, r.w - 6, r.h - 6), col, 1.6)
  c.fillRect(rectF(r.right - 6, r.y + 2, 4, 4), col)

# ------------------------------------------------------------------- main form

form CustomersForm:
  caption = "Customers"
  width = 1120; height = 700
  position = poScreenCenter
  var store*: CustomerStore
  var rebuilding: bool                     ## true while the list is re-filled by code
  var dataCalls*: int                      ## how often `onData` ran (tests)
  var searchTimer*: Timer
  var mainMenu: MainMenu
  var editItem, deleteItem: MenuItem

  ToolBar toolbar:
    ToolButton newTool:
      caption = "New"; hint = "Add a customer (Ctrl+N)"; glyph = glyphNew
    ToolButton editTool:
      caption = "Edit"; hint = "Edit the selected customer (Enter)"; glyph = glyphEdit
    ToolButton deleteTool:
      caption = "Delete"; hint = "Delete the selected customers (Delete)"
      glyph = glyphDelete
    ToolButton:
      kind = tbsDivider
    ToolButton refreshTool:
      caption = "Refresh"; hint = "Re-apply the filter and sort (F5)"
      glyph = glyphRefresh
  Panel filterBar:
    align = alTop; height = 44
    borderStyle = pbNone
    Label searchLbl:
      caption = "&Search"; left = 12; top = 13
      focusControl = self.search
    Edit search:
      left = 66; top = 8; width = 280
      placeholder = "Name, e-mail or city"
      hint = "Filters as you type (Ctrl+F)"
    Label countryLbl:
      caption = "C&ountry"; left = 366; top = 13
      focusControl = self.countryBox
    ComboBox countryBox:
      style = csDropDownList
      left = 430; top = 8; width = 190
      hint = "Show one country only"
    CheckBox activeOnly:
      caption = "A&ctive only"; left = 642; top = 11
      hint = "Hide inactive customers"
  StatusBar statusBar:
    height = 26
  ListView list:
    align = alClient
    margins = spacing(8, 0, 8, 8)
    viewStyle = vsReport
    ownerData = true
    multiSelect = true
    readOnly = true                        # no F2 / slow-click label editing
    rowSelect = true
    gridLines = false

  # ---------------------------------------------------------------- logic

  proc say*(self: CustomersForm, text: string) =
    self.statusBar.panels[2].text = text

  proc updateStatus*(self: CustomersForm) =
    let sel = self.list.selCount
    self.statusBar.panels[0].text = thousands(self.store.view.len) & " of " &
                                    thousands(self.store.rows.len)
    self.statusBar.panels[1].text = if sel == 0: "none selected"
                                    else: thousands(sel) & " selected"
    let canEdit = self.list.itemIndex >= 0
    self.editTool.enabled = canEdit
    self.editItem.enabled = canEdit
    self.deleteTool.enabled = sel > 0
    self.deleteItem.enabled = sel > 0

  proc selectedIds*(self: CustomersForm): HashSet[int32] =
    for i in self.list.selectedIndices:
      result.incl self.store.rows[self.store.view[i]].id

  proc focusedId*(self: CustomersForm): int32 =
    ## Id of the focused row, or 0.
    let i = self.list.itemIndex
    if i in 0 ..< self.store.view.len: self.store.rows[self.store.view[i]].id else: 0

  proc refillList*(self: CustomersForm, keep: HashSet[int32], focus: int32,
                   fallbackRow = -1) =
    ## Shows `store.view` in the list. The rows of `keep` (ids) that are still
    ## in the view stay selected (and `focus` stays the focused row); when
    ## `fallbackRow` >= 0 and nothing survived, that row is selected instead.
    self.rebuilding = true
    let l = self.list
    l.clearSelection()                      # selection is by row number: reset it
    l.itemsCount = self.store.view.len
    var focusRow = -1
    var rows: seq[int]
    if keep.len > 0 or focus != 0:
      for i, r in self.store.view:
        let id = self.store.rows[r].id
        if id == focus: focusRow = i
        if id in keep: rows.add i
    if focusRow < 0 and rows.len > 0: focusRow = rows[0]
    if focusRow >= 0:
      if rows.len == 0: rows.add focusRow          # focus without a selection
      l.setSelection(rows, focusRow)
    elif fallbackRow >= 0 and l.count > 0:
      l.itemIndex = min(fallbackRow, l.count - 1)
    self.rebuilding = false
    l.refreshData()
    self.updateStatus()

  proc applyView*(self: CustomersForm, fallbackRow = -1) =
    ## Re-runs filter and sort over all rows, keeping the selection.
    let keep = self.selectedIds
    let focus = self.focusedId
    self.store.rebuildView()
    self.refillList(keep, focus, fallbackRow)

  proc applySearchNow*(self: CustomersForm) =
    self.searchTimer.enabled = false
    if self.store.filter.search != self.search.text:
      self.store.filter.search = self.search.text
      self.applyView()
      self.say "Search: " & (if self.search.text.len > 0: "\"" & self.search.text & "\""
                             else: "cleared")

  proc applyFilters*(self: CustomersForm) =
    ## Country and active-only changes apply at once (no debounce).
    self.store.filter.country =
      if self.countryBox.itemIndex <= 0: "" else: self.countryBox.text
    self.store.filter.activeOnly = self.activeOnly.checked
    self.applyView()
    self.say "Filter: " & (if self.store.filter.country.len > 0: self.store.filter.country
                           else: "all countries") &
             (if self.activeOnly.checked: ", active only" else: "")

  proc sortBy*(self: CustomersForm, col: CustomerColumn, desc: bool) =
    self.store.sortCol = col
    self.store.sortDesc = desc
    self.list.sortColumn = ord(col)
    self.list.sortOrder = if desc: soDescending else: soAscending
    self.applyView()
    self.say "Sorted by " & self.list.columns[ord(col)].caption &
             (if desc: " (descending)" else: " (ascending)")

  proc columnClicked*(self: CustomersForm, col: int) =
    let c = CustomerColumn(col)
    self.sortBy(c, c == self.store.sortCol and not self.store.sortDesc)

  proc editRow*(self: CustomersForm, id: int32) =
    let r = self.store.rowOf(id)
    if r < 0: return
    var c = self.store.rows[r]
    if runCustomerDialog(c, "Edit customer #" & $id):
      discard self.store.updateCustomer(c)
      self.applyView()
      self.say "Edited #" & $id & " " & c.name
    else:
      self.say "Edit cancelled"

  proc editCurrent*(self: CustomersForm) =
    let id = self.focusedId
    if id != 0: self.editRow(id)

  proc newCustomer*(self: CustomersForm) =
    var c = Customer(active: true, country: Countries[0],
                     created: int32(getTime().toUnix div 86400))
    if runCustomerDialog(c, "New customer"):
      let id = self.store.addCustomer(c)
      self.store.rebuildView()
      self.refillList([id].toHashSet, id)
      var shown = false
      for r in self.store.view:
        if self.store.rows[r].id == id: shown = true
      self.say(if shown: "Added #" & $id & " " & c.name
               else: "Added #" & $id & " " & c.name & " (hidden by the filter)")
    else:
      self.say "New cancelled"

  proc deleteSelected*(self: CustomersForm) =
    let ids = self.selectedIds
    if ids.len == 0: return
    let q = if ids.len == 1: "Delete this customer?"
            else: "Delete " & thousands(ids.len) & " customers?"
    if messageDlg(q, mtConfirmation, {mbYes, mbNo}, mbNo, "Delete") != mrYes:
      self.say "Delete cancelled"
      return
    let row = self.list.itemIndex
    let n = self.store.deleteCustomers(ids)
    self.store.rebuildView()
    self.refillList(initHashSet[int32](), 0, fallbackRow = row)
    self.say "Deleted " & thousands(n) & (if n == 1: " customer" else: " customers")

  proc refreshAll*(self: CustomersForm) =
    self.applyView()
    self.say "Refreshed"

  proc buildMenus(self: CustomersForm) =
    let mm = newMainMenu(self)
    self.mainMenu = mm
    let file = mm.addItem("&Customers")
    file.addItem("&New...", proc(s: MenuItem) = self.newCustomer(), shortcut("Ctrl+N"))
    self.editItem = file.addItem("&Edit...", proc(s: MenuItem) = self.editCurrent(),
                                 shortcut("Ctrl+E"))
    self.deleteItem = file.addItem("&Delete...", proc(s: MenuItem) = self.deleteSelected())
    file.addSeparator()
    file.addItem("&Refresh", proc(s: MenuItem) = self.refreshAll(), shortcut("F5"))
    file.addSeparator()
    file.addItem("E&xit", proc(s: MenuItem) = self.close(), shortcut("Ctrl+Q"))
    let view = mm.addItem("&View")
    view.addItem("Focus &search", proc(s: MenuItem) = setFocus(self.search), shortcut("Ctrl+F"))
    view.addItem("&Clear filters", proc(s: MenuItem) =
      self.search.text = ""
      self.countryBox.itemIndex = 0
      self.activeOnly.checked = false
      self.applySearchNow()
      self.applyFilters())

  proc wire(self: CustomersForm) =
    let l = self.list
    l.columns.add("ID", 70, taRight)
    l.columns.add("Name", 190)
    l.columns.add("Email", 260)
    l.columns.add("City", 130)
    l.columns.add("Country", 130)
    l.columns.add("Balance", 110, taRight)
    l.columns.add("Created", 100)
    l.columns.add("Active", 60)
    l.onData = proc(s: Control, item: ListItem) =
      inc self.dataCalls
      let c = addr self.store.rows[self.store.view[item.index]]
      item.caption = $c.id
      item.subItems = @[c.name, c.email, c.city, c.country, formatMoney(c.balance),
                        formatDate(c.created), (if c.active: "Yes" else: "No")]
    l.onColumnClick = proc(s: Control, col: ListColumn) = self.columnClicked(col.index)
    l.onChange = proc(s: Control) =
      if not self.rebuilding: self.updateStatus()
    l.onItemDblClick = proc(s: Control, index, column: int) = self.editCurrent()
    l.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
      if sh * {ssCtrl, ssAlt, ssShift} != {}: return
      if k == keyEnter:
        k = Key(0)
        self.editCurrent()
      elif k == keyDelete:
        k = Key(0)
        self.deleteSelected()
    self.countryBox.items.add "All countries"
    for c in Countries: self.countryBox.items.add c
    self.countryBox.itemIndex = 0
    self.countryBox.onChange = proc(s: Control) = self.applyFilters()
    self.activeOnly.onChange = proc(s: Control) = self.applyFilters()
    self.searchTimer = newTimer(self, DebounceMs)
    self.searchTimer.enabled = false
    self.searchTimer.onTimer = proc(t: Timer) = self.applySearchNow()
    self.search.onChange = proc(s: Control) =
      self.searchTimer.enabled = false           # restart the debounce
      self.searchTimer.enabled = true
    self.search.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
      if k == keyEscape and self.search.text.len > 0:
        k = Key(0)
        self.search.text = ""
        self.applySearchNow()
      elif k == keyDown and sh == {}:
        k = Key(0)
        setFocus(self.list)
    self.newTool.onClick = proc(s: Control) = self.newCustomer()
    self.editTool.onClick = proc(s: Control) = self.editCurrent()
    self.deleteTool.onClick = proc(s: Control) = self.deleteSelected()
    self.refreshTool.onClick = proc(s: Control) = self.refreshAll()
    let sb = self.statusBar
    sb.addPanel("", 150)
    sb.addPanel("", 130, taCenter)
    sb.addPanel("Ready")
    sb.sizeGrip = true

  init:
    self.store = initStore(TotalRows, Seed)
    self.buildMenus()
    self.wire()
    self.list.sortColumn = 0
    self.list.sortOrder = soAscending
    self.list.itemsCount = self.store.view.len
    self.updateStatus()
    self.say "Loaded " & thousands(self.store.rows.len) & " customers"

# ------------------------------------------------------------------------ main

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let f = newCustomersForm()
  if shot.len > 0:
    f.show()
    f.syncMetrics()
    discard f.paintIfDirty()
    let search = getEnv("NIMVCL_SEARCH")
    if search.len > 0:
      f.search.text = search
      f.applySearchNow()
    let sort = getEnv("NIMVCL_SORT")
    if sort.len > 0:
      f.sortBy(CustomerColumn(clamp(parseInt(sort.strip(chars = {'d'})), 0, 7)),
               sort.endsWith("d"))
    let row = getEnv("NIMVCL_ROW")
    if row.len > 0:
      let n = clamp(parseInt(row), 0, max(f.list.count - 1, 0))
      f.list.itemIndex = n
      f.list.setSelected(n + 1, true)
      f.list.setSelected(n + 2, true)
      f.list.setFocus()
      f.list.scrollTo(0, float32(n) * f.list.itemHeight)
    else:
      f.list.itemIndex = min(2, f.list.count - 1)
      f.list.setSelected(3, true)
      f.list.setFocus()
    discard f.paintIfDirty()
    var target = Form(f)
    var dlg: CustomerDlg
    if getEnv("NIMVCL_EDIT") == "1":
      let i = max(f.list.itemIndex, 0)
      dlg = newCustomerDialog(f.store.rows[f.store.view[i]], "Edit customer")
      dlg.show()
      dlg.syncMetrics()
      if getEnv("NIMVCL_BAD") == "1":                # show the validation message
        dlg.emailEdit.text = "no-at-sign"
        discard dlg.validate()
      discard dlg.paintIfDirty()
      target = dlg
    let bmp = if shot.endsWith(".png"): shot.changeFileExt("bmp") else: shot
    if not target.screenshot(bmp): quit "screenshot failed: " & sdlError()
    if shot.endsWith(".png"):
      if execShellCmd("magick " & quoteShell(bmp) & " " & quoteShell(shot)) == 0:
        removeFile bmp
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    f.list.setFocus()
    Application.run(f)

when isMainModule:
  main()
