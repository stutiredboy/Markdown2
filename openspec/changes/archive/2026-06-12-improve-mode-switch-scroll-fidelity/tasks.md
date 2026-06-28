## 1. Core anchor model and renderer metadata

- [x] 1.1 Add a block/source-line viewport anchor model that carries source start line, optional end line, intra-block progress, viewport inset, scroll fraction, and heading fallback.
- [x] 1.2 Add pure helpers for resolving a source line within a block span, clamping intra-block progress, and converting an anchor to a target source line.
- [x] 1.3 Update `MarkdownRenderer` block output to include `data-md2-source-line` and, where known, `data-md2-source-end-line` on headings, paragraphs, lists, code blocks, blockquotes, tables, display math, diagram blocks, horizontal rules, and footnote blocks.
- [x] 1.4 Ensure fenced and indented code block contents are not interpreted as heading/source anchors beyond the containing code block metadata.
- [x] 1.5 Add MD2Core tests for renderer source-line metadata, long code block spans, code-fence `#` lines, and anchor helper edge cases.

## 2. Editor capture and destination scrolling

- [x] 2.1 Expose a fresh editor anchor capture path that reads the live `NSTextView`/`NSScrollView` on demand during Write→Read mode requests.
- [x] 2.2 Capture the top visible source line, scroll fraction, and a stable top inset from the editor viewport without relying only on the last scroll callback.
- [x] 2.3 Update editor destination scrolling to accept viewport anchors, compute the target source line from source span/progress, force TextKit layout, and clamp the scroll offset.
- [x] 2.4 Suppress transient anchor reporting while programmatic editor scrolling settles, then report the final visible anchor.
- [x] 2.5 Verify Read→Write does not leave `AXVisibleCharacterRange` empty or the editor overscrolled after layout settles.

## 3. Preview capture and destination scrolling

- [x] 3.1 Replace heading-only preview anchor JavaScript with block-source capture that inspects `data-md2-source-line` elements near the viewport top.
- [x] 3.2 Return source start/end line, intra-block progress, viewport inset, scroll fraction, and heading fallback from preview anchor capture.
- [x] 3.3 On Read→Write requests, ask the live `WKWebView` for a fresh anchor before switching modes, with a short timeout fallback to the cached anchor.
- [x] 3.4 Update preview destination scrolling to target the rendered block/source-line anchor when available, preserving intra-block progress and clamping after load/reflow.
- [x] 3.5 Keep existing heading fragment and proportional fraction behavior as fallback when block metadata cannot be resolved.

## 4. Mode coordination

- [x] 4.1 Update `ContentView.requestMode` so Write→Read and Read→Write use the new viewport anchor flow rather than only `jumpLine`, `jumpHeadingID`, and `jumpFraction`.
- [x] 4.2 Keep toolbar segmented control, Esc, and Cmd+double-click switching on the same anchor-capture path.
- [x] 4.3 Prevent stale cached anchors from overwriting fresher on-demand captures during quick scroll-then-switch interactions.
- [x] 4.4 Preserve outline-sidebar jumps and find-result scrolling without capturing those programmatic scrolls as user mode-switch anchors until they settle.

## 5. Verification

- [x] 5.1 Add or update unit tests for short-document clamping and long-document viewport-anchor target line resolution.
- [x] 5.2 Manually verify `/Users/tiredboy/Downloads/find_bugs_dsv4pro.md` at the top, middle body text, long code examples, section boundaries, and bottom summary.
- [x] 5.3 Manually verify a sparse-heading document where one heading contains many paragraphs; switching must preserve the local paragraph rather than the heading.
- [x] 5.4 Manually verify a no-heading document still uses proportional fallback and never resets to the top.
- [x] 5.5 Run `swift test` and a packaged `/Applications/Markdown2.app` smoke test for Write↔Read round trips.
