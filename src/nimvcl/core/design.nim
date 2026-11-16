## `DesignHook`: the interception point for design mode.
##
## A design hook is attached to a `UiRoot` (`ui.addDesigner(hook)`) with a
## `scope` container. While attached, mouse events whose target lies inside
## `scope` (the scope itself or any descendant) and the keyboard (while no
## control outside the scope has focus) go to the hook instead of the normal
## routing: controls under the scope get no hover, press, click, focus, text,
## wheel or key events, as in the Delphi form designer. Painting is not
## affected. With no hook attached the router pays one length check.
##
## Mouse positions are in the scope's client coordinates. A button press inside
## the scope captures the pointer: the moves and the release go to the hook
## until every button is up, even outside the scope.
##
## The hook is a plain base class with methods; `controls/designsurface.nim`
## has the real implementation (`FormDesigner`).

import ../graphics/geometry
import ./types, ./control

type
  DesignHook* = ref object of RootObj
    scope*: Container       ## the designed container
    cursor*: Cursor         ## the pointer shape for the current mouse position

method designMouseDown*(d: DesignHook, p: PointF, button: MouseButton,
                        shift: ShiftState, clicks: int) {.base.} =
  discard

method designMouseMove*(d: DesignHook, p: PointF, shift: ShiftState) {.base.} =
  ## `shift` includes the pressed buttons (`ssLeft`, ...).
  discard

method designMouseUp*(d: DesignHook, p: PointF, button: MouseButton,
                      shift: ShiftState) {.base.} =
  discard

method designMouseWheel*(d: DesignHook, p: PointF, shift: ShiftState,
                         dx, dy: float32): bool {.base.} =
  ## True when the wheel was used; otherwise it bubbles up from the scope.
  false

method designKeyDown*(d: DesignHook, key: var Key, shift: ShiftState): bool {.base.} =
  ## True when the key was used. An unused key continues through the normal
  ## key-handler chain (menu shortcuts, ...), but never reaches a control.
  false

method designKeyUp*(d: DesignHook, key: var Key, shift: ShiftState) {.base.} =
  discard

method designCancel*(d: DesignHook) {.base.} =
  ## The interaction in progress was interrupted (window deactivated, scope
  ## removed): drop any drag.
  discard
