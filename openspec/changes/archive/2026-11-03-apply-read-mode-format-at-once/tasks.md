## 1. Formatting from Read mode

- [x] 1.1 Add `MarkdownEditorSession.applyFormatWhileUnmounted`: bring the kept text view up to the document's text if they differ, then run the format through `performMarkdownAction`.
- [x] 1.2 In Read mode, have `DocumentStore.requestFormat` apply the format through it and then request Write, instead of publishing `formatCommand` for the mounted editor.

## 2. Tests

- [x] 2.1 `testFormattingFromReadModeSwitchesToEditorWithoutReplayingInFindFields`: check that the format is in the document before the editor has a window, and that the mounted editor does not apply it again.
- [x] 2.2 `testFormattingFromReadModeSurvivesAnEditorFocusedAfterItMounts`: hold the keyboard until the editor has mounted, then focus it, and check that the format is there once and undoes.
- [x] 2.3 Headless `DocumentUndoHistoryTests`: a format sent with no editor mounted formats the kept selection and undoes, and it follows a document that changed without the text view.
- [x] 2.4 Confirm both GUI tests fail with the old code, and that the resync test fails without the resync.

## 3. Verification

- [x] 3.1 Run `openspec validate apply-read-mode-format-at-once --strict`.
- [x] 3.2 Run `MD2_RUN_GUI_TESTS=1 swift test --filter MarkdownEditingGUITests --filter UndoHistoryGUITests`.
- [x] 3.3 Run the three non-GUI CI steps and the whole GUI lane locally (`MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing`); only the unrelated macOS 27.2 PDF-outline test fails.
