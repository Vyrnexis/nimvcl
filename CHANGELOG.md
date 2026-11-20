# Changelog

All notable changes to nimvcl are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/). Before 1.0 the API can still change
between minor versions.

## Unreleased

### Fixed

- The numpad Enter key arrives as Enter (default buttons, Edit, CodeEdit, grids
  handled only the main Enter key). (N19)
- The first use of a system font family no longer waits for a listing of every installed font: on Linux/BSD `fc-list` is asked for that family only; the Windows/macOS font folder scan is cached in the user's cache folder (`nimvcl/fontscan.tsv`). Replaced `registerFontFamilyData` bytes are freed once no rendering context can read them (they were kept forever). (Q7)
- `Application.shutdown` frees the windows modal forms first, then the others in reverse order of creation. (N22)
- Closing the main form first closes the other open forms (`onCloseQuery`, `onClose`); one that stays open cancels the close. A form closed with `caFree` fires `onHide`. (N21)
- A form released with `caFree` stops the `Timer`s it owns (they kept firing after the window was gone). (N23)
- A form's `constraints` reach the OS window (`PlatformWindow.setMinSize` / `setMaxSize`), so the window manager no longer lets the user resize below the minimum and the form does not fight back. (N20)
- Compiling with `--mm:refc` or `--mm:markAndSweep` is now a compile-time error where `runOnUi` / the file dialog callbacks are used (they are only safe under ORC/ARC). (N44)
- A Defect (index error, assertion) in an event handler, queued job, idle
  hook or paint no longer ends the application: it goes to `onException`, or
  without one it is logged to stderr and the loop continues. Set
  `Application.reraiseDefects = true` for the old behaviour. (N1)
- A queued job that opens a modal dialog no longer holds back the jobs queued
  after it (worker results stalled behind a message box). (N8)
- Saving a form writes an object reference (`focusControl`, `popupMenu`, `images`,
  `action`, `menu`...) only when its target is in the saved tree; a deleted
  component no longer makes a file that fails to load. (N2)
- `CodeEdit.saveToFile` / `CodeModel.saveFile` write to a temporary file with
  checked writes and replace the target only on success; a failure raises
  IOError and the text stays modified. `saveToFile(path)` now renames through
  `fileName=` (the language follows). New `saveCopyTo(path)` and
  `CodeModel.saveCopy` write a copy without renaming or marking saved. (N3)
- `CodeEdit.loadFromFile` reads the file before it changes the name or the
  highlighter, so an unreadable file leaves the editor as it was. (N4)
- The designer's `uniqueName` also looks at components owned by other
  components (menu items, a timer in a panel) and compares names like Nim
  identifiers (`Button_1` is `Button1`), so new names cannot collide. (N6)
- The inspector no longer lists `name` when several objects are selected
  (they would all get the same name and the form file would not load). (N5)
- The inspector refuses a component name or a handler name the form file cannot
  hold (`end`, `object`, `inherited`, `true`, `false`, spaces, a leading digit;
  an empty component name). New `validNfmName` in `nimvcl/dsl/nfmsyntax`. (N7)
- `DockSite.loadLayout` checks the whole text first (version, shape, at least
  one known panel) and cancels a tab drag in progress; if the rebuild still
  fails half way, the previous layout is put back and it returns false. (N9)
- Floating dock windows are moved onto a display when restored (a saved place
  may be off every display after a monitor change), and `saveLayout` leaves
  out window positions where the origin is unknown (Wayland). New
  `PlatformWindow.clampToDisplay`. (N10)
- A `PopupMenu` is released with its owner: `Control.free` of the owner takes
  it out of the form's popup menus (its shortcuts no longer fire) and unlinks
  its actions. (N11)
- The Nim highlighter closes a pragma on a bare `}` too (`{.inline}`), no longer
  colouring the following lines as pragma. (N12)
- CodeEdit markers: those on lines deleted as a whole (selection delete, cut,
  Delete Line) are dropped instead of piling onto the next line, a line joined
  into the previous one loses its markers, Alt+Up/Down carry the markers of the
  moved lines, and undo/redo put the markers of the edit back. New
  `CodeModel.onSplice` hook (called before every raw replacement). (N13)
