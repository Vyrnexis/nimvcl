## `StatusBar` (VCL TStatusBar): `alBottom` by default.
##
## Either one line of `simpleText` (`simplePanel = true`) or `panels`: each
## has `text`, `width` and `alignment`; the LAST panel takes all the space that
## is left (its `width` is ignored). `sizeGrip` draws the resize grip in the
## bottom-right corner (reserved from the last panel). Panels are `StatusPanel`
## refs: change `text` later and the bar repaints.
##
## Panel geometry is available as `panelRect(i)` (client coordinates).

import ./common

type
  StatusPanel* = ref object
    fText: string
    width*: float32
    alignment*: HAlign
    bar: StatusBar

  StatusBar* = ref object of Control
    fPanels: seq[StatusPanel]
    fSimple: bool
    fSizeGrip: bool

const GripSize = 14'f32

func text*(p: StatusPanel): string = p.fText
proc `text=`*(p: StatusPanel, v: string) =
  if v == p.fText: return
  p.fText = v
  if p.bar != nil: p.bar.invalidate()

func panels*(b: StatusBar): seq[StatusPanel] = b.fPanels
func simplePanel*(b: StatusBar): bool = b.fSimple
proc `simplePanel=`*(b: StatusBar, v: bool) =
  b.fSimple = v
  b.invalidate()
proc simpleText*(b: StatusBar): string = b.caption
proc `simpleText=`*(b: StatusBar, v: string) =
  ## Sets the simple text and switches to simple mode.
  b.caption = v
  b.fSimple = true
  b.invalidate()

func sizeGrip*(b: StatusBar): bool = b.fSizeGrip
proc `sizeGrip=`*(b: StatusBar, v: bool) =
  b.fSizeGrip = v
  b.invalidate()

proc addPanel*(b: StatusBar, text = "", width = 100'f32,
               alignment = taLeft): StatusPanel {.discardable.} =
  result = StatusPanel(fText: text, width: width, alignment: alignment, bar: b)
  b.fPanels.add result
  b.invalidate()

proc clearPanels*(b: StatusBar) =
  b.fPanels.setLen 0
  b.invalidate()

proc panelRect*(b: StatusBar, i: int): RectF =
  ## Client rectangle of panel `i`.
  let grip = if b.fSizeGrip: GripSize else: 0'f32
  var x = 0'f32
  for k in 0 ..< i: x += b.fPanels[k].width
  if i == b.fPanels.high:
    rectF(x, 0, max(b.width - x - grip, 0), b.height)
  else:
    rectF(x, 0, b.fPanels[i].width, b.height)

method paint*(b: StatusBar, c: Canvas) =
  let t = b.theme
  let col = if b.isEnabled: t.textMuted else: t.textDisabled
  let r = b.clientRect
  c.fillRect(r, t.surfaceAlt)
  c.line(0, 0.5, r.w, 0.5, t.border, 1)
  if b.fSimple or b.fPanels.len == 0:
    c.textRect(b.caption, b.font, rectF(t.spacing, 1, max(r.w - GripSize - t.spacing, 0), r.h - 1),
               col, taLeft, vaCenter)
  else:
    for i, p in b.fPanels:
      let pr = b.panelRect(i)
      c.textRect(p.text, b.font, rectF(pr.x + t.spacing, 1, max(pr.w - 2 * t.spacing, 0), r.h - 1),
                 col, p.alignment, vaCenter)
      if i < b.fPanels.high:
        c.line(pr.right - 0.5, 4, pr.right - 0.5, r.h - 3, t.border, 1)
  if b.fSizeGrip:
    for k in 0 .. 2:
      let d = 4'f32 + float32(k) * 4
      c.line(r.w - 2, r.h - 2 - d, r.w - 2 - d, r.h - 2, t.borderStrong, 1.5)
  procCall paint(Control(b), c)

proc initStatusBar*(b: StatusBar, owner: Component = nil) =
  b.initControl(owner)
  b.setBounds(0, 0, 200, 24)
  b.align = alBottom

proc newStatusBar*(parent: Container = nil, simpleText = ""): StatusBar =
  new result
  result.initStatusBar(parent)
  if simpleText.len > 0: result.simpleText = simpleText
  if parent != nil: parent.insertControl result
