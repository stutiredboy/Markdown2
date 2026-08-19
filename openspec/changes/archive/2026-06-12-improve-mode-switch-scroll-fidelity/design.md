## Context

The archived `sync-position-on-mode-switch` change solved the most visible failure mode: switching no longer always resets to the top. It did so by mapping the editor's top visible line to the nearest preceding heading, and by mapping the preview's current heading back to the heading source line.

That behavior is too coarse for real documents. In `/Users/user/Downloads/example-document.md`, long sections contain paragraphs, lists, and code fences spanning many lines between headings. Testing `/Applications/Markdown2.app` showed that a mid-section Write→Read switch loads the preview with a heading fragment such as `#section-4-example-heading`, even when the editor viewport is already down in body content. The user avoids a top reset, but still loses the local paragraph. A fast Read→Write return can also expose transient invalid editor geometry (`AXVisibleCharacterRange` empty while the scroll bar is at an extreme), which feels like a jump or blank settle.

The renderer is a hand-written block walker. Most block render methods already know their `startIndex`, so the implementation can attach source-line metadata during rendering instead of introducing a separate Markdown parser or external dependency.

## Goals / Non-Goals

**Goals:**
- Preserve the user's local viewport context across Write↔Read switches in long documents.
- Prefer block/source-line anchors over section headings.
- Keep heading anchors and proportional scroll fractions as fallbacks.
- Avoid stale anchors when the user switches immediately after scrolling.
- Clamp all destination scroll offsets and avoid empty/invalid visible ranges after settling.
- Keep the mapping testable in `MD2Core` where possible.

**Non-Goals:**
- Pixel-perfect equivalence between TextKit and WebKit layout.
- Live bidirectional scroll sync while both surfaces are visible.
- Preserving horizontal scroll, text selection column, or caret column.
- Replacing the Markdown renderer or adding an external Markdown source-map dependency.

## Decisions

### Decision 1: Emit source-line metadata on top-level rendered blocks

Add source metadata to rendered block-level elements, for example `data-md2-source-line` and `data-md2-source-end-line`. Headings, paragraphs, lists, code fences, indented code, blockquotes, tables, display math, diagram blocks, horizontal rules, and footnotes should carry the source line span that produced them when that span is known.

Rationale: the renderer already has `startIndex` and `nextIndex` for these blocks. This gives WebKit a DOM coordinate that can map back to the editor without relying on headings. Alternative considered: generate a full character-level source map. That would be more exact, but far more complex and unnecessary for preserving viewport context.

### Decision 2: Represent anchors as viewport-context anchors

Replace the effective mode-switch payload with a richer value such as:

```
struct ViewportAnchor {
    var sourceLine: Int?
    var sourceEndLine: Int?
    var intraBlockProgress: Double
    var viewportTopInset: Double
    var scrollFraction: Double
    var fallbackHeadingID: String?
}
```

The exact type name can vary, but it should carry a source line/span, a progress value inside the rendered/editor block, and the proportional fallback. Heading id remains a compatibility fallback, not the primary target.

Rationale: a paragraph, list, or code fence can be much closer to the user's actual location than the section heading. The intra-block progress helps with long code fences and long list blocks where the block start alone can still be too coarse.

### Decision 3: Capture the outgoing anchor on demand

For Write→Read, the editor can synchronously compute the top visible source line from the live `NSTextView`/`NSScrollView` at the moment `requestMode(.read)` is invoked. It should not depend only on the last cached scroll callback.

For Read→Write, the preview should keep a debounced cached anchor during scrolls, but `requestMode(.write)` should ask the live `WKWebView` for a fresh anchor and switch once that JavaScript returns. If the JavaScript call times out or fails, use the latest cached anchor.

Rationale: cached anchors are vulnerable to fast scroll-then-switch behavior and to programmatic scroll suppression. A short async capture before leaving preview is preferable to landing in the wrong section.

### Decision 4: Capture the preview block nearest the viewport top

Preview JavaScript should inspect elements with `data-md2-source-line`, find the element intersecting a small top capture band, and return its line span, intra-block progress, and scroll fraction. Headings are included because they also carry source metadata, but they no longer override a paragraph or code block that is actually at the viewport top.

Rationale: the current "heading within 25% of viewport" zone can select a heading that is not the content the user is reading, especially near section boundaries. A top-band block hit test matches the user's visible context more directly.

### Decision 5: Apply anchors after layout is measurable, then settle once

The editor should force TextKit layout, compute the target source line from the anchor span/progress, scroll to a clamped offset, and then report the final anchor after the next layout pass. The preview should apply the anchor after page load, keep the target pinned only while content above it reflows, and stop if the user scrolls.

Rationale: both TextKit and WebKit can briefly report incomplete geometry. A bounded settling pass prevents the "blank/overscrolled" feel without fighting user input.

## Risks / Trade-offs

- Source-line spans for complex nested content may be approximate -> prefer the containing block span and fall back to the start line when exact child spans are not available.
- Adding data attributes changes generated HTML -> use app-specific `data-md2-*` attributes and keep visual/semantic rendering unchanged.
- Preview capture is asynchronous -> impose a short timeout and use the cached anchor if JavaScript fails.
- WebKit content can reflow after math/diagram rendering -> keep the existing reflow pinning approach, but pin to the block/source-line target rather than only headings.
- Top-band block capture may select a large containing element -> prefer the deepest/topmost source-line element that intersects the capture band, then fall back to its parent.

## Migration Plan

No data migration is required. The change is local to rendering and view coordination. Existing heading-based behavior remains as fallback, so rollback is simply reverting to the current `ModeSwitchAnchor` and jump binding paths.

## Open Questions

- Should source metadata be emitted only in app preview HTML, or also in exported/copyable HTML if export is added later? For now, the renderer only produces app preview HTML.
- What top capture band feels best: a fixed 48-80 px band, a fraction of the viewport, or the editor text inset? This should be tuned during implementation with the supplied audit document.
