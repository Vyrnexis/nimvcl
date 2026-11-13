## `Canvas`: immediate-mode 2D drawing over a `RenderContext`.
##
## All coordinates are LOGICAL pixels (float32); the canvas multiplies by the
## context's scale. Create one per frame with `beginFrame` and finish with
## `endFrame`. Coordinates passed to drawing calls are relative to the current
## translate offset.
##
## Crispness rules: `fillRect`, `frameRect`, `drawImage` and the rounded
## shapes snap their edges to whole device pixels; text origins are snapped to
## device pixels. `line` and `fillPolygon`/ellipses are not snapped (the caller
## picks the coordinates), and are anti-aliased.

import std/[math, strutils]
import sdl3 except Color
import sdl3_ttf
import ./color, ./geometry, ./font, ./image, ./aa, ./context

type
  HAlign* = enum taLeft, taCenter, taRight
  VAlign* = enum vaTop, vaCenter, vaBottom

  Canvas* = ref object
    ## Per-frame drawing surface. Not thread safe.
    ctx: RenderContext
    ox, oy: float32                  # current translate (logical)
    offsets: seq[(float32, float32)]
    clips: seq[RectF]                # absolute logical rects; [0] is the full target
    ended: bool

const Ellipsis = "\u2026"

func ctx*(c: Canvas): RenderContext = c.ctx
func scale*(c: Canvas): float32 = c.ctx.scale

proc applyClip(c: Canvas) =
  let s = c.ctx.scale
  let r = renderer(c.ctx)
  if c.clips.len <= 1:
    discard setRenderClipRect(r, nil)
  else:
    let cl = c.clips[^1]
    let x0 = round(cl.x * s)
    let y0 = round(cl.y * s)
    let x1 = round(cl.right * s)
    let y1 = round(cl.bottom * s)
    var rc = Rect(x: x0.cint, y: y0.cint, w: max(x1 - x0, 0).cint,
                  h: max(y1 - y0, 0).cint)
    discard setRenderClipRect(r, addr rc)

proc beginFrame*(ctx: RenderContext): Canvas =
  ## Starts a frame: advances the cache clock, resets the clip and translate
  ## stacks and enables alpha blending.
  ctx.beginFrameTick()
  var w, h: cint
  discard getCurrentRenderOutputSize(ctx.renderer, w, h)
  result = Canvas(ctx: ctx)
  result.clips.add rectF(0, 0, w.float32 / ctx.scale, h.float32 / ctx.scale)
  discard setRenderDrawBlendMode(ctx.renderer, BLENDMODE_BLEND)
  discard setRenderClipRect(ctx.renderer, nil)

proc endFrame*(c: Canvas) =
  ## Ends the frame: restores the clip and sweeps idle cache entries. Does not
  ## present; the caller owns `renderPresent` (or reads pixels back).
  if c.ended: return
  c.ended = true
  discard setRenderClipRect(renderer(c.ctx), nil)
  c.ctx.sweep()

# ------------------------------------------------------------- state stacks

proc pushTranslate*(c: Canvas, dx, dy: float32) =
  ## Moves the origin by (dx, dy) until the matching `popTranslate`.
  c.offsets.add (c.ox, c.oy)
  c.ox += dx
  c.oy += dy

proc popTranslate*(c: Canvas) =
  doAssert c.offsets.len > 0, "popTranslate without pushTranslate"
  (c.ox, c.oy) = c.offsets.pop()

proc pushClip*(c: Canvas, rect: RectF) =
  ## Intersects the clip with `rect` (in current local coordinates).
  c.clips.add intersect(c.clips[^1], rect.offset(c.ox, c.oy))
  c.applyClip()

proc popClip*(c: Canvas) =
  doAssert c.clips.len > 1, "popClip without pushClip"
  discard c.clips.pop()
  c.applyClip()

func clipDepth*(c: Canvas): int = c.clips.len - 1

func currentClip*(c: Canvas): RectF =
  ## Current clip in LOCAL coordinates (the target bounds when nothing is pushed).
  c.clips[^1].offset(-c.ox, -c.oy)

