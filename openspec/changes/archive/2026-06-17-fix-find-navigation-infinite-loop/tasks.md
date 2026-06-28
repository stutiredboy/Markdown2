## 1. Editor surface (MarkdownEditorView)

- [x] 1.1 Add `lastFindNavigationToken` and `lastReplaceCommandToken` fields to the editor `Coordinator`
- [x] 1.2 In `updateNSView`, consume `findNavigation` only when its `token` differs from `lastFindNavigationToken`; remove the inline `self.findNavigation = nil`
- [x] 1.3 In `updateNSView`, consume `replaceCommand` only when its `token` differs from `lastReplaceCommandToken`; remove the inline `self.replaceCommand = nil`

## 2. Preview surface (MarkdownPreviewView)

- [x] 2.1 Add `lastFindNavigationToken` to the preview `Coordinator`
- [x] 2.2 In `updateNSView`, consume `findNavigation` only when its `token` differs from `lastFindNavigationToken`; remove the inline `self.findNavigation = nil`

## 3. Verification

- [x] 3.1 `swift build -c release` and `swift test` pass (151 tests)
- [x] 3.2 Reproduce-then-confirm in the packaged app, read mode: open find, type a query, invoke Find Next ×3 → exactly 3 navigations, process CPU returns to idle (was pinned)
- [x] 3.3 Same confirmation in edit mode: Find Next ×3 → exactly 3 navigations, CPU idle
- [x] 3.4 Confirm find still works as specified: matches highlight, status updates, wrap-around intact
