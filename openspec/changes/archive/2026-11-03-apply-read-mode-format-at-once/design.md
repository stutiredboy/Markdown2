## Context

A document owns one `MarkdownEditorSession`, and with it one source text view for its whole life. Write and Side by Side re-host that text view, and Read mode leaves it unhosted. It keeps its text, its selection and its undo actions while unhosted, and the session hands its text changes to the document, which is how undo and preview task toggles work in Read mode.

Format commands come from the Format and Paragraph menus through `DocumentStore.requestFormat`. With the editor mounted, the command is published as `formatCommand`. The editor applies it on the next run-loop turn if its text view is first responder, so a command sent while a find field has the keyboard does nothing. In Read mode the command was published the same way, and the store switched to Write for the editor to apply it.

## Decisions

### Apply a Read-mode format to the kept text view before switching

The editor that mounts for the switch got its window and its focus on a later run-loop turn than the one that checked for focus, at least on a loaded CI runner. Its one check then failed, and because it had already marked the command consumed, the format was lost for good. Locally the editor has its window and focus on the first turn, which is why the test passed here.

`requestFormat` now calls `MarkdownEditorSession.applyFormatWhileUnmounted` in Read mode and then requests Write. That method runs `MarkdownSourceTextView.performMarkdownAction` on the kept text view. The result does not depend on when the editor gets its window or focus, because the edit is done before the editor is mounted. It formats the selection the text view kept, as the editor did when the timing went right. The editor that mounts finds its text already up to date, and the command token it last consumed is unchanged, so it applies nothing again.

Before formatting, the method compares the text view's text with the document's, code unit by code unit. When they differ, it calls `resetText(to:)` first, as `makeNSView` does when an editor mounts. Formatting stale text would hand that stale text back to the document over the newer one.

*Alternatives considered:*
- **Keep the command pending until the text view becomes first responder after the mount.** The mount's anchor settle focuses the editor and moves the caret to the anchored line in the same step. Depending on which runs first, a format applied on focus could land on that caret instead of the kept selection. A pending command would also need rules for when it expires, so that focusing the editor long after the switch does not apply it then.
- **Consume the command only once it has been applied.** Any later SwiftUI update would retry it, including the one that follows a click into the editor long after the switch.

### Leave Write and Side by Side alone

A format there still needs the editor to be first responder, checked when it is requested and again when the editor applies it. That is the guard the second half of the existing test checks with a text field.

## Verification

- **The old code fails both GUI tests, 3 of 3 runs:**
  - `testFormattingFromReadModeSurvivesAnEditorFocusedAfterItMounts` ends with `"text"` instead of `"**text**"`, the loss CI saw.
  - `testFormattingFromReadModeSwitchesToEditorWithoutReplayingInFindFields` does not find the format before the editor has a window.
- **With the fix, both pass, 5 of 5 runs.**
- **Mutation:** dropping the resync from `applyFormatWhileUnmounted` fails `formatWithNoEditorMountedFollowsADocumentChangedWithoutTheTextView`, which finds `"**text**"` instead of `"more **text**"`.
- **Suites:** `MarkdownEditingGUITests`, `UndoHistoryGUITests` and the three non-GUI CI steps pass locally. The whole GUI lane passes locally too, except `PDFExportEndToEndVerification.testRealExportProducesValidMultiPagePDF`, which finds no outline in the exported PDF. That is a macOS 27.2 PDFKit behavior unrelated to this change, fixed separately in `write-pdf-outline-with-coregraphics`; CI's macOS 15 runner is not affected.
- **Unreproduced locally:** the exact order on the CI runner. Under CPU load locally, the editor always had its window and focus on the first turn. The test that holds the keyboard forces the order that fails, so it does not depend on runner timing.

## Risks / Trade-offs

- **The document changes while Read mode is still showing.** The preview may start re-rendering for the moment before the switch. The switch's anchor capture is sent to the page in the same update that starts the switch, before a re-render, which is debounced by 120 ms, can reach the page. If the capture does not answer, the switch falls back to the cached anchor, as it does on a timeout today.
- **The test's undo grouping.** `resetText(to:)` clears the undo history, and with it any undo group a test opened by hand. The app groups undo by event and opens a new group when the format registers its undo action. The headless test for the resync path therefore keeps the default grouping.
