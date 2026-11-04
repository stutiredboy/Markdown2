## 1. Document

- [x] 1.1 Add `sourceLineRevision`, bumped by every text change, and `renderedSourceLineRevision`, published with `rendered`.
- [x] 1.2 Replace `toggleTask(atLine:to:)` with `toggleTask(atLine:to:renderedAt:)`: refuse any revision but the current one, and keep the revision across the toggle's own edit.

## 2. Preview

- [x] 2.1 Send `window.__md2SourceLineRevision` from the isolated world with each click, and refuse a message without one.
- [x] 2.2 Label the page after a live update lands, on `didCommit` for the latest navigation (`WebDocumentLoader.currentNavigation`), and when new text renders to the same page.
- [x] 2.3 Add `restoreTaskBoxesScript`, and hand `onToggleTask` a closure that runs it.
- [x] 2.4 Pass the rendered revision from `ContentView`, and restore the boxes on a refusal.

## 3. Tests

- [x] 3.1 Headless `DocumentStoreTests`: the audit's probe, an identical line, deleted and moved tasks, a replaced document, a second click before the re-render, a duplicate click, an undone toggle, the rendered revision trailing the text.
- [x] 3.2 `PreviewTaskToggleGUITests`: stale clicks on a held page in Side by Side and Read mode, a refusal after the update on a kept block, a second click before the re-render, every way the label moves, a superseded commit, a script exception, page script reading and writing the label, a click without a revision, and `ContentView`'s refusal and one undo step.
- [x] 3.3 Keep `PreviewSecurityGUITests`' isolated-world message working with a revision.
- [x] 3.4 Confirm each guard's test fails without the guard.

## 4. Verification

- [x] 4.1 Run `openspec validate refuse-stale-task-toggles --strict`.
- [x] 4.2 Run `swift test`.
- [x] 4.3 Run `MD2_RUN_GUI_TESTS=1 swift test --filter UndoHistoryGUITests --filter IncrementalPreviewGUITests --filter LineNumberGutterGUITests --filter PreviewSecurityGUITests --filter PreviewTaskToggleGUITests`.
- [x] 4.4 Run the whole GUI lane locally (`MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing`).
