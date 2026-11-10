# Markdown-aware source editing

These commands work in Write and in the editor pane of Side by Side. Menu
commands target the focused source editor and do not format a search field.
The first formatting command from Read mode switches to the source editor and
reveals its retained selection or caret **without changing the document**. A short
notice asks you to select the source text and run the command again. Rendered text
is not guessed back to a source range: repeated words, links, formulas and
cross-paragraph selections can be ambiguous. Only a subsequent command in the
focused source editor applies formatting.

| Input | Behavior |
| --- | --- |
| Return | Continue `-`, `*`, `+`, `1.`, `1)`, task items and `>` quotes, including nested containers. Increment ordered markers and reset new tasks to unchecked. |
| Return on an empty item | Remove the innermost marker; `> - [ ] ` becomes `> `, then another Return exits the quote. |
| Shift+Return | Insert a source newline aligned with the list content column, retaining quote containers. This is a Markdown soft break, without trailing spaces or `<br>`. |
| Tab / Shift+Tab | Move forward/backward between supported table cells, skipping the separator row. Elsewhere, retain list indentation or native Tab behavior. |
| Cmd+B / Cmd+I | Wrap or unwrap the selected text with bold/italic markers. With no selection, insert markers around the caret. |
| Cmd+K | Wrap/unwrap a link. Use an HTTP(S) or mailto URL from the clipboard when available; otherwise place the caret in the destination. |
| Option+Cmd+1–6 / Cmd+0 | Set the selected lines' heading level / remove their ATX heading prefix. |
| Option+Cmd+C | Insert a fenced code block, or wrap selected text. Choose a longer fence if the text contains backticks. |
| Option+Cmd+T | Insert a two-column table template, selecting its first header. |

In code blocks Return preserves indentation without continuing literal Markdown
markers. List indentation shares the renderer's column calculation: tabs advance
to the next four-column tab stop and marker gaps of five or more spaces use a one-column gap.
The task checkbox is not part of that column calculation.

Code-block and table insertion retain the surrounding line-ending style,
including CRLF or CR when inserting at the end of a document. Links inserted
from the clipboard preserve literal HTML-entity spellings and URL percent
escapes, so the preview opens the original destination.

Typing `(`, `[`, `{`, single/double quotes, backticks, `（`, `「`, or `《` inserts
a matching closer when appropriate, or wraps the selection. Typing an existing
closer moves past it; Backspace between an empty pair deletes both characters.
Escaped delimiters and apostrophes within words remain literal. Paste and
explicit programmatic replacements do not trigger pairing.

All transformations are pure `MD2Core.MarkdownEditing` functions returning a
UTF-16 replacement range, replacement text and selection. The AppKit adapter
applies them through `insertText(_:replacementRange:)`, preserving the document
binding, dirty state, styling, autosave and native undo stack. Menu requests use
fresh tokens; consumption survives editor re-hosting so a mode switch cannot
replay an old command. Formatting shortcuts are registered with the mode
shortcut validator; Cmd+1/2/3 keep their existing defaults.

While `hasMarkedText()` is true, editing commands and automatic pairing yield to
the input method. Return used to commit Latin letters from a Chinese IME must
not also continue a list. Shift+Return's originating event is retained because
AppKit may dispatch it as `insertNewline:` rather than `insertLineBreak:`.

## Table editing

Tab selects the next cell's source content; Shift+Tab selects the previous cell.
The separator row is skipped. Tab from the last cell appends an empty body row;
Shift+Tab from the first header cell leaves the selection in place. Navigation
does not change the document or its undo history.

Format > Table Operations inserts rows above/below or columns left/right, and
deletes the current body row or column. The header and separator remain, and a
table keeps at least one column. A header cell supports Insert Row Below. Each
structure change is one undo step that restores both text and selection. These
commands use the same focused-editor and Read-mode source-reveal rules as other
formatting commands; native Find, filename and Settings fields keep ownership.

The supported subset is a top-level rectangular pipe table with matching column
counts, a header, a separator row and optional body rows. Select inside one cell;
cross-cell selections and separator-row selections are rejected. Escaped pipes
and closed single-backtick code spans follow the renderer's existing rules.
Entity spellings such as `&#124;` remain literal source. Nested list/quote tables,
code blocks, HTML blocks/comments, unclosed code spans and multiple-backtick
spans are not structurally edited. A rejected explicit command explains why.

