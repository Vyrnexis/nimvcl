## The Customers CRUD demo (phase 6 exit criterion) driven through dispatched
## events: debounced search, filters, sorting with stable selection, add / edit
## / delete through the modal dialogs, virtual-mode laziness and timings over
## 100,000 rows. Headless (offscreen SDL). The timing bounds are asserted in a
## release build only (`-d:release`); a debug build prints them.

import std/[unittest, strutils, sets, sequtils, algorithm, monotimes, times]
import nimvcl
import ../examples/crud_demo

# ------------------------------------------------------------------ helpers

proc ev(f: Form, kind: EventKind, x = 0'f32, y = 0'f32, k = Key(0),
        shift: ShiftState = {}, button = mbLeft, clicks = 1): PlatformEvent =
  PlatformEvent(kind: kind, windowId: f.win.id, x: x, y: y, key: k, shift: shift,
                button: button, clicks: clicks)

proc tap(f: Form, k: Key, shift: ShiftState = {}) =
  Application.dispatch(f.ev(ekKeyDown, k = k, shift = shift))
  Application.dispatch(f.ev(ekKeyUp, k = k, shift = shift))
proc typeText(f: Form, s: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: f.win.id, text: s))

proc mouse(f: Form, kind: EventKind, p: PointF, shift: ShiftState = {}, clicks = 1) =
  let s = f.win.scale
  Application.dispatch(f.ev(kind, p.x * s, p.y * s, shift = shift, clicks = clicks))
proc clickAt(f: Form, p: PointF, shift: ShiftState = {}, clicks = 1) =
  f.mouse(ekMouseMove, p)
  var sh = shift
  if clicks > 1: sh.incl ssDouble
  f.mouse(ekMouseDown, p, sh, clicks)
  f.mouse(ekMouseUp, p, shift)
proc settle(f: Form) =
  discard f.paintIfDirty()
  f.layoutIfNeeded()
  discard f.paintIfDirty()

proc rowPoint(f: CustomersForm, row: int): PointF =
  f.settle()
  let l = f.list
  l.clientToForm(pointF(l.width / 2, l.captionRect(row).y + l.itemHeight / 2))
proc headerPoint(f: CustomersForm, col: int): PointF =
  f.settle()
  let l = f.list
  l.clientToForm(pointF(l.columnLeft(col) - l.scrollPos.x + l.columns[col].width / 2 - 8,
                        l.headerHeight / 2 + 2))
proc clickRow(f: CustomersForm, row: int, shift: ShiftState = {}, clicks = 1) =
  f.clickAt(f.rowPoint(row), shift, clicks)
proc clickHeader(f: CustomersForm, col: int) = f.clickAt(f.headerPoint(col))
template whileModal(body: untyped) =
  ## Runs `body` on the UI thread once the modal loop runs; `dlg` is the modal form.
  Application.queue(proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let dlg {.inject.} = modalForm()
      body)

proc pressButton(d: Form, b: Button) =
  let o = b.formOrigin
  for kind in [ekMouseMove, ekMouseDown, ekMouseUp]:
    Application.dispatch(PlatformEvent(kind: kind, windowId: d.win.id,
      x: (o.x + b.width / 2) * d.win.scale, y: (o.y + b.height / 2) * d.win.scale,
      button: mbLeft, clicks: 1))

proc msgButton(d: Form, b: MsgDlgBtn): Button =
  for c in d.children:
    if c of Button and c.tag == ord(b): return Button(c)

proc newShown(w = 0'f32, h = 0'f32): CustomersForm =
  result = newCustomersForm()
  if w > 0: result.width = w
  if h > 0: result.height = h
  result.show()
  result.syncMetrics()
  discard result.paintIfDirty()

proc finish(f: CustomersForm) =
  f.close()
  Application.init()                    # closing the main form terminated the app

proc waitUntil(timeoutMs: int, cond: proc(): bool): bool =
  ## Pumps events (timers!) until `cond()` or the timeout.
  let t0 = getMonoTime()
  while not cond():
    if (getMonoTime() - t0).inMilliseconds > timeoutMs: return false
    Application.processMessages(10)
  true

proc ms(a, b: MonoTime): float = float((b - a).inNanoseconds) / 1e6

