# Imports and the prelude

`import nimvcl` brings in everything: every control, the code editor, the
docking system and the form macros. It is the easiest start and the slowest to
compile. For faster builds import only the modules you use.

## `nimvcl/prelude`

`import nimvcl/prelude` is the small set that code inside event handlers
usually needs, without dropping in any component:

| Module | You get |
|---|---|
| `core/control`, `core/form`, `core/application` | `Application` (including `Application.clipboard`), `Form`, `Control`, events, popups |
| `controls/common` | geometry, colours, fonts, canvas, theme and input types |
| `controls/dialogs` | `showMessage`, `messageDlg`, `inputQuery`, `inputBox`, `OpenDialog`, `SaveDialog`, `SelectFolderDialog` |
| `core/timer` | `Timer`, `newTimer` |
| `graphics/color`, `graphics/font` | `rgb`, `rgba`, `parseColor`, `FontSpec`, ... |

```nim
import nimvcl/prelude
import nimvcl/controls/button      # a control you create in code

let form = newForm(nil, 320, 160)
let b = newButton(form, "Open", 20, 20)
b.onClick = proc(sender: Control) = showMessage("Hello")
Application.run(form)
```

The prelude does not import the stock controls (`Button`, `Edit`, `ListView`,
...) or the `dsl` modules (`formload`, `formmacro`): import the module of a
control you use in code, for example `nimvcl/controls/edit`.

## What it costs

`scripts/prelude_cost.sh` times `nim check` of a tiny program (best of several
runs). On the development machine:

| Program imports | `nim check` |
|---|---|
| `core/[control, form, application]` + `controls/common` | about 1.26 s |
| `nimvcl/prelude` | about 1.38 s |
| `nimvcl` (everything) | about 2.6 s |

The prelude adds roughly 0.1 s over core alone. Most of that is
`controls/dialogs`, which pulls in `label`, `button`, `edit` and `paintbox` for
its dialog windows; the code editor, grids, list and tree views and the docking
modules stay out.
