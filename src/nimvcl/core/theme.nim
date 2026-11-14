## Theme tokens. Controls draw only from these (never from hard-coded colors).
## Pure Nim, no SDL.

import ../graphics/[color, font]

type
  Theme* = ref object
    name*: string
    # colors
    window*, surface*, surfaceAlt*: Color
    text*, textMuted*, textDisabled*: Color
    accent*, accentText*: Color
    border*, borderStrong*, focusRing*: Color
    selection*, selectionText*: Color
    hover*, pressed*, danger*: Color
    selectionInactive*: Color    ## selection of an unfocused list
    scrollTrack*, scrollThumb*, scrollThumbHover*: Color
    # menus and tooltips
    menuBg*, menuHover*, menuHoverText*, menuSeparator*, menuBorder*: Color
    tooltipBg*, tooltipText*, tooltipBorder*, shadow*: Color
    # metrics (logical px)
    radius*, borderWidth*, controlHeight*, spacing*, focusRingWidth*: float32
    # fonts
    font*, monoFont*: FontSpec

proc baseTheme(): Theme =
  Theme(radius: 4, borderWidth: 1, controlHeight: 28, spacing: 8,
        focusRingWidth: 2,
        font: font(DefaultFamily, DefaultFontSize),
        monoFont: font(MonoFamily, DefaultFontSize))

proc themeLight*(): Theme =
  result = baseTheme()
  result.name = "light"
  result.window = hex"#f3f4f6"
  result.surface = hex"#ffffff"
  result.surfaceAlt = hex"#eef0f3"
  result.text = hex"#1f2328"
  result.textMuted = hex"#5b6470"
  result.textDisabled = hex"#a0a7b1"
  result.accent = hex"#2563eb"
  result.accentText = hex"#ffffff"
  result.border = hex"#d5d9e0"
  result.borderStrong = hex"#aeb5c0"
  result.focusRing = hex"#3b82f6"
  result.selection = hex"#bfdbfe"
  result.selectionText = hex"#0b1f3a"
  result.hover = hex"#e8ebf0"
  result.pressed = hex"#d9dde4"
  result.danger = hex"#dc2626"
  result.menuBg = hex"#ffffff"
  result.menuHover = hex"#e3ebfa"
  result.menuHoverText = hex"#1f2328"
  result.menuSeparator = hex"#e1e4ea"
  result.menuBorder = hex"#c3c9d3"
  result.tooltipBg = hex"#2b2f36"
  result.tooltipText = hex"#f3f4f6"
  result.tooltipBorder = hex"#2b2f36"
  result.shadow = rgba(0, 0, 0, 38)
  result.selectionInactive = hex"#dde1e8"
  result.scrollTrack = hex"#e6e9ee"
  result.scrollThumb = hex"#b4bbc6"
  result.scrollThumbHover = hex"#8b94a1"

proc themeDark*(): Theme =
  result = baseTheme()
  result.name = "dark"
  result.window = hex"#16181d"
  result.surface = hex"#1e2128"
  result.surfaceAlt = hex"#262a33"
  result.text = hex"#e6e8ec"
  result.textMuted = hex"#9aa3af"
  result.textDisabled = hex"#5c6470"
  result.accent = hex"#2f6feb"
  result.accentText = hex"#ffffff"
  result.border = hex"#343a46"
  result.borderStrong = hex"#4a5262"
  result.focusRing = hex"#6ea2ff"
  result.selection = hex"#264f9a"
  result.selectionText = hex"#ffffff"
  result.hover = hex"#2a2f39"
  result.pressed = hex"#343a46"
  result.danger = hex"#f0605d"
  result.menuBg = hex"#23272f"
  result.menuHover = hex"#33405c"
  result.menuHoverText = hex"#ffffff"
  result.menuSeparator = hex"#3a404c"
  result.menuBorder = hex"#4a5262"
  result.tooltipBg = hex"#e6e8ec"
  result.tooltipText = hex"#1f2328"
  result.tooltipBorder = hex"#e6e8ec"
  result.shadow = rgba(0, 0, 0, 90)
  result.selectionInactive = hex"#323846"
  result.scrollTrack = hex"#262a33"
  result.scrollThumb = hex"#4f586a"
  result.scrollThumbHover = hex"#7a8499"

var gTheme: Theme

proc currentTheme*(): Theme =
  ## The process-wide default theme (light until `setTheme` is called).
  if gTheme == nil: gTheme = themeLight()
  gTheme

proc setTheme*(t: Theme) =
  ## Sets the default theme. Does not repaint; the application layer (2b)
  ## invalidates its forms. A host may override it per window via
  ## `RootHost.theme`.
  gTheme = t
