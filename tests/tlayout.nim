## Layout, tree and hit-testing tests. Pure Nim (no SDL init).

import std/[unittest, math]
import nimvcl

type
  Auto = ref object of Control
    pw, ph: float32
  Custom = ref object of Container
    seen: seq[RectF]
  MockHost = ref object of RootHost
    layoutRequests: int

method preferredSize(c: Auto): SizeF = sizeF(c.pw, c.ph)
method customAlign(c: Custom, child: Control, available: RectF) =
  c.seen.add available
  child.setBounds(available.x + 1, available.y + 2, 7, 8)
method requestLayout(h: MockHost) = inc h.layoutRequests

proc newAuto(pw, ph: float32): Auto =
  result = Auto(pw: pw, ph: ph)
  result.initControl()

proc root(w, h: float32): Container =
  result = newContainer()
  result.setBounds(0, 0, w, h)

proc kid(parent: Container, a: Align, w, h: float32): Control =
  result = newControl()
  result.align = a
  result.setBounds(0, 0, w, h)
  result.parent = parent

proc box(c: Control): (float32, float32, float32, float32) =
  (c.left, c.top, c.width, c.height)

proc b(l, t, w, h: float32): (float32, float32, float32, float32) = (l, t, w, h)

suite "align":
  test "top bottom left right client combination":
    let r = root(200, 100)
    let cl = r.kid(alClient, 1, 1)         # added first on purpose
    let ri = r.kid(alRight, 40, 1)
    let le = r.kid(alLeft, 30, 1)
    let bo = r.kid(alBottom, 1, 10)
    let to = r.kid(alTop, 1, 20)
    layout r
    check to.box == b(0, 0, 200, 20)
    check bo.box == b(0, 90, 200, 10)
    check le.box == b(0, 20, 30, 70)
    check ri.box == b(160, 20, 40, 70)
    check cl.box == b(30, 20, 130, 70)

  test "multiple of each, in child order":
    let r = root(200, 100)
    let t1 = r.kid(alTop, 1, 20)
    let t2 = r.kid(alTop, 1, 10)
    let b1 = r.kid(alBottom, 1, 10)
    let b2 = r.kid(alBottom, 1, 20)
    let l1 = r.kid(alLeft, 10, 1)
    let l2 = r.kid(alLeft, 20, 1)
    let r1 = r.kid(alRight, 10, 1)
    let r2 = r.kid(alRight, 20, 1)
    layout r
    check t1.box == b(0, 0, 200, 20)
    check t2.box == b(0, 20, 200, 10)
    check b1.box == b(0, 90, 200, 10)
    check b2.box == b(0, 70, 200, 20)
    check l1.box == b(0, 30, 10, 40)
    check l2.box == b(10, 30, 20, 40)
    check r1.box == b(190, 30, 10, 40)
    check r2.box == b(170, 30, 20, 40)

  test "several alClient share the rect":
    let r = root(100, 50)
    let a = r.kid(alClient, 1, 1)
    let c = r.kid(alClient, 1, 1)
    layout r
    check a.box == b(0, 0, 100, 50)
    check c.box == a.box

  test "margins":
    let r = root(200, 100)
    let t = r.kid(alTop, 1, 20)
    t.margins = spacing(5)
    let t2 = r.kid(alTop, 1, 10)
    let cl = r.kid(alClient, 1, 1)
    cl.margins = spacing(2, 3)
    layout r
    check t.box == b(5, 5, 190, 20)
    check t2.box == b(0, 30, 200, 10)
    check cl.box == b(2, 43, 196, 54)

  test "margins on bottom/left/right":
    let r = root(100, 100)
    let bo = r.kid(alBottom, 1, 10)
    bo.margins = spacing(1, 2, 3, 4)
    let le = r.kid(alLeft, 10, 1)
    le.margins = spacing(5, 0, 5, 0)
    let ri = r.kid(alRight, 10, 1)
    ri.margins = spacing(2, 0, 6, 0)
    layout r
    check bo.box == b(1, 86, 96, 10)     # y = 100 - 4 - 10
    check le.box == b(5, 0, 10, 84)      # remaining: 0 .. (86 - top margin 2)
    check ri.left == 84'f32

  test "padding":
    let r = root(200, 100)
    r.padding = spacing(10)
    let t = r.kid(alTop, 1, 20)
    let cl = r.kid(alClient, 1, 1)
    layout r
    check t.box == b(10, 10, 180, 20)
    check cl.box == b(10, 30, 180, 60)

  test "invisible children are skipped":
    let r = root(100, 100)
    let t = r.kid(alTop, 1, 30)
    let t2 = r.kid(alTop, 1, 10)
    t.visible = false
    layout r
    check t2.box == b(0, 0, 100, 10)

  test "remaining space never goes negative":
    let r = root(100, 50)
    discard r.kid(alTop, 1, 80)
    let cl = r.kid(alClient, 1, 1)
    layout r
    check cl.height == 0
    check cl.width == 100

  test "idempotent":
    let r = root(120, 90)
    let t = r.kid(alTop, 1, 20)
    let cl = r.kid(alClient, 1, 1)
    layout r
    let (a, c) = (t.box, cl.box)
    layout r
    check t.box == a
    check cl.box == c

