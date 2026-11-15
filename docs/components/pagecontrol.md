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
| `TabSheet.caption` | string | Tab text; `&` makes a mnemonic |

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
* When tabs do not fit, small arrows appear to scroll the strip.

[Back to the index](../README.md)
