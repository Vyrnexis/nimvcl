## nimvcl: a Delphi VCL-style UI library for Nim, drawn with SDL3.
##
## Umbrella module: re-exports the public API. `import nimvcl` is enough for an
## application; the individual modules stay importable for finer control.
##
## `platform/dialogs` (the raw SDL file-dialog calls) is not exported; use the
## `OpenDialog` / `SaveDialog` / `SelectFolderDialog` components of
## `controls/dialogs`.

import nimvcl/graphics/[color, geometry, font, image, context, canvas]
import nimvcl/platform/[sdlutil, events, window]
import nimvcl/core/[types, component, theme, control, layout, input, form,
                    timer, application, host]
import nimvcl/controls/[common, label, button, checkbox, radiobutton, panel,
                        paintbox, bevel, imagectl, edit, frame,
                        scrollbar, scrolling, scrollbox, listbox, menus, hint,
                        progressbar, trackbar, spinedit, splitter, statusbar,
                        toolbar, pagecontrol, flowpanel, dialogs,
                        memomodel, memo, combobox,
                        imagelist, viewsupport, treeview, listview,
                        gridmodel, grids, actions]
import nimvcl/controls/docking
import nimvcl/controls/[codemodel, highlight, nimlexer, folding, brackets, search]
import nimvcl/dsl/formmacro

export color, geometry, font, image, context, canvas, sdlutil, events, window
export types, component, theme, control, layout, input, form, timer,
       application, host
export common, label, button, checkbox, radiobutton, panel, paintbox, bevel,
       imagectl, edit, frame, scrollbar, scrolling, scrollbox, listbox, menus,
       hint, progressbar, trackbar, spinedit, splitter, statusbar, toolbar,
       pagecontrol, flowpanel, dialogs, memomodel, memo, combobox,
       imagelist, viewsupport, treeview, listview, gridmodel, grids, actions
export docking
export codemodel, highlight, nimlexer, folding, brackets, search
export formmacro