- Replace All edits line by line from the bottom up in one undo step, so
  markers and collapsed folds of the lines between the matches survive (and
  undo no longer keeps one huge span). Very large replacements still use one
  edit. (N14)
- Indent folds (Nim, Python...) ignore comment-only lines and the lines inside
  multi-line strings and comments when a highlighter is attached, so a
  column-0 comment no longer ends the open regions. (N15)
- Enter after `if x:  # comment` indents like `if x:` (the last code token
  decides, a comment behind the caret is looked through). (N16)
- CodeModel / CodeEdit keep a UTF-8 BOM (`hasBom`, `LoadReport.bom`) and write it
  again on save; a lone `\r` is a line break on load (`LoadReport.loneCr`),
  like other editors; Delete Line and Alt+Up/Down leave the empty line after
  the last line break alone, so the trailing newline of the file stays. (N17)
- CodeEdit: Alt+Backspace deletes the word before the caret. (N18)
- CodeEdit paint no longer copies the text of every visible line, the find
  bar matches of the visible lines are cached until the text, the lines shown
  or the search change, and a mouse drag that does not change the selection no
  longer runs the whole `touched` update (find recount, IME, events) per mouse
  move. (Q4)
- The undo history of CodeModel and MemoModel is also capped by stored text
  (64 MB, `maxUndoBytes=`) and drops its oldest steps without moving the whole
  history on every edit. (Q8)

## [0.2.1] - 2026-11-20

### Fixed

- PageControl measured its tabs from the sheet captions and ignored a
  subclass's `tabText`, so extra tab text (NimRAD's room for a close button)
  was drawn over. The new `sheetTabText` method is the one place a
  PageControl's tab text comes from.

## [0.2.0] - 2026-11-20

### Added

- `ObjectInspector`: a right click selects the row under the cursor, and
  `onContextMenu(prop, point)` lets the host show its popup for that row;
  `isOverridden(prop)` (host predicate, cached per row) draws properties that
  differ from the ancestor's value with a bold name.
- `unregisterFontFamily(name)` drops a registered family and flushes the cached
  fonts and texts that used it (a replaced bundled family comes back).
- Design-time gaps closed (Object Inspector, form files, `loadForm`):
  `StringGrid.cells` with a cell editor dialog, `colWidths` / `rowHeights`;
  `Edit.passwordChar`; `Button.images`, `imageIndex` and `imageAlignment`
  (an icon next to the caption); `Form.menu` and `Form.icon` (window icon);
  per-item images and check boxes for `ListView` and `TreeView`
  (`itemImages`, `itemSelectedImages`, `checkedItems`) with an items editor
  dialog (Add, Add child, Indent, Outdent, Up, Down).
- Property registry: `hide a, b` keeps a stored property out of the inspector.
- `ObjectInspector.setValue` also sets properties the inspector does not list.
- `propdeps`: one table of property dependencies (`tabIndex` after `tabs`,
  `cells` after `colCount` ...) shared by the registry, `loadNfm` and the
  compile-time `loadForm`, so a form file loads the same in any property order.
- `TrackBar` handles the mouse wheel when focused.

### Changed

- A disabled control (or one inside a disabled container) swallows mouse input
  instead of passing it to what lies below it, as in the VCL.
- `ComboBox` owns its items and its committed index (`items` is a
  `ComboItems`); the drop-down list is a view made for each opening.
- `ListBox`, `ListView`, `TreeView` and `DrawGrid` share row navigation,
  selection updates and the in-place editor (`rowview`), and the first three
  share type-ahead; the drag auto-scroll is shared too.
- System fonts are listed by one `fc-list` run (was `fc-match` per family).
- `StatusBar.simpleText` keeps the panels, and the size grip only takes room
  with `sizeGrip`; `FlowPanel` and `ToolBar` skip layout for unchanged values.

## [0.1.4] - 2026-11-19

Fixes from a full code review: logic first, then structure and speed.

