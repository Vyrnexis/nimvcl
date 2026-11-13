import std/unittest
import nimvcl/graphics/color

suite "color":
  test "hex parse":
    check parseColor("#ff8000") == rgb(255, 128, 0)
    check parseColor("ff8000") == rgb(255, 128, 0)
    check parseColor("#f80") == rgb(255, 136, 0)
    check parseColor("#11223344") == rgba(0x11, 0x22, 0x33, 0x44)
    check parseColor("#abcd") == rgba(0xaa, 0xbb, 0xcc, 0xdd)
    check parseColor("#ABCDEF") == rgb(0xab, 0xcd, 0xef)
    check hex"#3366cc" == rgb(0x33, 0x66, 0xcc)

  test "hex parse errors":
    expect ValueError: discard parseColor("#12")
    expect ValueError: discard parseColor("#gg0000")
    expect ValueError: discard parseColor("")

  test "toHex round trip":
    check rgb(1, 2, 3).toHex == "#010203"
    check rgba(1, 2, 3, 4).toHex == "#01020304"
    check parseColor(rgba(200, 100, 50, 25).toHex) == rgba(200, 100, 50, 25)

  test "clamping":
    check rgba(300, -5, 7, 999) == Color(r: 255, g: 0, b: 7, a: 255)

  test "withAlpha / mulAlpha":
    check rgb(10, 20, 30).withAlpha(77).a == 77
    check rgb(10, 20, 30).withAlpha(77).r == 10
    check rgb(10, 20, 30).mulAlpha(0.5).a == 128

  test "mix":
    check mix(rgb(0, 0, 0), rgb(255, 255, 255), 0) == rgb(0, 0, 0)
    check mix(rgb(0, 0, 0), rgb(255, 255, 255), 1) == rgb(255, 255, 255)
    check mix(rgb(0, 0, 0), rgb(255, 255, 255), 0.5) == rgb(128, 128, 128)
    check mix(rgba(0, 0, 0, 0), rgba(200, 100, 0, 200), 0.5) == rgba(100, 50, 0, 100)
    check mix(rgb(10, 10, 10), rgb(20, 20, 20), 5) == rgb(20, 20, 20)   # t clamped
    check lerp(rgb(0, 0, 0), rgb(100, 0, 0), 0.25) == rgb(25, 0, 0)