Existing cell text, padding, alignment markers and line endings are retained.
New empty rows use outer pipes. Adding an empty edge column or deleting down to
one column adds any missing outer pipe needed to keep the renderer's column
count. This does not align or reformat the other cells. List indentation retains
its existing sibling-content-column behavior outside supported tables.

To bound a key press, structural editing accepts at most 500,000 UTF-16 units and
20,000 lines of source. A table and its replacement each accept 100,000 UTF-16
units, 1,000 rows, 128 columns and 20,000 cells, counting the header and separator.
Exceeding a limit produces a notice for explicit commands; unsupported Tab
positions retain their existing behavior.

## Find and replace

The last query stays with the document when its find bar closes or its mode
changes. Cmd+G / Shift+Cmd+G continue forward/backward with the bar hidden;
opening Find restores that query. The incoming surface computes its own matches
from source or rendered text. In Side by Side, a search updates the pane you
use; the other pane adopts the last query when you invoke Find or navigation
there. Opening another document resets the query.

Find and Replace use separate rows, with flexible fields at the 360-point
minimum editor width. The bar occupies its own space above the source so it
cannot cover the first line. Close the bar to return focus to the editor.

Case matching and whole-word matching are document-local options shared by
source and preview. By default searches ignore case and accents; Match case
changes only case handling. Matches always cover complete Unicode grapheme
clusters, including decomposed accents and emoji. Whole word treats consecutive
Unicode letters, combining marks, numbers and connector punctuation (including
`_`) as one token. It does not perform Chinese dictionary segmentation: `中文`
does not whole-word-match part of `中文测试`. Word boundaries inspect the
adjacent Unicode scalars at each complete grapheme edge; an internal ZWJ does
not turn an Indic conjunct into a separator between surrounding letters.
Inline Markdown formatting does
not create an artificial word boundary in the preview. Visible hard line breaks
(`<br>`) remain newline separators, so text on either side is not joined into a
word that the rendered page does not contain.

Only selection freezes a single nonempty **source** selection when enabled. If
you select text before opening Find, that selection remains available even after
search navigation moves the caret. Navigation and hiding the bar keep the frozen
range. Find replacements adjust its length, and one Undo/Redo restores both the
text and the range. Other committed edits or reloads expire the range. An expired
scope stays explicitly marked and replacement remains disabled until you use a
new source selection or turn off Only selection; it never becomes a whole-file
replacement silently. Deleting the whole frozen selection leaves an empty scope.

Read mode keeps case/word options and searches rendered text. Selection scope and
replacement are disabled there. Returning to source retains its frozen or expired
scope; a rendered selection is never guessed back into source coordinates.

Replace All shows its source scope and match count, applies a snapshot once, then
reports the replacement count. Replacement text is not searched recursively. The
operation is one undo step, separate from surrounding typing. A replacement
request is canceled with a notice if its source, query, replacement text, caret,
options or scope changes before the native edit executes. Empty queries,
zero matches, expired scope and active input-method composition cannot replace
text. The three options and scope notices occupy additional rows so the fields
remain usable at 360 points in both supported languages.

Preview searches share the source matching engine and reject stale DOM results.
To keep large rendered pages bounded, snapshots stop at 2,000,000 UTF-16 units,
20,000 text/break nodes or 20,000 matches. Exceeding a limit shows an unavailable notice
and no partial results. Source searching is not subject to these preview limits.
Regular expressions remain deferred.

## Explicit paste

Edit offers **Paste as Plain Text** (`Option+Shift+Cmd+V`), **Paste as Markdown**,
and **Paste as Table**. The last two require the focused source editor in Write
or Side by Side. They are unavailable in Read, Find, filename fields and Settings;
they never edit a hidden source selection. Plain Text follows the focused native
text field when one has focus. Source commands are unavailable during input-method
composition or multiple selection.

Plain Text inserts the clipboard string exactly, including Markdown syntax,
spacing and line endings. Markdown with only a plain string also inserts that
string unchanged. These explicit source pastes use the existing preview policy.
Ordinary Cmd+V keeps its existing image-first behavior and selected-label + URL
link creation; the new commands do not inspect images or invoke attachment import.
Empty input never deletes selected text.

