## Why

Mermaid source could run script in Markdown2. `MarkdownRenderer` initialized Mermaid with `securityLevel: "loose"` and vendored Mermaid 10.9.1, so diagram source reached the page outside `HTMLSafety.sanitizeTag`, the F01 boundary for author HTML.

Tested in the real preview, in PDF export, in exported HTML (WebKit and Chromium), and in a packaged app:

- A `$$…$$` sequence label holding an event attribute ran as soon as the page was displayed, at `loose`, `antiscript` and `strict` alike. This is CVE-2025-54881, fixed in 10.9.4.
- A state diagram `classDef` holding the same attribute also ran with no click at `loose`.
- A `javascript:` target in a flowchart or class diagram `click`/`link` ran when clicked at `loose`.

The script could read the rendered document and send it out through an image or `fetch`. A scripted `a.click()` on an external URL reached the navigation policy as `linkActivated`, the type that hands a URL to `NSWorkspace`. The native task and edit bridges stayed out of reach. `Docs/Mermaid-Label-Findings-2026-11-04.md` has the evidence.

## What Changes

- **Bundle:** vendor Mermaid 10.9.8, the latest 10.9 patch release, in place of 10.9.1. Same major and minor line, verified against jsDelivr's published SHA-256.
- **Level:** initialize Mermaid with `securityLevel: "strict"`. The finished SVG then passes through the engine's sanitizer, `click` callbacks stay off, and `javascript:` targets are neutralized. A diagram cannot lower the level from its own source.
- **Behavior change:** a sequence actor's `link`/`links` menu no longer opens, because Mermaid opens it with an inline `onclick`. A `click` target of `_blank` loses its `target`; the preview already sends every external link to the default browser.
- **Stated limit:** a remote image or CSS `url()` in diagram source still loads when the diagram is shown, like a Markdown image. The spec now says so.
- **Tests:** `MermaidLabelSecurityGUITests` runs each payload on the real preview, the page PDF export renders, and an exported-file page. It also pins what must keep working and the stated limit.

**Non-goals:**

- No tag allowlist for labels. It would remove `<img>` from labels without closing the limit, because diagram CSS reaches the network the same way. The design explains this.
- No Content-Security-Policy on rendered pages. It would add a second layer that does not depend on any engine, and it is a separate change.
- No fix for the `flow` engine, whose `javascript:` link still runs on click. Mermaid's security level does not apply to it. It belongs with the policy above.
- No move to Mermaid 11, which is a larger upgrade with its own rendering changes.
- No change to Markdown images or to what HTML export embeds or reports.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `diagram-rendering`: requires that Mermaid source cannot run script, and states that a remote resource named in diagram source loads when the diagram is shown.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `mermaid.initialize` in the diagram bootstrap.
- `Sources/MD2Core/Resources/diagrams/mermaid.min.js`, `VERSIONS.md`.
- `Tests/MD2CoreTests/MermaidLabelSecurityGUITests.swift` (new), `DiagramRenderingTests.swift`.
- `Docs/Mermaid-Label-Findings-2026-11-04.md` (new), `Docs/Review-2026-10-15.md`, `Docs/MarkdownSupport.md`, `Docs/WebDocumentLoading.md`, `CLAUDE.md`, `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`, and the generated `Docs/CompatibilityMatrix.md`.
