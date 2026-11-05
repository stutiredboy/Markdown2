## Why

Document content could still run script in Markdown2. A `flow` block such as `st=>start: S:>javascript:window.pwned=1` renders a `javascript:` link that runs when clicked, in the preview, in the page PDF export renders, and in an exported HTML file. No engine setting reaches it, and the navigation policy never sees the click, because WebKit runs a `javascript:` URL without asking.

`harden-mermaid-source-boundary` closed every path found in Mermaid, but each engine's own sanitizing was still the only thing between its source and running script. One future sanitizer bug would put script back in the page, and script there is high impact: a scripted `a.click()` reaches the navigation policy as `linkActivated`, which hands external URLs to `NSWorkspace`.

## What Changes

- **Policy:** every page `MarkdownRenderer` produces carries a Content-Security-Policy `<meta>` ahead of everything it governs. `script-src` names only the page's own scripts, each inline script by its SHA-256 hash and each served engine by its exact URL. There is no `'unsafe-inline'` or `'unsafe-eval'` for scripts, so event handlers, `javascript:` URLs, injected `<script>` elements, frames and plugins all run nothing. `default-src` is `'none'`, and `base-uri` and `form-action` are closed too.
- **Router:** `PreviewLinkRouter` ignores a `javascript:` URL. WebKit asks about a new-window request before it applies the policy, so `S:>javascript:…[blank]` reached `NSWorkspace` with the policy in place.
- **Placeholder:** the preview's broken-image listener moves to document start. The policy refuses a missing local image during parsing, so a listener installed at document end never heard of it. It already missed many such images on a first load, because engine scripts hold up document end.
- **Behavior change:** a `<video>` or `<audio>` in a Mermaid label no longer loads. Remote images, including those in labels and CSS, are not affected.
- **Tests:** `ContentSecurityPolicyGUITests` runs on all three surfaces, each with a control showing the surface would notice script that does run. `PageContentSecurityPolicyTests` checks the policy's text in plain `swift test`. `MermaidLabelSecurityGUITests` and `PreviewSecurityGUITests` now remove the policy, so they keep proving the layers under it.

**Non-goals:**

- No change to remote image loads. `img-src` stays open to `http` and `https`, because Markdown images use it. A real offline guarantee is a separate product decision.
- No closing of `style-src`. Mermaid writes a `<style>` into each diagram, so CSS keeps the reach `harden-mermaid-source-boundary` stated as a limit.
- No rewrite of `flow` links in the page. The link stays in the SVG and does nothing.
- No limit on which schemes a `flow` link can name. A click on `ssh://…` still reaches its system handler, and Markdown links cannot do that. It is not script, and it belongs in its own change.

## Capabilities

### New Capabilities

- `page-content-security-policy`: what every rendered page allows to run and load, and what must keep working under it.

### Modified Capabilities

- `preview-link-handling`: a script URL is never handed to a handler.
- `image-attachment-management`: the broken-image placeholder appears on a first load too.
- `diagram-rendering`: a remote image named in diagram source still loads, which is narrower than "a remote resource". The `flow` and `sequence` engines are covered by the page policy.

## Impact

- `Sources/MD2Core/PageContentSecurityPolicy.swift` (new), `MarkdownRenderer.swift`, `BundledWebAsset.swift`.
- `Sources/MD2App/MarkdownPreviewView.swift`, `PreviewLinkRouter.swift`, `LocalImageAccess.swift`.
- `Tests/MD2CoreTests/ContentSecurityPolicyGUITests.swift`, `PageContentSecurityPolicyTests.swift`, `RenderedPageSurfaces.swift` (new), and `MermaidLabelSecurityGUITests.swift`, `PreviewSecurityGUITests.swift`, `IncrementalPreviewGUITests.swift`, `PreviewLinkRouterTests.swift`.
- `CLAUDE.md`, `Docs/WebDocumentLoading.md`, `Docs/Mermaid-Label-Findings-2026-11-04.md`, `Docs/Review-2026-10-15.md`, `Docs/MarkdownSupport.md`, `Sources/MD2Core/Resources/diagrams/VERSIONS.md`, `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`, and the generated `Docs/CompatibilityMatrix.md`.
