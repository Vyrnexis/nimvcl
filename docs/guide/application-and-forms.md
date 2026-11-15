# Application and forms

`Application` is the global object that owns the event loop. A `Form` is one
top-level window (Delphi `TForm`). Every form is one SDL3 window.

## Run an application

```nim
import nimvcl

let main = newForm(nil, 400, 300)
main.caption = "My app"
Application.run(main)       # shows `main`, loops until it closes
```

Closing the main form ends the program. You can also call
`Application.terminate()` from any handler.

Useful `Application` members:

| Member | Description |
|---|---|
| `run(form)` | Show the form and run the loop |
| `terminate()` | Leave the loop |
| `mainForm`, `activeForm`, `forms` | The registry of open forms |
| `onIdle: proc()` | Called after each batch of events |
| `onException: proc(e: ref Exception)` | Errors from handlers, queued jobs, layout and paint (default: re-raise). A failing queued job does not stop the others |
| `theme = themeDark()` | Switch the theme, see [theming](theming.md) |
| `clipboard` | Read or write the clipboard text |
| `processMessages()` | Pump events by hand inside a long loop |

The loop blocks while nothing happens, so an idle app costs no CPU.

## Form properties

```nim
let f = newForm(nil, 480, 320)
f.caption = "Settings"
f.position = poScreenCenter         # poDesigned | poScreenCenter | poMainFormCenter
f.borderStyle = bsSingle            # bsSizeable | bsSingle | bsNone
f.formStyle = fsStayOnTop           # fsNormal | fsStayOnTop
f.keyPreview = true                 # the form sees keys before the focused control
```

| Property / event | Description |
|---|---|
| `menu` | The form's `MainMenu`, see [menus](../components/menus.md) |
| `activeControl` | The focused control (settable) |
| `modalResult` | A value other than `mrNone` closes a modal form |
| `onShow`, `onHide`, `onActivate`, `onDeactivate` | `NotifyEvent`s |
| `onCloseQuery(sender, canClose: var bool)` | Set `canClose = false` to veto closing |
| `onClose(sender, action: var CloseAction)` | `caHide`, `caFree` or `caNone` (abort) |

Methods: `show`, `hide`, `close`, `showModal`, `bringToFront`.

Ask before closing:

```nim
form.onCloseQuery = proc(sender: Form, canClose: var bool) =
  canClose = messageDlg("Quit without saving?", mtConfirmation,
                        {mbYes, mbNo}) == mrYes
```

## Several windows

Make more forms and call `show`. Each one has its own window, theme and focus.

```nim
let tools = newForm(nil, 200, 300)
tools.caption = "Tools"
tools.show()
```

## Modal forms

`showModal` shows a form, blocks the other forms, and returns a `ModalResult`
when the form is done. A button with a `modalResult` closes the form with that
result when clicked.

```nim
proc askName(): string =
  let dlg = newForm(nil, 300, 120)
  dlg.caption = "Name"
  let edit = newEdit(dlg, "", 16, 16, 268)
  let ok = newButton(dlg, "OK", 120, 64, 80, 30)
  ok.modalResult = mrOk
  ok.isDefault = true                 # Enter clicks it
  let cancel = newButton(dlg, "Cancel", 204, 64, 80, 30)
  cancel.modalResult = mrCancel
  cancel.isCancel = true              # Esc clicks it
  if dlg.showModal() == mrOk: edit.text else: ""
```

Closing the window gives `mrCancel`. A modal form is centered on the active
form. For simple questions use the ready-made [dialogs](../components/dialogs.md)
(`messageDlg`, `inputQuery`).

## Host mode: embed the UI in your own SDL3 app

If you already have an SDL3 window and render loop, skip `Application` and
`Form`. Build a `Container` tree and give it to a `Host`. You keep the window and
the renderer.

```nim
import sdl3 except Color, Cursor
import nimvcl

discard initSdl()
let win = createWindow("my game", 640, 400, WINDOW_HIGH_PIXEL_DENSITY)
let ren = createRenderer(win, nil)

let root = newContainer()               # transparent, follows the window size
let btn = newButton(root, "Pause", 10, 10, 90, 30)
btn.onClick = proc(sender: Control) = echo "paused"

let host = newHost(win, ren, root)
var running = true
while running:
  var ev: Event
  while pollEvent(ev):
    if ev.`type` == EVENT_QUIT: running = false
    elif host.handleEvent(ev): continue   # the UI used it
    # ... your own event handling ...
  # ... draw your scene with `ren` ...
  host.paint()                            # draws the UI on top, no clear/present
  discard renderPresent(ren)
host.close()                              # before destroying the renderer
destroyRenderer ren
destroyWindow win
```

`Timer` works in host mode too: it fires from `handleEvent`. Menus, hints and
popups need `Application`, so they are for form mode.

[Back to the index](../README.md)
