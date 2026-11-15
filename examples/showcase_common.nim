## Shared pieces of the showcase: the vector icon set (drawn into an
## `ImageList` at start-up, so there are no asset files), the `Showcase`
## context that the page builders share, and a few layout helpers.

import std/[math, strutils, os]
import nimvcl

# ------------------------------------------------------------------ icons

const
  icOpen* = 0
  icSave* = 1
  icMoon* = 2
  icExit* = 3
  icInfo* = 4
  icPrev* = 5
  icNext* = 6
  icFolder* = 7
  icFile* = 8
  icButton* = 9
  icText* = 10
  icSlider* = 11
  icList* = 12
  icData* = 13
  icLayout* = 14
  icPaint* = 15
  icDialog* = 16
  icCode* = 17
  icImage* = 18
  icArchive* = 19
  icCheck* = 20
  icCount* = 21

  accentBlue* = rgb(0x4c, 0x8b, 0xe8)
  amber = rgb(0xf0, 0xa2, 0x2c)
  green = rgb(0x2f, 0xa4, 0x6a)
  violet = rgb(0x8b, 0x6b, 0xe0)
  slate = rgb(0x7a, 0x8a, 0x9e)

type Shape = proc(u, v: float): bool

proc rc(u, v, x0, y0, x1, y1: float): bool = u >= x0 and u <= x1 and v >= y0 and v <= y1
proc disc(u, v, cx, cy, r: float): bool = (u - cx) * (u - cx) + (v - cy) * (v - cy) <= r * r
proc ringAt(u, v, cx, cy, r, w: float): bool =
  let d = sqrt((u - cx) * (u - cx) + (v - cy) * (v - cy))
  d <= r and d >= r - w
proc seg(u, v, x1, y1, x2, y2, w: float): bool =
  ## Distance to the segment (x1,y1)-(x2,y2) is at most w / 2.
  let dx = x2 - x1
  let dy = y2 - y1
  let l2 = dx * dx + dy * dy
  var t = if l2 == 0: 0.0 else: ((u - x1) * dx + (v - y1) * dy) / l2
  t = clamp(t, 0.0, 1.0)
  let px = x1 + t * dx
  let py = y1 + t * dy
  (u - px) * (u - px) + (v - py) * (v - py) <= (w / 2) * (w / 2)

proc sOpen(u, v: float): bool = rc(u, v, 0.08, 0.32, 0.92, 0.84) or rc(u, v, 0.08, 0.16, 0.42, 0.34)
proc sSave(u, v: float): bool =
  rc(u, v, 0.1, 0.1, 0.9, 0.9) and not rc(u, v, 0.28, 0.1, 0.72, 0.38) and
    not rc(u, v, 0.26, 0.56, 0.74, 0.9)
proc sMoon(u, v: float): bool =
  ringAt(u, v, 0.5, 0.5, 0.42, 0.42) and not disc(u, v, 0.72, 0.36, 0.34) or
    disc(u, v, 0.4, 0.58, 0.16)
proc sExit(u, v: float): bool =
  rc(u, v, 0.1, 0.12, 0.2, 0.88) or rc(u, v, 0.1, 0.12, 0.5, 0.22) or
    rc(u, v, 0.1, 0.78, 0.5, 0.88) or rc(u, v, 0.3, 0.45, 0.68, 0.55) or
    (u >= 0.62 and u <= 0.92 and abs(v - 0.5) <= (0.92 - u) * 0.95)
proc sInfo(u, v: float): bool =
  ringAt(u, v, 0.5, 0.5, 0.44, 0.08) or rc(u, v, 0.45, 0.44, 0.55, 0.74) or disc(u, v, 0.5, 0.29, 0.07)
proc sPrev(u, v: float): bool =
  seg(u, v, 0.86, 0.5, 0.14, 0.5, 0.12) or seg(u, v, 0.14, 0.5, 0.46, 0.2, 0.12) or
    seg(u, v, 0.14, 0.5, 0.46, 0.8, 0.12)
proc sNext(u, v: float): bool = sPrev(1 - u, v)
proc sFile(u, v: float): bool =
  (rc(u, v, 0.2, 0.08, 0.8, 0.92) and not (u > 0.56 and v < 0.32 and (u - 0.56) > (0.32 - v))) and
    not rc(u, v, 0.32, 0.5, 0.68, 0.58) and not rc(u, v, 0.32, 0.68, 0.68, 0.76)