proc ids(f: CustomersForm): seq[int32] =
  for r in f.store.view: result.add f.store.rows[r].id

proc rowOfId(f: CustomersForm, id: int32): int =
  for i, r in f.store.view:
    if f.store.rows[r].id == id: return i
  -1

proc selectIds(f: CustomersForm, ids: openArray[int32]) =
  let l = f.list
  l.clearSelection()
  var first = true
  for id in ids:
    let r = f.rowOfId(id)
    doAssert r >= 0
    if first:
      l.itemIndex = r
      first = false
    else:
      l.setSelected(r, true)

proc slowCount(f: CustomersForm, search = "", country = "", activeOnly = false): int =
  let low = search.toLowerAscii
  for c in f.store.rows:
    if activeOnly and not c.active: continue
    if country.len > 0 and c.country != country: continue
    if low.len == 0 or low in c.name.toLowerAscii or low in c.email.toLowerAscii or
       low in c.city.toLowerAscii: inc result

proc keyCmp(a, b: Customer, col: CustomerColumn): int =
  ## The sort order, spelled out independently of the model.
  case col
  of ccId: cmp(a.id, b.id)
  of ccName: cmpIgnoreCase(a.name, b.name)
  of ccEmail: cmpIgnoreCase(a.email, b.email)
  of ccCity: cmpIgnoreCase(a.city, b.city)
  of ccCountry: cmpIgnoreCase(a.country, b.country)
  of ccBalance: cmp(a.balance, b.balance)
  of ccCreated: cmp(a.created, b.created)
  of ccActive: cmp(ord(not a.active), ord(not b.active))

proc isSorted(f: CustomersForm, col: CustomerColumn, desc: bool): bool =
  let v = f.store.view
  for i in 1 ..< v.len:
    let a = f.store.rows[v[i - 1]]
    let b = f.store.rows[v[i]]
    var c = keyCmp(a, b, col)
    if desc: c = -c
    if c > 0: return false
    if c == 0 and a.id >= b.id and not desc: return false
    if c == 0 and a.id <= b.id and desc: return false
  true

proc visibleRows(f: CustomersForm): int =
  int(ceil(f.list.viewport.h / f.list.itemHeight)) + 1

const Release = defined(release) or defined(danger)

template perfCheck(name: string, value: float, limit: float) =
  echo "  perf ", name, ": ", formatFloat(value, ffDecimal, 2), " ms (limit ", limit, ")"
  when Release: check value < limit

suite "customers: model":
  test "the generator is deterministic and makes 100,000 plausible rows":
    let a = generateCustomers(1000, 7)
    check a == generateCustomers(1000, 7)
    check a != generateCustomers(1000, 8)
    let big = generateCustomers(TotalRows, Seed)
    check big.len == 100_000
    check big[0].id == 1 and big[^1].id == 100_000
    check big[0] == generateCustomers(1, Seed)[0]       # a prefix is the same data
    var active = 0
    for i, c in big:
      if i > 0 and c.id != big[i - 1].id + 1: fail()
      if '@' notin c.email or c.name.len == 0 or c.city.len == 0 or
         c.country notin Countries or c.created < FirstDay: fail()
      if c.active: inc active
    check active in 78_000 .. 82_000

  test "money and date formatting":
    check formatMoney(123456) == "1,234.56"
    check formatMoney(-5) == "-0.05"
    check formatMoney(0) == "0.00"
    var c: int64
    check parseMoney("1,234.5", c) and c == 123450
    check parseMoney("-12", c) and c == -1200
    check parseMoney(" 0.07 ", c) and c == 7
    check not parseMoney("", c) and not parseMoney("abc", c) and
          not parseMoney("1.234", c) and not parseMoney("1.2.3", c) and
          not parseMoney("-", c)
    check formatDate(FirstDay) == "2015-01-01"
    check formatDate(0) == "1970-01-01"
    check formatDate(19782) == "2024-02-29"
    check thousands(100000) == "100,000" and thousands(999) == "999"