suite "constraints":
  test "alClient max width":
    let r = root(200, 100)
    let cl = r.kid(alClient, 1, 1)
    cl.constraints = constraints(maxWidth = 50)
    layout r
    check cl.box == b(0, 0, 50, 100)

  test "alClient min size beats available":
    let r = root(100, 100)
    let cl = r.kid(alClient, 1, 1)
    cl.constraints = constraints(minWidth = 150, minHeight = 120)
    layout r
    check cl.box == b(0, 0, 150, 120)

  test "cross axis of alTop / alLeft":
    let r = root(200, 100)
    let t = r.kid(alTop, 1, 20)
    t.constraints = constraints(maxWidth = 120)
    layout r
    check t.box == b(0, 0, 120, 20)
    let r2 = root(200, 100)
    let l = r2.kid(alLeft, 20, 1)
    l.constraints = constraints(minHeight = 130)
    layout r2
    check l.box == b(0, 0, 20, 130)

  test "main axis clamp is used for stacking":
    let r = root(100, 100)
    let t = r.kid(alTop, 1, 10)
    t.constraints = constraints(minHeight = 30)
    let t2 = r.kid(alTop, 1, 10)
    layout r
    check t.height == 30
    check t2.top == 30

  test "setBounds clamps":
    let c = newControl()
    c.constraints = constraints(minWidth = 20, maxWidth = 40, maxHeight = 10)
    c.setBounds(0, 0, 5, 99)
    check c.box == b(0, 0, 20, 10)
    c.width = 100
    check c.width == 40
    c.setBounds(0, 0, -5, -5)
    check c.height == 0

suite "autoSize":
  test "per alignment":
    let r = root(200, 100)
    let t = newAuto(60, 22)
    t.align = alTop
    t.autoSize = true
    t.parent = r
    let l = newAuto(35, 99)
    l.align = alLeft
    l.autoSize = true
    l.parent = r
    let n = newAuto(60, 20)
    n.setBounds(7, 8, 1, 1)
    n.autoSize = true
    n.parent = r
    let cl = newAuto(77, 77)
    cl.align = alClient
    cl.autoSize = true
    cl.parent = r
    layout r
    check t.box == b(0, 0, 200, 22)
    check l.box == b(0, 22, 35, 78)
    check n.box == b(7, 8, 60, 20)
    check cl.box == b(35, 22, 165, 78)

  test "autoSize honours constraints":
    let r = root(200, 100)
    let t = newAuto(1, 80)
    t.align = alTop
    t.autoSize = true
    t.constraints = constraints(maxHeight = 40)
    t.parent = r
    layout r
    check t.height == 40

  test "autoSize off keeps size":
    let r = root(200, 100)
    let t = newAuto(1, 80)
    t.align = alTop
    t.setBounds(0, 0, 10, 15)
    t.parent = r
    layout r
    check t.height == 15