proc sButton(u, v: float): bool =
  rc(u, v, 0.06, 0.26, 0.94, 0.74) and not rc(u, v, 0.14, 0.34, 0.86, 0.66) or
    rc(u, v, 0.3, 0.46, 0.7, 0.54)
proc sText(u, v: float): bool = rc(u, v, 0.14, 0.14, 0.86, 0.3) or rc(u, v, 0.43, 0.14, 0.57, 0.88)
proc sSlider(u, v: float): bool =
  (rc(u, v, 0.06, 0.44, 0.94, 0.56) and not disc(u, v, 0.62, 0.5, 0.25)) or disc(u, v, 0.62, 0.5, 0.2)
proc sList(u, v: float): bool =
  for i in 0 .. 2:
    let y = 0.16 + i.float * 0.27
    if rc(u, v, 0.1, y, 0.22, y + 0.13) or rc(u, v, 0.32, y, 0.9, y + 0.13): return true
proc sData(u, v: float): bool =
  rc(u, v, 0.12, 0.12, 0.88, 0.34) or rc(u, v, 0.12, 0.4, 0.88, 0.6) or rc(u, v, 0.12, 0.66, 0.88, 0.88)
proc sLayout(u, v: float): bool =
  rc(u, v, 0.08, 0.08, 0.56, 0.44) or rc(u, v, 0.62, 0.08, 0.92, 0.44) or
    rc(u, v, 0.08, 0.5, 0.38, 0.92) or rc(u, v, 0.44, 0.5, 0.92, 0.92)
proc sPaint(u, v: float): bool =
  disc(u, v, 0.5, 0.5, 0.42) and not disc(u, v, 0.34, 0.38, 0.09) and
    not disc(u, v, 0.62, 0.34, 0.09) and not disc(u, v, 0.7, 0.6, 0.09) and
    not disc(u, v, 0.45, 0.7, 0.09)
proc sDialog(u, v: float): bool =
  rc(u, v, 0.08, 0.16, 0.92, 0.34) or
    (rc(u, v, 0.08, 0.16, 0.92, 0.84) and not rc(u, v, 0.16, 0.4, 0.84, 0.76))
proc sCode(u, v: float): bool =
  seg(u, v, 0.34, 0.24, 0.1, 0.5, 0.12) or seg(u, v, 0.1, 0.5, 0.34, 0.76, 0.12) or
    seg(u, v, 0.66, 0.24, 0.9, 0.5, 0.12) or seg(u, v, 0.9, 0.5, 0.66, 0.76, 0.12) or
    seg(u, v, 0.57, 0.18, 0.43, 0.82, 0.1)
proc sImage(u, v: float): bool =
  (rc(u, v, 0.08, 0.16, 0.92, 0.84) and not rc(u, v, 0.15, 0.23, 0.85, 0.77)) or
    disc(u, v, 0.68, 0.4, 0.09) or
    (v >= 0.5 and v <= 0.77 and abs(u - 0.38) <= (v - 0.45) * 0.9)
proc sArchive(u, v: float): bool =
  (rc(u, v, 0.18, 0.08, 0.82, 0.92) and not rc(u, v, 0.45, 0.08, 0.55, 0.5)) or
    rc(u, v, 0.4, 0.5, 0.6, 0.68)
proc sCheck(u, v: float): bool =
  seg(u, v, 0.14, 0.54, 0.4, 0.78, 0.14) or seg(u, v, 0.4, 0.78, 0.88, 0.24, 0.14)

proc makeIcon*(size: int, color: Color, inside: Shape): Image =
  ## An icon of `size` logical px drawn at 2x, 3x3 supersampled.
  let n = size * 2
  result = newImage(n, n)
  for y in 0 ..< n:
    for x in 0 ..< n:
      var hit = 0
      for sy in 0 .. 2:
        for sx in 0 .. 2:
          if inside((x.float + (sx.float + 0.5) / 3) / n.float,
                    (y.float + (sy.float + 0.5) / 3) / n.float):
            inc hit
      if hit > 0: result.setPixel(x, y, rgba(color.r.int, color.g.int, color.b.int, hit * 255 div 9))

