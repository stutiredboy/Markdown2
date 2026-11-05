## 1. What each engine can do

- [x] 1.1 Render every link form of `flow`, `sequence` and Mermaid at `strict` in the real preview, click each, and record what reaches the system.
- [x] 1.2 Check that a Markdown link, reference, autolink or raw `<a>` leaves no link for a refused scheme.
- [x] 1.3 Check what the rule would take from `preview-link-handling`, including with a real click on a local link.

## 2. The rule

- [x] 2.1 Add `HTMLSafety.safeURLSchemes`, and have `isSafeURL` read it.
- [x] 2.2 Make `PreviewLinkRouter` ignore every scheme outside that list, and drop the checks the default now covers.
- [x] 2.3 Route both system opens through `MarkdownPreviewView.onOpenWithSystem`.

## 3. Tests

- [x] 3.1 Add allowed and refused schemes to `PreviewLinkRouterTests`, each checked against `isSafeURL` too.
- [x] 3.2 Move the real click into `RenderedPageSurfaces.swift`, and give `withPage` a recorder for system opens.
- [x] 3.3 Add `PreviewLinkSchemeGUITests`: `flow` in the same and a new window, odd spellings, Mermaid `click`, `link` and label links, and allowed links as the control.
- [x] 3.4 Confirm the router and GUI tests fail with the rule removed.

## 4. Docs

- [x] 4.1 Update `CLAUDE.md`, `Docs/WebDocumentLoading.md`, `Docs/MarkdownSupport.md` and the compatibility matrix.

## 5. Verification

- [x] 5.1 Run `swift test` and the GUI suites.