suite "anchors":
  proc resized(a: Anchors): Control =
    let r = root(200, 100)
    result = newControl()
    result.setBounds(10, 10, 50, 20)
    result.anchors = a
    result.parent = r
    layout r                       # records the size
    check result.box == b(10, 10, 50, 20)
    r.setBounds(0, 0, 300, 150)    # dw = 100, dh = 50
    layout r

  test "left+top (default) unchanged":
    check resized({akLeft, akTop}).box == b(10, 10, 50, 20)
  test "left+right stretches":
    check resized({akLeft, akRight, akTop}).box == b(10, 10, 150, 20)
  test "right moves":
    check resized({akRight, akTop}).box == b(110, 10, 50, 20)
  test "no horizontal anchor centres":
    check resized({akTop}).box == b(60, 10, 50, 20)
  test "top+bottom stretches":
    check resized({akLeft, akTop, akBottom}).box == b(10, 10, 50, 70)
  test "bottom moves":
    check resized({akLeft, akBottom}).box == b(10, 60, 50, 20)
  test "no vertical anchor centres":
    check resized({akLeft}).box == b(10, 35, 50, 20)
  test "no anchors at all":
    check resized({}).box == b(60, 35, 50, 20)
  test "all anchors":
    check resized({akLeft, akTop, akRight, akBottom}).box == b(10, 10, 150, 70)
  test "odd delta snaps to whole pixels":
    let r = root(200, 100)
    let c = newControl()
    c.setBounds(10, 10, 50, 20)
    c.anchors = {}
    c.parent = r
    layout r
    r.setBounds(0, 0, 201, 101)
    layout r
    check c.left == 11      # 10 + 0.5 -> 11
    check c.top == 11
  test "first layout only records":
    let r = root(500, 500)
    let c = newControl()
    c.setBounds(10, 10, 50, 20)
    c.anchors = {akRight, akBottom}
    c.parent = r
    layout r
    check c.box == b(10, 10, 50, 20)
  test "same size does not move":
    let r = root(200, 100)
    let c = newControl()
    c.setBounds(10, 10, 50, 20)
    c.anchors = {akRight}
    c.parent = r
    layout r
    layout r
    check c.box == b(10, 10, 50, 20)

