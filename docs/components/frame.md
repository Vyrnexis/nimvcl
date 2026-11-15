# Frame

A reusable group of controls (Delphi `TFrame`). Declare it once with the
`frame` macro, then drop as many instances as you like into forms or panels.

## Quick example

```nim
frame AddressFrame:
  width = 220; height = 70
  Edit street:
    placeholder = "Street"
    align = alTop
  Edit city:
    placeholder = "City"
    top = 34

let billing = newAddressFrame(form, 16, 16)
let shipping = newAddressFrame(form, 16, 100)
billing.street.text = "Main St"            # typed fields, per instance
```

It works the same inside a `form` block:

```nim
form Order:
  AddressFrame billing:
    top = 10
  AddressFrame shipping:
    top = 90
```

## Common properties

| Name | Type | Description |
|---|---|---|
| Named children | typed fields | `billing.street` is an `Edit` |
| `var x: T` | field | Extra fields declared in the `frame` block |
| `align`, `anchors`, `width`, `height` | | Like any control |

## Events

Whatever the children expose. Add your own procs inside the `frame` block:

```nim
frame Counter:
  var count: int
  Button plus:
    caption = "+"
    onClick: inc self.count
```

## Methods

The macro generates `type X* = ref object of Frame`, `initX` and
`newX(parent, left, top, width, height)`. Plain `newFrame(parent, ...)` makes an
empty transparent frame.

## Tips

* A `Frame` is a transparent `Panel` that draws nothing. Its children inherit the
  parent's color.
* The `init:` block runs after all children are built, like `FormCreate`.
* See [Forms and frames](../forms.md) for the full macro syntax.

[Back to the index](../README.md)
