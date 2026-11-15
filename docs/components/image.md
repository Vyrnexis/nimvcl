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
| `imageFromMemory(bytes)` | Decode from memory |
| `newImage(width, height, fill)` | Blank image |
| `imageFromRgba(w, h, pixels)` | From raw RGBA bytes |
| `img.setPixel(x, y, color)`, `getPixel(x, y)` | Edit pixels |
| `img.touch()` | Tell the renderer the pixels changed |
| `img.width`, `img.height` | Size in pixels |

## Events

The usual `onClick` and mouse events.

## Tips

* One image pixel equals one logical pixel at natural size. Use a larger image
  with `stretch` or `proportional` for sharp HiDPI output.
* `loadImage` is relative to the working directory; handle `ImageError` for
  missing files.
* Use an [ImageList](imagelist.md) for icons in toolbars, trees and menus.

[Back to the index](../README.md)
