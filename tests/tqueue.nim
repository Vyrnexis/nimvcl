## `Application.queue` from worker threads: data and plain-proc overloads.
## Also run with -d:useMalloc.

import std/[unittest, typedthreads, isolation, monotimes, times]
import nimvcl

{.warning[Effect]: off.}   # std/isolation's own `=destroy` warns when instantiated

type
  Msg = object
    worker, n: int
    text: string
    items: seq[string]
  Node = ref object
    name: string
    next: Node

var
  uiThread: int
  received: seq[Msg]
  strings: seq[string]
  ticks: int
  names: seq[string]
  wrongThread: int

proc onMsg(m: Msg) =
  if getThreadId() != uiThread: inc wrongThread
  received.add m

proc onString(s: string) = strings.add s
proc onTick() = inc ticks
proc onNode(n: Node) =
  var x = n
  while x != nil:
    names.add x.name
    x = x.next

proc closureJob(v: int): QueuedProc =
  result = proc() = ticks += v

proc sender(args: (int, int)) {.thread.} =
  let (id, count) = args
  for i in 1 .. count:
    var m = Msg(worker: id, n: i, text: "message number " & $i & " from " & $id)
    for j in 0 ..< i mod 5: m.items.add "item" & $j & "-" & $i
    {.cast(gcsafe).}:
      Application.queue(m, onMsg)

proc stringSender(count: int) {.thread.} =
  for i in 1 .. count:
    {.cast(gcsafe).}:
      Application.queue("s" & $i, onString)

proc tickSender(count: int) {.thread.} =
  for i in 1 .. count:
    {.cast(gcsafe).}:
      Application.queue(onTick)

proc closureSender(count: int) {.thread.} =
  for i in 1 .. count:
    {.cast(gcsafe).}:
      Application.queue(closureJob(2))

proc nodeSender(count: int) {.thread.} =
  for i in 1 .. count:
    {.cast(gcsafe).}:
      Application.queue(isolate(Node(name: "a" & $i, next: Node(name: "b" & $i))),
                        onNode)

proc pumpUntil(done: proc(): bool, seconds = 20.0) =
  let t0 = getMonoTime()
  while not done() and (getMonoTime() - t0).inMilliseconds < int(seconds * 1000):
    Application.processMessages(5)

suite "Application.queue":
  setup:
    Application.init()
    uiThread = getThreadId()
    received.setLen 0; strings.setLen 0; names.setLen 0
    ticks = 0; wrongThread = 0

  test "1000 string messages from one worker arrive in order":
    var t: Thread[int]
    createThread(t, stringSender, 1000)
    pumpUntil(proc(): bool = strings.len >= 1000)
    joinThread t
    check strings.len == 1000
    for i in 0 ..< 1000: check strings[i] == "s" & $(i + 1)

  test "1000 object messages with string and seq payloads, in order, on the UI thread":
    var t: Thread[(int, int)]
    createThread(t, sender, (1, 1000))
    pumpUntil(proc(): bool = received.len >= 1000)
    joinThread t
    check received.len == 1000
    check wrongThread == 0
    for i in 0 ..< 1000:
      let m = received[i]
      check m.n == i + 1
      check m.text == "message number " & $(i + 1) & " from 1"
      check m.items.len == (i + 1) mod 5
    check received[3].items == @["item0-4", "item1-4", "item2-4", "item3-4"]

  test "four workers: every message arrives, in order per worker":
    var ts: array[4, Thread[(int, int)]]
    for i in 0 .. 3: createThread(ts[i], sender, (i, 500))
    pumpUntil(proc(): bool = received.len >= 2000)
    joinThreads ts
    check received.len == 2000
    var last: array[4, int]
    for m in received:
      check m.n == last[m.worker] + 1
      last[m.worker] = m.n
    check last == [500, 500, 500, 500]

  test "plain proc without data":
    var t: Thread[int]
    createThread(t, tickSender, 1000)
    pumpUntil(proc(): bool = ticks >= 1000)
    joinThread t
    check ticks == 1000

  test "isolated ref graphs":
    var t: Thread[int]
    createThread(t, nodeSender, 300)
    pumpUntil(proc(): bool = names.len >= 600)
    joinThread t
    check names.len == 600
    check names[0] == "a1" and names[1] == "b1" and names[599] == "b300"

  test "closure overload built by a helper proc":
    var t: Thread[int]
    createThread(t, closureSender, 500)
    pumpUntil(proc(): bool = ticks >= 1000)
    joinThread t
    check ticks == 1000

  test "queue from the UI thread and mixing kinds keeps order":
    var order: seq[int]
    Application.queue(proc() {.closure, gcsafe.} = {.cast(gcsafe).}: order.add 1)
    Application.queue(onTick)
    Application.queue("x", onString)
    Application.queue(proc() {.closure, gcsafe.} = {.cast(gcsafe).}: order.add 2)
    Application.processMessages(50)
    check order == @[1, 2]
    check ticks == 1 and strings == @["x"]

suite "runOnUi (gcsafe, no Application global)":
  test "worker sends data without cast(gcsafe)":
    var got {.global.}: seq[string]
    proc onMsg(s: string) = {.cast(gcsafe).}: got.add s
    proc worker() {.thread.} =
      for i in 0 ..< 100: runOnUi($i, onMsg)
    var th: Thread[void]
    createThread(th, worker)
    joinThread(th)
    Application.processMessages(0)
    check got.len == 100
    check got[0] == "0" and got[99] == "99"
