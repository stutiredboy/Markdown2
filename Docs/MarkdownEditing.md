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
| Tab / Shift+Tab | Indent/outdent list items, selected lines and their descendants. Indenting after a sibling uses its content column, including wide ordered markers. |
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
does not whole-word-match part of `中文测试`. Inline Markdown formatting does
not create an artificial word boundary in the preview.

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
20,000 text nodes or 20,000 matches. Exceeding a limit shows an unavailable notice
and no partial results. Source searching is not subject to these preview limits.
Regular expressions remain deferred.

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

Table cell navigation and row/column operations, rich-text-to-Markdown paste,
and a dedicated Paste as Plain Text command are deferred to the second batch.
