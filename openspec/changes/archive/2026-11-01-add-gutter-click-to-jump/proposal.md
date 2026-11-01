## Why

Line numbers show where a line is, but they gave no way to get there. In the preview, numbers are block-start annotations: a 400-line code block shows one number, so "I see line 214, take me there" had no affordance. `add-line-numbers` deferred click-to-jump as its natural follow-up (Non-Goals and Open Questions). The reason it gave was that clicks would add interaction and focus routing that the editor's existing gestures (Esc, find, mode shortcuts) must coexist with.

This closes the `TODOS.md` item "Click a line-number gutter number to jump to that line".

## What Changes

- **Editor gutter clicks.** `MarkdownSourceTextView.mouseDown` hit-tests the gutter (left of the text container) when numbers are shown and no marked text is pending:
  - **Click:** selects the source line beside the click, together with its line break.
  - **Shift-click:** extends the current selection to that line.
  - **Drag:** extends the selection line by line, with autoscroll.

  Lines are numbered as the gutter numbers them (LF, CRLF, bare CR), through the new `sourceLineRange(forLine:in:)` and `sourceLineRange(containing:in:)`. With numbers hidden, the inset stays ordinary margin.
- **Preview gutter clicks.** The gutter's numbers take pointer events (the layer still passes clicks through) and show a pointer cursor. A listener in the isolated world accepts only trusted primary clicks on the layer's own spans. It posts the number's line to a new `revealSourceLine` handler, registered in `.defaultClient` beside `enterEdit` and `toggleTask`, so page scripts never see it.
- **Routing.** `ContentView` routes the line as follows:
  - **Side by Side:** focuses the editor and sends `DocumentStore.editorLineSelection`. The editor selects the line and scrolls its start into view only if needed, so the preview stays put.
  - **Read mode:** switches to Write with an anchor on that line, placing it at the top as an outline jump does, then selects it.

  The editor applies the request once per token, waits for a settling mode-switch anchor so the anchor's caret cannot overwrite the selection, and clears it so a later editor does not replay it.
- **Declare the behavior** in `line-number-display`, and update both READMEs, which called the numbers display-only.
- **Add tests:** headless line-range tests, GUI tests for editor clicks, a GUI test for the preview bridge, an end-to-end test through `ContentView` for both modes, and an assertion that page scripts cannot see the new handler.

**Non-goals:**

- Numbering list items in the preview (its own TODO, which needs a product decision).
- A keyboard path to a line ("Go to Line"). The gutter layer stays `aria-hidden`, so clicking a number is a mouse convenience.
- A pointer cursor over the editor gutter. `NSTextView` manages its own cursor rects.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `line-number-display`: clicking a line number selects its source line in the editor, from the editor gutter and from the preview.

## Impact

- `Sources/MD2App/MarkdownEditorView.swift`:
  - `MarkdownSourceTextView`: `mouseDown`, `gutterLineRange(atY:)`.
  - `Coordinator`: `selectSourceLine`, the line-range helpers, the settle hand-off.
  - `MarkdownEditorView`: the `lineSelection` binding.
- `Sources/MD2App/MarkdownPreviewView.swift`: gutter CSS, the interaction script, the `revealSourceLine` handler and the `onRevealSourceLine` callback.
- `Sources/MD2App/ContentView.swift`, `DocumentStore.swift`, `FindCommand.swift` (`LineSelectionRequest`), and the `AppSettings.swift` doc comment.
- Tests:
  - `MarkdownEditorLineRangeTests`
  - `EditorLineNumberGutterGUITests`
  - `LineNumberGutterGUITests` (its harness now keeps a page open)
  - `ReadingImprovementsGUITests`
  - `PreviewSecurityGUITests`
- `README.md`, `README.zh-CN.md`, `TODOS.md`.
- Rendering and exports are unchanged: the gutter script is preview-only and the renderer is untouched. No new setting or localized string.
