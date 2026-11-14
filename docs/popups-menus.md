# Popups, menus and hints

Modules: `core/popup.nim` (popup windows), `controls/menus.nim`
(`MenuItem`, `PopupMenu`, `MainMenu`), `controls/hint.nim` (tooltips). The
umbrella must import `menus` and `hint` for shortcuts and hints to be active
(they register themselves with `Application.addEventObserver`).

## PopupWindow

`showPopup(owner, content, anchorRectInForm, placement, kind, parent)` opens a
borderless window next to an anchor rectangle (owner logical px). `content` is
a `Container` sized by the caller. It has its own `UiRoot` and `RenderContext`.

* Created with `SDL_CreatePopupWindow` (`WINDOW_POPUP_MENU` for menus,
  `WINDOW_TOOLTIP` for hints), offset relative to the owner window, so it
  works with `xdg_popup` on Wayland. A submenu is created as a child of the
  popup below it (offset relative to that popup), as `xdg_popup` grabs require.
* Placement flips to the other side when the preferred one does not fit in the
  display's usable bounds, then slides (`placePopup`). On Wayland clients do
  not know window positions, so only the anchor-relative position is used and
  the compositor constrains the popup.
* Where the driver cannot create popups (SDL `offscreen`: "not supported") the
  platform layer creates a borderless always-on-top utility window at the same
  place (`PlatformWindow.popupFallback`). The logic is identical; this is what
  the tests run on.
* Menu popups form a chain per owner. A press anywhere else closes the chain
  and is swallowed (the release still arrives, so no capture is left behind);
  keys go to the topmost popup (`content.doKeyDown`) whichever window SDL says
  has the focus; Esc closes the topmost; the owner losing the focus to a
  window outside the group closes all. Hiding/freeing the owner, starting a
  modal form and `Application.shutdown` close popups too.
* Popups of the modal form work; popups of gated forms ignore input.
* Tooltips are outside the chain and take no input.

| | Wayland | X11 | offscreen |
|---|---|---|---|
| window | xdg_popup (grabbing for menus) | override-redirect popup | fallback top-level window |
| keyboard focus | the popup | the owner | the fallback window |
| position/flip | compositor | our flip, owner position from SDL | our flip |

## Key handlers

`Form.addKeyHandler(id, hook)` chains handlers on `ui.onUnhandledKey` (keys the
focused control did not use). Default/cancel buttons (id "dialog") and menu
shortcuts (id "menus") use it. A hook set on `ui.onUnhandledKey` before is
kept and runs first.

## Menus

See the module comment of `controls/menus.nim`. `form.menu = mainMenu` (or
`newMainMenu(form)`) puts the bar at the top; `attachPopupMenu(control, menu)`
gives right-click / Shift+F10 / Menu key. Radio items: `radioItem` plus
`groupIndex` (clicking unchecks the others of the group in the same parent).

## Hints

`Application.showHint`, `Application.hintPause` (600 ms), `hintShortPause`
(100 ms, within `hintRecentWindow` 1000 ms of the last hint). Hides on leave,
click, wheel, key, focus loss; never while a menu is open.