proc makeIcons*(size = 16): ImageList =
  ## The icon set; the file-type icons (folder, file, image, ...) are coloured.
  result = newImageList(size.float32, size.float32)
  let shapes: array[icCount, tuple[s: Shape, c: Color]] = [
    (Shape(sOpen), accentBlue), (Shape(sSave), accentBlue), (Shape(sMoon), accentBlue),
    (Shape(sExit), accentBlue), (Shape(sInfo), accentBlue), (Shape(sPrev), accentBlue),
    (Shape(sNext), accentBlue), (Shape(sOpen), amber), (Shape(sFile), slate),
    (Shape(sButton), accentBlue), (Shape(sText), accentBlue), (Shape(sSlider), accentBlue),
    (Shape(sList), accentBlue), (Shape(sData), accentBlue), (Shape(sLayout), accentBlue),
    (Shape(sPaint), accentBlue), (Shape(sDialog), accentBlue), (Shape(sCode), violet),
    (Shape(sImage), green), (Shape(sArchive), amber), (Shape(sCheck), green)]
  for (s, c) in shapes: result.add makeIcon(size, c, s)

# ------------------------------------------------------------------ fonts

proc registerCjkFont*(): bool =
  ## The bundled fonts have no CJK glyphs. Registers a system CJK font as a
  ## fallback when there is one and says whether it did.
  for f in ["/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/noto-cjk/NotoSansCJK-DemiLight.ttc",
            "/usr/share/fonts/OTF/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc"]:
    if fileExists(f):
      addFallbackFontFile(f)
      return true

# ------------------------------------------------------------------ context

type
  PageHook* = object
    page*: int
    activate*: proc(on: bool)         ## the page was shown or hidden

  Showcase* = ref object
    ## State shared by the form and the page builders.
    say*: proc(text: string)          ## status bar message
    icons*: ImageList                 ## 16 px
    bigIcons*: ImageList              ## 32 px, for the icon views
    hooks*: seq[PageHook]
    muted*: seq[Label]                ## labels that follow theme.textMuted
    shotMode*: bool                   ## screenshots: no timers, fixed values
    pickFile*: proc()                 ## the Open action
    dark*: bool
    listPages*: PageControl           ## the tabs of the "Lists & trees" page
    popupMenu*: PopupMenu             ## the context menu of the "Dialogs & menus" page
    cjk*: bool                        ## a CJK fallback font is registered

proc newShowcase*(): Showcase =
  Showcase(icons: makeIcons(16), bigIcons: makeIcons(32), cjk: registerCjkFont(),
           say: proc(text: string) = discard)

proc refreshMuted*(ctx: Showcase) =
  for l in ctx.muted: l.textColor = currentTheme().textMuted

# ------------------------------------------------------------------ helpers

proc thousands*(n: int): string =
  let s = $abs(n)
  for i, ch in s:
    if i > 0 and (s.len - i) mod 3 == 0: result.add ','
    result.add ch
  if n < 0: result = "-" & result

proc mutedLabel*(ctx: Showcase, parent: Container, text: string, left = 0'f32,
                 top = 0'f32, width = -1'f32, height = -1'f32): Label =
  result = newLabel(parent, text, left, top, width, height)
  result.textColor = currentTheme().textMuted
  ctx.muted.add result

proc boldLabel*(parent: Container, text: string, left = 0'f32, top = 0'f32,
                size = 14'f32): Label =
  result = newLabel(parent, text, left, top)
  result.font = font(size = size, style = {fsBold})

const
  BodyW* = 810'f32                       ## design size of a page body (at 1100x720)
  BodyH* = 537'f32

proc newPage*(ctx: Showcase, host: Container, title, subtitle: string): tuple[page, body: Panel] =
  ## A page: big title, muted subtitle, and a `body` panel that fills the rest.
  let page = newPanel(host)
  page.align = alClient
  page.borderStyle = pbNone
  page.padding = spacing(24, 18, 24, 14)
  page.visible = false
  let t = newLabel(page, title.replace("&", "&&"))
  t.align = alTop
  t.font = font(size = 22, style = {fsBold})
  t.margins = spacing(0, 0, 0, 2)
  let s = ctx.mutedLabel(page, subtitle.replace("&", "&&"))
  s.align = alTop
  s.margins = spacing(0, 0, 0, 12)
  let body = newPanel(page)
  body.borderStyle = pbNone
  body.setBounds(0, 0, BodyW, BodyH)     # the design size the anchors are relative to
  body.align = alClient
  (page, body)

proc card*(parent: Container, caption: string, left, top, width, height: float32,
           anchors: Anchors = DefaultAnchors): GroupBox =
  result = newGroupBox(parent, caption, left, top, width, height)
  result.anchors = anchors

proc addHook*(ctx: Showcase, page: int, activate: proc(on: bool)) =
  ctx.hooks.add PageHook(page: page, activate: activate)

const PageNames* = ["Buttons & choices", "Text input", "Ranges", "Lists & trees",
                    "Big data", "Layout", "Painting", "Dialogs & menus", "Form macro"]