suite "customers app":
  setup:
    Application.init()
    Application.forceScale = 0
    Application.theme = themeLight()
  teardown:
    for f in openForms(): f.freeWindow()

  test "starts with 100,000 virtual rows, sorted by id, status filled in":
    let f = newShown()
    check f.list.ownerData and f.list.count == 100_000 and f.store.rows.len == 100_000
    check f.list.columns.count == 8
    check f.list.sortColumn == 0 and f.list.sortOrder == soAscending
    check f.statusBar.panels[0].text == "100,000 of 100,000"
    check f.statusBar.panels[1].text == "none selected"
    check not f.editTool.enabled and not f.deleteTool.enabled
    check f.countryBox.items.len == 22 and f.countryBox.items[0] == "All countries"
    check f.countryBox.style == csDropDownList
    f.finish()

  test "onData runs only for the rows that are painted":
    let f = newShown()
    let vis = f.visibleRows
    check f.dataCalls > 0 and f.dataCalls <= vis
    f.dataCalls = 0
    f.list.scrollTo(0, 50_000 * f.list.itemHeight)
    check f.dataCalls == 0                       # scrolling alone reads nothing
    check f.paintIfDirty()
    check f.dataCalls > 0 and f.dataCalls <= vis
    f.dataCalls = 0
    f.list.scrollBy(0, f.list.itemHeight * 3)
    discard f.paintIfDirty()
    check f.dataCalls <= vis
    # the search result (4,000 rows) is not read in full either
    f.dataCalls = 0
    f.search.text = "ana"
    f.applySearchNow()
    discard f.paintIfDirty()
    check f.store.view.len > 1000 and f.dataCalls <= vis
    f.finish()

  # ------------------------------------------------------------ search
  test "search is debounced, then filters name, e-mail and city":
    let f = newShown()
    f.search.setFocus()
    f.typeText "a"
    check f.searchTimer.enabled                # armed
    check f.list.count == 100_000                 # nothing yet
    discard waitUntil(60, proc(): bool = false)   # less than the 150 ms
    f.typeText "n"                                # restarts the delay
    discard waitUntil(100, proc(): bool = false)
    check f.list.count == 100_000 and f.store.filter.search == ""
    check waitUntil(2000, proc(): bool = f.store.filter.search == "an")
    check f.store.filter.search == "an"           # never applied for "a" alone
    check f.list.count == f.slowCount("an") and f.list.count < 100_000
    check f.statusBar.panels[0].text == thousands(f.list.count) & " of 100,000"
    check not f.searchTimer.enabled
    # by city, case-insensitive; one row's e-mail narrows it to a single row
    f.search.text = "ZURICH"
    f.applySearchNow()
    check f.list.count == f.slowCount("zurich") and f.list.count > 0
    f.search.text = "alice.ito99232@"
    f.applySearchNow()
    check f.list.count == 1
    check f.store.rows[f.store.view[0]].id == 99232
    f.search.text = "no such customer anywhere"
    f.applySearchNow()
    check f.list.count == 0 and f.statusBar.panels[0].text == "0 of 100,000"
    # Esc in the box clears it; Down moves to the list
    f.search.setFocus()
    f.tap(keyEscape)
    check f.search.text == "" and f.list.count == 100_000
    f.typeText "x"
    f.tap(keyDown)
    check f.list.focused
    f.finish()

  test "country and active-only filters combine with the search":
    let f = newShown()
    f.countryBox.itemIndex = f.countryBox.items.indexOf("Japan")
    check f.store.filter.country == "Japan"
    let japan = f.slowCount(country = "Japan")
    check f.list.count == japan and japan > 3000
    f.activeOnly.checked = true
    check f.list.count == f.slowCount(country = "Japan", activeOnly = true)
    check f.list.count < japan
    f.search.text = "tokyo"
    f.applySearchNow()
    check f.list.count == f.slowCount("tokyo", "Japan", true) and f.list.count > 0
    for r in f.store.view:
      check f.store.rows[r].country == "Japan" and f.store.rows[r].active
    f.countryBox.itemIndex = 0
    check f.store.filter.country == "" and
          f.list.count == f.slowCount("tokyo", "", true)
    f.activeOnly.checked = false
    f.search.text = ""
    f.applySearchNow()
    check f.list.count == 100_000
    f.finish()

  test "selection survives a filter where the row still exists":
    let f = newShown()
    var jp, other: seq[int32]
    for c in f.store.rows[0 ..< 400]:
      if c.country == "Japan": jp.add c.id
      elif c.country == "Brazil": other.add c.id
    check jp.len >= 3 and other.len >= 3
    let picked = @[jp[0], jp[1], other[0], other[1]]
    f.selectIds picked
    f.list.itemIndex = f.rowOfId(other[1])        # focus on a Brazil row...
    for id in [jp[0], jp[1], other[0]]: f.list.setSelected(f.rowOfId(id), true)
    f.countryBox.itemIndex = f.countryBox.items.indexOf("Japan")
    check f.selectedIds == [jp[0], jp[1]].toHashSet     # Brazil rows are gone
    check f.list.selCount == 2
    check f.statusBar.panels[1].text == "2 selected"
    f.countryBox.itemIndex = 0                     # the removed rows do not come back selected
    check f.selectedIds == [jp[0], jp[1]].toHashSet
    f.finish()

  # ------------------------------------------------------------ sorting
  test "every column sorts ascending, then descending, from the header":
    let f = newShown()
    for col in CustomerColumn:
      let c = ord(col)
      f.clickHeader(c)
      let wantDesc = col == ccId                  # the id column starts ascending
      check f.store.sortCol == col and f.store.sortDesc == wantDesc
      check f.list.sortColumn == c
      check f.list.sortOrder == (if wantDesc: soDescending else: soAscending)
      check f.isSorted(col, wantDesc)
      f.clickHeader(c)
      check f.store.sortCol == col and f.store.sortDesc == not wantDesc
      check f.list.sortOrder == (if wantDesc: soAscending else: soDescending)
      check f.isSorted(col, not wantDesc)
      check f.list.count == 100_000
    check f.statusBar.panels[2].text.startsWith("Sorted by Active")
    f.finish()

  test "descending is the exact reverse of ascending":
    let f = newShown()
    f.sortBy(ccCity, false)
    let asc = f.ids
    f.sortBy(ccCity, true)
    check f.ids == asc.reversed
    f.finish()

  test "rows read through onData follow the sorted view":
    let f = newShown()
    f.sortBy(ccBalance, true)
    let l = f.list
    for i in [0, 1, 777, 99_999]:
      let it = l.getItem(i)
      let c = f.store.rows[f.store.view[i]]
      check it.caption == $c.id and it.subItems[1] == c.email
      check it.subItems[4] == formatMoney(c.balance)
    check f.store.rows[f.store.view[0]].balance >= f.store.rows[f.store.view[1]].balance
    f.finish()

  test "selection and focus stay with their customers across sorts":
    let f = newShown()
    let picked = @[int32(5), 77, 1000, 99_999]
    f.selectIds picked
    f.list.itemIndex = f.rowOfId(1000)
    for id in picked: f.list.setSelected(f.rowOfId(id), true)
    let focus = f.focusedId
    check focus == 1000
    for (col, desc) in [(ccName, false), (ccName, true), (ccBalance, false),
                        (ccCreated, true), (ccActive, false), (ccId, false)]:
      f.sortBy(col, desc)
      check f.selectedIds == picked.toHashSet
      check f.focusedId == focus
      check f.list.selCount == 4
      check f.list.selected(f.rowOfId(77))
    # the focused row is scrolled into view
    f.sortBy(ccEmail, true)
    f.settle()
    let r = f.list.itemRect(f.list.itemIndex)           # client coordinates
    let vp = f.list.viewport
    check r.bottom > vp.y and r.y < vp.bottom
    f.finish()

  test "refresh keeps the filter, the sort and the selection":
    let f = newShown()
    f.countryBox.itemIndex = f.countryBox.items.indexOf("Norway")
    f.sortBy(ccName, true)
    let before = f.ids
    f.selectIds [before[3], before[10]]
    f.tap(keyF5)
    check f.ids == before
    check f.selectedIds == [before[3], before[10]].toHashSet
    check f.statusBar.panels[2].text == "Refreshed"
    f.finish()

  # ------------------------------------------------------------ CRUD
  test "New: the dialog validates (focus on the bad field) and adds a customer":
    let f = newShown()
    whileModal:
      let d = CustomerDlg(dlg)
      check d.caption == "New customer"
      # 1. no name
      d.pressButton d.okBtn
      check modalForm() == dlg                  # still open
      check d.activeControl == Control(d.nameEdit) and d.errorLbl.caption.len > 0
      d.nameEdit.text = "   "                  # blanks are no name either
      d.pressButton d.okBtn
      check d.activeControl == Control(d.nameEdit)
      # 2. bad e-mail
      d.nameEdit.text = "Test Person"
      d.emailEdit.text = "person.example.com"
      d.pressButton d.okBtn
      check modalForm() == dlg
      check d.activeControl == Control(d.emailEdit) and "@" in d.errorLbl.caption
      # 3. bad balance
      d.emailEdit.text = "person@example.com"
      d.balanceEdit.text = "twelve"
      d.pressButton d.okBtn
      check d.activeControl == Control(d.balanceEdit) and "balance" in d.errorLbl.caption
      # 4. good: typed with the keyboard into the focused field
      d.balanceEdit.text = "1,250.75"
      d.cityEdit.text = "Testville"
      d.countryBox.itemIndex = d.countryBox.items.indexOf("Norway")
      d.activeBox.checked = false
      d.tap(keyEnter)                           # the default button
    f.newTool.onClick(f.newTool)
    check f.store.rows.len == 100_001 and f.store.rows[^1].id == 100_001
    let c = f.store.rows[^1]
    check c.name == "Test Person" and c.email == "person@example.com"
    check c.balance == 125_075 and c.city == "Testville" and c.country == "Norway"
    check not c.active
    check f.list.count == 100_001
    check f.selectedIds == [int32(100_001)].toHashSet and f.focusedId == 100_001
    check f.list.itemIndex == 100_000             # sorted by id: the last row, visible
    f.settle()
    check f.list.itemRect(100_000).bottom <= f.list.viewport.bottom + 1
    check f.statusBar.panels[0].text == "100,001 of 100,001"
    check f.statusBar.panels[2].text == "Added #100001 Test Person"
    f.finish()

  test "New is hidden by an active filter but still stored":
    let f = newShown()
    f.activeOnly.checked = true
    let n = f.list.count
    whileModal:
      let d = CustomerDlg(dlg)
      d.nameEdit.text = "Inactive Ian"
      d.emailEdit.text = "ian@example.com"
      d.activeBox.checked = false
      d.pressButton d.okBtn
    f.newCustomer()
    check f.store.rows.len == 100_001 and f.list.count == n
    check f.statusBar.panels[2].text.endsWith("(hidden by the filter)")
    f.finish()

  test "Edit: Enter and double click open it, OK stores, Cancel and Esc discard":
    let f = newShown()
    f.sortBy(ccName, false)
    f.clickRow 4
    let id = f.focusedId
    check id != 0 and f.editTool.enabled
    let orig = f.store.rows[f.store.rowOf(id)]
    # Enter edits the focused row
    whileModal:
      let d = CustomerDlg(dlg)
      check d.caption == "Edit customer #" & $id
      check d.nameEdit.text == orig.name and d.emailEdit.text == orig.email
      check d.cityEdit.text == orig.city and d.countryBox.text == orig.country
      check d.balanceEdit.text == formatMoney(orig.balance).replace(",", "")
      check d.createdValue.caption == formatDate(orig.created)
      check d.activeBox.checked == orig.active
      d.nameEdit.text = "Zzz Renamed"
      d.balanceEdit.text = "-3.50"
      d.countryBox.itemIndex = d.countryBox.items.indexOf("Japan")
      d.pressButton d.okBtn
    f.list.setFocus()
    f.tap(keyEnter)
    var c = f.store.rows[f.store.rowOf(id)]
    check c.name == "Zzz Renamed" and c.balance == -350 and c.country == "Japan"
    check c.email == orig.email and c.created == orig.created
    check f.focusedId == id and f.selectedIds == [id].toHashSet   # still selected
    check f.store.rows[f.store.view[f.list.itemIndex]].name == "Zzz Renamed"
    check f.list.itemIndex > 50_000               # re-sorted to the end of the names
    # Cancel discards
    whileModal:
      let d = CustomerDlg(dlg)
      d.nameEdit.text = "Should Not Stick"
      d.pressButton d.cancelBtn
    f.tap(keyEnter)
    check f.store.rows[f.store.rowOf(id)].name == "Zzz Renamed"
    check f.statusBar.panels[2].text == "Edit cancelled"
    # Esc discards
    whileModal:
      let d = CustomerDlg(dlg)
      d.nameEdit.text = "Nor This"
      d.tap(keyEscape)
    f.editTool.onClick(f.editTool)
    check f.store.rows[f.store.rowOf(id)].name == "Zzz Renamed"
    # double click on a row edits it
    f.list.scrollTo(0, 0)
    f.clickRow 0
    let id0 = f.focusedId
    whileModal:
      let d = CustomerDlg(dlg)
      check d.caption == "Edit customer #" & $id0
      d.pressButton d.cancelBtn
    f.statusBar.panels[2].text = ""
    f.clickRow(0, clicks = 2)
    check f.statusBar.panels[2].text == "Edit cancelled"
    f.finish()

  test "a double click on the header sorts but does not open the editor":
    let f = newShown()
    f.clickRow 2
    var opened = false
    Application.queue(proc() {.closure, gcsafe.} =       # would run inside a modal loop
      {.cast(gcsafe).}:
        if modalForm() != nil:
          opened = true
          modalForm().close())
    f.clickAt(f.headerPoint(1), clicks = 2)
    Application.processMessages()                        # drain it if no dialog opened
    check not opened
    check f.store.sortCol == ccName
    f.finish()

  test "Delete asks first; No keeps, Yes removes and selects the neighbour":
    let f = newShown()
    f.clickRow 10
    let id = f.focusedId
    check f.deleteTool.enabled
    whileModal:
      check dlg.caption == "Delete"
      dlg.pressButton dlg.msgButton(mbNo)
    f.list.setFocus()
    f.tap(keyDelete)
    check f.store.rows.len == 100_000 and f.statusBar.panels[2].text == "Delete cancelled"
    whileModal:
      dlg.pressButton dlg.msgButton(mbYes)
    f.tap(keyDelete)
    check f.store.rows.len == 99_999 and f.store.rowOf(id) < 0
    check f.list.count == 99_999 and f.statusBar.panels[0].text == "99,999 of 99,999"
    check f.statusBar.panels[2].text == "Deleted 1 customer"
    check f.list.itemIndex == 10 and f.list.selCount == 1     # the next row moved up
    check f.focusedId == id + 1
    f.finish()

  test "multi-select with Shift/Ctrl and delete them together":
    let f = newShown()
    f.clickRow 3
    f.clickRow(6, {ssShift})                      # rows 3..6
    f.clickRow(9, {ssCtrl})                       # + row 9
    check f.list.selCount == 5
    check f.statusBar.panels[1].text == "5 selected"
    let gone = f.selectedIds
    check gone.len == 5
    let nextId = f.store.rows[9].id + 1
    whileModal:
      check "5 customers" in dlg.children.filterIt(it of Label).mapIt(it.caption).join(" ")
      dlg.pressButton dlg.msgButton(mbYes)
    f.tap(keyDelete)
    check f.store.rows.len == 99_995
    for id in gone: check f.store.rowOf(id) < 0
    check f.statusBar.panels[2].text == "Deleted 5 customers"
    check f.list.selCount == 1                    # one row stays selected at the old focus
    # select all and delete, with a filter: only the visible rows go
    f.countryBox.itemIndex = f.countryBox.items.indexOf("Finland")
    let finland = f.list.count
    f.list.setFocus()
    f.tap('a'.key, {ssCtrl})
    check f.list.selCount == finland
    whileModal:
      dlg.pressButton dlg.msgButton(mbYes)
    f.deleteTool.onClick(f.deleteTool)
    check f.list.count == 0 and f.store.rows.len == 99_995 - finland
    check not f.deleteTool.enabled and not f.editTool.enabled
    check f.statusBar.panels[1].text == "none selected"
    discard nextId
    f.finish()

  test "the toolbar and menu items follow the selection":
    let f = newShown()
    check not f.editItem.enabled and not f.deleteItem.enabled
    f.clickRow 1
    check f.editItem.enabled and f.deleteItem.enabled
    check f.editTool.enabled and f.deleteTool.enabled
    f.tap(keyDown)
    check f.list.itemIndex == 2 and f.statusBar.panels[1].text == "1 selected"
    f.finish()

  # ------------------------------------------------------------ timing
  test "timings: open, filter, sort, scroll (100,000 rows)":
    echo ""
    let t0 = getMonoTime()
    let f = newShown()
    let tOpen = ms(t0, getMonoTime())
    perfCheck "open + first paint (incl. generating 100k rows)", tOpen, 1500

    # filter keystroke -> new view -> repaint
    var worst = 0.0
    for text in ["a", "an", "ana", "anak"]:
      f.search.text = text
      let t = getMonoTime()
      f.applySearchNow()
      discard f.paintIfDirty()
      worst = max(worst, ms(t, getMonoTime()))
    perfCheck "filter keystroke -> repaint (worst of 4)", worst, 150
    f.search.text = ""
    f.applySearchNow()

    # sort 100k by every column, ascending then descending
    var sortWorst = 0.0
    var sortSum = 0.0
    for col in CustomerColumn:
      for desc in [false, true]:
        let t = getMonoTime()
        f.sortBy(col, desc)
        discard f.paintIfDirty()
        let d = ms(t, getMonoTime())
        sortWorst = max(sortWorst, d)
        sortSum += d
        if d > 150: echo "    slow: ", col, " desc=", desc, " ", formatFloat(d, ffDecimal, 1), " ms"
    echo "  perf sort+repaint mean over 16 sorts: ", formatFloat(sortSum / 16, ffDecimal, 2), " ms"
    perfCheck "sort 100k + repaint (worst of 16)", sortWorst, 300

    # selection kept across a sort with a big selection
    f.list.setFocus()
    f.tap('a'.key, {ssCtrl})
    check f.list.selCount == 100_000
    let t1 = getMonoTime()
    f.sortBy(ccName, false)
    discard f.paintIfDirty()
    perfCheck "sort with 100k selected rows", ms(t1, getMonoTime()), 600
    check f.list.selCount == 100_000
    f.list.clearSelection()

    # scrolling: wheel notches through the list, one paint per frame. The frame
    # cost is dominated by the SOFTWARE renderer filling the list's big rounded
    # background (see the report), so the rows' own share is measured against
    # a repaint of the same form with an empty list.
    f.sortBy(ccId, false)
    f.list.scrollTo(0, 0)
    f.settle()
    f.list.itemsCount = 0
    var base = 0.0
    for i in 0 ..< 30:
      f.invalidate()
      let t = getMonoTime()
      discard f.paintIfDirty()
      base += ms(t, getMonoTime())
    base /= 30
    f.applyView()
    f.list.scrollTo(0, 0)
    f.settle()
    let frames = 600
    var times: seq[float]
    let wp = f.rowPoint(3)
    f.mouse(ekMouseMove, wp)
    for i in 0 ..< frames:
      f.dataCalls = 0
      let t = getMonoTime()
      Application.dispatch(PlatformEvent(kind: ekMouseWheel, windowId: f.win.id,
        x: wp.x * f.win.scale, y: wp.y * f.win.scale, dy: -3))
      let painted = f.paintIfDirty()
      times.add ms(t, getMonoTime())
      check painted
      check f.dataCalls <= f.visibleRows
    check f.list.scrollPos.y > 1000
    times.sort()
    let median = times[frames div 2]
    let p95 = times[frames * 95 div 100]
    echo "  perf scroll+paint over ", frames, " frames: median ",
         formatFloat(median, ffDecimal, 2), " ms, p95 ", formatFloat(p95, ffDecimal, 2),
         " ms, worst ", formatFloat(times[^1], ffDecimal, 2), " ms; empty-list repaint ",
         formatFloat(base, ffDecimal, 2), " ms"
    perfCheck "scroll + paint, median frame", median, 20
    perfCheck "scroll + paint, p95 frame", p95, 40
    perfCheck "rows' share of a scroll frame (median - empty repaint)", median - base, 8
    # a big jump (drag the thumb / End key) is as cheap
    let t2 = getMonoTime()
    f.list.scrollTo(0, 99_000 * f.list.itemHeight)
    discard f.paintIfDirty()
    perfCheck "jump to row 99,000 + paint", ms(t2, getMonoTime()), 40
    f.finish()
