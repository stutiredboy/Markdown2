## Why

Markdown2 can render existing image links, but creating image-heavy documents still requires users to manually save screenshots or dragged files, choose paths, and type Markdown links. For technical notes, course material, and reports, that missing image workflow breaks the app's Typora-like writing loop even though the preview can already display the final result.

## What Changes

- Add first-class image insertion from the editor surface:
  - Paste a clipboard image (a screenshot) — written into the attachment folder as PNG.
  - Paste or drop image files — linked in place at their existing absolute location, not copied.
- Save pasted clipboard image data into a document-relative attachment directory (default `assets/`) and insert Markdown image syntax with a relative path; link dropped/pasted files using their absolute path so the original file is not duplicated.
- Add a setting for the attachment directory name/path so users can choose a project convention while retaining a sensible default.
- Generate collision-safe filenames for stored clipboard images, and grant the preview read access to local image files referenced by absolute path so they display.
- Support lightweight image size control through Pandoc-style `{width=...}` attributes, extending the renderer's existing URL-inferred dimension and `.image-frame` handling without breaking plain Markdown fallback.
- Surface missing or unreadable local images in the preview as an explicit broken-image placeholder instead of silently showing an empty or confusing result, scoped to the live preview so exported PDFs (which reuse the same rendered HTML) are unaffected.
- Preserve existing rendering behavior for authored image links that are already valid.

## Capabilities

### New Capabilities
- `image-attachment-management`: Editor-driven image paste/drop insertion, automatic attachment storage, relative Markdown insertion, configurable attachment path, image size rendering, and preview diagnostics for missing local image assets.

### Modified Capabilities
<!-- None. Existing Markdown rendering and export behavior should continue to work; this change introduces a new image asset workflow around existing image rendering. -->

## Impact

- **Code**:
  - `Sources/MD2App/MarkdownEditorView.swift` / editor text view integration for paste and drag/drop handling.
  - `Sources/MD2App/DocumentStore.swift` for attachment destination resolution, file copying/writing, Markdown insertion coordination, and unsaved-document behavior.
  - `Sources/MD2App/AppSettings.swift` and `Sources/MD2App/SettingsView.swift` for the configurable attachment directory.
  - `Sources/MD2Core/MarkdownRenderer.swift` for image-size attributes and broken-image markup.
  - `Sources/MD2App/MarkdownPreviewView.swift` if preview-side diagnostics need WebKit coordination.
- **Data / files**: New image files are created beside the Markdown document under the configured attachment directory. Existing Markdown files remain plain text.
- **Docs**: README and `Docs/MarkdownSupport.md` should describe image insertion, attachment path defaults, size syntax, and broken-image behavior, and move image drag/drop insertion, resize, and configurable root out of the "Not Yet Supported" list.
- **Tests**: Unit tests for path generation, Markdown insertion text, renderer output, and broken-image handling; focused AppKit integration tests where feasible.
