# Dialogs

Ready-made modal dialogs: message boxes, a text prompt, and native file and
folder dialogs (Delphi `ShowMessage`, `MessageDlg`, `InputQuery`,
`TOpenDialog`, `TSaveDialog`, `TSelectDirectoryDialog`).

## Quick example

```nim
let ask = newButton(form, "Delete...", 16, 16, 110, 30)
ask.onClick = proc(sender: Control) =
  let r = messageDlg("Delete this file?", mtConfirmation,
                     {mbYes, mbNo}, defaultButton = mbNo)
  if r == mrYes: echo "deleted"

var name = "untitled"
if inputQuery("Rename", "New name:", name):    # true when OK was pressed
  echo "renamed to ", name

showMessage("All done")                        # OK only, no icon
```

These calls block (a nested loop runs) until the user answers, so call them
from event handlers, not before `Application.run`.

## Message dialogs

| Call | Description |
|---|---|
| `showMessage(text)` | OK-only message |
| `messageDlg(text, dlgType, buttons, defaultButton, title)` | Returns the `ModalResult` of the pressed button |
| `inputQuery(caption, prompt, value: var string): bool` | Text prompt; `value` is updated on OK |
| `inputBox(caption, prompt, default): string` | Returns the text, or `default` when cancelled |

Types:

* `MsgDlgType`: `mtInformation`, `mtWarning`, `mtError`, `mtConfirmation`
* `MsgDlgBtn`: `mbYes`, `mbNo`, `mbOK`, `mbCancel`, `mbAbort`, `mbRetry`, `mbIgnore`
  (use as a set: `{mbYes, mbNo, mbCancel}`)
* Results: `mrYes`, `mrNo`, `mrOk`, `mrCancel`, `mrAbort`, `mrRetry`, `mrIgnore`

Esc or the close button gives Cancel, else No, else the only button.

## File dialogs

`OpenDialog`, `SaveDialog` and `SelectFolderDialog` are components that use the
system's native dialogs.

```nim
let dlg = newOpenDialog(form)
dlg.title = "Open an image"
dlg.initialDir = "/home"
dlg.filters = @[("Images", "png;jpg"), ("All files", "*")]
dlg.multiSelect = false

# 1. async: returns at once, the callback runs later on the UI thread
dlg.execute(proc(ok: bool, files: seq[string]) =
  if ok: echo "chose ", files[0])

# 2. blocking: a nested loop runs until the dialog closes
if dlg.executeModal():
  echo "chose ", dlg.fileName
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `title` | string | Dialog title |
| `initialDir` | string | Where to start |
| `filters` | `seq[(string, string)]` | `(label, "ext;ext")` pairs, `"*"` for all |
| `multiSelect` | bool | Allow several files (Open) |
| `files`, `fileName` | `seq[string]`, string | Result of the last successful run |
| `isRunning` | bool | A dialog is open |

## Events

`execute(onDone)` takes the callback `proc(ok: bool, files: seq[string])`.

## Methods

| Method | Description |
|---|---|
| `execute(onDone)` | Start without blocking |
| `executeModal(): bool` | Block until done; true on OK |

## Tips

* Message dialogs are drawn by nimvcl, so they match the theme. File dialogs are
  native.
* `execute` is ignored while the dialog is already open.
* The dialogs are centered on the active form.
* Custom dialogs: build a `Form` and call `showModal`, see
  [Application and forms](../guide/application-and-forms.md).

[Back to the index](../README.md)
