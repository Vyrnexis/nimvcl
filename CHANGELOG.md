# Changelog

All notable changes to nimvcl are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/). Before 1.0 the API can still change
between minor versions.

## [0.1.1] - 2026-11-18

### Fixed

- The bundled fonts now ship inside the nimble package (`src/nimvcl/assets`),
  so a project that installs nimvcl with nimble compiles.

## [0.1.0] - 2026-11-18

First release. There are no earlier versions.

### Added

- **Core.** A control tree with VCL-style properties and events (`align`,
  `anchors`, `margins`, `padding`, `constraints`, `autoSize`, `onClick` and
  friends); one SDL3 window per `Form`, modal forms and multiple windows; keyboard
  focus, `&` mnemonics and shortcuts; `Timer`; a thread-safe `Application.queue`
  and `runOnUi`; host mode to embed the UI in an existing SDL3 application.
- **Controls.** Label, Button, CheckBox, RadioButton, Panel, GroupBox, Edit, Memo,
  SpinEdit, ComboBox, ListBox, ListView, TreeView, DrawGrid, StringGrid,
  TrackBar, ProgressBar, ScrollBar, ScrollBox, Splitter, StatusBar, ToolBar,
  PageControl, TabControl, PaintBox, Image, Bevel and Frame. ListBox, ListView and
  grids have a virtual mode for millions of rows.
- **Layout.** VCL layout with `Align` and `Anchors` measured against the design
  size, plus `FlowPanel` and `GridPanel`.
- **Menus, hints and actions.** Main menu, popup menus, hints, `ActionList` and
  `Action` shared by menu items, tool buttons, buttons, check boxes and
  shortcuts, and `ImageList`.
- **Dialogs.** `showMessage`, `messageDlg`, `inputQuery` and native Open, Save and
  folder dialogs.
- **Forms.** The `form` and `frame` macros, which declare a form with typed fields
  for its controls and check every property at compile time.
- **Form files.** `.nfm` text forms. `loadForm` builds a typed form at compile time
  and needs only the light `nimvcl/dsl/formload` module (no property registry);
  `loadNfm` and `formToNfm` load and save at run time. Visual form inheritance
  with `inherited` blocks and handler overrides.
- **Property registry, inspector and designer.** A registry that plays the part of
  Delphi's RTTI; `ObjectInspector` with editors for colours, fonts, references,
  events, pictures, image lists, string lists and collections; `FormDesigner`
  (select, move, resize, snap, reparent, create, undo) and the editor and
  designer APIs the IDE needs.
- **Docking.** `DockSite` and `DockPanel` with split, tab and floating panels,
  drop guides, and saving and loading of layouts.
- **CodeEdit.** A source code editor with gutter (line numbers, fold markers,
  breakpoint and bookmark icons), incremental Nim syntax highlighting, code
  folding, bracket matching, find and replace with a built-in regex engine, line
  commands and markers; it opens a 100 MB file in about a second and handles
  files of 2 million lines.
- **Theming and colour.** Flat light and dark themes with HiDPI and fractional
  scaling. Delphi colour semantics: `color` is a control's background and
  `font.color` its text, both inherited through `parentColor` and `parentFont`;
  `Button` derives its face, hover and pressed shades from its own color. Text
  colours can follow the theme by role (`textRole`, `muted`).
- **Fonts.** Noto Sans and Noto Sans Mono embedded in the executable (opt out with
  `-d:nimvclNoEmbedFonts`); system font families through fontconfig;
  `registerFontFamily` and `registerFontFamilyData` for project fonts; an
  automatic CJK fallback font.
- **Painting.** `Canvas` with partial repainting through a per-form backbuffer and
  dirty rectangles, and PNG and BMP screenshots that need no visible window.
- **Documentation and tests.** A getting-started page, guide pages, one page for
  each component, a gallery and demo programs, and a headless test suite
  (`nimble test`).

[0.1.1]: https://github.com/Vyrnexis/nimvcl/releases/tag/v0.1.1
[0.1.0]: https://github.com/Vyrnexis/nimvcl/releases/tag/v0.1.0
