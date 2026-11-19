## Which properties must be applied after which others, by property name.
##
## One table for both loaders: the property registry (`props`, run-time
## loader, writer, inspector) orders a class's properties with it, and the
## compile-time `loadForm` (which does not import the registry) orders the
## properties of every object of a form file with it, so a file written in any
## order loads the same. It depends on nothing, so it costs no compile time.
##
## A dependency names properties that an object may not have (`text` after
## `itemIndex` for a class without an `itemIndex`): those are ignored.

const propDeps*: array[12, (string, seq[string])] = [
  ("tabIndex", @["tabs"]),                       # a page must exist before it is selected
  ("itemIndex", @["items"]),                     # ... likewise a list row
  ("text", @["itemIndex"]),                      # an edit text overrides the selected row's
  ("value", @["minValue", "maxValue"]),          # values are clamped to the range
  ("position", @["min", "max", "pageSize"]),
  ("cells", @["colCount", "rowCount"]),          # grid cells outside the grid are dropped
  ("colWidths", @["colCount", "defaultColWidth"]),
  ("rowHeights", @["rowCount", "defaultRowHeight"]),
  ("itemImages", @["items"]),                    # per-item data needs the items
  ("itemSelectedImages", @["items"]),
  ("checkedItems", @["items", "itemImages", "propagateChecks"]),
  ("imageIndex", @["images"])]

proc depsOf*(name: string): seq[string] =
  ## The properties that are applied before `name`.
  for (n, d) in propDeps:
    if n == name: return d

proc place(names: seq[string], i: int, state: var seq[int], order: var seq[int]) =
  if state[i] != 0: return
  state[i] = 1
  for dep in depsOf(names[i]):
    for j in 0 ..< names.len:
      if names[j] == dep:
        place(names, j, state, order)
        break
  state[i] = 2
  order.add i

proc applyOrder*(names: seq[string]): seq[int] =
  ## The indexes of `names` in the order the properties are applied: each one
  ## behind those it depends on (`propDeps`), otherwise in the given order. A
  ## dependency cycle keeps the given order.
  var state = newSeq[int](names.len)     # 0 new, 1 being placed, 2 placed
  for i in 0 ..< names.len: place(names, i, state, result)
