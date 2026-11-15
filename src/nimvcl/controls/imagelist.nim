## `ImageList` (VCL TImageList): a numbered set of same-size icons.
##
## Every image is drawn stretched into the list's logical `width` x `height`
## (so an image of 2x pixels gives crisp icons on a high-DPI display).
## Used by `TreeView` and `ListView` (`images`, `smallImages`, `largeImages`);
## ToolBar and menus can use it the same way (`draw` at a position, or
## `image(i)` for the raw `Image`).
##
##   let il = newImageList(16, 16)
##   let folder = il.add(makeFolderIcon())     # index 0
##   il.draw(canvas, folder, x, y)             # enabled
##   il.draw(canvas, folder, x, y, enabled = false)   # faded
##
## Change notification: every change (`add`, `insert`, `delete`, `clear`,
## `[]=`, `width=`, `height=`) bumps `version` and calls the listeners added
## with `addListener` (`TreeView` and `ListView` subscribe while the list is
## assigned, so they repaint / re-measure by themselves). A control that keeps
## an ImageList should `removeListener` when it lets go of it.

import ../graphics/[geometry, canvas, image]
export image

type
  ImageList* = ref object
    fImages: seq[Image]
    fWidth, fHeight: float32
    fVersion: int
    fNextId: int
    fListeners: seq[(int, proc() {.closure.})]

const DisabledAlpha* = 110'u8     ## opacity of an icon drawn disabled

proc newImageList*(width = 16'f32, height = 16'f32): ImageList =
  ImageList(fWidth: width, fHeight: height)

func version*(l: ImageList): int = l.fVersion
  ## Incremented by every change.

proc addListener*(l: ImageList, cb: proc() {.closure.}): int =
  ## Calls `cb` after every change; returns an id for `removeListener`.
  inc l.fNextId
  l.fListeners.add (l.fNextId, cb)
  l.fNextId

proc removeListener*(l: ImageList, id: int) =
  for i in 0 ..< l.fListeners.len:
    if l.fListeners[i][0] == id:
      l.fListeners.delete(i)
      return

proc changed(l: ImageList) =
  inc l.fVersion
  let ls = l.fListeners                 # a callback may remove itself
  for (_, cb) in ls: cb()

func width*(l: ImageList): float32 = l.fWidth
func height*(l: ImageList): float32 = l.fHeight
proc `width=`*(l: ImageList, v: float32) =
  let w = max(v, 1)
  if w != l.fWidth:
    l.fWidth = w
    l.changed()
proc `height=`*(l: ImageList, v: float32) =
  let h = max(v, 1)
  if h != l.fHeight:
    l.fHeight = h
    l.changed()
func count*(l: ImageList): int = l.fImages.len

proc add*(l: ImageList, img: Image): int {.discardable.} =
  ## Appends `img`; returns its index.
  l.fImages.add img
  result = l.fImages.high
  l.changed()

proc insert*(l: ImageList, index: int, img: Image) =
  l.fImages.insert(img, min(max(index, 0), l.fImages.len))
  l.changed()

proc delete*(l: ImageList, index: int) =
  if index in 0 ..< l.fImages.len:
    l.fImages.delete(index)
    l.changed()

proc clear*(l: ImageList) =
  if l.fImages.len == 0: return
  l.fImages.setLen(0)
  l.changed()

proc image*(l: ImageList, index: int): Image =
  ## The image at `index`; nil when out of range.
  if index in 0 ..< l.fImages.len: l.fImages[index] else: nil

proc `[]`*(l: ImageList, index: int): Image = l.image(index)

proc `[]=`*(l: ImageList, index: int, img: Image) =
  if index in 0 ..< l.fImages.len:
    l.fImages[index] = img
    l.changed()

proc draw*(l: ImageList, c: Canvas, index: int, x, y: float32,
           enabled = true) =
  ## Draws icon `index` with its top-left at (x, y); nothing for a bad index.
  let img = l.image(index)
  if img == nil: return
  c.drawImage(img, rectF(x, y, l.fWidth, l.fHeight),
              alpha = if enabled: 255'u8 else: DisabledAlpha)
