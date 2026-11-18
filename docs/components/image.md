# Image

`ImageControl` shows a picture (Delphi `TImage`). `Image` is the pixel
buffer type behind it, loaded from files or made in code.

## Quick example

```nim
let pic = newImageControl(form, loadImage("logo.png"), 16, 16, 160, 120)
pic.proportional = true                   # keep the aspect ratio
pic.center = true

# or draw your own pixels
let gradient = newImage(64, 64)
for y in 0 ..< 64:
  for x in 0 ..< 64:
    gradient.setPixel(x, y, rgb(x * 4, y * 4, 128))
pic.picture = gradient
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `picture` | `Image` | What to show. Set it again after changing pixels |
| `stretch` | bool | Fill the whole control |
| `proportional` | bool | Fit while keeping the aspect ratio (grows only with `stretch`) |
| `center` | bool | Center when drawn at natural size |
| `transparent` | bool | No background fill (default). Otherwise `color` is filled first |
| `autoSize` | bool | Size the control to the picture |

## Image functions

| Function | Description |
|---|---|
| `loadImage(path)` | Load PNG, JPG and others via SDL3_image; raises `ImageError` |
| `imageFromMemory(bytes)` | Decode from memory (`bytes` can also be a string, as `staticRead` returns, with the `source` to record) |
| `img.source` | The file path the image came from (what a form file stores) |
| `newImage(width, height, fill)` | Blank image |
| `imageFromRgba(w, h, pixels)` | From raw RGBA bytes |
| `img.setPixel(x, y, color)`, `getPixel(x, y)` | Edit pixels |
| `img.touch()` | Tell the renderer the pixels changed |
| `img.width`, `img.height` | Size in pixels |

## In a form file

`picture` is stored as the path of the image file, relative to the folder of
the `.nfm`:

```
object logo: ImageControl
  stretch = true
  picture = 'images/logo.png'
end
```

* `loadNfm` / `loadNfmFile` read the file from disk (relative to the `.nfm`, or
  to `NfmOptions.baseDir`). A file that is missing does not stop loading: a
  blank 1x1 image that keeps the path stands in, and a line is added to
  `NfmOptions.warnings`, so saving the form again does not lose the path.
* `loadForm` **embeds** the file bytes in the program at compile time
  (`staticRead`) and decodes them from memory, so a shipped binary needs no
  image files. The file must exist when the program is compiled.
* `formToNfm` writes `picture` from `img.source`. `loadImage(path)` sets it
  to `path`; an image made in memory has no source and is not written.
* In the Object Inspector the `picture` row has a "..." button
  ([property editors](inspector.md#property-editor-dialogs)): a picture dialog
  with the preview, Load..., Clear, OK and Cancel; Delete on the row clears it.

## Events

The usual `onClick` and mouse events.

## Tips

* One image pixel equals one logical pixel at natural size. Use a larger image
  with `stretch` or `proportional` for sharp HiDPI output.
* `loadImage` is relative to the working directory; handle `ImageError` for
  missing files.
* Use an [ImageList](imagelist.md) for icons in toolbars, trees and menus.

[Back to the index](../README.md)