suite "anchors: design baseline":
  proc design(): (Container, Control, Control) =
    ## A 400x300 form with an akRight|akBottom button and an akLeft+akRight edit.
    let r = newContainer()
    r.setBounds(0, 0, 400, 300)
    let btn = newControl()
    btn.setBounds(320, 260, 70, 30)
    btn.anchors = {akRight, akBottom}
    btn.parent = r
    let ed = newControl()
    ed.setBounds(10, 10, 380, 24)
    ed.anchors = {akLeft, akTop, akRight}
    ed.parent = r
    (r, btn, ed)

  test "window manager resizes before the first layout":
    let (r, btn, ed) = design()
    let ui = newUiRoot(r)
    ui.resize(1000, 700)             # what a tiling WM does
    layout r
    check btn.box == b(920, 660, 70, 30)
    check ed.box == b(10, 10, 980, 24)
    ui.resize(400, 300)
    layout r
    check btn.box == b(320, 260, 70, 30)
    check ed.box == b(10, 10, 380, 24)

  test "explicit resize before the first layout is the design size, after it is a resize":
    let (r, btn, _) = design()
    r.setBounds(0, 0, 500, 300)      # still designing: baseline 500x300
    layout r
    check btn.left == 320
    r.setBounds(0, 0, 600, 300)
    layout r
    check btn.left == 420

  test "1000 random resizes do not drift":
    let (r, btn, ed) = design()
    let c = newControl()
    c.setBounds(33, 41, 51, 23)
    c.anchors = {}                   # centred: odd deltas round
    c.parent = r
    layout r
    var seed = 12345'u32
    proc rnd(): float32 =
      seed = seed * 1664525'u32 + 1013904223'u32
      float32(100 + (seed shr 8) mod 1500)
    for i in 1..1000:
      r.setBounds(0, 0, rnd(), rnd())
      layout r
      check btn.left == 320 + (r.width - 400)
      check ed.width == 380 + (r.width - 400)
      check c.left == round(33 + (r.width - 400) / 2)
    r.setBounds(0, 0, 400, 300)
    layout r
    check btn.box == b(320, 260, 70, 30)
    check ed.box == b(10, 10, 380, 24)
    check c.box == b(33, 41, 51, 23)

  test "nested alClient panel: baseline is the first laid-out size":
    let r = newContainer()
    r.setBounds(0, 0, 400, 300)
    let panel = newContainer()
    panel.align = alClient
    panel.parent = r
    let btn = newControl()
    btn.setBounds(300, 200, 50, 20)
    btn.anchors = {akRight, akBottom}
    btn.parent = panel
    let ui = newUiRoot(r)
    ui.resize(800, 600)              # panel is first laid out at 800x600
    layout r
    check panel.box == b(0, 0, 800, 600)
    check btn.box == b(300, 200, 50, 20)    # never explicitly sized: no delta
    ui.resize(900, 650)
    layout r
    check btn.box == b(400, 250, 50, 20)

  test "explicitly sized alClient panel gets the delta":
    let r = newContainer()
    r.setBounds(0, 0, 400, 300)
    let panel = newContainer()
    panel.setBounds(0, 0, 400, 300)  # designed at 400x300
    panel.align = alClient
    panel.parent = r
    let btn = newControl()
    btn.setBounds(300, 200, 50, 20)
    btn.anchors = {akRight, akBottom}
    btn.parent = panel
    let ui = newUiRoot(r)
    ui.resize(800, 600)
    layout r
    check btn.box == b(700, 500, 50, 20)

  test "child added after the first layout is relative to the current size":
    let r = newContainer()
    r.setBounds(0, 0, 400, 300)
    let ui = newUiRoot(r)
    ui.resize(800, 600)
    layout r
    let c = newControl()
    c.setBounds(700, 500, 50, 20)
    c.anchors = {akRight, akBottom}
    c.parent = r
    layout r
    check c.box == b(700, 500, 50, 20)
    ui.resize(900, 650)
    layout r
    check c.box == b(800, 550, 50, 20)
    c.setBounds(10, 10, 50, 20)      # explicit move re-baselines
    layout r
    check c.box == b(10, 10, 50, 20)
    ui.resize(800, 600)
    layout r
    check c.box == b(-90, -40, 50, 20)

suite "anchors: default-sized containers":
  test "constructor default size is not a design size (alClient panel)":
    let r = root(800, 600)
    let panel = newPanel(r)            # 200x100 by default, then stretched
    panel.align = alClient
    let c = newControl()
    c.setBounds(10, 10, 100, 20)
    c.anchors = {akLeft, akTop, akRight}
    c.parent = panel
    let ui = newUiRoot(r)
    layout r
    check panel.box == b(0, 0, 800, 600)
    check c.box == b(10, 10, 100, 20)  # as given, relative to the first real size
    ui.resize(900, 600)
    layout r
    check c.box == b(10, 10, 200, 20)
    ui.resize(800, 600)
    layout r
    check c.box == b(10, 10, 100, 20)

  test "bottom/right anchors keep their gap to the first real size":
    let r = root(800, 600)
    let panel = newPanel(r, "", 0, 0)
    panel.align = alClient
    let c = newControl()
    c.setBounds(700, 560, 90, 30)
    c.anchors = {akRight, akBottom}
    c.parent = panel
    let ui = newUiRoot(r)
    layout r
    check c.box == b(700, 560, 90, 30)
    ui.resize(1000, 700)
    layout r
    check c.box == b(900, 660, 90, 30)

  test "alClient panel inside a page that is shown later":
    let r = root(800, 600)
    let page = newPanel(r)
    page.align = alClient
    page.visible = false
    let body = newPanel(page)
    body.align = alClient
    let c = newControl()
    c.setBounds(10, 10, 100, 20)
    c.anchors = {akLeft, akTop, akRight}
    c.parent = body
    layout r                           # the page is hidden: nothing laid out yet
    page.visible = true
    layout r
    check body.width == 800
    check c.box == b(10, 10, 100, 20)

  test "nested default-sized containers (tab sheet in a page control)":
    let r = root(800, 600)
    let pc = newPageControl(r)
    pc.align = alClient
    let sheet = newTabSheet(pc, "One")
    let c = newControl()
    c.setBounds(10, 10, 100, 20)
    c.anchors = {akLeft, akTop, akRight}
    c.parent = sheet
    layout r
    check c.box == b(10, 10, 100, 20)
    check sheet.width > 700

  test "an explicit size still is the design size":
    let r = root(800, 600)
    let panel = newPanel(r, "", 0, 0, 400, 300)   # explicit: designed at 400x300
    panel.align = alClient
    let c = newControl()
    c.setBounds(300, 200, 50, 20)
    c.anchors = {akRight, akBottom}
    c.parent = panel
    layout r
    check c.box == b(700, 500, 50, 20)

