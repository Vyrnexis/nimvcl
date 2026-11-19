## Native file dialogs (SDL3 `SDL_ShowOpenFileDialog` & co.).
##
## SDL shows these asynchronously and calls back on a thread of its choosing
## (often not the UI thread). This module only starts the dialog and reports
## `done(token, ok, files)` from whatever thread that is; marshalling to the UI
## thread is the caller's job (controls/dialogs.nim uses `runOnUi`). `done` is
## a plain `nimcall` proc, so nothing GC-managed is shared across threads.
##
## `showFileDialogImpl` is the injection point: tests replace it with a fake
## that calls `done` from another thread. It is called on the UI thread.
##
## `ok` is false when the user cancelled or SDL reported an error (`files`
## then empty). Paths are UTF-8, one entry per selection.

import sdl3
import ./window

type
  FileDialogKind* = enum fdkOpen, fdkSave, fdkFolder

  FileDialogRequest* = object
    kind*: FileDialogKind
    title*: string
    initialDir*: string          ## starting folder (or file) path, may be ""
    filters*: seq[(string, string)]  ## (name, "ext1;ext2") like ("Images", "png;jpg")
    multiSelect*: bool
    parent*: PlatformWindow      ## may be nil

  FileDialogDone* = proc(token: int, ok: bool, files: seq[string]) {.nimcall, gcsafe.}

  FileDialogImpl* = proc(req: FileDialogRequest, token: int,
                         done: FileDialogDone)

  CallbackBox = object
    token: int
    done: FileDialogDone
    strings: seq[string]
    filters: seq[DialogFileFilter]

proc deliver*(done: FileDialogDone, token: int, ok: bool, files: seq[string]) =
  ## Calls `done`; nothing it raises may escape into SDL's C code.
  try:
    done(token, ok, files)
  except Exception as e:
    when not defined(release):
      stderr.writeLine "nimvcl: file dialog callback raised " & $e.name & ": " & e.msg

proc sdlCallback(userdata: pointer, filelist: cstringArray, filter: cint)
                {.cdecl.} =
  let box = cast[ptr CallbackBox](userdata)
  var files: seq[string]
  var ok = false
  if filelist != nil:
    var i = 0
    while filelist[i] != nil:
      files.add $filelist[i]
      inc i
    ok = files.len > 0
  let token = box.token
  let done = box.done
  `=destroy`(box[])
  dealloc box
  deliver(done, token, ok, files)

proc realShow(req: FileDialogRequest, token: int, done: FileDialogDone) =
  let box = cast[ptr CallbackBox](alloc0(sizeof(CallbackBox)))
  box.token = token
  box.done = done
  # SDL wants ';'-separated extensions without dots; it copies the strings
  # only after the callback runs on some platforms, so keep them in the box.
  box.strings = @[req.title, req.initialDir]
  for (name, pat) in req.filters:
    box.strings.add name
    box.strings.add pat
  for i in 0 ..< req.filters.len:
    box.filters.add DialogFileFilter(name: box.strings[2 + 2 * i].cstring,
                                      pattern: box.strings[3 + 2 * i].cstring)
  let props = createProperties()
  if req.title.len > 0:
    discard setStringProperty(props, PROP_FILE_DIALOG_TITLE_STRING.cstring,
                              box.strings[0].cstring)
  if req.initialDir.len > 0:
    discard setStringProperty(props, PROP_FILE_DIALOG_LOCATION_STRING.cstring,
                              box.strings[1].cstring)
  if req.multiSelect:
    discard setBooleanProperty(props, PROP_FILE_DIALOG_MANY_BOOLEAN.cstring, true)
  if req.parent != nil and req.parent.window != nil:
    discard setPointerProperty(props, PROP_FILE_DIALOG_WINDOW_POINTER.cstring,
                               cast[pointer](req.parent.window))
  if req.kind != fdkFolder and box.filters.len > 0:
    discard setPointerProperty(props, PROP_FILE_DIALOG_FILTERS_POINTER.cstring,
                               addr box.filters[0])
    discard setNumberProperty(props, PROP_FILE_DIALOG_NFILTERS_NUMBER.cstring,
                              box.filters.len.int64)
  let kind = case req.kind
             of fdkOpen: FILEDIALOG_OPENFILE
             of fdkSave: FILEDIALOG_SAVEFILE
             of fdkFolder: FILEDIALOG_OPENFOLDER
  showFileDialogWithProperties(kind, sdlCallback, box, props)
  # SDL copies what it needs from `props` before returning.
  destroyProperties(props)

var showFileDialogImpl*: FileDialogImpl = realShow
  ## Replace to fake the native dialog (tests).

proc showFileDialog*(req: FileDialogRequest, token: int, done: FileDialogDone) =
  ## Starts a dialog; `done` is called once, possibly from another thread.
  showFileDialogImpl(req, token, done)
