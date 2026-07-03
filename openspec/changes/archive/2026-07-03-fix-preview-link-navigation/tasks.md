## 1. Link Routing Core

- [x] 1.1 Add a pure `PreviewLinkRouter` that classifies a navigation target against the app-owned page URL into `allowInPage` (app-owned load or same-page fragment), `openExternal`, `openMarkdownDocument`, or `openWithSystem`, handling `loadFileRequest` and `loadHTMLString` base modes, percent-encoding/standardized-path variants, and unresolvable relative targets.
- [x] 1.2 Add unit tests covering: external schemes (`https`, `mailto`), same-file fragment vs. different file, preview temp-file URL with fragment/query/encoding variants, `.md`/`.markdown`/`.MD` extensions, non-Markdown local files, and untitled-document (nil base) relative links.

## 2. Preview Wiring

- [x] 2.1 Implement `webView(_:decidePolicyFor:decisionHandler:)` in the preview `Coordinator`: allow app-owned/in-page navigations, cancel and route everything else through `PreviewLinkRouter`.
- [x] 2.2 Implement `webView(_:createWebViewFor:...)` (WKUIDelegate) to return `nil` and route the request through the same router so `target="_blank"`/Cmd+click behave like plain clicks.
- [x] 2.3 Dispatch routed results: `openExternal`/`openWithSystem` via `NSWorkspace`, `openMarkdownDocument` via a new `onOpenMarkdownLink` callback on `MarkdownPreviewView`.
- [x] 2.4 Wire `onOpenMarkdownLink` through `ContentView` to the app delegate's open-in-window path (front existing window, reuse starter window, else new window); expose that path from `MD2AppDelegate`.
- [x] 2.5 Disable `allowsBackForwardNavigationGestures` on the preview web view.

## 3. Verification

- [x] 3.1 Run `swift test` and build the app.
- [x] 3.2 Manual pass with a document containing: an `https://` link, a `mailto:` link, a `[TOC]`/heading anchor, footnote references, a relative `.md` link (closed and already-open target), a relative PDF link, and the same document unsaved (untitled) — verify each routes per spec in Read and Side by Side modes, and that Read-mode edits still reload the preview normally.
