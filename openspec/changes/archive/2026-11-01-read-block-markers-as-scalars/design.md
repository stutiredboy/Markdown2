## Context

The block parser walks normalized lines and tests each for a block opener. Most tests are `String` operations that compare `Character`s:
- `trimmed.hasPrefix("- ")`, `afterHashes.first == " "`, `dropFirst(2)`
- `prefix { $0 == " " }` for indentation

Unicode's grapheme rules join a base character with a following extending scalar (GB9), ZWJ (GB9) or spacing mark (GB9a). So when content starts with such a scalar, the space or delimiter that ends the marker is no longer a `Character` equal to `" "` or `">"`, and the marker goes unseen. Where a marker was recognized and then dropped by `Character`, the drop also took the joiner.

The fixes already landed for the bare-URL scheme check (`fix-bare-url-tail-and-scheme`), HTML escaping and the source-line stamp (`fix-source-line-stamp-after-joining-scalar`) were the same class at other sites.

## Decisions

### Scope from a reference, not by inspection

A scoping harness renders each construct with a letter and with each of four joiners (U+0301, U+200D, U+FE0F, U+093F) in the same place. It compares the tag structure with markdown-it-py's CommonMark renderer, which reads code points. A construct is a bug when the joiner changes our structure but not the reference's.

**Affected:**
- ATX headings (with and without a closing sequence)
- the three bullet markers
- `>` without a space, and a list inside a quote
- open and done tasks
- fence info strings
- indented code
- nested list items and list continuations
- reference labels, keys and titles
- `$$` and `\[` math, where the reference has no math, so only our letter rendering is the baseline

**Unaffected:** ordered lists, a quote with a space, tables, setext headings, footnotes, emphasis, code spans, links, image alt text, strikethrough and inline HTML. They either use UTF-16 regexes or scalar scanners already, or, like setext underlines and thematic breaks, become invalid in CommonMark too when a joiner is added.

### Two `String` helpers, applied at each marker

`hasScalarPrefix(_:)` compares `unicodeScalars`. `droppingScalars(_:)` returns the text after the first *n* scalars, as `String(unicodeScalars.dropFirst(n))`.

The first version built the result with `String.UnicodeScalarView(…)`, which re-encodes scalar by scalar. That made a 2,000-item list 18% slower, because list parsing drops markers several times per line. Slicing the scalar view copies the bytes and restores parity.

The helpers are on `String` because every call site has one, and the generic `StringProtocol` form cannot use the slice initializer.

Each site keeps its existing logic and only changes the unit:
- **ATX headings:** hashes are counted by scalar; the title is the text after one scalar space.
- **Blockquotes:** the two blockquote strippers (the block walk and link-definition collection) become `MarkdownLine.isBlockquote` and `MarkdownLine.blockquoteContent`.
- **Bullets and tasks:** compare their exact prefixes. The case-insensitive `[x]` check, which lowercased the whole text, becomes `[x] ` or `[X] `.
- **Fences and math openers:** compare and drop by scalar.

*Alternative considered:* rewriting the block parser to walk scalars throughout. Rejected: it is far more code for the same result. The helpers keep each site's diff to the comparison itself.

### Indentation is one measure for the editor and the renderer

`MarkdownIndentation.width` counts by scalar. List nesting, `collectListItemContinuation` and `listContentIndent` all use it, and the editor's list commands share it, so both agree that `"  ́x"` is indented two columns.

`dropIndentColumns` and `isIndentedContinuation` also step by scalar, so the strip removes the width that was measured. Today the leftover space a `Character`-based strip would leave is trimmed when the paragraph is built, so no rendering exposes it. The conversion keeps the measure and the strip consistent rather than relying on that.

### Reference syntax steps by scalar

`LinkReference`'s cursor peeks and advances `Unicode.Scalar`s:
- Labels, destinations and titles are appended by scalar.
- Whitespace uses `properties.isWhitespace`, and the control-character check reads the scalar value directly.

`renderReferenceLinks` pairs `[`/`]` and walks the text through `unicodeScalars`. So a mark after `[` (label or key), or a prepended mark such as U+0600 before it, no longer hides the bracket.

## Verification

- **Scoping harness:** every construct listed above as affected is now clean, and the branch introduces no new joiner-only differences.
- **Metamorphic fuzz:** 6,000 generated documents, each mixing 1–4 lines of markers, indentation, joiners and reference usage, with a letter version beside each.
  - `main`: a joiner changes our structure without changing the reference's in 3,278 of the 5,014 documents that contain one.
  - This change: 0.
  - The 6,000 letter versions render byte-identically on `main` and this change.
- **Differential** (`swiftc -O`, `main` at `4031d02`):
  - 0 of 1,827 repository/local documents and CommonMark/GFM examples differ.
  - 1 of 240,000 generic fuzz inputs differs: `* ́́` is now a list item.
- **Timing:** `Scripts/benchmark_inline.sh` is within noise on every workload. Interleaved timings of 2,000-line documents (bare URLs, angle autolinks, prose, list items) match `main`.
- **Tests:** `BlockMarkerScalarTests` covers 19 constructs × 4 joiners for structure and joiner placement, plus content checks, the prepend case and the indentation width. Nearly every case fails against `main`'s parser.
- **Mutation:** a `Character`-based `MarkdownIndentation.width` fails the width test and the list-continuation cases.
- **Full suites:** the non-GUI suite passes in CI's three steps, including the conformance baseline, the editor's `MarkdownEditingTests` and `OutlineBuilderTests`. `MarkdownEditingGUITests` passes too.

## Risks / Trade-offs

- **The change touches many parser sites.** Mitigation: each site keeps its logic, the joiner-free corpora are byte-identical, and the metamorphic fuzz covers combinations of sites.
- **The editor's indentation measure changes for joiner-led lines.** That is the intended agreement with the renderer, and `MarkdownEditingTests` stays green.
