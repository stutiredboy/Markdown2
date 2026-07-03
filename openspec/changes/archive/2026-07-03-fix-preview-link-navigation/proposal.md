## Why

Clicking a link in the rendered preview navigates the preview `WKWebView` itself: an `https://` link replaces the document with the external website, a relative link to a local file loads that file's raw bytes in the pane, and the user loses the document view (scroll sync, find, task toggles, and mode switching all stop making sense on the foreign page). The preview has no `WKNavigationDelegate` policy handler, so every navigation is allowed. A Markdown reader must treat the preview as a viewport onto the document, never as a general-purpose browser.

## What Changes

- Add a navigation policy to the preview web view so the document page itself is never navigated away by a link click.
- External links (`http`/`https`, `mailto`, and other non-file schemes) open in the user's default browser/handler via `NSWorkspace`; the preview stays on the document.
- Same-document fragment links (`#heading`, footnote references/back-references, cross-references, `[TOC]` entries) keep scrolling in-page as they do today.
- Relative or absolute links to local Markdown files (`.md`, `.markdown`) open in Markdown2 through the existing open-in-window path (reusing an already-open window when the file is open).
- Links to other local files open with the system default application instead of rendering raw bytes in the pane.
- Requests for a new web view (`target="_blank"`, Cmd+click) route through the same policy instead of being silently dropped or hijacking the pane.
- Programmatic loads owned by the app (the rendered preview file, `loadHTMLString` fallback, live content swaps) remain allowed, so rendering behavior is unchanged.
- Back/forward swipe gestures are disabled on the preview, since the document page no longer accumulates navigation history.

## Capabilities

### New Capabilities
- `preview-link-handling`: How link activations inside the rendered preview are routed — in-page fragments, external browser handoff, local Markdown opened in the app, other local files opened with the system default — while the preview itself never leaves the document.

### Modified Capabilities

## Impact

- `Sources/MD2App/MarkdownPreviewView.swift`: `Coordinator` gains `decidePolicyFor navigationAction` (and `createWebViewWith`); `allowsBackForwardNavigationGestures` turned off.
- `Sources/MD2App/MD2AppDelegate.swift`: exposes the existing open-file-in-window path so the preview can request opening a linked Markdown file.
- Tests: link-classification logic (app-owned load vs. fragment vs. external vs. local Markdown vs. other local file) is factored into a pure, testable helper with unit coverage in `Tests/MD2CoreTests` or an app-level test target as appropriate.
