# Getting started

This page takes you from zero to a running window.

## Install

nimvcl needs Nim 2.2 or newer and three SDL3 system libraries: SDL3 itself,
SDL3_ttf (text) and SDL3_image (image loading).

| Distro | Command |
|---|---|
| Arch | `sudo pacman -S sdl3 sdl3_ttf sdl3_image` |
| Debian / Ubuntu | `sudo apt install libsdl3-dev libsdl3-ttf-dev libsdl3-image-dev` |
| Fedora | `sudo dnf install SDL3-devel SDL3_ttf-devel SDL3_image-devel` |

Package names differ between releases. If your distro has no SDL3 packages
yet, build SDL3, SDL3_ttf and SDL3_image from source.

Then add nimvcl to your `.nimble` file. The SDL3 binding is pinned by URL, so
list it too:

```nim
requires "nim >= 2.2.0"
requires "https://github.com/nim-lang/sdl3#533d22196dab2ea637ea0131171ed3f8db61fe90"
```

Working from a clone of this repository, `nim.cfg` already points the compiler
at `src/`, so `import nimvcl` just works for files inside the repo.

## Hello window

```nim
import nimvcl

let form = newForm(nil, 320, 160)       # owner, width, height
form.caption = "Hello"

let btn = newButton(form, "Say hello", 20, 20, 120, 32)
btn.onClick = proc(sender: Control) =
  showMessage("Hello from nimvcl!")

Application.run(form)
```

What happens here:

* `newForm` makes a top-level window. `Application.run` shows it and runs the
  event loop until the main form closes.
* Every control constructor is `newXxx(parent, <main property>, ..., left, top,
  width, height)`. Passing `form` as `parent` puts the button inside it. Leave
  out the size to get the control's default size.
* Events are plain fields: `onClick = proc(sender: Control) = ...`.

Build and run it:

```
nim c -r hello.nim
```

## The same with the `form` macro

`form` declares the window as a tree, like a Delphi `.dfm`. Names become typed
fields, and the compiler checks every property.

```nim
import nimvcl

form MainForm:
  caption = "Hello"
  width = 320; height = 160
  Button helloBtn:
    caption = "Say hello"
    left = 20; top = 20; width = 120; height = 32
    onClick: showMessage("Hello from nimvcl!")

Application.run(newMainForm())
```

See [Forms and frames](forms.md) for the full syntax.

## Run the examples

```
nim c -r examples/settings_demo.nim   # a preferences app using most controls
nim c -r examples/controls_demo.nim   # the basic controls
nimble examples                       # build them all into build/examples
```

## Run the tests

The suite runs headless (SDL offscreen driver, software renderer):

```
scripts/test.sh              # debug build
scripts/test.sh -d:release   # extra nim flags are passed through
nimble test                  # same as scripts/test.sh
```

Logs land in `build/tests/<name>.log`.

## Next steps

* [Application and forms](guide/application-and-forms.md)
* [Layout](guide/layout.md)
* [Component reference](README.md#components)

[Back to the index](README.md)
