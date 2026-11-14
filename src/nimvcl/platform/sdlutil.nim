## Thin helpers over gaps in the nim-lang/sdl3 binding (see docs/dev/binding-audit.md).
## Only `platform/` and `graphics/` import sdl3.

import sdl3
import sdl3_ttf

proc sdlError*(): string =
  ## Last SDL error as a Nim string.
  $sdl3.getError()

proc initSdl*(flags: InitFlags = INIT_VIDEO): bool =
  ## `SDL_Init`, qualified (the binding's `init` collides with sdl3_ttf's).
  sdl3.init(flags)

proc quitSdl*() =
  ## `SDL_Quit`, qualified (`quit` is also `system.quit` and `TTF_Quit`).
  sdl3.quit()

proc initTtf*(): bool =
  ## `TTF_Init`.
  sdl3_ttf.init()

proc quitTtf*() =
  ## `TTF_Quit`.
  sdl3_ttf.quit()

proc userEventType*(ev: Event): uint32 =
  ## Raw event type as uint32. Use this for events from `registerEvents`:
  ## reading `ev.type` yields an enum with an invalid value for those.
  ev.user.`type`

proc getClipboard*(): string =
  ## Clipboard text ("" when empty); frees the SDL-allocated buffer.
  let p = sdl3.getClipboardText()
  if p == nil: return ""
  result = $p
  sdlFree(p)

proc setClipboard*(text: string): bool =
  ## Sets the clipboard text.
  sdl3.setClipboardText(text.cstring)