func isClippedOut*(c: Canvas, rect: RectF): bool =
  ## True when `rect` (local coordinates) cannot touch any visible pixel.
  not c.clips[^1].intersects(rect.offset(c.ox, c.oy))

# ---------------------------------------------------------- device helpers

func dev(c: Canvas, v: float32): float32 {.inline.} = round(v * c.ctx.scale)

proc setColor(c: Canvas, col: Color) =
  discard setRenderDrawColor(renderer(c.ctx), col.r, col.g, col.b, col.a)

# Device-pixel rect with snapped edges.
func snapRect(c: Canvas, r: RectF): FRect =
  let s = c.ctx.scale
  let x0 = round((r.x + c.ox) * s)
  let y0 = round((r.y + c.oy) * s)
  let x1 = round((r.right + c.ox) * s)
  let y1 = round((r.bottom + c.oy) * s)
  FRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

proc flushGeo(c: Canvas) =
  if not c.ctx.geo.isEmpty:
    discard renderGeometry(renderer(c.ctx), nil, c.ctx.geo.verts, c.ctx.geo.idx)
  c.ctx.geo.clear()

# --------------------------------------------------------------- primitives

proc clear*(c: Canvas, color: Color) =
  ## Fills the whole render target; like SDL_RenderClear it ignores the clip.
  c.setColor color
  discard renderClear(renderer(c.ctx))

proc fillRect*(c: Canvas, rect: RectF, color: Color) =
  ## Fills a rect with edges snapped to device pixels (not anti-aliased).
  let r = c.snapRect(rect)
  if r.w <= 0 or r.h <= 0 or color.a == 0: return
  c.setColor color
  discard renderFillRect(renderer(c.ctx), r)

