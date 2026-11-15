## `Component`: the VCL TComponent analogue. A named object with an owner.
## Ownership is for lookup (and later streaming) only; memory is managed by ORC.

type
  ActionLinkBase* = ref object of RootObj
    ## Hook between a client (control or menu item) and an `Action`
    ## (controls/actions.nim). Clients just report clicks to it.

  Component* = ref object of RootObj
    name*: string
    tag*: int
    owner*: Component            ## read-only by convention; use `insertComponent`
    components*: seq[Component]  ## owned components; mutate via insert/remove
    actionLink*: ActionLinkBase  ## set by `client.action = a` (controls/actions.nim)

method clientClicked*(l: ActionLinkBase) {.base.} =
  ## The linked client was clicked (after its own state change and `onClick`).
  discard

method release*(l: ActionLinkBase) {.base.} =
  ## Unlinks the client from its action (both strong references go away).
  ## Called when the client is freed (`Control.free`, deleted menu items).
  discard

proc removeComponent*(owner, c: Component)

proc insertComponent*(owner, c: Component) =
  ## Makes `owner` the owner of `c` (removing it from a previous owner).
  if c == nil or c.owner == owner: return
  if c.owner != nil: removeComponent(c.owner, c)
  c.owner = owner
  if owner != nil: owner.components.add c

proc removeComponent*(owner, c: Component) =
  let i = owner.components.find(c)
  if i >= 0: owner.components.delete(i)
  if c.owner == owner: c.owner = nil

proc initComponent*(c: Component, owner: Component = nil) =
  ## For subclass constructors: `result = MyComp(); result.initComponent(owner)`.
  c.owner = nil
  if owner != nil: owner.insertComponent(c)

proc newComponent*(owner: Component = nil): Component {.discardable.} =
  new result
  result.initComponent(owner)

proc componentCount*(c: Component): int = c.components.len

proc findComponent*(c: Component, name: string): Component =
  ## Direct owned component with this name (case-sensitive), else nil.
  for x in c.components:
    if x.name == name: return x
