# nimvcl documentation

nimvcl is a Delphi VCL-style UI library for Nim 2.2, drawn with SDL3. If you
know `TForm`, `TButton`, `Align`, `Anchors` and `OnClick`, you already know most
of it. These pages are for Nim programmers who are new to the library. The visual
form designer built on it is [NimRAD](https://github.com/Vyrnexis/NimRAD). These
pages describe version 0.2.0 (see the [changelog](../CHANGELOG.md)); the source is
at <https://github.com/Vyrnexis/nimvcl>.

**Conventions.** Examples assume `import nimvcl` and a form named `form`:

```nim
import nimvcl
let form = newForm(nil, 480, 320)   # owner, width, height
```

Every control is created with `newXxx(parent, <main property>, ..., left, top,
width, height)`. All arguments are optional, and a size you leave out gives the
control's default size. The parent owns the control, so constructors are
`{.discardable.}`: `newLabel(form, "Hi", 10, 10)` works as a statement. Each component page has a quick example, then tables for
properties, events and methods.

## Guide

| Page | What it covers |
|---|---|
| [Getting started](getting-started.md) | Install, a first window, building and running tests |
| [Application and forms](guide/application-and-forms.md) | `Application.run`, forms, modal forms, host mode |
| [Imports and the prelude](guide/imports.md) | `import nimvcl` vs single modules, what `nimvcl/prelude` holds, its cost |
| [Forms and frames](forms.md) | The `form` and `frame` macros (a typed `.dfm`) |
| [Form files](guide/form-files.md) | `.nfm` text forms, `loadForm`, `loadNfm`, inheritance, the property registry and the property order |
| [Layout](guide/layout.md) | `align`, `anchors`, margins, padding, constraints, autoSize |
| [Events and input](guide/events-and-input.md) | Event types, keyboard, focus, disabled controls, mnemonics, shortcuts |
| [Docking](guide/docking.md) | Dock panels, floating windows, saving the layout |
| [Design mode](guide/designer.md) | `FormDesigner`: select, move, resize, create and undo on a form |
| [Actions](guide/actions.md) | One command shared by menus, toolbars, buttons and keys; releasing clients |
| [Threads and timers](guide/threads-and-timers.md) | `Timer`, `runOnUi`, `Application.queue`, idle work |
| [Painting and custom controls](guide/painting.md) | `Canvas`, `PaintBox`, subclassing `Control`, fonts and font families |
| [Theming](guide/theming.md) | Light and dark themes, tokens, HiDPI |

## Components

### Text and buttons

| Page | Components |
|---|---|
| [Label](components/label.md) | Static text with mnemonics |
| [Button](components/button.md) | Push button, default and cancel roles, icon |
| [CheckBox](components/checkbox.md) | Two or three state check box |
| [RadioButton](components/radiobutton.md) | One choice from a group |

### Input

| Page | Components |
|---|---|
| [Edit](components/edit.md) | Single-line text box, password mask |
| [Memo](components/memo.md) | Multi-line text editor |
| [CodeEdit](components/codeedit.md) | Source code editor: gutter, highlighting, folding, find bar, regex |
| [SpinEdit](components/spinedit.md) | Integer edit with up and down buttons |
| [ComboBox](components/combobox.md) | Edit or list with a drop-down, owner-drawn rows |
| [TrackBar](components/trackbar.md) | Slider |
| [ScrollBar](components/scrollbar.md) | Standalone scrollbar |

### Containers and layout

| Page | Components |
|---|---|
| [Panel and GroupBox](components/panel.md) | Grouping containers |
| [FlowPanel](components/flowpanel.md) | Wrapping row or column layout |
| [GridPanel](components/gridpanel.md) | Rows and columns with track sizes |
| [ScrollBox](components/scrollbox.md) | Scrolling container |
| [Splitter](components/splitter.md) | Resizable divider |
| [PageControl and TabControl](components/pagecontrol.md) | Tabs and pages |
| [DockSite and DockPanel](components/docksite.md) | Dock panels, tab groups, floating windows |
| [Frame](components/frame.md) | Reusable composite control |
| [Bevel](components/bevel.md) | Separator lines and frames |

### Display and drawing

| Page | Components |
|---|---|
| [PaintBox](components/paintbox.md) | Draw with `onPaint` |
| [Image](components/image.md) | `ImageControl` and the `Image` type |
| [ImageList](components/imagelist.md) | Numbered icons shared by controls, `ImageListRef` |
| [ProgressBar](components/progressbar.md) | Progress and busy indicator |
| [StatusBar](components/statusbar.md) | Text panels at the bottom |
| [Hint](components/hint.md) | Tooltips |
| [ObjectInspector](components/inspector.md) | Property grid for any registered object, editor dialogs, context menu and override hooks |

### Lists, trees and tables

| Page | Components |
|---|---|
| [ListBox](components/listbox.md) | One-line items, type-ahead, virtual mode |
| [ListView](components/listview.md) | Report, list and icon views, item images and checks, Items Editor |
| [TreeView](components/treeview.md) | Trees with lazy children, item images and checks, Items Editor |
| [DrawGrid and StringGrid](components/grids.md) | Cell tables, `cells`, `colWidths`, `rowHeights` |

### Menus, dialogs and non-visual

| Page | Components |
|---|---|
| [Menus](components/menus.md) | `MainMenu`, `PopupMenu`, `MenuItem` |
| [ToolBar](components/toolbar.md) | `ToolBar` and `ToolButton` |
| [Dialogs](components/dialogs.md) | Message boxes, input prompt, file dialogs |
| [Timer](components/timer.md) | Periodic `onTimer`, tick coalescing |

## Reference

| Page | What it covers |
|---|---|
| [Popups, menus and hints](popups-menus.md) | Popup windows, key-handler chain, modal details |
| [Form macro syntax](forms.md) | Every statement the `form` / `frame` macros accept |
| [Binding audit](dev/binding-audit.md) | Developer notes on the SDL3 binding |
| [Changelog](../CHANGELOG.md) | What each release added |
| `src/nimvcl/**/*.nim` | The module comments are the most detailed reference |

## Delphi to nimvcl cheat sheet

| Delphi | nimvcl |
|---|---|
| `Application.Run` | `Application.run(form)` |
| `Align := alClient` | `c.align = alClient` |
| `Anchors := [akLeft, akRight]` | `c.anchors = {akLeft, akRight}` |
| `Button.Default := True` | `button.isDefault = true` |
| `ShowMessage('x')` | `showMessage("x")` |
| `Form.ShowModal` | `form.showModal()` |
| `TTimer.Interval` | `newTimer(owner, interval)` |
| `Items.Add('x')` | `list.items.add "x"` (or `list.add "x"`) |
| `Sender as TButton` | `Button(sender)` |
| `Parent := Panel1` | pass the parent to the constructor, or `c.parent = panel` |
