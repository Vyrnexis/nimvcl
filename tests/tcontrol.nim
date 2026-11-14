## Control model tests: setters vs host notifications, inheritance, events,
## keys and paintTree (real Canvas on an offscreen software renderer).

import std/[unittest, strutils]
import sdl3 except Color
import nimvcl

type
  MockHost = ref object of RootHost
    inv: seq[RectF]
    layouts: int
    lost: seq[Control]
    cursors: int
  Rec = ref object of Control
    log: ptr seq[string]
    seenClip: RectF
    seenDepth: int
  RecBox = ref object of Container
    log: ptr seq[string]
    seenClip: RectF

type Btn = ref object of Control
  clicks: int

method doClick(b: Btn) =
  inc b.clicks
  procCall doClick(Control(b))

method invalidate(h: MockHost, r: RectF) = h.inv.add r
method requestLayout(h: MockHost) = inc h.layouts
method controlLost(h: MockHost, c: Control) = h.lost.add c
method cursorChanged(h: MockHost, c: Control) = inc h.cursors

method paint(c: Rec, canvas: Canvas) =
  c.log[].add c.name
  c.seenClip = canvas.currentClip
  c.seenDepth = canvas.clipDepth
method paint(c: RecBox, canvas: Canvas) =
  c.log[].add c.name
  c.seenClip = canvas.currentClip

proc rec(name: string, log: var seq[string], x, y, w, h: float32): Rec =
  result = Rec(log: addr log)
  result.initControl()
  result.name = name
  result.setBounds(x, y, w, h)

proc recBox(name: string, log: var seq[string], x, y, w, h: float32): RecBox =
  result = RecBox(log: addr log)
  result.initContainer()
  result.name = name
  result.setBounds(x, y, w, h)

proc hosted(w = 200'f32, h = 100'f32): (Container, MockHost) =
  let r = newContainer()
  r.setBounds(0, 0, w, h)
  let m = MockHost()
  r.host = m
  (r, m)

suite "host notifications":
  test "no host: setters are harmless":
    let c = newControl()
    c.caption = "x"
    c.visible = false
    c.width = 3
    c.cursor = crHand
    check c.host == nil

  test "caption / color / font invalidate, same value does not":
    let (r, m) = hosted()
    let c = newControl()
    c.setBounds(10, 20, 30, 40)
    c.parent = r
    m.inv.setLen 0
    c.caption = "hello"
    check m.inv == @[rectF(10, 20, 30, 40)]     # form coordinates
    c.caption = "hello"
    check m.inv.len == 1
    c.color = rgb(1, 2, 3)
    check m.inv.len == 2
    c.color = rgb(1, 2, 3)
    check m.inv.len == 2
    c.font = font("mono", 20)
    check m.inv.len == 3
    c.enabled = false
    check m.inv.len == 4
    check c.text == "hello"

  test "autoSize caption change also requests layout":
    let (r, m) = hosted()
    let c = newControl()
    c.parent = r
    layout r
    let n = m.layouts
    c.caption = "a"
    check m.layouts == n                     # not autoSize
    c.autoSize = true
    check m.layouts > n
    layout r
    let n2 = m.layouts
    c.caption = "ab"
    check m.layouts > n2

  test "geometry: invalidate old+new, layout only for aligned children":
    let (r, m) = hosted()
    let c = newControl()
    c.setBounds(0, 0, 10, 10)
    c.parent = r
    layout r
    m.inv.setLen 0
    let n = m.layouts
    c.left = 50
    check m.inv == @[rectF(0, 0, 10, 10), rectF(50, 0, 10, 10)]
    check m.layouts == n
    c.align = alTop
    check m.layouts > n
    layout r
    let n2 = m.layouts
    c.height = 33
    check m.layouts > n2 and r.needsLayout

  test "visible / enabled / removal tell the host":
    let (r, m) = hosted()
    let c = newControl()
    c.parent = r
    c.visible = false
    check m.lost == @[c]
    c.visible = true
    c.enabled = false
    check m.lost == @[c, c]
    c.enabled = true
    c.parent = nil
    check m.lost.len == 3
    check c.parent == nil

  test "invisible controls do not invalidate":
    let (r, m) = hosted()
    let p = newContainer()
    p.parent = r
    let c = newControl()
    c.parent = p
    p.visible = false
    m.inv.setLen 0
    c.caption = "zzz"
    check m.inv.len == 0

  test "cursor":
    let (r, m) = hosted()
    let c = newControl()
    c.parent = r
    c.cursor = crIBeam
    c.cursor = crIBeam
    check m.cursors == 1
    check c.cursor == crIBeam

  test "host is found from any descendant":
    let (r, m) = hosted()
    let p = newContainer()
    p.parent = r
    let c = newControl()
    c.parent = p
    check c.host == RootHost(m)
    check c.root == Control(r)

