# Phase 3 demo: the Edit control in several configurations.
#
# Keys: Tab / Shift+Tab move focus, Esc closes the window.
#
# Env:
#   NIMVCL_SCREENSHOT   lay out, render one frame to this BMP and exit
#   NIMVCL_SCALE        force the display scale (headless testing of 1.5x etc.)
#   NIMVCL_DARK=1       start with the dark theme
#
# Build: nim c --outdir:build examples/edit_demo.nim

import std/[os, strutils]
import nimvcl

type
  Caption = ref object of Control
    ## A line of muted text above an edit (Label arrives with the other controls).
    muted: bool

method paint(c: Caption, cv: Canvas) =
  let t = c.theme
  cv.textRect(c.caption, c.font, c.clientRect, (if c.muted: t.textMuted else: t.text),
              taLeft, vaBottom)

proc caption(parent: Container, text: string, x, y: float32): Caption =
  result = Caption()
  result.initControl()
  result.caption = text
  result.muted = true
  result.setBounds(x, y, 320, 18)
  parent.insertControl result

const
  Lorem = "The quick brown fox jumps over the lazy dog, then keeps running " &
          "through the meadow until the sun goes down behind the hills."

proc buildForm(): tuple[f: Form, focus: Edit] =
  let f = newForm(nil, 420, 590)
  f.caption = "nimvcl edit demo"
  f.keyPreview = true
  var y = 14'f32
  template field(label: string, e: Edit) =
    discard f.caption(label, 20, y)
    y += 20
    e.setBounds(20, y, 380, 28)
    y += 46

  let normal = newEdit(f, "Hello, wörld 漢字")
  field("Normal", normal)
  let hint = newEdit(f)
  hint.placeholder = "Placeholder text"
  field("Placeholder", hint)
  let pw = newEdit(f, "hunter2")
  pw.password = true
  field("Password", pw)
  let ro = newEdit(f, "Read only: select and copy, no edits")
  ro.readOnly = true
  field("Read only", ro)
  let num = newEdit(f, "12345")
  num.numbersOnly = true
  field("Numbers only", num)
  let ml = newEdit(f, "abcdefghij")
  ml.maxLength = 10
  field("Max length 10", ml)
  let long = newEdit(f, Lorem)
  field("Long text (scrolls)", long)
  let off = newEdit(f, "Disabled")
  off.enabled = false
  field("Disabled", off)
  let flat = newEdit(f, "No border")
  flat.borderStyle = ebNone
  field("Border none", flat)

  f.onKeyDown = proc(s: Control, k: var Key, sh: ShiftState) =
    if k == keyEscape:
      k = Key(0)
      f.close()
  (f, normal)

proc main() =
  let shot = getEnv("NIMVCL_SCREENSHOT")
  let scaleEnv = getEnv("NIMVCL_SCALE")
  Application.init()
  if scaleEnv.len > 0: Application.forceScale = parseFloat(scaleEnv).float32
  if getEnv("NIMVCL_DARK") == "1": Application.theme = themeDark()
  let (f, focus) = buildForm()
  if shot.len > 0:
    f.show()
    focus.setFocus()
    focus.select(7, 6)                  # "wörld" selected, caret at its end
    if not f.screenshot(shot): quit "screenshot failed: " & sdlError()
    echo "wrote ", shot, "  scale ", f.ctx.scale
    Application.shutdown()
  else:
    Application.run(f)

main()
