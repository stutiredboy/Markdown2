## 1. Fix

- [x] 1.1 Vendor Mermaid 10.9.8, check it against jsDelivr's published SHA-256, and update `VERSIONS.md`.
- [x] 1.2 Initialize Mermaid with `securityLevel: "strict"`.

## 2. Tests

- [x] 2.1 Add `MermaidLabelSecurityGUITests`: label markup, `click` and `link` targets, directives, on the preview, the PDF page and an exported-file page.
- [x] 2.2 Add a control showing each surface detects a handler that runs.
- [x] 2.3 Pin what must keep working: line breaks, inline formatting, `$$` math, `https` links.
- [x] 2.4 Pin the stated limit: an image in a label stays in the page.
- [x] 2.5 Add a plain `swift test` check of the level in the bootstrap.
- [x] 2.6 Confirm the suite fails with neither change, with only the bundle, and with only the level.

## 3. Docs

- [x] 3.1 Write the findings in `Docs/Mermaid-Label-Findings-2026-11-04.md` and link them from the audit.
- [x] 3.2 Update `Docs/MarkdownSupport.md`, the compatibility matrix, `Docs/WebDocumentLoading.md` and `CLAUDE.md`.

## 4. Verification

- [x] 4.1 Run `swift test` and the GUI suites, including `MermaidOffscreenRenderingTests` and `PDFExportEndToEndVerification`.
- [x] 4.2 Open a document in a packaged app and compare requests before and after.
