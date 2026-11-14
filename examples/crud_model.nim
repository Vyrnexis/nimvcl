## The data model of the Customers demo (examples/crud_demo.nim): plain
## objects in a seq, a deterministic generator, and a filtered + sorted index
## view (`seq[int32]` of row positions) that the virtual ListView reads.
## No UI code here.

import std/[algorithm, strutils, sets]

type
  Customer* = object
    id*: int32
    name*, email*, city*, country*: string
    balance*: int64                 ## in cents
    created*: int32                 ## days since 1970-01-01
    active*: bool

  CustomerColumn* = enum
    ccId, ccName, ccEmail, ccCity, ccCountry, ccBalance, ccCreated, ccActive

  CustomerFilter* = object
    search*: string                 ## substring of name, email or city (any case)
    country*: string                ## "" = all countries
    activeOnly*: bool

  CustomerStore* = object
    rows*: seq[Customer]            ## ascending by id
    nextId*: int32
    view*: seq[int32]               ## positions in `rows`: filtered, then sorted
    filter*: CustomerFilter
    sortCol*: CustomerColumn
    sortDesc*: bool

const
  Countries* = ["Argentina", "Australia", "Austria", "Belgium", "Brazil",
                "Canada", "Denmark", "Finland", "France", "Germany", "Ireland",
                "Italy", "Japan", "Mexico", "Netherlands", "Norway", "Spain",
                "Sweden", "Switzerland", "United Kingdom", "United States"]
  Cities = [
    ["Buenos Aires", "Cordoba", "Rosario"], ["Sydney", "Melbourne", "Perth"],
    ["Vienna", "Graz", "Salzburg"], ["Brussels", "Antwerp", "Ghent"],
    ["Sao Paulo", "Recife", "Curitiba"], ["Toronto", "Vancouver", "Montreal"],
    ["Copenhagen", "Aarhus", "Odense"], ["Helsinki", "Tampere", "Oulu"],
    ["Paris", "Lyon", "Marseille"], ["Berlin", "Hamburg", "Munich"],
    ["Dublin", "Cork", "Galway"], ["Rome", "Milan", "Turin"],
    ["Tokyo", "Osaka", "Kyoto"], ["Mexico City", "Guadalajara", "Monterrey"],
    ["Amsterdam", "Rotterdam", "Utrecht"], ["Oslo", "Bergen", "Trondheim"],
    ["Madrid", "Barcelona", "Valencia"], ["Stockholm", "Gothenburg", "Malmo"],
    ["Zurich", "Geneva", "Basel"], ["London", "Manchester", "Leeds"],
    ["New York", "Chicago", "Austin"]]
  FirstNames = ["Alice", "Bruno", "Chloe", "David", "Elena", "Felix", "Greta",
                "Hugo", "Irene", "Jonas", "Katya", "Liam", "Maya", "Nico",
                "Olga", "Pavel", "Quinn", "Rosa", "Stefan", "Tara", "Umar",
                "Vera", "Wim", "Xenia", "Yusuf", "Zoe"]
  LastNames = ["Andersen", "Baker", "Costa", "Dubois", "Evans", "Fischer",
               "Garcia", "Haas", "Ito", "Jensen", "Keller", "Lopez", "Meyer",
               "Novak", "Olsen", "Petrov", "Rossi", "Silva", "Tanaka", "Ulrich",
               "Vogel", "Weber", "Young", "Zimmer"]
  Domains = ["example.com", "mail.test", "corp.example", "post.invalid"]
  FirstDay* = 16436'i32             ## 2015-01-01
  DaySpan = 4000                    ## ... up to about the end of 2025

# ---------------------------------------------------------------- generator

proc nextRand(s: var uint64): uint64 =
  ## xorshift64*: deterministic for a seed, same on every platform.
  s = s xor (s shr 12)
  s = s xor (s shl 25)
  s = s xor (s shr 27)
  s * 2685821657736338717'u64

