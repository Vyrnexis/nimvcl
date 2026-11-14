## The `form` and `frame` macros (headless: forms are built but not shown).

import std/unittest
import nimvcl

var trace: seq[string]

# ----------------------------------------------------------- a custom control

type
  Badge* = ref object of Panel
    count*: int

proc initBadge*(b: Badge, owner: Component = nil) =
  b.initPanel(owner)
  b.count = 1

proc newBadge*(parent: Container = nil): Badge =
  new result
  result.initBadge(parent)
  if parent != nil: parent.insertControl result

# ------------------------------------------------------------------ the forms

frame AddressFrame:
  width = 200; height = 60
  var edits: int
  Edit street:
    placeholder = "Street"
  Edit city:
    placeholder = "City"
    top = 30
  init:
    self.edits = 2

form Sample:
  caption = "Sample"
  width = 420; height = 380
  var attempts: int
  var limit = 3
  var note: string = "t"
  var names: seq[string]
  GroupBox account:
    caption = "Account"
    align = alTop; height = 220
    Label userLbl:
      caption = "User"
      focusControl = self.user          # forward reference to a later sibling
    Edit user:
      placeholder = "you@example.com"
    Panel box:
      Label:                            # unnamed grandchild
        caption = "inside"
  Label:
    caption = "hello"
  Button ok:
    caption = "OK"; isDefault = true
    onClick = proc(sender: Control) = self.bump()
  Button more:
    caption = "More"
    onClick: self.names.add sender.name
  Badge badge:
    left = 5
  AddressFrame billing:
    left = 10; top = 100
  AddressFrame shipping:
    left = 10; top = 200
  caption = "Sample 2"                   # later assignment wins
  proc bump(self: Sample) =
    inc self.attempts
    self.names.add "bump"
  proc second(self: Sample): int = self.limit + self.attempts
  onShow: self.names.add "shown"
  init:
    trace.add "sample init 1: " & self.ok.caption & " " & $self.limit
    self.ok.caption = "ready"
  init:
    trace.add "sample init 2: " & self.ok.caption

form Base1:
  caption = "base"
  var log: seq[string]
  Label baseLbl:
    caption = "b"
  init:
    trace.add "A"
    self.log.add "A"

form Derived of Base1:
  caption = "derived"
  Button derivedBtn:
    caption = "d"
  init:
    trace.add "B"
    self.log.add "B"
    self.log.add $self.children.len

form Third of Derived:
  init:
    self.log.add "C"

form Empty:
  discard

form Paged:
  PageControl pages:
    align = alClient
    TabSheet one:
      caption = "One"
      Edit first:
        left = 10; top = 10
    TabSheet two:
      caption = "Two"
      Edit second:
        left = 10; top = 10

# ---------------------------------------------------------------------- tests

suite "form macro":
  test "generated type, fields and constructor":
    let f = newSample()
    check f is Form
    check f.ok is Button
    check f.account is GroupBox
    check f.user is Edit
    check f.userLbl is Label
    check f.badge is Badge
    check f.billing is AddressFrame
    check f.ok.caption == "ready"
    check f.caption == "Sample 2"
    check f.width == 420 and f.height == 380
    check f.account.caption == "Account" and f.account.align == alTop
    check f.account.height == 220
    check f.ok.isDefault
    check f.user.placeholder == "you@example.com"
    check f.badge.count == 1 and f.badge.left == 5
    check f.ok.name == "ok" and f.account.name == "account"
    check newEmpty() is Form

  test "nesting: each child is parented to the enclosing child":
    let f = newSample()
    check f.account.parent == Container(f)
    check f.userLbl.parent == Container(f.account)
    check f.user.parent == Container(f.account)
    check f.ok.parent == Container(f)
    check f.badge.parent == Container(f)
    check f.account.children.len == 3
    check f.account.children[0] == Control(f.userLbl)
    # source order at each level: account, hello label, ok, more, badge, 2 frames
    check f.children.len == 7
    check f.children[0] == Control(f.account)
    check f.children[2] == Control(f.ok)

  test "unnamed children are in the tree but not fields":
    let f = newSample()
    let hello = f.children[1]
    check hello of Label and hello.caption == "hello" and hello.name == ""
    check f.box.children.len == 1
    check f.box.children[0].caption == "inside"
    check f.box.children[0].parent == Container(f.box)
    check not compiles(f.hello)

  test "forward reference to a sibling declared later":
    let f = newSample()
    check f.userLbl.focusControl == Control(f.user)

  test "var fields with and without defaults":
    let f = newSample()
    check f.attempts == 0 and f.limit == 3 and f.note == "t" and f.names.len == 0
    check f.second() == 3

  test "events call form methods through self":
    let f = newSample()
    f.ok.doClick()
    f.ok.doClick()
    check f.attempts == 2
    check f.names == @["bump", "bump"]
    check f.second() == 5

  test "NotifyEvent shorthand has `sender`; form-level shorthand":
    let f = newSample()
    f.more.doClick()
    check f.names == @["more"]
    f.show()
    check "shown" in f.names
    f.freeWindow()

  test "init blocks run last, in order":
    trace.setLen 0
    discard newSample()
    check trace == @["sample init 1: OK 3", "sample init 2: ready"]

  test "inheritance: base children and init first, then the derived ones":
    trace.setLen 0
    let d = newDerived()
    check d is Base1
    check trace == @["A", "B"]
    check d.log == @["A", "B", "2"]          # base label + derived button
    check d.caption == "derived"
    check d.baseLbl.caption == "b" and d.derivedBtn.caption == "d"
    check d.children[0] == Control(d.baseLbl) and d.children[1] == Control(d.derivedBtn)
    let t = newThird()
    check t.log == @["A", "B", "2", "C"]
    check t.derivedBtn.parent == Container(t)

  test "frames: two independent instances in one form":
    let f = newSample()
    check f.billing != f.shipping
    check f.billing.street != f.shipping.street
    check f.billing.street.parent == Container(f.billing)
    check f.billing.parent == Container(f)
    check f.billing.edits == 2 and f.shipping.edits == 2
    check f.billing.width == 200 and f.billing.left == 10 and f.shipping.top == 200
    check f.billing.city.top == 30
    f.billing.street.text = "Main St"
    check f.shipping.street.text == ""
    check f.billing.street.placeholder == "Street"
    check f.billing is Panel

  test "frame constructor follows the control convention":
    let f = newForm()
    let a = newAddressFrame(f, 4, 5, 150)
    check a.parent == Container(f) and a.left == 4 and a.top == 5 and a.width == 150
    check a.height == 60
    check newAddressFrame().parent == nil

  test "custom controls following the newT(parent) convention":
    let f = newSample()
    check f.badge.parent == Container(f)
    f.badge.count = 7
    check f.badge.count == 7

  test "TabSheet is a form macro child: pages are created in order under the PageControl":
    let f = newPaged()
    check f.pages.pageCount == 2
    check f.one.parent == Container(f.pages) and f.two.parent == Container(f.pages)
    check f.pages.sheets[0] == f.one and f.pages.sheets[1] == f.two
    check f.one.caption == "One" and f.two.caption == "Two"
    check f.first.parent == Container(f.one) and f.second.parent == Container(f.two)
    check f.pages.tabIndex == 0 and f.one.visible and not f.two.visible

