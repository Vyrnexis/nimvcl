# nimvcl: plan

A Delphi VCL-style UI library for Nim, drawn entirely with SDL3.

Status: phases 0-6 are done (the MVP, the standard set and the business set),
and a deep review round has landed on top of them. Phases 7-9 (editor set,
designer, reach) have not started. See "Progress and deviations" and "Open
issues" at the end.

## 1. Goal

Make desktop apps in Nim the way you make them in Delphi. The app is a tree of
controls with properties and `onClick`-style events. Layout comes from `align`
and `anchors`, and painting goes through a `Canvas`. Forms are declared once in
a typed `form` block.

```nim
form MainForm:
  caption = "Demo"; width = 400; height = 300
  Panel top:
    align = alTop; height = 40
    Button okBtn:
      caption = "OK"; align = alRight
      onClick = proc(sender: Control) = self.status.caption = "Clicked"
  Label status:
    align = alClient

when isMainModule:
  Application.run(newMainForm())
```

### Decisions made
| Topic | Decision |
|---|---|
| Name | `nimvcl` (free on Nimble) |
| Binding | [nim-lang/sdl3](https://github.com/nim-lang/sdl3), the official binding (Nimble `sdl3`), with its `sdl3_ttf` and `sdl3_image` modules |
| Platforms | Linux first (Wayland and X11). Code stays portable; Windows and macOS are verified later |
| Look | One theme of our own, flat, in light and dark. Themes can be swapped; no imitation of native looks |
| Licence | MIT |
| Forms | `form` macro now. A text form format and a visual designer come in a later phase |
| Rendering | `SDL_Renderer` behind a `Canvas` abstraction; an SDL_GPU backend later |
| App loop | Either `Application.run` owns the loop, or a **host mode** embeds the UI in an existing SDL3 app |
| Scope | Eventually tools, business apps, editors and overlays, so the core must not block any of them |

### Non-goals (for now)
- Native OS widgets. Every control is drawn by nimvcl.
- Copying VCL names one to one. We keep the concepts but use Nim naming (`Button`, not `TButton`).
- CSS, HTML or a browser engine.
- Animation frameworks, beyond a basic timer and redraw.

## 2. Architecture

```
app code / form macro
        │
  controls/         Button, Edit, ListBox, ... (one module each)
        │
  core/             Component, Control, Container, Form, Application,
                    events, focus, mouse capture, invalidation, layout, theme
        │
  graphics/         Canvas, Font, TextLayout (TTF_Text), Image, Color
        │
  platform/         windows, event pump, display scale, clipboard, cursors,
                    timers, cross-thread queue, file dialogs (SDL3 calls only)
        │
  sdl3 (nim-lang/sdl3) + sdl3_ttf + sdl3_image
```

Rule: only `platform/` and `graphics/` import `sdl3`. That keeps the backend
replaceable (SDL_GPU, tests) and stops SDL types from leaking into the public API.

### 2.1 Object model (VCL to nimvcl)
| VCL | nimvcl |
|---|---|
| `TComponent` | `Component`: a name, an owner, non-visual (Timer, ActionList) |
| `TControl` / `TGraphicControl` | `Control`: bounds, visible, enabled, hint, cursor, font, colors, events, `paint` method |
| `TWinControl` | `Container` (a `Control` with children): tab order, focus inside it, padding |
| `TCustomControl` | Any `Control` overriding `paint(c: Canvas)` |
| `TForm` | `Form`: owns one SDL window and its renderer. Modal and modeless |
| `TApplication` | `Application`: the event loop, forms, timers, `queue` |

- `ref object of RootObj` with `method` for virtual behaviour (`paint`,
  `mouseDown`, `keyDown`, `measure`, ...).
- Properties are Nim getter and setter procs (`proc caption=(b: Button, v: string)`).
  A setter calls `invalidate()` or `relayout()` itself.
- Events are closure fields, `onClick: proc(sender: Control)`, nil by default.
  Controls call protected `doClick` / `doChange`, which fire the field.
- The parent/children cycle is left to ORC. Profile in phase 2 before trying
  anything like `{.cursor.}`.

### 2.2 Event loop
- Single UI thread, like VCL. No user code runs on other threads.
- `Application.run` blocks in `waitEvent` (zero CPU when idle). It turns each
  SDL event into a control event, then repaints any form marked dirty.
- **Timers**: `Timer` component. SDL's timer callback pushes a user event, so
  the handler runs on the UI thread.
- **Cross-thread**: `Application.queue(proc)`, like `TThread.Queue`. A locked
  queue plus `pushEvent` to wake the loop.
- **Modal**: `form.showModal()` runs a nested loop until the form closes, then
  returns `ModalResult`.
- **Host mode**: `let host = newHost(window, renderer)`.
  `host.handleEvent(ev): bool` returns true when the UI consumed the event, and
  `host.paint()` draws into the caller's renderer.
  `Application.run` is built on the same pieces.

### 2.3 Input
- Mouse: hit test from the topmost control down, hover enter and leave, capture
  while a button is held, double-click, wheel, cursor shape per control.
- Keyboard: focus, Tab and Shift+Tab order, a default and a cancel button
  (Enter and Esc), accelerators (`&File`), shortcuts through actions (phase 7).
- Text: `startTextInput` and stop per focused editor, `TEXT_INPUT`, IME
  `TEXT_EDITING` with the composition shown inline, IME candidate rectangle via
  `setTextInputArea`.

### 2.4 Graphics
- Coordinates are **logical pixels** (float32). `Canvas` multiplies by the
  window's display scale. Windows use `WINDOW_HIGH_PIXEL_DENSITY`. Fonts are
  rasterised at `pt × scale`, so text stays sharp at 125%, 150% and 200%
  (Wayland fractional scaling). The `DISPLAY_SCALE_CHANGED` event relayouts the
  form and rebuilds its fonts.
- `Canvas` API in the spirit of `TCanvas`: `fillRect`, `frameRect`,
  `roundRect` (filled or stroked, anti-aliased through `renderGeometry`),
  `line`, `polygon`, `ellipse`, `drawImage`, `textOut`, `textRect` (wrap,
  align, ellipsis), `measureText`, a clip stack, and a translate stack.
- Text uses the SDL_ttf 3 **renderer text engine** (`createText` /
  `drawRendererText`), which caches glyphs and shapes text with HarfBuzz. Each
  control caches its `Text` objects and rebuilds them only when the string,
  font or wrap width changes.
- Default font: bundle one OFL font (for example Inter or Noto Sans) with a
  fallback chain via `addFallbackFont` for symbols, CJK and emoji. Use
  fontconfig lookup on Linux when it is available.
- Painting: a `Form` repaints only its dirty regions into a persistent
  backbuffer texture; popups and `Host` redraw fully.

### 2.5 Layout (VCL semantics)
- `align`: `alNone, alTop, alBottom, alLeft, alRight, alClient, alCustom`.
  Siblings are processed in VCL order: top, bottom, left, right, then client,
  each shrinking the remaining rectangle.
- `anchors` (`{akLeft, akTop, akRight, akBottom}`) for `alNone` controls; when
  the parent resizes, anchored edges keep their distance. Anchors are relative
  to the DESIGN size (VCL): a container's design size is the size it was given
  explicitly (`setBounds`/`width=`/`height=` outside a layout) before its first
  layout, else its size at its first layout; window-manager resizes (host
  driven, `hostSized`) never count, so a tiling WM that resizes the window
  before the first layout still moves/stretches anchored children. Each child
  keeps the rect it was last placed at explicitly plus the parent size it
  belongs to (children added after the first layout are relative to the size
  at that moment). Positions are computed as design rect + TOTAL size change,
  never incrementally, so repeated resizes do not drift and returning to the
  design size restores the design positions exactly. Children with the default
  anchors `{akLeft, akTop}` are never touched.
- `margins` per child and `padding` on the parent. `constraints` (min and max
  width and height). `autoSize`, where the control reports `measure()`.
- Later containers: `FlowPanel` and `GridPanel` (phase 6), `Splitter`.
- **The layout code is pure Nim with no SDL**, so it can be unit tested exactly.

### 2.6 Theme
- A `Theme` object of tokens: colors (window, surface, text, muted, accent,
  border, focus ring, selection, danger), metrics (radius, border width, control
  height, spacing) and fonts.
- `themeLight`, `themeDark` and `Application.theme = ...` switch at runtime.
- A per-control `style` can override a token. Each control draws itself only
  from tokens, never from hard-coded colors.

### 2.7 Resource ownership
- SDL handles (`Texture`, `Font`, `Text`) are wrapped in Nim objects with
  `=destroy` hooks, **but** they must be freed on the UI thread and before their
  renderer. So each `Form` keeps a registry of what it owns and frees it
  explicitly on close; the hooks only check that this happened. This is the
  riskiest point in the core design, so it is decided and tested in phase 1.
- Controls themselves are plain ORC refs. Things that hold clients strongly
  from outside (an `Action`'s links, an `ImageList`'s listener closures) are
  released by `Control.free` (and `PopupMenu.free`, `MenuItem.delete/clear`).

## 3. Repository layout

```
nimvcl/
  nimvcl.nimble           requires "nim >= 2.2", "sdl3 >= 1.1"
  src/nimvcl.nim          umbrella import
  src/nimvcl/
    platform/  sdlapp.nim  window.nim  clipboard.nim  timers.nim  dialogs.nim
    graphics/  canvas.nim  font.nim  text.nim  image.nim  color.nim
    core/      component.nim  control.nim  container.nim  form.nim
               application.nim  events.nim  focus.nim  layout.nim  theme.nim
               host.nim
    controls/  label.nim  button.nim  edit.nim  checkbox.nim  ...
    dsl/       formmacro.nim
  assets/fonts/           bundled OFL font plus its licence
  examples/               one runnable demo per phase
  tests/                  layout unit tests, headless render tests
  docs/
```

## 4. Testing
- **Unit tests**: layout, text-edit model (cursor, selection, undo), focus
  order, and the form macro's expansion. Pure Nim, run with `nimble test`.
- **Headless rendering tests**: `SDL_VIDEO_DRIVER=offscreen` plus the software
  renderer. Render a form, read the pixels back, and compare against golden PNGs
  with a small tolerance.
- **Event tests**: inject synthetic SDL events (`pushEvent`) and assert the
  callbacks and the state.
- **Examples**: each phase ends with a demo you can run, then a manual check on
  Wayland (nimdow-wl) and on X11.
- CI: GitHub Actions on Ubuntu with SDL3 from source or a PPA, running the tests
  headless.

## 5. Phases

Each phase ends with something you can run, plus tests. The sizes are rough.

**Phase 0: setup and spike (small)** (done)
- Create the repo, the nimble file, CI, the MIT licence and a README.
- Spike: a window with HiDPI, `waitEvent`, one `Text` drawn, and a rounded rect
  drawn with `renderGeometry`, at 100% and at a fractional scale.
- Audit nim-lang/sdl3 for any missing or wrong declarations; fix them upstream
  with a PR if needed.
- *Done when:* the spike looks sharp at 1×, 1.5× and 2× on Wayland, and idle CPU is about 0%.

**Phase 1: graphics (small to medium)** (done)
- `Canvas`, `Font` (with fallback), `TextLayout`, `Image` (sdl3_image), colors,
  the clip and translate stacks.
- Settle the resource ownership rules (§2.7).
- *Done when:* `examples/canvas_demo` draws every primitive and text sample, and
  the headless golden tests pass.

**Phase 2: core (medium to large)** (done)
- `Component`, `Control`, `Container`, `Form`, `Application`, `Host`.
- Mouse routing, hover, capture, cursors, focus, tab order, invalidation and
  repaint, VCL layout, `Theme`, `Timer`, `Application.queue`, `showModal`,
  multiple windows.
- *Done when:* the layout tests cover align order, anchors, margins,
  constraints and autoSize; the demo shows nested panels resizing correctly;
  and host mode works inside a plain SDL3 example loop.

**Phase 3: basic controls (medium)** (done)
- `Label`, `Button` (default, cancel, flat), `CheckBox`, `RadioButton` (grouped),
  `Panel`, `GroupBox`, `PaintBox` (`onPaint`), `Image`, `Bevel`.
- `Edit`: one line, selection, clipboard, undo, password mode, placeholder, IME.
- *Done when:* a login-form demo is fully usable with the keyboard alone.

**Phase 4: the `form` macro (medium)** (done)
- Generates a `Form` subtype with typed fields for each named child, a
  constructor, property assignments, event closures with `self`, and nested
  children.
- Gives clear compile errors for unknown properties.
- *Done when:* the phase 3 demo is rewritten with the macro at about the same
  amount of code as a DFM file, and the macro tests pass.

**Phase 5: standard set (large)** (done)
- Scrolling: `ScrollBar` and `ScrollBox` (smooth wheel, touchpad).
- `ListBox`, `ComboBox` (popup via `createPopupWindow`, using `xdg_popup` on
  Wayland), `Memo` (multi-line edit), `SpinEdit`, `TrackBar`, `ProgressBar`.
- `PageControl` and `TabControl`, `Splitter`, `StatusBar`, `ToolBar`.
- `MainMenu`, `PopupMenu`, hints and tooltips.
- Dialogs: `showMessage` and `messageDlg` (drawn by us), and Open, Save and
  folder dialogs (SDL's native ones).
- `FlowPanel` and `GridPanel`.
- *Done when:* a "settings app" demo uses every control.

**Phase 6: business set (large)** (done)
- `ListView` (report and icon views, sort, virtual mode), `TreeView` (lazy
  nodes), `StringGrid` and `DrawGrid` (with editing), `ActionList` and actions
  shared by menus, toolbars and shortcuts.
- *Done when:* a CRUD demo runs over 100k virtual rows and scrolls smoothly.

**Phase 7: editor set (large)**
- A code editor control (gutter, syntax-highlighting hook, large files),
  docking or tearable panels, more sophisticated splitter layouts.
- *Done when:* a small text editor demo is built with nimvcl.

**Phase 8: designer (large)**
- A text form format (like DFM) with load and save at runtime.
- A visual form designer app written in nimvcl that generates `form` code or
  the text format.

**Phase 9: reach (ongoing)**
- An SDL_GPU backend for `Canvas`.
- Verified Windows and macOS builds.
- Accessibility through AccessKit (C API).
- RTL and bidirectional text checks.

Phases 0–4 are the **MVP**, roughly the 2–3k lines discussed earlier. The rest
is incremental and can be reordered by what you want to build first.

## 6. Risks and open questions
1. **Resource lifetime under ORC** (§2.7): SDL objects must be freed on the UI
   thread before their renderer. Decided in phase 1.
2. **IME on Wayland**: SDL3 supports `text-input-v3`, but behaviour varies by
   compositor. Test on nimdow-wl early in phase 3.
3. **Popups on Wayland**: menus and combo boxes must use popup windows, because
   Wayland doesn't let an app position its own top-level windows. Prototype this
   at the start of phase 5.
4. **Binding gaps**: nim-lang/sdl3 is young. Plan to send upstream fixes
   instead of keeping a fork.
5. **Full-form repaint cost** on large grids or editors: measure in phase 6, and
   add dirty rectangles or render-target caching if needed.
6. **Open**: should controls copy VCL property names exactly (`caption`,
   `checked`, `itemIndex`) for familiarity? The proposal is yes, where they read
   naturally in Nim.
7. **Open**: which font to bundle by default (Inter, Noto Sans, or another OFL
   font)?

## 7. How the work will be done
- Each phase is broken into tasks with a brief (goal, files, constraints, how to
  verify). Independent tasks run in parallel.
- Every task is reviewed through `git diff` plus the tests before the next
  phase starts.

## 8. Progress and deviations

Done: phases 0-4 (the MVP) and phases 5 and 6. Phase 5 delivered ScrollBar,
ScrollBox, ListBox, ComboBox, Memo, ProgressBar, TrackBar, SpinEdit, Splitter,
StatusBar, ToolBar, PageControl/TabControl, FlowPanel/GridPanel, MainMenu/
PopupMenu, hints, message/input dialogs and the native file dialogs, popup
windows, `&` mnemonics, a shared key-handler chain and modal ownership
(`runModalLoop`); its exit criterion is `examples/settings_demo`. Phase 6
delivered ListView (report/icon/list views, virtual mode), TreeView (lazy
nodes), DrawGrid/StringGrid (editing), ImageList, and ActionList/Action; its
exit criterion is `examples/crud_demo` over 100k virtual rows. Additions that
were not in the plan: layout-owner hook (`arrangeChildren`), visibility
notification (`visibilityChanged`), anchors from a design-size baseline,
`captureLost`, umbrella `import nimvcl`, end-user docs in `docs/`, a showcase
example and a Frame macro.

**Review round** (commit 4a952a6 and the refinement pass after it): about 95
findings fixed across core, graphics, platform and controls, each with a
regression test. Highlights: handler copies before calling (no use-after-free),
per-job error handling in the queue, `try/finally` around showModal/run/paint,
font changes re-measure descendants, key auto-repeat flag (`keyIsRepeat`),
display scale from pixel density, `captureLost`, list/tree/grid index
bookkeeping on insert/delete/clear, grid and ImageList change notification,
PageControl active-sheet tracking and `TabSheet.tabVisible`, Memo line-break
rule, form macro reserved names. The refinement pass added: mnemonics on Runes
(any script, e.g. Cyrillic `&Файл`), a `wheelLines` setting on ScrollBar shared
with ScrollingControl, `{.discardable.}` on every control constructor, the
`newXxx(parent, <main property>, ..., left, top, width, height)` convention for
Splitter, StatusBar, ToolBar and ToolButton, scrolling pages in the settings
demo, and `Control.free` (plus `PopupMenu.free`, and release on `MenuItem.delete`/
`clear`) so Actions and ImageLists no longer keep removed controls alive.

Deviations from the plan, decided while building (details in the module
comments and `docs/`):
- **Scroll semantics**: only `alNone` children live in content coordinates and
  scroll; aligned children (scrollbars, `alClient` content) are laid out
  against the viewport and do not scroll. Layout never reads the scroll offset.
- **ListBox**: owner-draw items have a fixed height (`itemHeight`), no
  variable-height rows.
- **Scroll position is float64** inside `ScrollingControl` and the scrollbars
  (`scrollPosY`, `contentH`, ...), so lists of millions of rows scroll to the
  exact pixel; `scrollPos` / `contentSize` still return float32 (rounded) for
  small content. Views convert to float32 only after subtracting the scroll
  position.
- **Popups on offscreen/headless**: SDL cannot create real popup windows there,
  so popups fall back to small top-level windows (`docs/popups-menus.md`).
  Tests and screenshots use that path; Wayland uses `xdg_popup`, X11
  override-redirect windows.
- **Anchor baseline of parent-sized containers**: a container that was never
  sized explicitly (constructor default size only) has its first layout size as
  design size, so children added before it follow the size `align` gives it.
  An explicit size is still the design size (`docs/guide/layout.md`).
- **Same-`align` siblings** are ordered by child order, not by Top/Left as in
  the VCL.
- **FlowPanel/GridPanel** position every visible child themselves and ignore
  its `align` (the property is untouched).

## 9. Open issues

Known limitations, not yet fixed:
- **Partial repaint floor**: forms repaint only dirty regions into a persistent
  backbuffer (see docs/guide/painting.md), but every frame still copies the whole
  backbuffer to the window and presents it (about 1.5 ms at 1100x700 on the
  software renderer, vs about 11 ms for a full repaint). Copying only the dirty
  rects would need a renderer whose window contents survive a present.
  `requestLayout`, scrolling and `ui.dirty = true` still repaint the whole form;
  popups and `Host` always do.
- **Memo background measurement is slow per line**: documents over 500 lines
  are measured in the background (4-5 ms slices) so the horizontal extent / the
  wrapped row count become exact within seconds, but each line costs one text
  measurement through the render context's text cache (about 20 us, so about
  20 s for a million lines; memory stays flat because the sweep trims the
  cache). Until then the extents are exact for the measured lines only
  (`Memo.extentsExact`, `measureAll`). A core `RenderContext` call that measures
  a string without creating a cached text object would make this about 10x
  cheaper.
- **ListView has no column reordering** (`goColMoving` exists for the grids).
  Column 0 is the caption and the other columns are `subItems[k - 1]`, so
  moving a column would have to move item data too.
- **Real Wayland/X11 popups and IME are untested**: only the offscreen fallback
  and the SDL contracts are covered by the tests.
- **`ListView.onSelectItem` is still per item** (by design, VCL compatible):
  a huge selection change calls it once per changed item. Use the batched
  `onSelectionChanged(sender, added, removed)` for big selections.

