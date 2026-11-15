# PageControl and TabControl

`PageControl` is a tabbed container with one `TabSheet` per page (Delphi
`TPageControl` and `TTabSheet`). `TabControl` draws only the tab strip, and you
fill the area below yourself (Delphi `TTabControl`).

## Quick example

```nim
let pages = newPageControl(form, 16, 16, 420, 260)
let general = newTabSheet(pages, "&General")
let advanced = newTabSheet(pages, "&Advanced")

let opt = newCheckBox(general, "Start with the system", left = 12, top = 12)
let log = newCheckBox(advanced, "Verbose logging", left = 12, top = 12)

pages.onChange = proc(sender: Control) =
  echo "page ", PageControl(sender).activePageIndex
pages.activePage = advanced
```

A bare tab strip:

```nim
let tabs = newTabControl(form, @["One", "Two", "Three"], 16, 290, 420, 30)
tabs.onChange = proc(sender: Control) = echo TabControl(sender).tabIndex
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `tabIndex` / `activePageIndex` | int | Selected tab |
| `activePage` | `TabSheet` | Selected page (PageControl) |
| `pageCount`, `sheets()` | | The pages |
| `tabs` | `seq[string]` | TabControl captions; `addTab(caption)` appends |
| `showTabs` | bool | `false` hides the tab strip; pages are then switched by code only. Default `true` |
| `TabSheet.caption` | string | Tab text; `&` makes a mnemonic |
| `TabSheet.tabVisible` | bool | `false` hides the tab (like Delphi's `TabVisible`); default `true` |

## Events

| Event | Description |
|---|---|
| `onChange` | The selected tab changed |
| `onChanging(sender, allowChange: var bool)` | Before it changes; set `allowChange = false` to veto |

## Methods

| Method | Description |
|---|---|
| `newTabSheet(pc, caption)` | Add a page |
| `cycle(dir)` | Select the next (`1`) or previous (`-1`) tab |
| `tabAt(x, y)` | Tab under a point |

## Tips

* Create each page with `newTabSheet(pages, ...)` and put controls inside the
  sheet. Sheets are `alClient` containers. Only the active one is visible, so
  hidden pages are out of the tab order.
* The first sheet created becomes active.
* Ctrl+Tab and Ctrl+PageUp/Down switch pages while focus is inside the active
  page. Alt+letter selects a page by mnemonic (enabled sheets only).
* `sheet.tabVisible = false` hides a page's tab. A page without a tab cannot be
  reached by click, arrows or Ctrl+Tab (code can still pick it with
  `activePage`). Hiding the active page's tab moves to the next selectable page.
* `pages.showTabs = false` hides the whole strip, for wizards and "page stack"
  layouts that drive the pages from a list, a toolbar or code. The pages move up
  to fill the space and the control draws just its border. The user can no
  longer switch pages (no click, arrow keys, Ctrl+Tab or Alt+letter) and the
  control takes no focus; `activePage`, `activePageIndex`, `tabIndex` and
  `cycle` still work, and `onChange` still fires.
* Disabled pages cannot be selected by the user either.
* When tabs do not fit, small arrows appear to scroll the strip.

[Back to the index](../README.md)
