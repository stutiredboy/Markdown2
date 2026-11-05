## Why

A document can offer the reader a link that hands an arbitrary URL scheme to the system, and it takes one click. `HTMLSafety.isSafeURL` limits Markdown links to `http`, `https`, `mailto` and `file`, but a diagram engine draws its own links, so they never pass it. `st=>start: S:>ssh://example.com` renders a link that `PreviewLinkRouter` returned as `.openExternal`, and `NSWorkspace` started whatever handles the scheme. On the development machine `ssh://` and `x-man-page://` both reach Terminal.

`add-page-content-security-policy` left this out because it is not script. The same gap reaches further than `flow`: at `strict`, a Mermaid link keeps eight schemes a Markdown link cannot use.

## What Changes

- **Router:** `PreviewLinkRouter` hands over only the schemes in `HTMLSafety.safeURLSchemes`. Anything else is `.ignore`, so a click does nothing and opens nothing. This replaces the separate checks for `javascript:` and the app's own schemes, which the default now covers.
- **One list:** `isSafeURL` and the router read the same `safeURLSchemes`, so the two cannot drift apart.
- **Behavior change:** a diagram link to any other scheme stops working, including `tel:`, `ftp:` and an app's own scheme. Markdown links never could.
- **Test seam:** `MarkdownPreviewView.onOpenWithSystem` replaces the direct `NSWorkspace` calls, so a test can click a real link without starting a handler.
- **Tests:** `PreviewLinkSchemeGUITests` clicks real `flow` and Mermaid links in the preview. `PreviewLinkRouterTests` covers allowed and refused schemes in plain `swift test`.

**Non-goals:**

- No change to what a Markdown link may use.
- No rewrite of diagram links in the page. The link stays in the SVG and does nothing, and an exported file keeps it, for whatever opens that file to handle.
- No limit on which files a `file:` link may open.
- No fix for local links, which do not reach the router today. See `design.md`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `preview-link-handling`: a link reaches a handler only if a Markdown link could use its scheme. External links are `http`, `https` and `mailto`, not "any other external scheme".

## Impact

- `Sources/MD2App/PreviewLinkRouter.swift`, `MarkdownPreviewView.swift`, `Sources/MD2Core/HTMLSafety.swift`.
- `Tests/MD2CoreTests/PreviewLinkSchemeGUITests.swift` (new), `PreviewLinkRouterTests.swift`, `RenderedPageSurfaces.swift`, `ContentSecurityPolicyGUITests.swift`.
- `CLAUDE.md`, `Docs/WebDocumentLoading.md`, `Docs/MarkdownSupport.md`, `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`, and the generated `Docs/CompatibilityMatrix.md`.
