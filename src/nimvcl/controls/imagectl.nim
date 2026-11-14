## `ImageControl` (VCL TImage): shows a `picture`.
##
## Placement (see `imageDrawRect`, the pure function that computes it):
## * `proportional`: scaled to fit the client keeping the aspect ratio, always
##   centred; it only grows beyond the natural size when `stretch` is set.
## * `stretch` alone: fills the client.
## * neither: natural size (image pixels = logical px), top-left, or centred
##   with `center`.
## `transparent` (default) draws no background, otherwise `color` is filled
## first. `autoSize` sizes the control to the picture.
## (Named imagectl to avoid clashing with graphics/image.)

import ../graphics/image
import ./common

export image

type
  ImageControl* = ref object of Control
    fPicture: Image
    fStretch, fProportional, fCenter, fTransparent: bool

func imageDrawRect*(clientW, clientH, imgW, imgH: float32,
                    stretch, proportional, center: bool): RectF =
  ## Destination rectangle (client coordinates) of an image of imgW x imgH.
  if imgW <= 0 or imgH <= 0: return rectF(0, 0, 0, 0)
  if proportional:
    var s = min(clientW / imgW, clientH / imgH)
    if not stretch: s = min(s, 1'f32)
    let w = imgW * s
    let h = imgH * s
    return rectF((clientW - w) / 2, (clientH - h) / 2, w, h)
  if stretch: return rectF(0, 0, clientW, clientH)
  if center: rectF((clientW - imgW) / 2, (clientH - imgH) / 2, imgW, imgH)
  else: rectF(0, 0, imgW, imgH)

func picture*(i: ImageControl): Image = i.fPicture
proc `picture=`*(i: ImageControl, v: Image) =
  i.fPicture = v
  i.invalidate()
  if i.autoSize: i.requestLayout()

func stretch*(i: ImageControl): bool = i.fStretch
proc `stretch=`*(i: ImageControl, v: bool) =
  if v == i.fStretch: return
  i.fStretch = v
  i.invalidate()

func proportional*(i: ImageControl): bool = i.fProportional
proc `proportional=`*(i: ImageControl, v: bool) =
  if v == i.fProportional: return
  i.fProportional = v
  i.invalidate()

func center*(i: ImageControl): bool = i.fCenter
proc `center=`*(i: ImageControl, v: bool) =
  if v == i.fCenter: return
  i.fCenter = v
  i.invalidate()

func transparent*(i: ImageControl): bool = i.fTransparent
proc `transparent=`*(i: ImageControl, v: bool) =
  if v == i.fTransparent: return
  i.fTransparent = v
  i.invalidate()

proc drawRect*(i: ImageControl): RectF =
  ## Where the picture is drawn, in client coordinates (empty without picture).
  if i.fPicture == nil: return rectF(0, 0, 0, 0)
  imageDrawRect(i.width, i.height, float32(i.fPicture.width),
                float32(i.fPicture.height), i.fStretch, i.fProportional, i.fCenter)

method preferredSize*(i: ImageControl): SizeF =
  if i.fPicture == nil: sizeF(i.width, i.height)
  else: sizeF(float32(i.fPicture.width), float32(i.fPicture.height))

method paint*(i: ImageControl, c: Canvas) =
  if not i.fTransparent: c.fillRect(i.clientRect, i.color)
  if i.fPicture != nil: c.drawImage(i.fPicture, i.drawRect)
  procCall paint(Control(i), c)

proc initImageControl*(i: ImageControl, owner: Component = nil) =
  i.initControl(owner)
  i.fTransparent = true
  i.setBounds(0, 0, 105, 105)

proc newImageControl*(parent: Container = nil, picture: Image = nil,
                      left = 0'f32, top = 0'f32,
                      width = -1'f32, height = -1'f32): ImageControl =
  new result
  result.initImageControl(parent)
  result.fPicture = picture
  result.placeControl(parent, left, top, width, height)
