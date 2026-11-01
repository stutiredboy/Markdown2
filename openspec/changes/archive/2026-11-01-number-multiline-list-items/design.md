## Context

The renderer stamps each top-level block with its source span (`taggedWithSourceLines`). Blocks nested in a blockquote or a loose list item get spans too, because those contents are rendered with a line offset. Footnote items carry a start line. A tight list item had no span of its own: its text is not wrapped in a `<p>`.

Two consumers read the spans:
- The preview gutter (`__md2RenderLineNumbers`) numbers the direct children of `<main>`. A subtree query would also number footnote items and quoted blocks.
- The anchor scripts (`captureAnchor`, `sourceLineTargetY`) query every `[data-md2-source-line]` and take the deepest element at the anchor band or target line.

## Decisions

### Stamp every list item, number only the multi-line ones

`buildList` stamps each item it emits. The start is the item's own line. The end is the last line of the last item it consumed, which is its deepest, latest descendant, plus that item's continuation lines. The end attribute appears only when it differs from the start.

Every item gets a start line, not only multi-line ones, because the anchor needs it. A one-line source item can still be tall in the preview: a long line wraps into many rows. Without a span, the anchor falls back to the list and interpolates by height, and one tall item makes every later item resolve several lines off (`testReadToWriteLandsOnTheListItemAtTheTop` measured 17 lines off).

The gutter numbers only items that carry an end line, per the product decision. A column of numbers on one-line items is noise. A multi-line item is where a reader loses track of the line.

*Alternative considered:* stamp only multi-line items. Rejected because it leaves the anchoring gap above for the most common list shape.

### Which items get a number

The gutter takes `:scope > ul li[data-md2-source-end-line]` and `:scope > ol li[...]`. That is every multi-line item of a top-level list, nested items included. It then skips any item with a `blockquote` or `.markdown-alert` ancestor. The rule for blocks is that quoted content is not numbered; the skip keeps that rule when the quote or alert sits inside an item. Top-level quotes, alerts and footnotes are excluded already, since their lists are not direct children of `<main>`.

A line is numbered once (`numberedLines`). The list and its first item share a start line, and two numbers on one line would overlap. Numbers are collected from blocks and items, then sorted by position before the spans are created. The DOM order of the spans has no meaning, but sorting keeps them in reading order for anything that walks the layer.

An item's number sits at the item's top. The `<li>` box starts where its marker line starts, so `rect.top - mainTop` works as for blocks.

### Anchoring needs no script change

`captureAnchor` takes the last element in document order whose top is at or above the band, and `sourceLineTargetY` takes the deepest element whose start is at or before the line. Items nest inside their list, so an item wins over its list in both scripts, and a nested item wins over its parent.

## Verification

- **Differential.** `swiftc -O` probes built from `main` and from this branch rendered 243,446 inputs: repository and local documents, fuzz cases, structured cases, the test-suite inputs and the earlier edge-case sets. 2,222 outputs differ. Each differs only in `<li>` attributes: stripping them gives `main`'s output byte for byte. 49,203 items are stamped. No regular `<li>` is left unstamped, and every end line is after its start line.
- **Cost.** On a worst case of 40,000 one-line items (858 KB), output grows 96% and render time 8% (1.20 s to 1.29 s). The time tracks the added bytes. Structured documents cost 1–3%. The `InlineRenderingPerformanceTests` budgets pass.
- **Mutations.**
  - Emitting a bare `<li>` fails the anchoring GUI test: the anchor becomes the list (lines 3–153), and the editor lands 503 pt from the item. It also fails the gutter test and both metadata tests.
  - Removing the quote/alert skip numbers lines 22 and 26 in the gutter test.

## Risks / Trade-offs

- **Exported HTML** carries the item attributes, as it already carries block metadata. They are inert, and no line number reaches an export. DOCX and EPUB are built from the Markdown source by pandoc.
- **Pre-existing issues found while testing, out of scope:**
  - The first Read → Write switch that creates the editor's text view settles its anchor before the editor's asynchronous styling changes line heights. The styler keeps the pixel offset, so the editor lands far from the anchored line: line 12 instead of 63 in the measured case. The anchoring test therefore opens the document in Write mode first.
  - The gutter re-renders every animation frame while numbers are shown. Each pass disconnects the `ResizeObserver` and observes every block again, and a new observation delivers a notification that schedules the next pass: 120 passes in 2 s on an idle page in Chromium. A click whose mouse-down and mouse-up straddle a pass hits a replaced span and is lost. That explains the intermittent `testPreviewGutterNumberSelectsItsLineInTheEditor` failures.
