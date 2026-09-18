## Why

Exporting an **untitled** document (one never saved to disk) to PDF produces a PDF whose local images are all blank. `DocumentStore.baseURL` is `fileURL?.deletingLastPathComponent()`, which is `nil` for an untitled document; `PDFExporter.export` sees that `nil` base and falls through to `loadHTMLString` *without* running `LocalImageHTMLRewriter`, so the app-local image scheme is never wired up and every `<img>` — including absolute-path references to dropped files, which are the supported way to add images to an untitled document — fails to load. A file-backed document with the same images exports correctly, so the defect only shows up for untitled documents, which is exactly the flow the image-drop feature advertises ("a dropped image does not require the document to be saved first").

## What Changes

- Make `PDFExporter.export` always run `LocalImageHTMLRewriter.rewrite` and register the resulting image whitelist with the scheme handler, regardless of whether `baseURL` is `nil`.
- When `baseURL` is `nil`, load the *rewritten* HTML via `loadHTMLString` so absolute-path and `file://` image references resolve through the app-local scheme (which serves them from disk without needing file read access). File-backed documents keep the existing temp-file + `loadFileRequest` path unchanged.
- Add GUI-gated regression coverage that an absolute-path image renders in an exported PDF both with and without a `baseURL`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pdf-export`: add a requirement that resolvable local image references (absolute paths and `file://` URLs) are embedded in the exported PDF even when the document is untitled and has no base directory.

## Impact

- `Sources/MD2App/PDFExporter.swift` — `export` no longer short-circuits image rewriting when `baseURL` is `nil`; it rewrites and registers local images, then loads the rewritten HTML via `loadHTMLString`.
- `Tests/MD2CoreTests/PDFExportEndToEndVerification.swift` — GUI-gated assertions that an absolute-path image appears in the exported PDF both with a `baseURL` and with `baseURL: nil`.
- `DocumentPrinter` reuses `PDFExporter`, so print inherits the fix with no separate change.
- No dependency or vendored-asset changes.
