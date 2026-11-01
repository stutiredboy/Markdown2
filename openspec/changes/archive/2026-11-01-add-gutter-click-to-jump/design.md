## Context

The editor gutter is drawn in `MarkdownSourceTextView`'s left text-container inset (at least 58pt, present whether or not numbers are shown). The preview gutter is a layer of absolutely positioned spans that the page-world script `__md2RenderLineNumbers` creates inside `<main>`. Each span shows its block's `data-md2-source-line` as CSS generated content, with `pointer-events: none` on the whole layer.

The preview already sends user input to native through an isolated content world. `installInteractionBridge` registers `enterEdit` (Cmd+double-click) and `toggleTask` (checkbox clicks) in `.defaultClient`, and its script accepts only trusted events. `PreviewSecurityGUITests` pins that page scripts cannot see those handlers.

The editor already has a line jump (`jumpLine`, used by outline clicks) that scrolls a line to the top and places the caret, and a mode-switch anchor (`editorJumpAnchor`) that settles over several runloop turns.

## Decisions

### Editor: hit-test in `mouseDown`, select with the gutter's line rule

`mouseDown` claims a click when numbers are shown, no marked text is pending, and the click lies left of `textContainerOrigin.x`. Anything else goes to `super`, so the hidden-number inset, IME composition and clicks in the text are unchanged.

`gutterLineRange(atY:)` maps the click's y to a glyph (`glyphIndex(for:in:)` at x = 0), and then to the source line containing it:
- A click beside a wrapped row maps to the whole line.
- A click below the text maps to the extra line fragment, which is the empty last line.

Lines follow the gutter's own rule (LF, CRLF and a bare CR; `gutterRows`). That rule applies through `sourceLineRange(forLine:in:)` and `sourceLineRange(containing:in:)`. `NSString.lineRange` would also break at U+2028, U+2029 and NEL, and select less than the numbered line.

The selection includes the line break, like a triple-click. Shift and drag follow the gutters of other editors (Xcode, BBEdit). The anchor is the clicked line, or with Shift the current selection, and each drag event selects the union with the line under the pointer. `autoscroll(with:)` keeps a drag past the edge moving. The tracking loop reads `leftMouseDragged`/`leftMouseUp` from the window, the standard AppKit pattern, so the tests drive it by queuing those events.

*Alternative considered:* synthesizing a triple-click so `NSTextView` does paragraph selection. Rejected: it is a hack on private behavior, and paragraph boundaries are not the gutter's line boundaries.

### Preview: clickable numbers, isolated-world listener

Only the spans get `pointer-events: auto` (and `cursor: pointer`). The layer still covers `<main>` with `pointer-events: none`, so text selection and links elsewhere are unaffected.

The listener lives in the interaction script, in `.defaultClient`. It requires a trusted primary click, ignores the second click of a double click, and matches only `main > .md2-line-gutter > span[data-md2-gutter]`. It posts `{ line }` to `revealSourceLine`.

The coordinator checks the world and the body, as it does for `toggleTask`. A forged span from a page script could only ask to select a line, since the bridge never edits text, and it would still need a real user click.

### Routing: Side by Side selects in place; Read mode opens the editor

**Side by Side.** The editor is already beside the preview. `ContentView` sets `focusedPane = .editor` and publishes `editorLineSelection`. The editor selects the line and scrolls its start into view only when it is off screen. That scroll is programmatic, so it does not drive the preview, which stays where the user clicked.

**Read mode.** The click means "take me to this line in the source", like Cmd+double-click but with a target. `ContentView` delivers a Write-mode anchor on that line (with the usual fraction and heading fallbacks), so the line lands at the top as an outline jump places a heading, and then publishes the selection.

**Write mode.** The preview is not on screen, so there is nothing to route.

*Alternative considered:* switching Read mode to Side by Side so the preview stays visible. Rejected: Cmd+double-click already goes to Write, and the TODO describes opening the line in the editor. A user who wants both panes can be in Side by Side to begin with.

### The editor applies a selection once, after any anchor settles

`LineSelectionRequest` carries a token, so a second click on the same line is a new request. `MarkdownEditorView` takes it as a binding:
- The coordinator applies each token once.
- `updateNSView` clears the binding afterwards, so an editor mounted by a later mode switch does not replay it.
- The request is handled after the jump bindings in `updateNSView`. An anchor that the same pass starts is therefore already settling, and the coordinator holds the selection until the settle's final pass.

Without that hand-off, the selection lands while the freshly mounted editor is still being settled, and the editor does not end up focused with the line selected. The end-to-end test fails when the deferral is removed.

## Verification

- **Headless:** `MarkdownEditorSourceLineRangeTests` covers line breaks, CRLF, bare CR, U+2028, the empty last line, out-of-range lines, and an index inside a CRLF.
- **Editor GUI:** a click, a click beside a wrapped row, Shift-click and drag each select the expected lines, and with numbers hidden nothing is selected.
- **Preview GUI:** a trusted click on a number reaches the coordinator as its line. A page script's synthetic `click()` and a click on the text send nothing. `PreviewSecurityGUITests` asserts the page world cannot see `revealSourceLine`.
- **End to end** through `ContentView`, in Read and in Side by Side: clicking line 5's number leaves the editor mounted and focused, with line 5 selected and on screen. Side by Side keeps the preview.
- **Mutation checks:** each of these fails its test:
  - turning the editor gutter handling off
  - ignoring the number preference
  - accepting untrusted clicks
  - removing the spans' pointer events
  - skipping the settle deferral
- **Full lanes:** the full GUI lane passes locally, with the skip check, as do the non-GUI suite and `openspec validate --strict`.

## Risks / Trade-offs

- **A click in Read mode leaves the preview.** It is the same destination as Cmd+double-click, and the numbers are opt-in and small targets in the margin.
- **The editor gutter keeps the I-beam cursor.** `NSTextView` resets its cursor rects; a pointer cursor there is a possible follow-up.
- **No keyboard equivalent.** The gutter layer stays `aria-hidden`, so this adds no accessibility surface; clicking a number is a mouse convenience.
