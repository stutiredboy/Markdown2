## Why

HTML export can leave a file that is not self-contained and say nothing about it. Exporting a saved document with `![remote](https://example.com/r.png)` and `![missing](missing.png)` succeeds, keeps both `src` values, and shows no alert. The user gets a file that needs the network or shows a broken image, and has no way to know without opening it somewhere else. This is audit finding F08 in `Docs/Review-2026-10-15.md`.

Keeping remote URLs is intended: `html-export` requires it, and `SelfContainedHTMLExportTests` pins it. The problem is the silence and the overclaim. `README.md` and `README.zh-CN.md` say images are all inlined and the file opens offline. The spec requires both "opens with no external files and no network access" and "remote images stay URLs", and it says nothing about a missing local file.

## What Changes

- **The builder reports what it left out.** `SelfContainedHTMLBuilder.build` returns an `Output`: the HTML, plus the remote images and the local images it could not embed, in document order, each listed once. `data:` URIs and empty sources do not count.
- **The builder reads only `<main>`.** Its regex also ran over the inlined engines. KaTeX, which is in every export, contains an `<img src=` string literal, so a report built on the old scan would have warned about a nonexistent image on every export.
- **`DocumentStore.exportHTML()` shows one notice.** It still writes the file, then shows one localized `DocumentAlert` listing the images that are not embedded: at most five names per group, then a count of the rest. No notice when everything is embedded. A failed write shows the existing failure alert instead.
- **The claims match.** `README.md`, `README.zh-CN.md`, `Docs/MarkdownSupport.md` and the compatibility matrix say what is embedded and what is not. The `html-export` spec no longer contradicts itself.
- **Tests:** the report (remote, missing, unresolved with no base URL, inlined, `data:`), and `DocumentStore` with an injected `htmlDestinationPicker` (notice, no notice, cap, failed write, Chinese copy).

**Non-goals:**

- No fetching of remote images at export time. The app is offline-first and makes no network requests of its own, and fetching would add a new network behavior with its own failure modes. If it is wanted later, it should be a separate opt-in export mode.
- No export mode split ("self-contained" and "keep links"). The audit offers that or a clear notice; this change takes the notice.
- No detection of images that a diagram's own source loads, such as an `<img>` in a Mermaid label. The spec and docs state this limit, and the design explains it.
- No change to PDF export or Print.
- No change to which sources are inlined, or to the exported HTML of any document. Only the reporting is new.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `html-export`: states what the file embeds and what it can leave outside, covers a local image that cannot be embedded, and requires a notice listing every image that is not in the file.

## Impact

- `Sources/MD2App/SelfContainedHTMLBuilder.swift`: new `Output`, `build` returns it, scan limited to `<main>`.
- `Sources/MD2App/DocumentStore.swift`: `exportHTML`, new `htmlExportNotice`.
- `Sources/MD2App/AppSettings.swift`: four new alert strings, English and Simplified Chinese.
- `Tests/MD2CoreTests/SelfContainedHTMLExportTests.swift`, `LineNumberExportIsolationTests.swift`, `MarkdownFileDecoderTests.swift`.
- `README.md`, `README.zh-CN.md`, `Docs/MarkdownSupport.md`, `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`, and the generated `Docs/CompatibilityMatrix.md`.