suite "inheritance":
  test "parentFont / parentColor":
    let (r, m) = hosted()
    let p = newContainer()
    p.parent = r
    let c = newControl()
    c.parent = p
    check c.parentFont and c.parentColor
    check c.font.family == currentTheme().font.family
    check c.font.size == currentTheme().font.size
    check c.color.toHex == currentTheme().window.toHex
    r.font = font("mono", 20)
    r.color = rgb(10, 20, 30)
    check c.font.family == "mono" and c.font.size == 20
    check c.color.toHex == rgb(10, 20, 30).toHex
    c.font = font("sans", 9)
    check not c.parentFont
    check c.font.size == 9
    r.font = font("mono", 30)
    check c.font.size == 9
    check p.font.size == 30
    c.parentFont = true
    check c.font.size == 30
    c.color = rgb(1, 1, 1)
    check not c.parentColor and c.color.toHex == rgb(1, 1, 1).toHex
    c.parentColor = true
    check c.color.toHex == rgb(10, 20, 30).toHex
    # turning inheritance off freezes the current value
    p.parentFont = false
    check p.font.size == 30
    r.font = font("sans", 11)
    check p.font.size == 30
    check m.inv.len > 0

  test "theme: host overrides global, root falls back to theme values":
    let (r, m) = hosted()
    let c = newControl()
    c.parent = r
    check c.theme == currentTheme()
    m.theme = themeDark()
    check c.theme == m.theme
    check c.color.toHex == m.theme.window.toHex
    check c.font.size == m.theme.font.size

  test "isEnabled through parents":
    let r = newContainer()
    let p = newContainer()
    p.parent = r
    let c = newControl()
    c.parent = p
    check c.isEnabled
    p.enabled = false
    check c.enabled and not c.isEnabled
    p.enabled = true
    r.enabled = false
    check not c.isEnabled
    check not c.isVisible == false
    r.visible = false
    check not c.isVisible

suite "components":
  test "findComponent and ownership":
    let owner = newComponent()
    let a = newControl(owner)
    a.name = "a"
    let b = newControl(owner)
    b.name = "b"
    check owner.findComponent("b") == Component(b)
    check owner.findComponent("zz") == nil
    check a.owner == owner and owner.componentCount == 2
    a.tag = 7
    check a.tag == 7
    let other = newComponent()
    other.insertComponent(a)
    check owner.componentCount == 1 and a.owner == other
    check owner.findComponent("a") == nil
    check other.findComponent("a") == Component(a)

suite "events":
  test "base methods fire the on* fields":
    let c = newControl()
    var log: seq[string]
    c.onClick = proc(s: Control) = log.add "click"
    c.onDblClick = proc(s: Control) = log.add "dbl"
    c.onMouseEnter = proc(s: Control) = log.add "enter"
    c.onMouseLeave = proc(s: Control) = log.add "leave"
    c.onEnter = proc(s: Control) = log.add "focus"
    c.onExit = proc(s: Control) = log.add "blur"
    c.onResize = proc(s: Control) = log.add "resize"
    c.onMouseDown = proc(s: Control, b: MouseButton, sh: ShiftState, x, y: float32) =
      log.add "down " & $b & " " & $x & "," & $y & " " & $(ssCtrl in sh)
    c.onMouseUp = proc(s: Control, b: MouseButton, sh: ShiftState, x, y: float32) =
      log.add "up"
    c.onMouseMove = proc(s: Control, sh: ShiftState, x, y: float32) = log.add "move"
    c.onMouseWheel = proc(s: Control, sh: ShiftState, dx, dy: float32,
                          handled: var bool) =
      log.add "wheel"
      handled = true
    c.doClick; c.doDblClick; c.doMouseEnter; c.doMouseLeave
    c.doEnter; c.doExit
    c.doMouseDown(mbRight, {ssCtrl}, 1, 2)
    c.doMouseUp(mbLeft, {}, 0, 0)
    c.doMouseMove({}, 0, 0)
    var handled = false
    c.doMouseWheel({}, 0, 1, handled)
    check handled
    c.width = 99
    c.width = 99                     # unchanged: no event
    check log == @["click", "dbl", "enter", "leave", "focus", "blur",
                   "down mbRight 1.0,2.0 true", "up", "move", "wheel", "resize"]

  test "nil handlers are fine":
    let c = newControl()
    c.doClick
    var k = keyEnter
    c.doKeyDown(k, {})
    check k == keyEnter

  test "key handlers can swallow":
    let c = newControl()
    c.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
      if k == keyEscape: k = Key(0)
    c.onKeyUp = proc(s: Control, k: var Key, sh: ShiftState) = discard
    var k = keyEscape
    c.doKeyDown(k, {})
    check k == Key(0)
    var k2 = keyEnter
    c.doKeyDown(k2, {ssShift})
    check k2 == keyEnter
    c.doKeyUp(k2, {})
    c.onKeyPress = proc(s: Control, t: var string) = t = t.toUpperAscii
    var t = "ab"
    c.doKeyPress(t)
    check t == "AB"

  test "subclass override with procCall":
    let b = Btn()
    b.initControl()
    var fired = 0
    b.onClick = proc(s: Control) = inc fired
    b.doClick
    check b.clicks == 1 and fired == 1

  test "defaults":
    let c = newControl()
    check c.visible and c.enabled and c.anchors == {akLeft, akTop}
    check c.align == alNone and not c.autoSize and not c.canFocus
    check c.preferredSize == sizeF(75, 25)
    check not c.tabStop and c.tabOrder == 0

