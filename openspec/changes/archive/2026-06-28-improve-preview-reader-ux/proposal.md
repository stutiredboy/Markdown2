## Why

Manual testing of `/Applications/Markdown2.app` shows the core Markdown rendering path is strong, but several reader-facing workflows are still easy to misinterpret or hard to discover. This change improves the preview and navigation experience without expanding export formats.

## What Changes

- Clarify preview diagnostics for image load failures so remote-image failures are not presented as missing local files.
- Hide YAML front matter from live reading surfaces by default while preserving an explicit way to inspect it; exported PDF/HTML output keeps existing shared-renderer semantics.
- Improve toolbar discoverability for Open, Save, Outline, and mode switching without weakening the compact macOS layout.
- Make outline navigation robust for mouse, keyboard, and assistive technologies.
- Improve Side by Side layout when the outline is visible so editor and preview panes remain usable.
- Non-goal: DOCX/EPUB export is intentionally out of scope for this change.

## Capabilities

### New Capabilities
- `reader-front-matter-presentation`: Controls how YAML front matter is presented in rendered reading views.
- `document-toolbar-discoverability`: Defines discoverability requirements for primary document toolbar actions and mode switching.
- `document-outline-navigation`: Defines outline navigation interaction, keyboard support, selection, and accessibility requirements.

### Modified Capabilities
- `image-attachment-management`: Clarify broken-image diagnostics so local missing files and remote load failures communicate different causes.
- `preview-layout`: Improve Side by Side and outline-visible layout behavior so both panes remain readable and usable.

## Impact

- Affected app UI: `ContentView`, `OutlineSidebar`, toolbar items, and Side by Side layout.
- Affected preview code: `MarkdownPreviewView` and preview JavaScript for front matter visibility and broken-image placeholders.
- Affected tests: renderer/front matter tests, image diagnostic tests, outline interaction/accessibility tests, and split layout tests.
- No new third-party dependencies are expected.
- Shared renderer output, PDF export, self-contained HTML export, and DOCX/EPUB conversion behavior remain unchanged and out of scope.
