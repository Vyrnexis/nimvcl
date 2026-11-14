# nimvcl

A Delphi VCL-style UI library for Nim, drawn entirely with SDL3.

**Status:** phases 0-4 (graphics, core, basic controls, `form` macro) are done
and phase 5 (the standard control set) is nearly done: ComboBox and Memo are
the last pieces. The API can still change. See [PLAN.md](PLAN.md).

## Features

- Control tree with VCL-style properties and events: `align`, `anchors`,
  `margins`, `padding`, `constraints`, `autoSize`, `onClick` and friends.
- Flat light and dark themes, HiDPI and fractional scaling, one SDL3 window per
  `Form`, modal forms, multiple windows, `Timer`, `Application.queue`.
- Host mode: embed the UI in an existing SDL3 application.
- Controls: Label, Button, CheckBox, RadioButton, Panel, GroupBox, Edit
  (selection, undo, clipboard, IME), ListBox, ScrollBar and ScrollBox,
  SpinEdit, TrackBar, ProgressBar, Splitter, StatusBar, ToolBar, PageControl and
  TabControl, FlowPanel and GridPanel, PaintBox, Image, Bevel, Frame.
- Main menu, popup menus, hints, `&` mnemonics, shortcuts.
- Dialogs: `showMessage`, `messageDlg`, `inputQuery`, native Open, Save and
  folder dialogs.
- A `form` macro that declares a form with typed fields for its controls.

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

`import nimvcl` brings in everything; single modules can be imported instead
(`nimvcl/controls/listbox`, ...).

## Requirements

- Nim 2.2+
- SDL3, SDL3_ttf, SDL3_image (Arch: `pacman -S sdl3 sdl3_ttf sdl3_image`)
- [nim-lang/sdl3](https://github.com/nim-lang/sdl3) (installed by nimble)

## Demos

```
nim c -r examples/std_demo.nim        # the phase 5 controls
nim c -r examples/menu_demo.nim       # menus, popups, hints
nim c -r examples/controls_demo.nim   # basic controls
nim c -r examples/login_demo.nim      # the login form, keyboard only
nim c -r examples/list_demo.nim       # ListBox and ScrollBox
nim c -r examples/edit_demo.nim       # Edit
```

(`nimble install -d` first; `nim.cfg` already puts `src` on the path.)

## Tests

```
nimble test
```

or one file: `SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software nim c -r tests/tlistbox.nim`.
The tests run headless on SDL's offscreen video driver with the software
renderer, so no window opens. Popups use their top-level fallback there.

## Documentation

[docs/forms.md](docs/forms.md) (the form macro),
[docs/popups-menus.md](docs/popups-menus.md) (popups, menus, hints, key
handlers, mnemonics, modal forms). Every module starts with a comment that
documents its behaviour.

## Licence

MIT
