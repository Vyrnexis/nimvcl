# nimvcl

A Delphi VCL-style UI library for Nim 2.2, drawn entirely with SDL3 (Linux
first). Forms, `Align` and `Anchors`, `onClick` events, actions, menus, and a
`form` macro that works like a `.dfm` checked by the compiler.

**Status:** early. The API can still change. See [PLAN.md](PLAN.md) for the
architecture and roadmap.

![The nimvcl showcase: buttons and choices](docs/images/showcase-buttons.png)

<p>
<img src="docs/images/showcase-listview-dark.png" width="32%" alt="ListView in the dark theme">
<img src="docs/images/showcase-bigdata.png" width="32%" alt="A virtual ListView over 100,000 rows">
<img src="docs/images/showcase-painting.png" width="32%" alt="Custom painting on a PaintBox">
</p>

Run the gallery yourself: `nim c -r examples/showcase.nim`.

## Features

- Control tree with VCL-style properties and events: `align`, `anchors`,
  `margins`, `padding`, `constraints`, `autoSize`, `onClick` and friends.
  Anchors are relative to the design size, so they also work when a tiling
  window manager resizes the window first.
- Flat light and dark themes, HiDPI and fractional scaling, one SDL3 window per
  `Form`, modal forms, multiple windows.
- Host mode: embed the UI in an existing SDL3 application.
- Controls: Label, Button, CheckBox, RadioButton, Panel, GroupBox, Edit, Memo,
  SpinEdit, ComboBox, ListBox, ListView, TreeView, DrawGrid and StringGrid,
  TrackBar, ProgressBar, ScrollBar, ScrollBox, Splitter, StatusBar, ToolBar,
  PageControl and TabControl, FlowPanel, GridPanel, PaintBox, Image, Bevel,
  Frame.
- Main menu, popup menus, hints, `&` mnemonics, shortcuts.
- `ActionList` / `Action`: one command shared by menu items, tool buttons,
  buttons, check boxes and shortcuts.
- Dialogs: `showMessage`, `messageDlg`, `inputQuery`, native Open, Save and
  folder dialogs.
- `Timer`, `ImageList`, and a thread-safe `Application.queue` / `runOnUi`.
- A `form` macro that declares a form with typed fields for its controls.

## Example

```nim
import nimvcl

form MainForm:
  caption = "Demo"; width = 400; height = 300
  Button okBtn:
    caption = "&OK"; align = alBottom
    onClick = proc(sender: Control) = showMessage("Hello")

when isMainModule:
  Application.run(newMainForm())
```

The same without the macro:

```nim
import nimvcl

let form = newForm(nil, 400, 300)
form.caption = "Demo"
let ok = newButton(form, "&OK")
ok.align = alBottom
ok.onClick = proc(sender: Control) = showMessage("Hello")
Application.run(form)
```

`import nimvcl` brings in everything. Single modules can be imported instead
(`nimvcl/controls/listbox`, ...).

## Requirements

- Nim 2.2+
- SDL3, SDL3_ttf, SDL3_image (Arch: `pacman -S sdl3 sdl3_ttf sdl3_image`)
- [nim-lang/sdl3](https://github.com/nim-lang/sdl3) (installed by nimble)

Other distros and the `requires` line are in
[Getting started](docs/getting-started.md).

## Documentation

Start at the [documentation index](docs/README.md).

- [Getting started](docs/getting-started.md): install, first window, tests.
- Guide: [application and forms](docs/guide/application-and-forms.md),
  [layout](docs/guide/layout.md),
  [events and input](docs/guide/events-and-input.md),
  [actions](docs/guide/actions.md),
  [threads and timers](docs/guide/threads-and-timers.md),
  [painting](docs/guide/painting.md), [theming](docs/guide/theming.md),
  [the form macro](docs/forms.md).
- Components: one page each, from [Label](docs/components/label.md) to
  [TreeView](docs/components/treeview.md); see the
  [component list](docs/README.md#components).
- Every module starts with a comment that documents its behaviour.

## Demos

```
nim c -r examples/settings_demo.nim   # a preferences app using (nearly) every control
nim c -r examples/std_demo.nim        # the standard controls
nim c -r examples/menu_demo.nim       # menus, popups, hints
nim c -r examples/controls_demo.nim   # basic controls
nim c -r examples/login_demo.nim      # the login form, keyboard only
nim c -r examples/list_demo.nim       # ListBox and ScrollBox
nim c -r examples/edit_demo.nim       # Edit
nim c -r examples/memo_demo.nim       # Memo
nim c -r examples/grid_demo.nim       # DrawGrid and StringGrid
nim c -r examples/views_demo.nim      # TreeView and ListView
```

(`nimble install -d` first; `nim.cfg` already puts `src` on the path.)

## Tests

```
nimble test
```

or one file: `SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software nim c -r tests/tlistbox.nim`.
The tests run headless on SDL's offscreen video driver with the software
renderer, so no window opens. Popups use their top-level fallback there.

## Licence

MIT
