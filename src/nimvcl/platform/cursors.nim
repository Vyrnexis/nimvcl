## Mouse cursor shapes: SDL system cursors, created lazily and cached.

import ../core/types
from sdl3 as sdl import nil

var
  cache: array[Cursor, sdl.Cursor]
  made: array[Cursor, bool]
  current = crDefault
  haveCurrent = false

proc systemId(c: Cursor): sdl.SystemCursor =
  case c
  of crDefault, crArrow: sdl.SYSTEM_CURSOR_DEFAULT
  of crIBeam: sdl.SYSTEM_CURSOR_TEXT
  of crWait: sdl.SYSTEM_CURSOR_WAIT
  of crCross: sdl.SYSTEM_CURSOR_CROSSHAIR
  of crHand: sdl.SYSTEM_CURSOR_POINTER
  of crSizeWE: sdl.SYSTEM_CURSOR_EW_RESIZE
  of crSizeNS: sdl.SYSTEM_CURSOR_NS_RESIZE
  of crSizeNWSE: sdl.SYSTEM_CURSOR_NWSE_RESIZE
  of crSizeNESW: sdl.SYSTEM_CURSOR_NESW_RESIZE
  of crSizeAll: sdl.SYSTEM_CURSOR_MOVE
  of crNo: sdl.SYSTEM_CURSOR_NOT_ALLOWED

proc setCursorShape*(c: Cursor) =
  ## Makes `c` the current cursor (no-op when it already is).
  let c = if c == crDefault: crArrow else: c
  if haveCurrent and current == c: return
  if not made[c]:
    cache[c] = sdl.createSystemCursor(systemId(c))
    made[c] = true
  if cache[c] != nil:
    discard sdl.setCursor(cache[c])
    current = c
    haveCurrent = true

proc freeCursors*() =
  ## Destroys the cached cursors (call before SDL quits).
  for c in Cursor:
    if made[c] and cache[c] != nil: sdl.destroyCursor(cache[c])
    cache[c] = nil
    made[c] = false
  haveCurrent = false
