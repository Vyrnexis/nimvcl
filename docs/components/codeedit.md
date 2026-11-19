# CodeEdit

A source code editor (Delphi's SynEdit): monospace text with a gutter, syntax
highlighting, code folding, bracket matching, find and replace, auto-indent and
a buffer that opens very large files quickly. Use `Memo` for plain multi-line
text and `CodeEdit` for code. `examples/editor_demo.nim` is a small text editor
built from it (file tree, tabs, find bar, status bar).

## Quick example

```nim
let ed = newCodeEdit(form, "", 8, 8, 560, 380)
ed.align = alClient
ed.language = "nim"                  # or ed.highlighter = newNimHighlighter()
ed.text = "proc hello() =\n  echo \"hi\"\n"
ed.tabWidth = 2
ed.onCaretMove = proc(sender: Control, line, col: int) =
  echo "Ln ", line + 1, ", Col ", col + 1
ed.onModifiedChanged = proc(sender: Control) =
  echo "modified: ", CodeEdit(sender).modified

ed.addMarker(0, mkBreakpoint)        # an icon in the gutter
ed.find("echo")                      # selects the first match
ed.showFindBar(replace = true)       # Ctrl+H does the same
```

Opening and saving a file keeps the line endings and picks the language by
extension (`.nim`, `.nims`, `.nimble` are Nim, anything else is plain text):

```nim
let report = ed.loadFromFile("main.nim")     # LoadReport: lineEnding, invalidBytes, ...
echo ed.fileName, " ", ed.language, " ", report.lines, " lines"
ed.saveToFile()                              # back to the same name, same line endings
```

Positions are `(line, col)`, both **zero based**; `col` is a byte index in the
UTF-8 line (the status bar of an editor shows `line + 1`).

## Properties

| Name | Type | Description |
|---|---|---|
| `text` | string | All lines joined with `\n`; setting it clears history, markers and scroll |
| `lineCount` | int | Number of lines (a text ending in a newline has an empty last line) |
| `lineAt(i)` | string | One line, no terminator |
| `color` | Color | Own editor background (the gutter is a shade of it); default `theme.surface`. Syntax token colors are kept, made readable on the fill |
| `font.color` | Color | Color of the plain text (VCL `Font.Color`); alpha 0 uses the theme's text color |
| `readOnly` | bool | No typing; programmatic edits and `text =` still work |
| `modified` | bool | Differs from the last `markSaved` / `saveToFile` / `loadFromFile` |
| `fileName` | string | Remembered name; setting it picks the language (see `autoHighlighter`) |
| `language` | string | `"nim"` or `"text"` (read); `language = "nim"` attaches the Nim highlighter |
| `highlighter` | `Highlighter` | The language; nil is plain text. One highlighter per editor |
| `autoHighlighter` | bool | `fileName` / `loadFromFile` choose the language (default true) |
| `caretPos` | `CodePos` | `(line, col)`; setting expands folds and scrolls |
| `selection` | `Selection` | `sel(anchor, caret)`; `select(a, b)` is the same |
| `selectedText`, `hasSelection` | | The primary selection (there is only one) |
| `borderStyle` | `BorderStyle` | `bsSingle` (default) or `bsNone`: no border, no focus ring and square corners, so the control can sit flush in a panel |
| `tabWidth` | int | Width of a TAB in cells (default 4) |
| `insertSpaces` | bool | Tab and indentation insert spaces (default) or TABs |
| `showWhitespace` | bool | Dots for spaces, arrows for TABs |
| `showLineNumbers` | bool | The number column of the gutter (default true) |
| `showIndentGuides` | bool | Thin vertical lines in the indentation (default true) |
| `highlightCurrentLine`, `highlightBrackets` | bool | Current line band, matching bracket boxes (default true) |
| `folding` | bool | Fold column and folding (default true) |
| `foldKinds` | `set[FoldKind]` | `fkIndent`, `fkBrackets`, `fkMarkers`; default depends on the language |
| `markerColumn` | bool | Always show the marker column (it also appears while markers exist) |
| `overwrite` | bool | Overwrite mode with a block caret (Insert key) |
| `lineComment` | string | Prefix of Ctrl+/; default: the highlighter's `commentToken` (`#` for Nim) |
| `indentAfter` | string | Characters that make Enter indent one more level (`:=([{` for Nim, `([{` otherwise) |
| `lineEnding` | `LineEnding` | `leLF` or `leCRLF`, written by `saveToFile` |
| `encoding` | string | Always `"UTF-8"` |
| `ensureTrailingNewline` | bool | `saveToFile` adds a final newline when missing (default false: the file is written as read) |
| `topLine`, `visibleRowCount` | int | First line in view, rows that fit |
| `rowHeight`, `charWidth`, `gutterWidth` | float32 | Metrics in logical pixels |
| `font` | `FontSpec` | Default: the theme's monospace font (bundled Noto Sans Mono) |
| `markerPainter` | `MarkerPainter` | Draws your own marker icons (return false for the built-in one) |
| `gotoLineDialog` | `proc(e: CodeEdit)` | What Ctrl+G does; default asks with `inputQuery` |

`wordWrap` is **not supported yet**: long lines scroll horizontally.

## Events

| Event | Description |
|---|---|
| `onChange` | The text changed (once per operation) |
| `onCaretMove(sender, line, col)` | The caret moved |
| `onModifiedChanged` | `modified` changed |
| `onOverwriteChange` | Insert toggled overwrite mode |
| `onGutterClick(sender, line, area, button, handled)` | A click on the marker column (`gaMarkers`) or on a line number (`gaNumbers`). Set `handled = true` to skip the default (selecting the line); an IDE toggles a breakpoint here |

Attach a `PopupMenu` with `attachPopupMenu(ed, menu)`: a right click moves the
caret first unless it lands inside the selection.

## Methods

| Method | Description |
|---|---|
| `loadFromFile(path)`, `saveToFile(path = "")` | Files; line endings, trailing newline preserved |
| `markSaved()` | Declare the text saved |
| `gotoLine(line, col = 0)` | Caret there (clamped), folds expanded, line centred when it was out of view |
| `ensureVisible(line, col = 0, center = false)` | Scroll without moving the caret |
| `replaceRange(a, b, text, keepSelection = false)`, `insertAt(pos, text)` | Edit from outside the way the user would: one undo step, repaint, `onChange`. The caret ends after the new text, or with `keepSelection` the selection stays (shifted along with the text). Returns false when read-only or nothing changes |
| `beginUndoGroup()`, `endUndoGroup()` | Make every edit in between one undo step (they nest) |
| `touched(follow = true)` | After you changed `model` directly: resync, repaint and fire `onChange`, `onCaretMove`, `onModifiedChanged` |
| `undo()`, `redo()`, `cutToClipboard()`, `copyToClipboard()`, `pasteFromClipboard()`, `selectAll()` | Without a selection copy and cut take the whole line |
| `indent()`, `outdent()`, `toggleComment()`, `duplicateLine()`, `deleteLine()`, `moveLineUp()`, `moveLineDown()` | Line commands; one undo step each |
| `foldAll()`, `unfoldAll()`, `foldCaret()`, `unfoldCaret()`, `toggleFold(line)` | Folding; `isFolded(line)`, `canFold(line)`, `isLineVisible(line)` |
| `setSearch(pattern, opts)`, `find(pattern, opts, forward)`, `findNext()`, `findPrev()` | Search from the caret, wrapping; the match is selected |
| `replaceCurrent(text)`, `replaceAll(pattern, text, opts)` | Replace; `replaceAll` is one undo step and returns the count |
| `showFindBar(replace = false)`, `hideFindBar()`, `findBarVisible`, `findBar` | The built-in find bar |
| `addMarker(line, kind)`, `removeMarker`, `toggleMarker`, `hasMarker`, `clearMarkers([kind])`, `markerLines(kind)`, `nextMarker(kind, fromLine)` | Gutter markers |
| `posAtPoint(x, y)`, `pointOfPos(pos)`, `caretRect` | Hit testing in client coordinates |
| `model`, `foldMap` | The underlying `CodeModel` and `FoldMap` for advanced use |

`SearchOptions` has `ignoreCase`, `wholeWord` and `regex`. A bad regular
expression makes `find` return false (the find bar shows "Invalid pattern").

The regular expressions come from a built-in engine (`minire`; `std/re` needs
PCRE at run time) that works on one line at a time: literals, `.`, classes
`[a-z_]` / `[^...]`, `\d \w \s` and their negations, `\b \B`, `^ $`, groups
`( )` and `(?: )`, `|`, greedy and lazy quantifiers (`* + ? {n,m}`, `*?` ...)
and the escapes `\t \n \r \xHH \uHHHH`. No backreferences, lookaround or
possessive quantifiers. Matching time grows with pattern size times line length,
so nested repetition such as `(a|aa)+$` is safe and a group that can match
nothing (`(a*)*b`) works. **Whole word** means the match does not start or end
inside a word, so it also works for patterns that begin or end with punctuation.
F3 and Replace step past an empty match, Find Previous visits every position,
and **Replace All** builds the new text once: one undo step, fast on a 40,000
line file.

## Keys

| Keys | Action |
|---|---|
| Arrows, Ctrl+Left / Right | Move; by word with Ctrl. Shift extends |
| Home | First non-blank, then column 0 |
| End, Ctrl+Home, Ctrl+End, PgUp, PgDn | As usual; Ctrl+Up / Down scroll |
| Ctrl+A, Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z | Select all, undo, redo |
| Ctrl+X / C / V, Ctrl+Insert, Shift+Insert, Shift+Delete | Clipboard |
| Ctrl+D | Duplicate the line (or the selected lines) |
| Ctrl+Shift+K | Delete the line(s) |
| Alt+Up / Alt+Down | Move the line(s); a folded block moves as a whole |
| Tab, Shift+Tab | Indent and outdent; Tab on a caret inserts up to the next tab stop |
| Backspace | In the indentation: back to the previous tab stop |
| Enter | Keeps the indentation; one more level after `:` `=` or an open bracket (not after `==`, `+=`, nor inside a comment or string); between `(` `)`, `[` `]`, `{` `}` it opens a three-line block |
| Ctrl+/ | Toggle the line comment |
| Ctrl+Shift+[ / ] | Fold / unfold the region around the caret |
| Ctrl+K Ctrl+0 / Ctrl+K Ctrl+J | Fold all / unfold all |
| Ctrl+K Ctrl+C / Ctrl+K Ctrl+U | Comment / uncomment |
| Ctrl+F, Ctrl+H | Find bar, find and replace bar |
| F3, Shift+F3 | Next / previous match |
| Ctrl+G | Go to line (`line` or `line:column`) |
| Insert | Overwrite mode |
| Esc | Close the find bar |

Mouse: click, Shift+click, double click (word) and triple click (line), both
extend by words or lines while dragging, drag with auto-scroll, wheel
(Shift = horizontal). A click on the gutter selects the line (drag for more); a
click on a fold chevron or on the "..." pill of a folded line folds or unfolds.

## The find bar

`showFindBar` (Ctrl+F) puts a small card at the top right of the text area: the
find field (Enter next, Shift+Enter previous), toggles for match case (Alt+C),
whole word (Alt+W) and regular expression (Alt+R), a counter ("3 of 12",
"No results"), previous / next / close buttons and, with the replace row open
(Ctrl+H), the replace field with "Replace" (Enter) and "All" (Ctrl+Enter).
While it is open every match in view is highlighted. Typing searches as you type
from the start of the current selection. The bar is a `FindBar` container
(`ed.findBar`); it only reports through callbacks, `CodeEdit` does the work.

## Markers

```nim
ed.addMarker(12, mkBreakpoint)       # kinds: mkBookmark, mkInfo, mkWarning,
ed.addMarker(20, mkError)            #   mkBreakpoint, mkError, mkCurrent,
ed.addMarker(31, mkCurrent)          #   mkUser0 .. mkUser3
ed.onGutterClick = proc(sender: Control, line: int, area: GutterArea,
                        button: MouseButton, handled: var bool) =
  if area == gaMarkers:
    CodeEdit(sender).toggleMarker(line, mkBreakpoint)
    handled = true
```

Markers follow their line when lines are inserted or removed above them; a line
deleted with Ctrl+Shift+K takes its markers along, lines merged away by other
edits hand theirs to the surviving line. `mkCurrent` also tints the line.

## Tips

* **Theme**: syntax colours come from `syntaxStylesFor(theme)`, so switching
  between `themeLight()` and `themeDark()` repaints in the matching palette.
* **Large files**: only the rows in view are measured and painted, positions
  are float64 and the buffer is a line array that loads 100 MB / 2 million
  lines in about a second (release build). Highlighting is incremental. When
  the view jumps more than 5000 lines past what has been lexed, the visible
  lines are painted from an approximate lex of the lines around them
  (`approximateHighlight` tells) until a background pass catches up; documents
  over 150,000 lines are not warmed up in the background and become exact only
  when scrolled through. Folding is switched off above 500,000 lines (the
  region scan is a full pass per edit). Measured in release on a 2,000,000 line
  file: paint after a jump to the end 4 ms, wheel scrolling 4 ms per frame,
  typing in the middle 4 ms.
* **Folded lines** never hold the caret: moving into them, a search hit,
  `gotoLine` or `caretPos =` unfold first; folding with the caret inside moves
  it to the header.
* **Caret blink** repaints only the caret rectangle (partial repaint).
* **IME**: the composition is drawn inline at the caret and underlined.
* **Non-ASCII**: ASCII characters are placed by arithmetic (advance times
  column); other text is measured. Every codepoint counts as one cell for
  `Up` / `Down` and the status column, so wide CJK characters shift visual
  columns slightly.
* `CodeEdit` is built on `ScrollingControl`; the highlighter, fold map and
  searcher are separate modules (`highlight`, `nimlexer`, `folding`, `search`)
  that need no window and are documented in their module comments.
