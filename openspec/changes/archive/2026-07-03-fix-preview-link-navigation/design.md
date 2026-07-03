## Context

The preview loads the rendered document either via `loadFileRequest` (a `.md2-preview-<id>.html` temp file written next to the document, with read access granted to the document directory) or via `loadHTMLString` (untitled documents). The renderer emits plain `<a href="...">` anchors: absolute external URLs, in-page fragments (`#slug` headings, footnotes, cross-references), and author-written relative paths (`other.md`, `assets/file.pdf`). The `Coordinator` is already the `WKNavigationDelegate` but implements only `didFinish`/`didCommit`, so WebKit's default policy (allow) applies to every user click. `allowsBackForwardNavigationGestures` is `true`, which lets a swipe re-navigate between the document and any page the user wandered to.

Side by Side live updates swap `<main>` content via JavaScript (no navigation), while Read-mode edits and document switches reload the preview file — both are app-owned navigations the policy must keep allowing.

## Goals / Non-Goals

**Goals:**
- The preview never displays anything other than the current document's rendered page.
- External links reach the user's default browser/handler; local Markdown links open in Markdown2; other local files open with their default app.
- In-page fragment navigation (headings, footnotes, cross-references, TOC) keeps working exactly as today, including the initial load that carries a `#fragment` for early positioning.
- Link classification is a pure function with unit tests; the delegate method stays a thin adapter.

**Non-Goals:**
- No link preview/tooltips, no context-menu customization ("Open Link in Browser" etc. beyond what WebKit provides).
- No handling of links inside exported HTML/PDF output (those open in the user's browser/PDF viewer, out of app control by design).
- No change to how images/resources load (scheme handler and file access model stay as-is).

## Decisions

- **Classify by comparing the navigation target against the app-owned page, not by `navigationType`.** `decidePolicyFor` allows a navigation when (a) it is not a link activation (the initial/reload loads, including `loadHTMLString`'s `about:blank` base), or (b) it targets the currently loaded preview file URL itself and differs at most in fragment (in-page anchor). Everything else is cancelled and dispatched. Rationale: `navigationType == .linkActivated` alone misses `window.open`/JS-driven navigations, while URL comparison is robust for both `loadFileRequest` and `loadHTMLString` modes. Alternative considered: intercepting clicks in JavaScript — rejected because it duplicates policy in two runtimes and misses non-click navigations.
- **Fragment navigation stays native.** Same-file-different-fragment navigations are allowed (WebKit scrolls without a reload), preserving the existing early-positioning trick where the preview file is loaded with `#fragment`.
- **Route cancelled navigations by resolved URL.** A pure helper `PreviewLinkRouter.route(for:documentPageURL:)` returns one of: `.allowInPage`, `.openExternal(URL)`, `.openMarkdownDocument(URL)`, `.openWithSystem(URL)`. File URLs whose path extension is `md`/`markdown` (case-insensitive) map to `.openMarkdownDocument`; other file URLs to `.openWithSystem`; every non-file scheme to `.openExternal`. The helper lives next to the preview code but has no WebKit dependency so it is unit-testable.
- **Open Markdown links through the app delegate's existing window path.** `MarkdownPreviewView` gains an `onOpenMarkdownLink: (URL) -> Void` callback wired by `ContentView` up to `MD2AppDelegate.openInNewWindow(_:)` (made internal). This reuses dedupe (already-open window comes to front) and starter-window reuse. Alternative considered: `NSWorkspace.open` with own-bundle preference — rejected: spawns a second app instance under `swift run`, and skips window dedupe.
- **`createWebViewWith` returns `nil` and routes the request through the same router**, so `target="_blank"` and Cmd+click behave like plain clicks instead of silently doing nothing.
- **Disable back/forward swipe gestures.** With the policy in place the page has no history to traverse; leaving gestures enabled would only re-expose edge cases. Relative non-file bases (`loadHTMLString(_, baseURL: nil)`) resolve relative hrefs to `about:blank`-relative URLs that cannot be meaningfully opened; those navigations are cancelled and ignored (no beep, no crash).
- **Relative links from untitled documents degrade gracefully.** With no `baseURL`, a relative `other.md` cannot resolve to a file; the router treats an unresolvable target as `.allowInPage`-cancel (ignore). This mirrors how relative images already degrade for untitled documents.

## Risks / Trade-offs

- [WebKit may report the preview temp-file URL with percent-encoding differences] → compare via `URL.standardizedFileURL.path` plus fragment stripping, covered by unit tests with fragment/query/encoding variants.
- [Opening arbitrary local files with the default app could surprise users for executable types] → `NSWorkspace.open` uses LaunchServices' normal warnings; we do not add our own execution path. Only files the document author linked are reachable.
- [A malicious document could contain a `file:///…` link to a sensitive path] → opening with the system default app is equivalent to the user double-clicking in Finder and requires an explicit click on a visible link; no read access is granted to the web view beyond what exists today.
- [Cancelling navigations that WebKit initiates for the app's own reload could blank the preview] → every app-initiated load targets the app-owned page (preview temp file or the string-load base), which the policy always allows regardless of navigation type; regression covered by exercising Read-mode edit reload and Side by Side entry in the functional pass. Foreign-target navigations are dispatched to external handlers only for genuine link activations — a script/meta redirect is cancelled without dispatch so a hostile document cannot auto-open a browser.

## Open Questions

- None blocking. If sandboxing is adopted later, `.openWithSystem` for paths outside granted access may need security-scoped bookmarks; out of scope here.
