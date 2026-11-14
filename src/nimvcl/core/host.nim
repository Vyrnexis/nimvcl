## Host mode: embed a nimvcl control tree in an existing SDL3 application.
##
## ```nim
## let host = newHost(window, renderer, rootContainer)
## # in the app's loop:
## while pollEvent(ev):
##   if host.handleEvent(ev): continue        # consumed by the UI
##   ...                                      # the app's own handling
## # app draws its scene, then:
## host.paint()                               # draws over it, no clear/present
## # on exit, BEFORE destroying the renderer:
## host.close()
## ```
##
## This API edge exposes sdl3 types (`Window`, `Renderer`, `Event`).
## The caller owns window and renderer; SDL and SDL_ttf must be initialised
## by the caller (`newHost` initialises SDL_ttf itself if needed). The root
## container is transparent (not cleared) and follows the window size unless
## `host.autoSizeRoot = false`. Timers (`Timer`) fire from `handleEvent`.

import ../graphics/context
import ../platform/[window, events]
import ./control, ./input, ./timer

type Host* = UiRoot

proc newHost*(window: Window, renderer: Renderer, root: Container): Host =
  ## Attaches `root` to the caller's window. The root's size is set from the
  ## window (logical px).
  ensureTtf()
  let w = wrapWindow(window, renderer)
  result = newUiRoot(root)
  result.win = w
  result.ctx = newRenderContext(renderer, w.scale)
  result.autoSizeRoot = true
  result.rootGetsMouse = false
  result.syncMetrics()

proc handleEvent*(h: Host, ev: var Event): bool =
  ## Feeds one SDL event. True when the UI consumed it: a mouse event over a
  ## control (or while a button is held on one), a key or text event while a
  ## control has focus, or a `Timer` tick. Events for other windows are ignored.
  let pe = translate(ev)
  if pe.kind == ekTimer: return dispatchTimer(pe.timerId)
  if pe.windowId != 0 and pe.windowId != h.win.id: return false
  h.handle(pe)

proc paint*(h: Host) =
  ## Lays out and draws the tree into the renderer's current target. Does not
  ## clear or present. Call every frame, after the app drew its own content.
  h.paintFrame(clear = false, present = false)

proc resize*(h: Host) =
  ## (`h.resize(w, h)` from input.nim sets an explicit root size.)
  ## Re-reads window size and scale (when the window changed outside events).
  h.syncMetrics()

proc invalidate*(h: Host) = h.dirty = true

proc close*(h: Host) =
  ## Frees the RenderContext. Call before the renderer is destroyed.
  h.closeContext()