suite "rounding":
  test "fractional margins and heights snap and stack without gaps":
    let r = root(100, 100)
    let t1 = r.kid(alTop, 1, 10.3)
    t1.margins = spacing(0.4)
    let cl = r.kid(alClient, 1, 1)
    layout r
    check t1.box == b(0, 0, 99, 10)
    check cl.top == 10            # 10.4 snaps to 10: no gap, no overlap
    check cl.height == 90         # 89.6
    for c in [Control(t1), cl]:
      check c.left == round(c.left) and c.width == round(c.width)
      check c.top == round(c.top) and c.height == round(c.height)

suite "nested":
  test "resize propagates through child containers":
    let r = root(200, 100)
    let panel = newContainer()
    panel.align = alClient
    panel.parent = r
    let right = panel.kid(alRight, 30, 1)
    discard panel.kid(alClient, 1, 1)
    let inner = newContainer()
    inner.align = alTop
    inner.setBounds(0, 0, 1, 40)
    inner.parent = panel
    let deep = inner.kid(alClient, 1, 1)
    layout r
    check panel.box == b(0, 0, 200, 100)
    check right.box == b(170, 40, 30, 60)   # alTop is placed before alRight
    check inner.box == b(0, 0, 200, 40)
    check deep.box == b(0, 0, 200, 40)
    r.setBounds(0, 0, 300, 120)
    layout r
    check right.box == b(270, 40, 30, 80)
    check inner.width == 300
    check deep.box == b(0, 0, 300, 40)

  test "flagged deep container is found from a clean root":
    let r = root(200, 100)
    let panel = newContainer()
    panel.align = alClient
    panel.parent = r
    let c = panel.kid(alTop, 1, 10)
    layout r
    check not r.needsLayout and not r.childNeedsLayout
    c.height = 25                       # alTop: parent relayouts
    check panel.needsLayout and r.childNeedsLayout
    layoutIfNeeded r
    check not panel.needsLayout and not r.childNeedsLayout
    layoutIfNeeded r                    # nothing to do
    let c2 = panel.kid(alTop, 1, 5)
    layoutIfNeeded r
    check c2.top == 25

  test "padding change relayouts":
    let r = root(100, 100)
    let cl = r.kid(alClient, 1, 1)
    layout r
    r.padding = spacing(10)
    check r.needsLayout
    layout r
    check cl.box == b(10, 10, 80, 80)

  test "layout requests reach the host once per change":
    let r = root(100, 100)
    let h = MockHost()
    r.host = h
    let cl = r.kid(alClient, 1, 1)
    check h.layoutRequests > 0
    layout r
    let n = h.layoutRequests
    layout r                      # setBounds inside layout must not request more
    check h.layoutRequests == n
    discard cl

suite "customAlign":
  test "receives remaining rect":
    let r = Custom()
    r.initContainer()
    r.setBounds(0, 0, 100, 100)
    discard r.kid(alTop, 1, 10)
    let c = r.kid(alCustom, 1, 1)
    layout r
    check r.seen == @[rectF(0, 10, 100, 90)]
    check c.box == b(1, 12, 7, 8)

