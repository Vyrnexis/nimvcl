## CPU-side images.
##
## An `Image` owns an SDL surface (RGBA32 pixels in system memory). Surfaces are
## not bound to a renderer, so an `Image` can be freed by the GC at any time.
## The GPU texture is created lazily by the `RenderContext` that draws it and
## re-uploaded when `generation` changes.

import std/atomics
import sdl3 except Color
import sdl3_image
import ./color

type
  ImageError* = object of CatchableError

  ImageObj = object
    surface: ptr Surface
    id: uint64
    generation: uint32
    fSource: string

  Image* = ref ImageObj
    ## Pixel image. `width`/`height` are in pixels (not logical units).

var nextImageId: Atomic[uint64]   # images may be loaded on worker threads

proc `=destroy`(x: ImageObj) =
  if x.surface != nil: destroySurface(x.surface)

proc `=copy`(a: var ImageObj, b: ImageObj) {.error.}

proc wrap(surf: ptr Surface, what: string): Image =
  if surf == nil:
    raise newException(ImageError, what & ": " & $getError())
  var s = surf
  if s.format != PIXELFORMAT_RGBA32:
    let conv = convertSurface(s, PIXELFORMAT_RGBA32)
    destroySurface(s)
    if conv == nil:
      raise newException(ImageError, what & ": " & $getError())
    s = conv
  Image(surface: s, id: nextImageId.fetchAdd(1'u64) + 1, generation: 0)

func source*(img: Image): string = img.fSource
  ## Where the image came from: the path it was loaded with (`loadImage`), or
  ## the project-relative path a form file stores for it ("" for an image made
  ## in memory). The form file writer saves this path for `picture` properties.

proc `source=`*(img: Image, v: string) = img.fSource = v

proc loadImage*(path: string): Image =
  ## Loads PNG, JPEG, BMP, ... through SDL_image. Raises `ImageError`. The
  ## image's `source` is `path`.
  result = wrap(sdl3_image.load(path.cstring), "loadImage " & path)
  result.source = path

proc imageFromMemory*(data: openArray[byte]): Image =
  ## Decodes an encoded image held in memory. Raises `ImageError`.
  if data.len == 0: raise newException(ImageError, "imageFromMemory: empty data")
  let io = ioFromConstMem(unsafeAddr data[0], data.len.csize_t)
  wrap(sdl3_image.loadIO(io, true), "imageFromMemory")

proc imageFromMemory*(data: string, source = ""): Image =
  ## Decodes the bytes of an encoded image file held in a string (what
  ## `staticRead` returns) and records `source` (see `source`).
  if data.len == 0: raise newException(ImageError, "imageFromMemory: empty data")
  let io = ioFromConstMem(unsafeAddr data[0], data.len.csize_t)
  result = wrap(sdl3_image.loadIO(io, true), "imageFromMemory " & source)
  result.source = source

proc newImage*(width, height: int, fill = Color()): Image =
  ## Blank image (transparent by default).
  let surf = createSurface(width.cint, height.cint, PIXELFORMAT_RGBA32)
  result = wrap(surf, "newImage")
  if fill != Color():
    for y in 0 ..< height:
      for x in 0 ..< width:
        let o = y * surf.pitch + x * 4
        surf.pixels[o] = fill.r
        surf.pixels[o + 1] = fill.g
        surf.pixels[o + 2] = fill.b
        surf.pixels[o + 3] = fill.a
  else:
    for y in 0 ..< height:
      zeroMem(addr surf.pixels[y * surf.pitch], width * 4)

proc imageFromRgba*(width, height: int, pixels: openArray[uint8]): Image =
  ## Copies tightly packed RGBA bytes (R, G, B, A order, `width*height*4`).
  if pixels.len < width * height * 4:
    raise newException(ImageError, "imageFromRgba: not enough pixel data")
  result = newImage(width, height)
  let surf = result.surface
  for y in 0 ..< height:
    copyMem(addr surf.pixels[y * surf.pitch], unsafeAddr pixels[y * width * 4], width * 4)

func width*(img: Image): int = img.surface.w.int
func height*(img: Image): int = img.surface.h.int
func id*(img: Image): uint64 = img.id
  ## Unique id, used as the texture cache key.
func generation*(img: Image): uint32 = img.generation
  ## Bumped by every pixel change; caches re-upload when it differs.

proc surface*(img: Image): ptr Surface = img.surface
  ## The backing surface (for the graphics layer).

proc touch*(img: Image) =
  ## Call after writing pixels directly, so textures are re-uploaded.
  inc img.generation

proc getPixel*(img: Image, x, y: int): Color =
  doAssert x in 0 ..< img.width and y in 0 ..< img.height
  let o = y * img.surface.pitch + x * 4
  let p = img.surface.pixels
  Color(r: p[o], g: p[o + 1], b: p[o + 2], a: p[o + 3])

proc setPixel*(img: Image, x, y: int, c: Color) =
  ## Writes one pixel and bumps the generation.
  doAssert x in 0 ..< img.width and y in 0 ..< img.height
  let o = y * img.surface.pitch + x * 4
  let p = img.surface.pixels
  p[o] = c.r
  p[o + 1] = c.g
  p[o + 2] = c.b
  p[o + 3] = c.a
  inc img.generation
