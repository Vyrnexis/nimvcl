## A reusable composite control declared with the `frame` macro. The showcase
## shows this very file on the "Form macro" page and places two instances.
import nimvcl

frame ContactCard:
  width = 294; height = 214
  var saved: int
  Label title:
    caption = "New contact"
    font = font(size = 16, style = {fsBold})
  Edit fullName:
    placeholder = "Full name"
    top = 34; width = 294
  Edit email:
    placeholder = "name@example.com"
    top = 72; width = 294
  CheckBox newsletter:
    caption = "Send me the newsletter"
    top = 112
  Button saveBtn:
    caption = "&Save"
    top = 150; width = 110; height = 32
    onClick: self.save()
  Label status:
    left = 124; top = 157
  proc save(self: ContactCard) =
    inc self.saved
    self.status.caption = "Saved #" & $self.saved
