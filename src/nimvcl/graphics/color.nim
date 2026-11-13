## RGBA colors (8 bits per channel, non-premultiplied) and helpers.

import std/strutils

type
  Color* = object
    ## Non-premultiplied RGBA color.
    r*, g*, b*, a*: uint8

func rgba*(r, g, b: int, a: int = 255): Color =
  ## Color from 0..255 components (values are clamped).
  Color(r: uint8(clamp(r, 0, 255)), g: uint8(clamp(g, 0, 255)),
        b: uint8(clamp(b, 0, 255)), a: uint8(clamp(a, 0, 255)))

func rgb*(r, g, b: int): Color =
  ## Opaque color from 0..255 components.
  rgba(r, g, b, 255)

func parseColor*(s: string): Color =
  ## Parses "#rgb", "#rgba", "#rrggbb" or "#rrggbbaa" (the '#' is optional).
  ## Raises ValueError on malformed input.
  var h = s.strip()
  if h.startsWith("#"): h = h[1 .. ^1]
  proc nib(c: char): int =
    case c
    of '0' .. '9': ord(c) - ord('0')
    of 'a' .. 'f': ord(c) - ord('a') + 10
    of 'A' .. 'F': ord(c) - ord('A') + 10
    else: raise newException(ValueError, "invalid hex color: " & s)
  case h.len
  of 3, 4:
    result = rgba(nib(h[0]) * 17, nib(h[1]) * 17, nib(h[2]) * 17,
                  if h.len == 4: nib(h[3]) * 17 else: 255)
  of 6, 8:
    result = rgba(nib(h[0]) * 16 + nib(h[1]), nib(h[2]) * 16 + nib(h[3]),
                  nib(h[4]) * 16 + nib(h[5]),
                  if h.len == 8: nib(h[6]) * 16 + nib(h[7]) else: 255)
  else:
    raise newException(ValueError, "invalid hex color: " & s)

func hex*(s: static string): Color =
  ## Compile-time checked hex color literal, e.g. `hex"#3366cc"`.
  parseColor(s)

func toHex*(c: Color): string =
  ## "#rrggbb", or "#rrggbbaa" when not opaque.
  result = "#" & toHex(c.r.int, 2) & toHex(c.g.int, 2) & toHex(c.b.int, 2)
  if c.a != 255: result.add toHex(c.a.int, 2)
  result = result.toLowerAscii

func `$`*(c: Color): string = c.toHex

func withAlpha*(c: Color, a: int): Color =
  ## Same color with alpha replaced (0..255).
  result = c
  result.a = uint8(clamp(a, 0, 255))

func mulAlpha*(c: Color, f: float32): Color =
  ## Scales alpha by `f` (0..1).
  result = c
  result.a = uint8(clamp(float32(c.a) * f + 0.5, 0, 255))

func mix*(a, b: Color, t: float32): Color =
  ## Linear interpolation per channel: t = 0 gives `a`, t = 1 gives `b`.
  let t = clamp(t, 0'f32, 1'f32)
  template ch(f: untyped): uint8 =
    uint8(float32(a.f) + (float32(b.f) - float32(a.f)) * t + 0.5)
  Color(r: ch(r), g: ch(g), b: ch(b), a: ch(a))

func lerp*(a, b: Color, t: float32): Color = mix(a, b, t)

const
  clBlack* = Color(r: 0, g: 0, b: 0, a: 255)
  clWhite* = Color(r: 255, g: 255, b: 255, a: 255)
  clTransparent* = Color(r: 0, g: 0, b: 0, a: 0)