proc frameRect*(c: Canvas, rect: RectF, color: Color, width: float32 = 1) =
  ## Rectangular border of `width` logical px drawn INSIDE `rect`. The border
  ## thickness is rounded to whole device pixels (at least 1), so 1 logical px
  ## is crisp at 1x, 1.5x and 2x.
  let r = c.snapRect(rect)
  if r.w <= 0 or r.h <= 0 or color.a == 0: return
  let bw = min(max(round(width * c.ctx.scale), 1'f32), min(r.w, r.h) / 2)
  c.setColor color
  let rr = renderer(c.ctx)
  if r.h <= 2 * bw or r.w <= 2 * bw:
    discard renderFillRect(rr, r)
    return
  discard renderFillRect(rr, FRect(x: r.x, y: r.y, w: r.w, h: bw))                       # top
  discard renderFillRect(rr, FRect(x: r.x, y: r.y + r.h - bw, w: r.w, h: bw))            # bottom
  discard renderFillRect(rr, FRect(x: r.x, y: r.y + bw, w: bw, h: r.h - 2 * bw))         # left
  discard renderFillRect(rr, FRect(x: r.x + r.w - bw, y: r.y + bw, w: bw, h: r.h - 2 * bw)) # right

proc fillRoundRect*(c: Canvas, rect: RectF, radius: float32, color: Color) =
  ## Anti-aliased filled rounded rect; edges snapped to device pixels.
  if color.a == 0: return
  let r = c.snapRect(rect)
  c.ctx.geo.addFillRoundRect(r.x, r.y, r.w, r.h, radius * c.ctx.scale, color)
  c.flushGeo()

proc strokeRoundRect*(c: Canvas, rect: RectF, radius: float32, color: Color,
                      width: float32 = 1) =
  ## Anti-aliased rounded border of `width` logical px, drawn inside `rect`.
  if color.a == 0: return
  let r = c.snapRect(rect)
  c.ctx.geo.addStrokeRoundRect(r.x, r.y, r.w, r.h, radius * c.ctx.scale,
                               max(width * c.ctx.scale, 1'f32), color)
  c.flushGeo()

proc fillEllipse*(c: Canvas, rect: RectF, color: Color) =
  ## Anti-aliased ellipse inscribed in `rect`.
  if color.a == 0: return
  let r = c.snapRect(rect)
  c.ctx.geo.addFillEllipse(r.x, r.y, r.w, r.h, color)
  c.flushGeo()

proc strokeEllipse*(c: Canvas, rect: RectF, color: Color, width: float32 = 1) =
  ## Anti-aliased ellipse outline of `width` logical px, drawn inside `rect`.
  if color.a == 0: return
  let r = c.snapRect(rect)
  c.ctx.geo.addStrokeEllipse(r.x, r.y, r.w, r.h, max(width * c.ctx.scale, 1'f32), color)
  c.flushGeo()

proc line*(c: Canvas, x1, y1, x2, y2: float32, color: Color, width: float32 = 1) =
  ## Anti-aliased line, centred on the segment, butt caps. Not pixel snapped:
  ## an axis-aligned 1 px line is crisp only if it sits on a pixel centre
  ## (e.g. y = n + 0.5 at 1x).
  if color.a == 0: return
  let s = c.ctx.scale
  c.ctx.geo.addLine((x1 + c.ox) * s, (y1 + c.oy) * s, (x2 + c.ox) * s,
                    (y2 + c.oy) * s, width * s, color)
  c.flushGeo()

proc fillPolygon*(c: Canvas, points: openArray[PointF], color: Color) =
  ## Anti-aliased filled polygon. CONVEX polygons only (any winding): concave
  ## shapes would be filled incorrectly. Points are not snapped.
  if color.a == 0 or points.len < 3: return
  let s = c.ctx.scale
  var pts = newSeqOfCap[FPoint](points.len)
  for p in points:
    pts.add FPoint(x: (p.x + c.ox) * s, y: (p.y + c.oy) * s)
  c.ctx.geo.addFillPolygon(pts, color)
  c.flushGeo()

proc drawImage*(c: Canvas, img: Image, dst: RectF, src: RectF = RectF(),
                alpha: uint8 = 255) =
  ## Draws `img` stretched into `dst` (logical). `src` is in IMAGE pixels; an
  ## empty `src` (the default) means the whole image. `alpha` modulates opacity.
  if alpha == 0 or dst.isEmpty: return
  let tex = c.ctx.textureFor(img)
  discard setTextureAlphaMod(tex, alpha)
  var d = c.snapRect(dst)
  var sr = if src.isEmpty: FRect(x: 0, y: 0, w: img.width.float32, h: img.height.float32)
           else: FRect(x: src.x, y: src.y, w: src.w, h: src.h)
  discard renderTexture(renderer(c.ctx), tex, addr sr, addr d)

# -------------------------------------------------------------------- text

proc measureText*(c: Canvas, text: string, font: FontSpec,
                  maxWidth: float32 = 0): SizeF =
  ## Size in logical px. `maxWidth` > 0 wraps at that width.
  let wrap = if maxWidth > 0: int(floor(maxWidth * c.ctx.scale)) else: 0
  let (w, h) = c.ctx.measureDevice(text, font, wrap)
  sizeF(w / c.ctx.scale, h / c.ctx.scale)

proc fontMetrics*(c: Canvas, font: FontSpec): FontMetrics =
  ## Ascent, descent and line height in logical px.
  c.ctx.fontMetrics(font)

proc drawDecorations(c: Canvas, t: ptr Text, font: FontSpec, dx, dy: float32,
                    color: Color) =
  ## Underline and strike-out, drawn here because SDL_ttf's renderer engine clips
  ## the underline and renders the strike as a light gap. One rect per laid-out
  ## line (works for wrapped and multi-line text), in the text colour.
  let s = c.ctx.scale
  let px = (if font.size <= 0: DefaultFontSize else: font.size) * s
  let fm = c.ctx.fontMetrics(font)
  let thick = max(round(px / 14), 1'f32)
  let gap = max(round(px * 0.09), 1'f32)           # baseline to underline top
  c.setColor color
  for i in 0 ..< t.num_lines:
    var sub: SubString
    if not getTextSubStringForLine(t, i.cint, sub): continue
    let baseline = dy + sub.rect.y.float32 + fm.ascent * s
    let x = dx + sub.rect.x.float32
    let w = sub.rect.w.float32
    if fsUnderline in font.style:
      discard renderFillRect(renderer(c.ctx), FRect(
        x: x, y: round(baseline) + gap, w: w, h: thick))
    if fsStrikeOut in font.style:      # around the middle of the x-height
      discard renderFillRect(renderer(c.ctx), FRect(
        x: x, y: round(baseline - 0.3 * fm.ascent * s - thick / 2), w: w, h: thick))

proc drawTextDev(c: Canvas, text: string, font: FontSpec, dx, dy: float32,
                 color: Color, wrapPx = 0, align = horizontalAlignLeft) =
  if text.len == 0 or color.a == 0: return
  let t = c.ctx.getText(text, font, wrapPx, align)
  discard setTextColor(t, color.r, color.g, color.b, color.a)
  discard drawRendererText(t, dx, dy)
  if font.style * {fsUnderline, fsStrikeOut} != {}: c.drawDecorations(t, font, dx, dy, color)

proc drawText*(c: Canvas, text: string, font: FontSpec, x, y: float32, color: Color) =
  ## Draws `text` with its top-left at (x, y). Embedded newlines break lines.
  c.drawTextDev(text, font, c.dev(x + c.ox), c.dev(y + c.oy), color)

func firstLine(s: string): string =
  let i = s.find('\n')
  if i < 0: s else: s[0 ..< i]

proc ellipsize(c: Canvas, text: string, font: FontSpec, maxPx: float32): string =
  ## `text` shortened with an ellipsis so it fits in `maxPx` device px.
  let full = c.ctx.measureDevice(text, font).w
  if full <= maxPx: return text
  let ew = c.ctx.measureDevice(Ellipsis, font).w
  if ew > maxPx: return ""
  var n = c.ctx.fitPrefix(text, font, maxPx - ew)
  n = min(n, text.len)
  while n > 0 and text[n - 1] in {' ', '\t'}: dec n
  text[0 ..< n] & Ellipsis

proc textRect*(c: Canvas, text: string, font: FontSpec, rect: RectF, color: Color,
               hAlign = taLeft, vAlign = vaTop, wrap = false, ellipsis = true) =
  ## Draws text aligned inside `rect` and clipped to it.
  ## Single line (`wrap = false`): only the first line of `text` is shown, and
  ## when it does not fit it is cut with "…" (if `ellipsis`).
  ## `wrap = true`: a paragraph wrapped at the rect width (hAlign applies to
  ## each line), vertically aligned as a block, clipped to the rect.
  if rect.isEmpty or text.len == 0 or color.a == 0: return
  let r = c.snapRect(rect)          # device rect, absolute
  var str = text
  var wrapPx = 0
  if wrap:
    wrapPx = int(r.w)
  else:
    str = firstLine(text)
    if ellipsis: str = c.ellipsize(str, font, r.w)
    if str.len == 0: return
  let (tw, th) = c.ctx.measureDevice(str, font, wrapPx)
  var x = r.x
  case hAlign
  of taLeft: discard
  of taCenter: x = r.x + (r.w - tw) / 2
  of taRight: x = r.x + r.w - tw
  var y = r.y
  case vAlign
  of vaTop: discard
  of vaCenter: y = r.y + (r.h - th) / 2
  of vaBottom: y = r.y + r.h - th
  let needClip = wrap or tw > r.w or th > r.h
  if needClip:
    c.pushClip(rect)
  if wrap:
    # the paragraph box is r.w wide, so alignment happens inside the text object
    let al = case hAlign
             of taLeft: horizontalAlignLeft
             of taCenter: horizontalAlignCenter
             of taRight: horizontalAlignRight
    c.drawTextDev(str, font, r.x, round(y), color, wrapPx, al)
  else:
    c.drawTextDev(str, font, round(x), round(y), color)
  if needClip: c.popClip()