suite "reparenting":
  test "both parents are marked":
    let a = root(100, 100)
    let bb = root(100, 100)
    let c = a.kid(alTop, 1, 10)
    layout a
    layout bb
    check not a.needsLayout and not bb.needsLayout
    c.parent = bb
    check a.needsLayout and bb.needsLayout
    check c.parent == bb and a.controlCount == 0 and bb.controlCount == 1
    layout a
    layout bb
    check c.box == b(0, 0, 100, 10)
    c.parent = nil
    check c.parent == nil and bb.needsLayout

  test "insertControl at index and cycle protection":
    let r = root(100, 100)
    let x = newControl()
    let y = newControl()
    let z = newControl()
    r.insertControl x
    r.insertControl y
    r.insertControl(z, 0)
    check r.children == @[z, x, y]
    let p = newContainer()
    r.insertControl p
    expect AssertionDefect:
      p.insertControl r

  test "bringToFront / sendToBack":
    let r = root(100, 100)
    let x = r.kid(alNone, 1, 1)
    let y = r.kid(alNone, 1, 1)
    let z = r.kid(alNone, 1, 1)
    x.bringToFront
    check r.children == @[y, z, x]
    x.sendToBack
    check r.children == @[x, y, z]
    check r[1] == y
    check r.controls[2] == z

suite "hit testing":
  test "topmost wins, skips invisible / disabled":
    let r = root(200, 100)
    let a = r.kid(alNone, 100, 100)
    let c = newControl()
    c.setBounds(50, 50, 100, 50)
    c.parent = r
    check r.controlAtPoint(pointF(10, 10)) == a
    check r.controlAtPoint(pointF(60, 60)) == c
    check r.controlAtPoint(pointF(120, 10)) == nil
    c.enabled = false
    check r.controlAtPoint(pointF(60, 60)) == a
    check r.controlAtPoint(pointF(60, 60), includeDisabled = true) == c
    c.enabled = true
    c.visible = false
    check r.controlAtPoint(pointF(60, 60)) == a
    check r.controlAtPoint(pointF(60, 60), includeDisabled = true) == a

  test "deepest child, coordinates are container-relative":
    let r = root(200, 100)
    let panel = newContainer()
    panel.setBounds(10, 10, 100, 80)
    panel.parent = r
    let c = newControl()
    c.setBounds(5, 5, 20, 20)
    c.parent = panel
    check r.controlAtPoint(pointF(20, 20)) == c
    check r.controlAtPoint(pointF(11, 11)) == panel
    check panel.controlAtPoint(pointF(6, 6)) == c

  test "children are clipped by their container":
    let r = root(200, 100)
    let panel = newContainer()
    panel.setBounds(0, 0, 50, 50)
    panel.parent = r
    let c = newControl()
    c.setBounds(40, 0, 100, 20)
    c.parent = panel
    check r.controlAtPoint(pointF(45, 5)) == c
    check r.controlAtPoint(pointF(90, 5)) == nil

  test "disabled container hides its subtree":
    let r = root(100, 100)
    let panel = newContainer()
    panel.setBounds(0, 0, 100, 100)
    panel.parent = r
    let c = panel.kid(alClient, 1, 1)
    layout r
    panel.enabled = false
    check r.controlAtPoint(pointF(5, 5)) == nil
    check r.controlAtPoint(pointF(5, 5), true) == c

suite "coordinates":
  test "clientToForm / formToClient round trip":
    let r = root(300, 300)
    r.setBounds(50, 60, 300, 300)       # root origin is ignored
    let panel = newContainer()
    panel.setBounds(10, 20, 100, 100)
    panel.parent = r
    let c = newControl()
    c.setBounds(5, 7, 10, 10)
    c.parent = panel
    check c.clientToForm(pointF(1, 2)) == pointF(16, 29)
    check c.formToClient(pointF(16, 29)) == pointF(1, 2)
    check r.clientToForm(pointF(3, 4)) == pointF(3, 4)
    check c.clientToForm(rectF(0, 0, 10, 10)) == rectF(15, 27, 10, 10)
    check c.formToClient(c.clientToForm(rectF(1, 2, 3, 4))) == rectF(1, 2, 3, 4)
    check c.clientToParent(pointF(1, 2)) == pointF(6, 9)
    check c.parentToClient(pointF(6, 9)) == pointF(1, 2)
    check c.root == Control(r)
    check c.clientRect == rectF(0, 0, 10, 10)
