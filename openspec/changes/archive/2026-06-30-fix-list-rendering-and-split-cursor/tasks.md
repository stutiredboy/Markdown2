## 1. Reproduction and Coverage

- [x] 1.1 Render the reported monthly-report document and identify all nested ordered/unordered/task-list shapes affected by indentation handling.
- [x] 1.2 Add renderer regression tests for two-space unordered child lists, ordered marker content-column nesting, mixed ordered/unordered nesting, and nested task-list indentation.
- [x] 1.3 Add split coordination regression coverage for edit-window suppression so preview layout anchors cannot drive editor scrolling during typing.

## 2. List Rendering Fix

- [x] 2.1 Replace the fixed three-column nesting heuristic with parent content-column based nesting.
- [x] 2.2 Preserve loose-list, continuation block, indented-code, source-line, and task-checkbox behavior under the new nesting algorithm.
- [x] 2.3 Update preview CSS so nested regular and task lists retain visible indentation.

## 3. Side by Side Cursor Stability Fix

- [x] 3.1 Audit live preview update, full reload, and scroll-sync paths for editor-moving feedback during active typing.
- [x] 3.2 Prevent edit-triggered preview anchors/reloads from scrolling the editor or stealing focus/selection.
- [x] 3.3 Remove noisy split-scroll debug logging from production paths.

## 4. Verification

- [x] 4.1 Run targeted Swift tests for renderer, split coordination, and document store behavior.
- [x] 4.2 Build the SwiftPM app successfully.
- [x] 4.3 Render the provided monthly-report document and verify nested list indentation; verify Side by Side typing stability through split sync tests and attempted GUI smoke checks.
