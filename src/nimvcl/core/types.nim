## Plain enums and value types shared by the core. Pure Nim, no SDL.
## (Event callback types mention `Control` and live in control.nim.)

import std/[hashes, strutils]

type
  Align* = enum
    ## How a control is placed inside its parent's client area (VCL `TAlign`).
    alNone, alTop, alBottom, alLeft, alRight, alClient, alCustom

  Anchor* = enum akLeft, akTop, akRight, akBottom
  Anchors* = set[Anchor]

  Spacing* = object
    ## Per-side distances (margins of a control, padding of a container).
    left*, top*, right*, bottom*: float32

  SizeConstraints* = object
    ## Min/max size. 0 means unconstrained.
    minWidth*, minHeight*, maxWidth*, maxHeight*: float32

  MouseButton* = enum mbLeft, mbRight, mbMiddle, mbX1, mbX2

  ShiftKey* = enum
    ssShift, ssCtrl, ssAlt, ssSuper, ssLeft, ssRight, ssMiddle, ssDouble
  ShiftState* = set[ShiftKey]

  Cursor* = enum
    crDefault, crArrow, crIBeam, crWait, crCross, crHand,
    crSizeWE, crSizeNS, crSizeNWSE, crSizeNESW, crSizeAll, crNo

  Key* = distinct uint32
    ## A key code. Values equal SDL3 keycodes (`SDLK_*`), so the platform layer
    ## converts with a plain cast. Printable keys are lowercase ASCII.

const DefaultAnchors* = {akLeft, akTop}

func spacing*(all: float32): Spacing =
  Spacing(left: all, top: all, right: all, bottom: all)
func spacing*(h, v: float32): Spacing =
  ## Horizontal (left/right) and vertical (top/bottom).
  Spacing(left: h, top: v, right: h, bottom: v)
func spacing*(l, t, r, b: float32): Spacing =
  Spacing(left: l, top: t, right: r, bottom: b)

func `==`*(a, b: Spacing): bool =
  a.left == b.left and a.top == b.top and a.right == b.right and a.bottom == b.bottom
func `==`*(a, b: SizeConstraints): bool =
  a.minWidth == b.minWidth and a.minHeight == b.minHeight and
    a.maxWidth == b.maxWidth and a.maxHeight == b.maxHeight

func horizontal*(s: Spacing): float32 = s.left + s.right
func vertical*(s: Spacing): float32 = s.top + s.bottom

func constraints*(minWidth = 0'f32, minHeight = 0'f32,
                  maxWidth = 0'f32, maxHeight = 0'f32): SizeConstraints =
  SizeConstraints(minWidth: minWidth, minHeight: minHeight,
                  maxWidth: maxWidth, maxHeight: maxHeight)

func clampWidth*(k: SizeConstraints, w: float32): float32 =
  result = w
  if k.maxWidth > 0 and result > k.maxWidth: result = k.maxWidth
  if k.minWidth > 0 and result < k.minWidth: result = k.minWidth

func clampHeight*(k: SizeConstraints, h: float32): float32 =
  result = h
  if k.maxHeight > 0 and result > k.maxHeight: result = k.maxHeight
  if k.minHeight > 0 and result < k.minHeight: result = k.minHeight

# ---------------------------------------------------------------- keys

func `==`*(a, b: Key): bool {.borrow.}
func hash*(k: Key): Hash = hash(uint32(k))

const
  # Values copied from SDL3 (SDLK_*), deliberately without importing it.
  keyBackspace* = Key(0x08)
  keyTab*       = Key(0x09)
  keyEnter*     = Key(0x0d)
  keyEscape*    = Key(0x1b)
  keySpace*     = Key(0x20)
  keyDelete*    = Key(0x7f)
  keyF1*        = Key(0x4000003a)
  keyF2*        = Key(0x4000003b)
  keyF3*        = Key(0x4000003c)
  keyF4*        = Key(0x4000003d)
  keyF5*        = Key(0x4000003e)
  keyF6*        = Key(0x4000003f)
  keyF7*        = Key(0x40000040)
  keyF8*        = Key(0x40000041)
  keyF9*        = Key(0x40000042)
  keyF10*       = Key(0x40000043)
  keyF11*       = Key(0x40000044)
  keyF12*       = Key(0x40000045)
  keyInsert*    = Key(0x40000049)
  keyHome*      = Key(0x4000004a)
  keyPageUp*    = Key(0x4000004b)
  keyEnd*       = Key(0x4000004d)
  keyPageDown*  = Key(0x4000004e)
  keyRight*     = Key(0x4000004f)
  keyLeft*      = Key(0x40000050)
  keyDown*      = Key(0x40000051)
  keyUp*        = Key(0x40000052)
  keyApplication* = Key(0x40000065)   ## the menu / context-menu key
  keyLCtrl*     = Key(0x400000e0)
  keyLShift*    = Key(0x400000e1)
  keyLAlt*      = Key(0x400000e2)
  keyRCtrl*     = Key(0x400000e4)
  keyRShift*    = Key(0x400000e5)
  keyRAlt*      = Key(0x400000e6)

func key*(c: char): Key =
  ## Key for a printable character; letters map to their lowercase keycode.
  Key(uint32(if c in {'A'..'Z'}: char(ord(c) + 32) else: c))

const NamedKeys = [
  (keyBackspace, "Backspace"), (keyTab, "Tab"), (keyEnter, "Enter"),
  (keyEscape, "Escape"), (keySpace, "Space"), (keyDelete, "Delete"),
  (keyInsert, "Insert"), (keyHome, "Home"), (keyPageUp, "PageUp"),
  (keyEnd, "End"), (keyPageDown, "PageDown"), (keyRight, "Right"),
  (keyLeft, "Left"), (keyDown, "Down"), (keyUp, "Up")]

func `$`*(k: Key): string =
  ## "Enter", "F5", "a", or "Key(0x01234567)" (8 hex digits) for anything else.
  let v = uint32(k)
  for (kk, name) in NamedKeys:
    if kk == k: return name
  if v >= uint32(keyF1) and v <= uint32(keyF12):
    return "F" & $(v - uint32(keyF1) + 1)
  if v > 0x20 and v < 0x7f: return $char(v)
  "Key(0x" & toHex(int64(v), 8).toLowerAscii & ")"

