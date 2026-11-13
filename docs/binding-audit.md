# nim-lang/sdl3 binding audit (phase 0)

Audited revision: nim-lang/sdl3 `533d22196dab2ea637ea0131171ed3f8db61fe90`
(`sdl3.nimble` version 1.1, "Based on SDL 3.4.18"; `sdl3_ttf.nim` "Based on SDL_ttf 3.2.2").
Tested against system SDL3 3.4.20, SDL3_ttf 3.2.2, SDL3_image 3.4.8, Nim 2.2.10.
Method: read the declarations the plan relies on, then compiled and ran
`examples/spike.nim`. Items marked (spike) were exercised at runtime; the rest
are from reading the declarations only.

## Install note (not a binding bug, but affects `nimble install`)

- On this machine `github.com` fails TLS (`unexpected eof while reading`) from
  both git and curl, while `api.github.com` works. `nimble install` therefore
  hangs or errors when it clones.
- `nimble install -y "sdl3@>=1.1"` resolves the name `sdl3` through the package
  list to `https://github.com/transmutrix/nim-sdl3`, **a different package**.
  The official binding must be installed by URL or by local path.
- `nimble install` run inside the unpacked sdl3 checkout starts downloading Nim
  2.4.2 (`nim >= 2.2.0` is judged unmet, probably because the toolchain choice
  nimble makes differs from the active choosenim Nim 2.2.10). That is why the
  earlier install appeared to hang.
- Workaround used: fetched the tarball with `gh api repos/nim-lang/sdl3/tarball`
  and copied `src/*` plus `sdl3.nimble` into
  `~/.nimble/pkgs2/sdl3-1.1-533d221.../` with a hand-written `nimblemeta.json`.
  The spike build also passes `--path:` to that directory explicitly, because an
  old `sdl3-1.0-5ecbff9...` is still in pkgs2 and a plain `nim c` may pick either.
- Decision needed: CI should install the binding by URL with a pinned commit
  (`requires "https://github.com/nim-lang/sdl3#533d221"`), or vendor it.

## Gaps and bugs found

### 1. `getenv` returns the wrong type (bug, crashes if called)
- Where: `sdl3.nim:69`
  `proc getenv*(name: cstring): string {.importc: "SDL_getenv".}`
- The C function returns `const char*`; declaring a Nim `string` return is
  invalid (`string` is a `(len, ptr)` struct), so calling it is undefined.
  `getenvUnsafe` (line 70) has the right type.
- Workaround: spike uses `std/os.getEnv`.
- Upstream fix: return `cstring`, or delete (SDL_getenv is deprecated in favour
  of `SDL_GetEnvironmentVariable`).

### 2. `getTextureColorMod` takes non-var out parameters (bug)
- Where: `sdl3.nim` line 5100, `proc getTextureColorMod*(texture: Texture, r,g,b: uint8)`.
- Out parameters must be `var uint8`; as written the call cannot return values
  (and writes through a copy). Compare `getRenderDrawColor`, which is right.
- Workaround: not used by the spike. Avoid; track the colour in Nim.
- Upstream fix: `r,g,b: var uint8`. Worth a quick grep for other `get*` procs
  with plain scalar out parameters (a regex over the file found none else for
  the APIs checked, but only the render and window sections were read closely).

### 3. `EventType` is an enum with holes, user events need a cast
- Where: `sdl3.nim:4499` `EventType {.size: sizeof(uint32).} = enum`; `Event.type`
  has this type, while `CommonEvent.type` and `UserEvent.type` are `uint32`
  (spike did not hit this; found by reading).
- `registerEvents(n)` returns a `uint32` base (`> EVENT_USER`, not in the enum).
  Reading `ev.type` for such an event is a Nim enum with an invalid value. In
  `case ev.type` it falls to `else`, and `$ev.type` / range checks can raise.
  Comparing needs `ev.common.type == myBase` (uint32), which is OK but easy to
  get wrong.
- Workaround for nimvcl: always read the event kind as `ev.common.type`
  (uint32) in the dispatcher, and only convert known values to the enum.
  Pushing: fill `ev.user.type = base + n` then `pushEvent(ev)`.
- Upstream fix: expose `EventKind = uint32` consts, or document `common.type`.

### 4. `getClipboardText` / `getPrimarySelectionText` ownership
- Where: `sdl3.nim:738, 741` return `cstring`.
- SDL returns a heap string the caller must `SDL_free`. The binding offers
  `sdlFree(pointer)` (line 41) but no doc, so a naive `$getClipboardText()`
  leaks. Not a wrong declaration.
- Workaround for nimvcl: wrap as `let p = getClipboardText(); result = $p; sdlFree(p)`.
- Upstream fix: add a doc comment, or a `string`-returning helper that frees.
  Same applies to other SDL-allocated returns (`getWindows`, `getDisplays`,
  `glob*`, `getEnvironmentVariables`, file dialog results are callback-owned).

### 5. Mixed-case/overload hazards when importing both modules
- `sdl3_ttf` exports `init`, `quit`, `version`, `Font`, `Text`, `Direction`
  that collide with `sdl3.init/quit` and (for `quit`) `system.quit`.
- (spike) `init(INIT_VIDEO)` resolves by arguments, but the no-argument `quit()`
  is ambiguous and `ttf_init`-style names do not exist. The spike calls
  `sdl3.init`, `sdl3_ttf.init`, `sdl3_ttf.quit`, `sdl3.quit` fully qualified.
- Upstream fix: prefix the ttf entry points (`ttfInit`, `ttfQuit`), as the C
  names do, or keep as is and document the qualification.

