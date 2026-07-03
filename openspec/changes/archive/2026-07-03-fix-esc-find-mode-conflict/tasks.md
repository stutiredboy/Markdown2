## 1. Routing Rule

- [x] 1.1 Add a pure Esc-routing helper (find visible → dismiss; else single-pane write → mode switch; else none) with unit tests for write/read/split × find-visible/hidden.
- [x] 1.2 Route the editor pane's Esc callback in `ContentView` through the helper: dismiss editor find with refocus when visible, otherwise keep the existing single-pane mode switch.

## 2. Preview Esc Hook

- [x] 2.1 Surface Esc from `PreviewWebView` (`cancelOperation` plus `performKeyEquivalent` fallback) through the find-action callback path.
- [x] 2.2 Dismiss the preview find bar with refocus when visible; ignore Esc otherwise.

## 3. Verification

- [x] 3.1 Run `swift test` and build the app.
- [x] 3.2 Manual pass: in edit mode open find, click into the text, Esc closes the bar and stays in edit; second Esc switches to preview; in read mode open find, click the page, Esc closes the bar; split mode Esc still never switches modes.
