## 1. Policy

- [x] 1.1 Add `PageContentSecurityPolicy` and `InlineScript`, and give each asset its inline hash and each asset mode its sources.
- [x] 1.2 Gather a page's scripts before its `<head>`, and put the policy ahead of everything it governs.
- [x] 1.3 Test on real pages whether any engine needs `'unsafe-eval'`, and leave it out.

## 2. Gaps the policy does not close

- [x] 2.1 Make `PreviewLinkRouter` ignore `javascript:`, which reaches it ahead of the policy on a new-window request.
- [x] 2.2 Move the preview's broken-image listener to document start, so it hears images the policy refuses during parsing.

## 3. Tests

- [x] 3.1 Extract the three-surface harness into `RenderedPageSurfaces.swift`, with the exported surface built by the real `SelfContainedHTMLBuilder`.
- [x] 3.2 Add `ContentSecurityPolicyGUITests`: the `flow` link on all three surfaces with real and scripted clicks, injected markup, each with a control that runs without the policy, and what the policy leaves closed.
- [x] 3.3 Cover what must keep working: every engine with `eval` off, user scripts and native calls, print overrides, remote and exported images, first-load placeholders.
- [x] 3.4 Add a live-update test through the real preview, including an edit that adds an engine.
- [x] 3.5 Add `PageContentSecurityPolicyTests` for plain `swift test`, and a router case.
- [x] 3.6 Remove the policy from the pages in `MermaidLabelSecurityGUITests` and `PreviewSecurityGUITests`, so they keep testing the layers under it.
- [x] 3.7 Confirm the tests fail when each part of the policy or the fixes is removed.

## 4. Docs

- [x] 4.1 Update `CLAUDE.md`, `Docs/WebDocumentLoading.md`, `Docs/MarkdownSupport.md`, the compatibility matrix and `VERSIONS.md`.
- [x] 4.2 Record the outcome in `Docs/Mermaid-Label-Findings-2026-11-04.md` and `Docs/Review-2026-10-15.md`.

## 5. Verification

- [x] 5.1 Run `swift test` and the GUI suites in `CLAUDE.md`.
- [x] 5.2 Open an exported file in a second browser engine.
