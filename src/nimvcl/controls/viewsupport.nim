## Small drawing / input helpers shared by `TreeView` and `ListView`.

import ./common, ./checkbox, ./listbox
export checkbox.CheckBoxState, listbox.ItemState, listbox.ItemStates,
       listbox.nowMs, listbox.prefixIC

const CheckSize* = 14'f32      ## side of the check boxes drawn inside the views


proc drawCheckGlyph*(c: Canvas, box: RectF, state: CheckBoxState, t: Theme,
                     enabled = true) =
  ## A small check box (same look as `CheckBox`) filling `box`.
  let rad = 3'f32
  if state != cbUnchecked:
    c.fillRoundRect(box, rad, if enabled: t.accent else: mix(t.accent, t.surface, 0.6))
    let mark = t.accentText
    let w = 1.7'f32
    let s = box.w / 16
    template dot(px, py: float32) =
      c.fillEllipse(rectF(box.x + px * s - w / 2, box.y + py * s - w / 2, w, w), mark)
    if state == cbChecked:
      c.line(box.x + 3.6 * s, box.y + 7.6 * s, box.x + 6.4 * s, box.y + 10.2 * s, mark, w)
      c.line(box.x + 6.4 * s, box.y + 10.2 * s, box.x + 11.2 * s, box.y + 4.8 * s, mark, w)
      dot(3.6, 7.6); dot(6.4, 10.2); dot(11.2, 4.8)
    else:
      c.line(box.x + 4 * s, box.y + 7.5 * s, box.x + 10.5 * s, box.y + 7.5 * s, mark, w)
      dot(4, 7.5); dot(10.5, 7.5)
  else:
    c.fillRoundRect(box, rad, if enabled: t.surface else: t.surfaceAlt)
    c.strokeRoundRect(box, rad, if enabled: t.borderStrong else: t.border, 1)

proc drawChevron*(c: Canvas, center: PointF, expanded: bool, color: Color) =
  ## The expander glyph: ">" collapsed, "v" expanded.
  let w = 1.5'f32
  if expanded:
    c.line(center.x - 3.5, center.y - 1.8, center.x, center.y + 1.8, color, w)
    c.line(center.x, center.y + 1.8, center.x + 3.5, center.y - 1.8, color, w)
  else:
    c.line(center.x - 1.8, center.y - 3.5, center.x + 1.8, center.y, color, w)
    c.line(center.x + 1.8, center.y, center.x - 1.8, center.y + 3.5, color, w)

proc typeAheadChar*(key: Key, shift: ShiftState): char =
  ## The printable ASCII character of `key` for type-ahead, '\0' otherwise.
  ## With Shift only letters count (shifted digits / symbols arrive as text and
  ## are not type-ahead).
  if shift * {ssCtrl, ssSuper, ssAlt} != {}: return '\0'
  let v = uint32(key)
  if v >= 0x20 and v < 0x7f:
    if ssShift in shift and not (v >= 0x61 and v <= 0x7a): return '\0'
    char(v)
  else: '\0'