### 6. `setRenderClipRect(renderer, Rect)` helper takes the address of a parameter
- Where: `sdl3.nim:5130` `proc setRenderClipRect*(renderer: Renderer, rect: Rect): bool = setRenderClipRect(renderer, rect.addr)`
- It compiles, but depends on by-reference parameter passing. Harmless today.
  The `ptr Rect` overload is the one nimvcl uses (`nil` disables clipping)
  (spike).

### 7. Minor
- `getTextureColorMod`, `Text` naming: `Text` is the SDL_ttf object (`TTF_Text`)
  and is easily confused with other text types. Not a defect.
- `Surface` pixel access: `renderReadPixels` returns a `ptr Surface`; the
  result must be freed with `destroySurface` (spike does).
- `WindowFlags` is a plain `uint64` with `const WINDOW_*`; flags combine with
  `or` and nothing prevents passing unrelated integers. Style only.

## Presence check of APIs the plan relies on

All of these exist with usable signatures (present = declared in the binding;
(spike) = also run in `examples/spike.nim`).

| API | Binding | Notes |
|---|---|---|
| `SDL_CreatePopupWindow` | `createPopupWindow(parent, offset_x, offset_y, w, h, flags)` | present. Needs `WINDOW_POPUP_MENU` or `WINDOW_TOOLTIP` in flags (both defined). |
| `SDL_AddTimer` / `AddTimerNS` / `RemoveTimer` | `addTimer`, `addTimerNS`, `removeTimer` | present. Callback is `{.cdecl.}` and runs on SDL's timer thread: it must only call `pushEvent` (thread-safe), no Nim GC-managed shared state. With `--mm:orc` this is fine as long as the callback allocates nothing shared. |
| `SDL_PushEvent` / `SDL_RegisterEvents` | `pushEvent(var Event)`, `registerEvents(n): uint32` | present; see gap 3 for the enum issue. `pushEvent` takes `var Event`, so it needs a mutable local. |
| `SDL_StartTextInput` / `StopTextInput` / `TextInputActive` | `startTextInput(window)`, `stopTextInput`, `textInputActive`, `startTextInputWithProperties` | present, with `PROP_TEXTINPUT_*` constants. |
| `SDL_SetTextInputArea` / `GetTextInputArea` | `setTextInputArea(window, rect: ptr Rect, cursor)` | present. Takes `ptr Rect`, so pass `addr`. |
| `TEXT_EDITING` event fields | `Event.edit: TextEditingEvent` with `windowID, text: cstring, start, length: int32` | present and matches SDL 3.4. Also `edit_candidates` (`TextEditingCandidatesEvent`) and `Event.text` (`TextInputEvent`). Event enum names: `EVENT_TEXT_EDITING`, `EVENT_TEXT_INPUT`, `EVENT_TEXT_EDITING_CANDIDATES`. |
| Clipboard | `setClipboardText`, `getClipboardText`, `hasClipboardText`, primary selection, `setClipboardData` | present; see gap 4. |
| System cursors | `SystemCursor` enum, `createSystemCursor`, `setCursor`, `getCursor`, `createColorCursor` | present. |
| `SDL_ShowOpenFileDialog` (+ save, folder) | `showOpenFileDialog`, `showSaveFileDialog`, `showOpenFolderDialog` with `DialogFileFilter` | present, with `ptr`+count and `openArray` overloads. Callback is `{.cdecl.}`; may be invoked from another thread on some platforms. |
| `TTF_AddFallbackFont` | `addFallbackFont(font, fallback): bool`, `removeFallbackFont`, `clearFallbackFonts` | present. |
| `TTF_GetTextSubString` | `getTextSubString(text, offset, var SubString)` | present, plus `ForLine`, `ForRange`, `ForPoint`, previous/next. |
| `TTF_GetTextSubStringForPoint` | `getTextSubStringForPoint(text, x, y: cint, var SubString)` | present. The ForRange result array must be freed with `sdlFree`. |
| `SDL_RenderGeometry` | `renderGeometry(renderer, texture, openArray[Vertex], openArray[cint])` and `ptr` form, plus `renderGeometryRaw` | present (spike). `Vertex` uses `FColor`. Works on software, opengl, opengles2, vulkan and gpu renderers (spike, headless). |
| Render clip rect | `setRenderClipRect(ptr Rect)`, `getRenderClipRect`, `renderClipEnabled` | present (spike). |
| Renderer text engine | `createRendererTextEngine`, `createText`, `drawRendererText`, `setTextWrapWidth`, `getTextSize`, `setTextString`, `setTextColorFloat` | present and correct (spike). |
| Scale queries | `getWindowSizeInPixels`, `getWindowSize`, `getWindowPixelDensity`, `getWindowDisplayScale`, `getDisplayContentScale` | present (spike). |
| Read back / BMP | `renderReadPixels`, `saveBMP`, `destroySurface` | present (spike). |
| Window events | `EVENT_WINDOW_EXPOSED`, `_RESIZED`, `_PIXEL_SIZE_CHANGED`, `_DISPLAY_SCALE_CHANGED`, `_CLOSE_REQUESTED` | present (spike). `WindowEvent` has `data1/data2` only. |

Also relevant for later phases: `setWindowParent`, `setWindowModal`,
`setWindowMinimumSize`, `setWindowHitTest`, `sdl3_image.loadTexture`.

## Missing

Nothing the plan relies on is missing. Real defects are items 1 and 2; item 3
is the one that will shape the nimvcl event dispatcher.

## Suggested upstream PRs

1. Fix `getenv` (return `cstring`) and `getTextureColorMod` (`var` out params).
2. Document `common.type` for user events, or add helper consts.
3. Note the SDL-owned-string freeing rule on clipboard procs.
