## Smoke test of the showcase example: the main form builds, every page can be
## shown and painted, the tree and the actions switch pages, and the theme
## toggles both ways. Headless (offscreen SDL).

import std/unittest
import nimvcl
import ../examples/showcase

proc newShown(): ShowcaseForm =
  result = newShowcaseForm()
  result.show()
  result.syncMetrics()
  discard result.paintIfDirty()

suite "showcase":
  setup:
    Application.init()
  teardown:
    Application.shutdown()

  test "the form builds with nine pages and shows the first":
    let f = newShown()
    check f.pages.len == 9
    check f.current == 0
    check f.pages[0].visible
    check not f.pages[1].visible
    check f.statusBar.panels[1].text == "Page 1 of 9"
    check f.menu != nil
    check f.menu.items.count == 3

  test "every page can be shown and painted":
    let f = newShown()
    for i in 0 ..< f.pages.len:
      f.showPage(i)
      check f.current == i
      for k, p in f.pages: check p.visible == (k == i)
      check f.nav.selected == f.navNodes[i]
      check f.statusBar.panels[1].text == "Page " & $(i + 1) & " of 9"
      discard f.paintIfDirty()
      Application.paintForms()

  test "the tree, the actions and the list tabs navigate":
    let f = newShown()
    f.nav.selected = f.navNodes[4]
    check f.current == 4
    check f.nextAct.execute()
    check f.current == 5
    check f.prevAct.execute()
    check f.current == 4
    f.showPage(0)
    check not f.prevAct.enabled
    f.showPage(8)
    check not f.nextAct.enabled
    f.showPage(3)
    for t in 0 .. 2:
      f.ctx.listPages.tabIndex = t
      discard f.paintIfDirty()

  test "the theme toggles live in both directions":
    let f = newShown()
    let light = currentTheme().window
    check f.darkAct.execute()                  # autoCheck: checked is now true
    check f.ctx.dark
    check currentTheme().window != light
    for i in 0 ..< f.pages.len:
      f.showPage(i)
      discard f.paintIfDirty()
    check f.statusBar.panels[2].text == "Dark theme"
    check f.darkAct.execute()
    check not f.ctx.dark
    check currentTheme().window == light
    check f.statusBar.panels[2].text == "Light theme"
    discard f.paintIfDirty()