proc generateCustomers*(n: int, seed = 12345'u64): seq[Customer] =
  ## `n` customers with ids 1..n; the same `seed` gives the same rows.
  var s = seed * 0x9E3779B97F4A7C15'u64 + 1
  result = newSeqOfCap[Customer](n)
  for i in 1 .. n:
    let r = nextRand(s)
    let fn = FirstNames[int(r mod FirstNames.len.uint64)]
    let ln = LastNames[int((r shr 8) mod LastNames.len.uint64)]
    let ci = int((r shr 20) mod Countries.len.uint64)
    result.add Customer(
      id: int32(i),
      name: fn & " " & ln,
      email: fn.toLowerAscii & "." & ln.toLowerAscii & $i & "@" &
             Domains[int((r shr 30) mod Domains.len.uint64)],
      city: Cities[ci][int((r shr 36) mod 3)],
      country: Countries[ci],
      balance: int64((r shr 40) mod 3_000_000'u64) - 50_000,
      created: FirstDay + int32((r shr 16) mod DaySpan.uint64),
      active: (r shr 58) mod 5 != 0)             # about 80% active

# --------------------------------------------------------------- formatting

proc thousands*(n: int64): string =
  ## 1234567 -> "1,234,567"
  let digits = $abs(n)
  for i, ch in digits:
    if i > 0 and (digits.len - i) mod 3 == 0: result.add ','
    result.add ch
  if n < 0: result = "-" & result

proc formatMoney*(cents: int64): string =
  ## 123456 -> "1,234.56"
  let a = abs(cents)
  result = thousands(a div 100) & "." & align($(a mod 100), 2, '0')
  if cents < 0: result = "-" & result

proc parseMoney*(text: string, cents: var int64): bool =
  ## "1234.5", "1,234.56", "-12" -> cents. False for anything else.
  let t = text.strip().replace(",", "")
  if t.len == 0: return false
  var neg = false
  var i = 0
  if t[0] in {'-', '+'}:
    neg = t[0] == '-'
    i = 1
  var whole, frac, fracDigits = 0'i64
  var digits = 0
  var seenDot = false
  while i < t.len:
    let ch = t[i]
    if ch in Digits:
      inc digits
      if seenDot:
        if fracDigits >= 2: return false
        frac = frac * 10 + (ord(ch) - ord('0'))
        inc fracDigits
      else:
        whole = whole * 10 + (ord(ch) - ord('0'))
        if whole > 10_000_000_000_000'i64: return false
    elif ch == '.' and not seenDot: seenDot = true
    else: return false
    inc i
  if digits == 0: return false
  if fracDigits == 1: frac *= 10
  cents = whole * 100 + frac
  if neg: cents = -cents
  true

proc formatDate*(days: int32): string =
  ## Days since 1970-01-01 -> "YYYY-MM-DD" (proleptic Gregorian).
  let z = int64(days) + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  let y = yoe + era * 400 + (if m <= 2: 1 else: 0)
  $y & "-" & align($m, 2, '0') & "-" & align($d, 2, '0')

proc columnText*(c: Customer, col: CustomerColumn): string =
  case col
  of ccId: $c.id
  of ccName: c.name
  of ccEmail: c.email
  of ccCity: c.city
  of ccCountry: c.country
  of ccBalance: formatMoney(c.balance)
  of ccCreated: formatDate(c.created)
  of ccActive: (if c.active: "Yes" else: "No")

# ------------------------------------------------------------ filter + sort

func containsIC(s, lowerNeedle: string): bool =
  ## ASCII case-insensitive substring test without allocating.
  let n = lowerNeedle.len
  if n == 0: return true
  if s.len < n: return false
  for i in 0 .. s.len - n:
    var j = 0
    while j < n and toLowerAscii(s[i + j]) == lowerNeedle[j]: inc j
    if j == n: return true

func matches*(c: Customer, f: CustomerFilter, lowerSearch: string): bool =
  if f.activeOnly and not c.active: return false
  if f.country.len > 0 and c.country != f.country: return false
  lowerSearch.len == 0 or c.name.containsIC(lowerSearch) or
    c.email.containsIC(lowerSearch) or c.city.containsIC(lowerSearch)

proc keyString(c: Customer, col: CustomerColumn): string =
  case col
  of ccName: c.name.toLowerAscii
  of ccEmail: c.email.toLowerAscii
  of ccCity: c.city.toLowerAscii
  else: c.country.toLowerAscii

proc keyInt(c: Customer, col: CustomerColumn): int64 =
  case col
  of ccBalance: c.balance
  of ccCreated: int64(c.created)
  of ccActive: (if c.active: 0 else: 1)       # active first when ascending
  else: int64(c.id)

proc rebuildView*(s: var CustomerStore) =
  ## Re-runs the filter and the sort. Ties are broken by position (rows are in
  ## id order), so the order is total and a descending sort is the exact
  ## reverse of the ascending one. The sort keys are extracted once per row
  ## (lower-cased strings / integers) instead of compared through the objects.
  let low = s.filter.search.toLowerAscii
  s.view.setLen(0)
  for i in 0 ..< s.rows.len:
    if s.rows[i].matches(s.filter, low): s.view.add int32(i)
  let col = s.sortCol
  let desc = s.sortDesc
  case col
  of ccId:
    if desc: s.view.reverse()                        # rows are ascending by id
  of ccName, ccEmail, ccCity, ccCountry:
    var keyed = newSeqOfCap[tuple[k: string, i: int32]](s.view.len)
    for r in s.view: keyed.add (s.rows[r].keyString(col), r)
    keyed.sort(proc(a, b: tuple[k: string, i: int32]): int =
      result = cmp(a.k, b.k)
      if result == 0: result = cmp(a.i, b.i)
      if desc: result = -result)
    for n in 0 ..< keyed.len: s.view[n] = keyed[n].i
  of ccBalance, ccCreated, ccActive:
    var keyed = newSeqOfCap[tuple[k: int64, i: int32]](s.view.len)
    for r in s.view: keyed.add (s.rows[r].keyInt(col), r)
    keyed.sort(proc(a, b: tuple[k: int64, i: int32]): int =
      result = cmp(a.k, b.k)
      if result == 0: result = cmp(a.i, b.i)
      if desc: result = -result)
    for n in 0 ..< keyed.len: s.view[n] = keyed[n].i

# --------------------------------------------------------------- operations

proc initStore*(n: int, seed = 12345'u64): CustomerStore =
  result.rows = generateCustomers(n, seed)
  result.nextId = int32(n + 1)
  result.rebuildView()

func rowOf*(s: CustomerStore, id: int32): int =
  ## Position of the customer with this id in `rows` (binary search), or -1.
  var lo = 0
  var hi = s.rows.high
  while lo <= hi:
    let mid = (lo + hi) div 2
    let v = s.rows[mid].id
    if v == id: return mid
    if v < id: lo = mid + 1 else: hi = mid - 1
  -1

proc addCustomer*(s: var CustomerStore, c: Customer): int32 =
  ## Appends with a fresh id (the view is NOT rebuilt).
  result = s.nextId
  inc s.nextId
  s.rows.add c
  s.rows[^1].id = result

proc updateCustomer*(s: var CustomerStore, c: Customer): bool =
  let r = s.rowOf(c.id)
  if r < 0: return false
  s.rows[r] = c
  true

proc deleteCustomers*(s: var CustomerStore, ids: HashSet[int32]): int =
  ## Removes the customers with these ids; returns how many were removed.
  var kept = newSeqOfCap[Customer](s.rows.len)
  for c in s.rows:
    if c.id notin ids: kept.add c
  result = s.rows.len - kept.len
  s.rows = kept