suite "keys":
  test "values match SDL3":
    check keyEnter == Key(0x0d)
    check keyEscape == Key(27)
    check keyTab == Key(9)
    check keyBackspace == Key(8)
    check keyDelete == Key(0x7f)
    check keySpace == Key(32)
    check keyF1 == Key(0x4000003a) and keyF12 == Key(0x40000045)
    check keyLeft == Key(0x40000050) and keyUp == Key(0x40000052)
    check keyHome == Key(0x4000004a) and keyEnd == Key(0x4000004d)
    check keyPageUp == Key(0x4000004b) and keyPageDown == Key(0x4000004e)
    check keyInsert == Key(0x40000049) and keyRight == Key(0x4000004f)
    check keyDown == Key(0x40000051)
    check key('a') == Key(0x61) and key('A') == key('a') and key('7') == Key(0x37)
    check keyEnter != keyTab
  test "string and hash":
    check $keyEnter == "Enter"
    check $keyF5 == "F5"
    check $key('q') == "q"
    check $Key(0x1234567) == "Key(0x01234567)"
    var seen: seq[Key]
    seen.add keyEnter
    check keyEnter in seen
    check hash(keyEnter) == hash(Key(13))

suite "types":
  test "spacing helpers":
    check spacing(3) == spacing(3, 3, 3, 3)
    check spacing(1, 2) == spacing(1, 2, 1, 2)
    check spacing(1, 2, 3, 4).horizontal == 4
    check spacing(1, 2, 3, 4).vertical == 6
  test "default constraints are unconstrained":
    let k = SizeConstraints()
    check k.clampWidth(1e6) == 1e6
    check k.clampHeight(0) == 0

# ---- paintTree: real canvas, offscreen software renderer

suite "paintTree":
  test "order, translate, clip, skipping":
    var log: seq[string]
    let surf = createSurface(400, 300, PIXELFORMAT_RGBA32)
    doAssert surf != nil, sdlError()
    let rend = createSoftwareRenderer(surf)
    doAssert rend != nil, sdlError()
    let ctx = newRenderContext(rend, 1)
    try:
      let root = recBox("root", log, 0, 0, 300, 200)
      let a = recBox("a", log, 20, 30, 100, 80)
      let a1 = rec("a1", log, 10, 5, 30, 20)
      let a2 = rec("a2", log, 90, 70, 50, 50)       # overflows a: 100x80
      let a3 = rec("a3", log, 500, 500, 10, 10)     # fully outside a
      let hid = rec("hidden", log, 0, 0, 10, 10)
      hid.visible = false
      let b = rec("b", log, 150, 10, 40, 40)
      a.parent = root
      a1.parent = a
      a2.parent = a
      a3.parent = a
      hid.parent = a
      b.parent = root
      let canvas = ctx.beginFrame()
      root.paintTree(canvas)
      check log == @["root", "a", "a1", "a2", "b"]
      check canvas.clipDepth == 0               # stacks balanced
      check root.seenClip == rectF(0, 0, 300, 200)
      check a.seenClip == rectF(0, 0, 100, 80)
      check a1.seenClip == rectF(0, 0, 30, 20)  # translate is right
      check a2.seenClip == rectF(0, 0, 10, 10)  # clipped by a's client rect
      check b.seenClip == rectF(0, 0, 40, 40)
      check a1.seenDepth == 3                   # root, a, a1
      # painting a child subtree alone: canvas at the parent's origin
      log.setLen 0
      canvas.pushTranslate(20, 30)
      a1.paintTree(canvas)
      canvas.popTranslate()
      check log == @["a1"]
      canvas.endFrame()
    finally:
      ctx.close()
      destroyRenderer rend
      destroySurface surf

  test "root origin is ignored":
    var log: seq[string]
    let surf = createSurface(100, 100, PIXELFORMAT_RGBA32)
    let rend = createSoftwareRenderer(surf)
    let ctx = newRenderContext(rend, 1)
    try:
      let root = recBox("root", log, 40, 40, 50, 50)
      let canvas = ctx.beginFrame()
      root.paintTree(canvas)
      check root.seenClip == rectF(0, 0, 50, 50)
      canvas.endFrame()
    finally:
      ctx.close()
      destroyRenderer rend
      destroySurface surf