### Fixed

- Regex search: patterns with nested repetition (`(a|aa)+$`) no longer take
  seconds or minutes; groups that can match empty (`(a*)*b`) now match.
  Whole word works with patterns that start or end with punctuation.
- Find: F3 and Replace move past an empty match; Find Previous no longer skips
  positions.
- Undo past a save point followed by a new edit no longer reports the text as
  unmodified.
- Object Inspector: leaving an unchanged editor no longer writes it back (a
  mixed multi-selection value was wiped), and committing on blur no longer
  steals focus from the clicked control.
- Form files: `TabControl.tabIndex` and other properties that depend on
  others survive save and load (properties can declare `after` dependencies);
  NaN/inf and out-of-range integers are rejected with a clear error; an
  inherited control under a non-inherited parent is rejected.
- Designer: Esc during a rubber band restores the selection; a second button
  during a drag no longer corrupts it; undo after restoring a deleted
  container works; pictures are copied into the project only on OK.
- A modal opened from a mouse handler no longer leaves capture stuck; a click
  is not delivered to a control the mouse-up handler removed.
- Freeing a control stops the timers it owns; SDL timer events are coalesced.
- `Button.modalResult` is set before `onClick`, so a handler can veto it.
- Actions: freeing an Action or ActionList restores upgraded tool buttons;
  `onUpdate` handlers may change the lists safely.
- Docking: Ctrl+Tab reaches a PageControl inside a dock panel; appending to a
  group lands last; an emptied floating window is freed after its event.
- A freed PopupMenu no longer keeps firing its shortcuts.
- StringGrid: row heights follow insert, delete and sort.
- TreeView: `selectNode` respects a refused expansion; paint no longer
  changes layout.
- ListView: deleting an unselected, unfocused item no longer fires onChange.

### Changed

- Replace all builds the new text once: one edit and one undo step (40k
  lines: 29 s to under 0.1 s).
- Layout no longer repaints the whole form; font resolution is cached and
  fallback fonts open only for non-ASCII text.
- Action updates run from a registry of action lists instead of walking every
  form after each event batch.
- Tab strips, grid sorting, multi-selection and the Object Inspector paint
  path avoid repeated work.
- Shared code: `textutil` (UTF-8 and word helpers), `ClickableControl`
  (hover/press/activation for Button, CheckBox, RadioButton, ToolButton),
  `ImageListRef` (one image-list subscription for all controls),
  `indexset` (selection as sorted runs).

## [0.1.3] - 2026-11-19

### Added

- Windows and macOS support (experimental), with CI jobs for both. System
  fonts are found by scanning the platform font folders and reading each
  file's name table; the bundled Noto fonts work everywhere.
- On macOS the Command key acts as Ctrl for shortcuts.
- macOS builds link SDL3, SDL3_ttf and SDL3_image at build time (`nim.cfg`),
  since dyld does not find Homebrew's libraries by bare name.

### Fixed

- `importPicture` stored an absolute path for a file on another drive.
- An `.nfm` `ancestor` path written with `\` is read as `/`.
- `.gitattributes` keeps LF line endings in checkouts on Windows.

## [0.1.2] - 2026-11-19

### Added

- `nimvcl/prelude`: the modules handler code needs without importing a
  component (core control/form/application, `controls/common`, the standard
  dialogs, `core/timer`, colours and fonts). `scripts/prelude_cost.sh` measures
  its compile cost.

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

[0.1.2]: https://github.com/Vyrnexis/nimvcl/releases/tag/v0.1.2
[0.1.1]: https://github.com/Vyrnexis/nimvcl/releases/tag/v0.1.1
[0.1.0]: https://github.com/Vyrnexis/nimvcl/releases/tag/v0.1.0
[0.1.3]: https://github.com/Vyrnexis/nimvcl/releases/tag/v0.1.3
[0.1.4]: https://github.com/Vyrnexis/nimvcl/releases/tag/v0.1.4
[0.2.0]: https://github.com/Vyrnexis/nimvcl/releases/tag/v0.2.0
