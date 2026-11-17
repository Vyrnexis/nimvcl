# Memo

A multi-line text editor (Delphi `TMemo`) with scrollbars, word wrap, undo
and clipboard.

## Quick example

```nim
let memo = newMemo(form, "", 16, 16, 360, 200)
memo.wordWrap = true
memo.lines.add "First line"
memo.lines.add "Second line"
memo.onChange = proc(sender: Control) =
  echo Memo(sender).lines.count, " lines"

echo memo.text            # lines joined with "\n"
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `text` | string | All lines joined with `\n` |
| `lines` | `MemoLines` | `add`, `insert(i, s)`, `delete(i)`, `clear`, `[i]`, `count` |
| `wordWrap` | bool | Wrap at the viewport width; removes horizontal scrolling |
| `readOnly` | bool | No typing (programmatic edits still work) |
| `wantTabs` | bool | Tab inserts a tab character (default: moves focus) |
| `wantReturns` | bool | Enter inserts a line break (default true). When false, every line break, typed, IME or pasted, becomes a space |
| `scrollBars` | `MemoScrollBars` | `msNone`, `msHorizontal`, `msVertical`, `msBoth` |
| `maxLength` | int | Limit in characters |
| `placeholder` | string | Hint while empty |
| `borderStyle` | `BorderStyle` | `bsSingle` (default) or `bsNone`: no border, no focus ring and square corners, so the control can sit flush in a panel |
| `caretPos` | `MemoPos` | `(line, col)` with a byte column |
| `selStart`, `selLength`, `selText` | | Selection in the joined text (byte offsets) |

## Events

| Event | Description |
|---|---|
| `onChange` | The text changed |
| `onKeyDown`, `onKeyPress` | Key handling |

## Methods

| Method | Description |
|---|---|
| `selectAll()`, `select(start, length)`, `clearSelection()` | Selection |
| `undo()`, `redo()` | History |
| `copyToClipboard()`, `cutToClipboard()`, `pasteFromClipboard()` | Clipboard |
| `clear()` | Remove everything |
| `scrollCaretIntoView()` | Reveal the caret |
| `extentsExact` | True when the scroll range is exact (see below) |
| `measureAll()` | Finish measuring a big text now |

## Tips

* An empty memo has one empty line, so `lines.count` is 1. `lines.add` on a
  *pristine* memo (empty text, never edited, nothing added yet) fills that line,
  so the first `add` gives one line, not two. After any edit or add it appends;
  `text = ""` makes the memo pristine again.
* Cut, paste and `lines` edits all fire `onChange`, once per operation.
* With `wantReturns = false` the memo acts like a single-line box: Enter is not
  consumed (a default button gets it) and pasted line breaks become spaces.
* With `wantReturns` on, Enter never reaches a default button.
* `text =` and the `lines` API work on read-only memos and clear undo.
* Memo is built on `ScrollingControl`, so it has `scrollPos` and `scrollTo`.
* **Big texts**: only the visible lines are drawn, and a million lines scroll
  to the exact pixel. Up to 500 lines the scroll range (widest line, or with
  `wordWrap` the number of wrapped rows) is always exact. A bigger text is
  measured in the background, a few milliseconds at a time, so typing and
  scrolling stay responsive; the range is exact for the lines measured so far
  and settles when all are done (`extentsExact` is then true; it takes on the
  order of 20 microseconds per line). Editing is incremental: a changed line is
  measured at once, the widest line is tracked with a counter, and only making
  the last widest line narrower costs one scan. While wrapping, the view stays
  anchored on the same text when rows above it are measured.

  ```nim
  memo.text = hugeString
  memo.measureAll()                     # optional: exact range right now (slow for 1M lines)
  echo memo.extentsExact, " ", memo.visualRowCount
  ```

[Back to the index](../README.md)
