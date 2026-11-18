## The small set of modules that handler code needs without importing a
## component: `import nimvcl/prelude` gives you
##
## * the form and application basics (`core/control`, `core/form`,
##   `core/application`: `Application`, `Form`, `Control`, the events, the
##   clipboard through `Application.clipboard`, popups),
## * `controls/common` (and what it re-exports: geometry, colours, fonts,
##   canvas, theme, input types),
## * the standard dialogs of `controls/dialogs`: `showMessage`, `messageDlg`,
##   `inputQuery`, `inputBox`, and the `OpenDialog` / `SaveDialog` /
##   `SelectFolderDialog` components,
## * `core/timer` (`Timer`, `newTimer`).
##
## It does not import any stock control (`Button`, `Edit`, `ListView`, ...):
## import the module of a control you use in code (`nimvcl/controls/edit`), or
## `import nimvcl` for everything (slower to compile). The `dsl` modules
## (`formload`, `formmacro`) are not included either.

import ./core/[control, form, application, timer]
import ./controls/[common, dialogs]
import ./graphics/[color, font]

export control, form, application, timer, common, dialogs, color, font