Markdown prefers HTML, then RTF. HTML converts semantic paragraphs, breaks,
bold/italic, HTTP(S)/mailto links, headings, lists, quotes and code. CSS, fonts,
colors, IDs and layout are not retained. RTF accepts only text, Unicode escapes,
paragraph/line breaks, bold and italic plus known cosmetic metadata; Unicode
fallback is consumed by token, and group boundaries end that fallback scan. HTML
title metadata is accepted only in a leading document head containing metadata;
inert void `meta` markers (such as a clipboard charset marker) remain allowed
with safe attributes. RTF metadata destinations must be in the header before
body text, and `\*` must name a supported destination. Fields,
list/heading styles, images, objects and unknown semantic controls are unsupported.
There is no browser or system HTML/RTF importer, network request, clipboard image
fetch, script execution or arbitrary file access in capture, conversion or menu
validation. The existing trusted bundled HTML-entity table is reused.

For unsupported, unsafe or malformed rich content, Markdown can escape the complete
captured plain representation as literal prose and show **Formatting was not
preserved**. This representation is not a guarantee of equivalence to the rich
content. Fallback is available only when the original selection includes all
non-whitespace source content, including an empty document. At other positions,
the command leaves text, selection and undo unchanged and explains that the user
can explicitly choose Plain Text. It never expands the selection to fit fallback.
If no complete plain representation is available, nothing is pasted. A changed
source, selection, document identity, backing-file path, editor host, focus or
active input method cancels pending work. Identical-content resets, opening another
file, first-save/relocation and closing also invalidate old requests;
returning to the old target does not revive it.

Structured paste uses the preceding source line ending, or a following one if
none precedes the selection. With no surrounding clue, it uses the first ending in
the selected source, preserving CRLF/CR when replacing the whole document. Only
source with no line-ending clue defaults to LF; final size checks include this
conversion and any block separators.

Table parses quoted TSV: the first row is the header, doubled quotes inside quoted
fields represent one quote, and embedded tabs/newlines stay within their cell.
Empty cells and trailing columns are retained; short rows are padded. One final
record separator does not create an extra row. Malformed quoting rejects the
whole conversion. Markdown punctuation is escaped as literal cell content;
newlines become `<br>`, embedded tabs become `&#9;`, and edge spaces become `&#32;`.
ASCII spaces are not replaced with nonbreaking spaces. Normal HTML layout can
collapse spaces visually; the source/DOM text retains those characters.

Structured output is separated from surrounding text as a Markdown block and
uses the document's local line ending. One Undo reverses the insertion. Conversion
limits are 1 MiB raw rich data, 2 MiB plain/TSV UTF-8, 2 MiB generated UTF-8,
20,000 parser tokens, 64 nesting levels and a one-second cooperative deadline.
TSV additionally allows 999 input rows, 128 columns, 20,000 padded cells including
the generated separator row, and 100,000 UTF-16 units in the final insertion
including CRLF expansion and surrounding block separators. These limits reject
without fallback or partial insertion. Table editing also has its own
whole-document source limit.

## Verification

```sh
swift test
swift test --filter PreciseTextSearchTests --filter PreciseFindSessionTests
MD2_RUN_GUI_TESTS=1 swift test --filter MarkdownEditingGUITests --filter ReadFormattingSelectionGUITests
MD2_RUN_GUI_TESTS=1 swift test --filter PreciseFindGUITests --filter FindBarLayoutGUITests --filter FindSessionGUITests
MD2_RUN_GUI_TESTS=1 swift test --filter UndoHistoryGUITests --filter FindFindDeleteGUITests --filter SettingsWindowPresentationGUITests
```

The pure parameterized suite covers text and selection output, Unicode, CRLF,
nested containers, fences, clipboard links, marker toggles, and renderer content
column agreement. The window-hosted suite covers command dispatch, undo/redo,
autosave, menu tokens across mode switches, paste and marked-text commits. Its
real Pinyin test requires the Simplified Chinese Pinyin input source to be
enabled; it reports a skip if unavailable. The deterministic marked-text test
runs independently of installed input sources.

Table editing and explicit paste have separate bounded parsers. Generated TSV
tables are covered by integration tests for navigation, column edits and native
Undo/Redo.
