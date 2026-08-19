## Why

The existing mode-switch sync prevents a full reset to the top, but real use on `/Users/user/Downloads/example-document.md` still feels disruptive because the viewport snaps to the nearest section heading instead of the paragraph, list item, or code block the user was actually reading or editing. On long sections this can move the user dozens of source lines upward, and quick Read↔Write round trips can leave the editor briefly overscrolled or with no valid visible text range.

## What Changes

- Upgrade mode-switch positioning from heading-granularity anchoring to viewport-context anchoring.
- When switching Write → Read, preserve the source line/block near the top of the editor viewport, not only the preceding heading.
- When switching Read → Write, preserve the rendered block or source line near the top of the preview viewport, not only the current heading.
- Add stable source-line metadata to preview block elements so rendered paragraphs, lists, code fences, tables, blockquotes, math blocks, diagrams, and headings can map back to source.
- Preserve a small top-of-viewport offset when applying the destination scroll so the target content does not land flush against the edge or disappear behind transient layout changes.
- Keep existing heading and proportional fallbacks for cases where block-level source metadata is unavailable.
- Prevent stale cached anchors and invalid destination scroll states during fast switches, immediately after scrolls, and after programmatic mode-switch jumps.

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `mode-switch-scroll-anchoring`: change long-document behavior from section-heading anchoring to viewport-context anchoring with block/source-line fidelity, stale-anchor protection, and clamped settling.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift` — emit source-line metadata on rendered block-level elements while preserving existing HTML semantics.
- `Sources/MD2Core/ModeSwitchAnchor.swift` and/or a new core helper — represent block/source-line anchors, offsets, and fallback resolution in pure testable code.
- `Sources/MD2App/MarkdownEditorView.swift` — capture a fresh editor viewport anchor on demand and after scroll/layout changes; apply line anchors without overscroll.
- `Sources/MD2App/MarkdownPreviewView.swift` — capture the preview block at the viewport top through JavaScript and apply block/line anchors after load and reflow.
- `Sources/MD2App/ContentView.swift` / `DocumentStore.swift` — coordinate mode-switch anchor capture and delivery without relying solely on stale debounced state.
- Tests in `Tests/MD2CoreTests` and focused manual verification with long, sparse-heading, no-heading, and code-heavy documents.
