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

Find and Replace use separate rows, with flexible fields at the 360-point
minimum editor width. The bar occupies its own space above the source so it
cannot cover the first line. Close the bar to return focus to the editor.

## Verification

```sh
swift test
MD2_RUN_GUI_TESTS=1 swift test --filter MarkdownEditingGUITests --filter ReadFormattingSelectionGUITests
MD2_RUN_GUI_TESTS=1 swift test --filter FindBarLayoutGUITests
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
