# Edit

A single-line text box (Delphi `TEdit`) with selection, undo, clipboard and IME
support.

## Quick example

```nim
let name = newEdit(form, "", 16, 16, 240)
name.placeholder = "Your name"
name.maxLength = 40
name.onChange = proc(sender: Control) =
  echo "now: ", Edit(sender).text

let pass = newEdit(form, "", 16, 56, 240)
pass.password = true                       # shows dots
```

## Common properties

| Name | Type | Description |
|---|---|---|
| `text` | string | The content. Setting it clears the undo history |
| `placeholder` (`textHint`) | string | Muted hint shown while empty |
| `readOnly` | bool | Blocks typing but allows selecting and copying |
| `maxLength` | int | Maximum characters (0 = unlimited) |
| `password` / `passwordChar` | bool / Rune | Mask the text |
| `charCase` | `EditCharCase` | `ecNormal`, `ecUpperCase`, `ecLowerCase` |
| `numbersOnly` | bool | Accept only digits |
| `borderStyle` | `EditBorder` | `ebSingle` or `ebNone` |
| `autoSelect` | bool | Select all when the edit gets the focus (also by a click: see Tips) |
| `selStart`, `selLength`, `selText`, `caretPos` | int / string | Selection and caret (UTF-8 byte indexes) |
| `color` | Color | Own background: the box fill (`TEdit.Color`); default `theme.surface`. A disabled edit fades it. With no `font.color`, text stays readable on a dark or light fill. Set it and `parentColor` turns off |
| `font.color` | Color | Text color (VCL `Font.Color`); alpha 0 (the default) uses the theme's text color. `fontColor` is a shortcut |

## Events

| Event | Description |
|---|---|
| `onChange` | The text changed, by typing or by code |
| `onKeyDown`, `onKeyPress` | Filter keys, see [events](../guide/events-and-input.md) |
| `onEnter`, `onExit` | Focus gained or lost |

## Methods

| Method | Description |
|---|---|
| `selectAll()`, `select(start, length)`, `clearSelection()` | Selection |
| `insertText(s)` | Replace the selection (one undo step) |
| `replaceRange(start, length, s)` | Replace a byte range |
| `clear()` | Empty the text |
| `undo()`, `redo()`, `canUndo`, `canRedo` | History |
| `copyToClipboard()`, `cutToClipboard()`, `pasteFromClipboard()` | Clipboard |

## Tips

* With `autoSelect`, tabbing into the edit or clicking it selects all the text.
  The click that gives the edit the focus keeps that selection (it does not
  place the caret); dragging, or a later click, works normally, and a double
  click selects a word.
* Pasting turns line breaks and tabs into spaces (a single line cannot hold
  them). Shift+Backspace deletes backward like Backspace; Shift+Delete cuts.
* Indexes are byte offsets into the UTF-8 text, not character counts.
* Edit does not handle Enter or Esc, so a default or cancel button still gets them.
* Tab moves focus away. Edit is a tab stop by default.
* Use `insertText` instead of `text =` to keep undo working.

[Back to the index](../README.md)
