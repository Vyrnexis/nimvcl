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

[Back to the index](../README.md)
