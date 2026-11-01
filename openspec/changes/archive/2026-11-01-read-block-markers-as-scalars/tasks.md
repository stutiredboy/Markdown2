## 1. Parser

- [x] 1.1 Add `String.hasScalarPrefix(_:)` and `String.droppingScalars(_:)`.
- [x] 1.2 Read ATX headings, fences, indented code, blockquotes (`MarkdownLine.isBlockquote`, `MarkdownLine.blockquoteContent`), bullet and task markers, list content indentation, display-math openers, and continuation indentation as scalars.
- [x] 1.3 Count `MarkdownIndentation.width` by scalar.
- [x] 1.4 Step `LinkReference`'s cursor by scalar, and pair and walk `renderReferenceLinks`'s brackets by scalar.

## 2. Tests

- [x] 2.1 Add `BlockMarkerScalarTests`; confirm it fails against `main`'s parser.
- [x] 2.2 Mutation check: a `Character`-based `MarkdownIndentation.width` fails a test.

## 3. Verification

- [x] 3.1 Run the scoping harness against markdown-it-py and the 6,000-document metamorphic fuzz (results in `design.md`).
- [x] 3.2 Compare `swiftc -O` probes with and without this change on the repository, local and spec documents and the generic fuzz corpora.
- [x] 3.3 Compare timings with `Scripts/benchmark_inline.sh` and interleaved runs on line-heavy documents.
- [x] 3.4 Run the full non-GUI suite in CI's three steps, `MarkdownEditingGUITests`, and `openspec validate read-block-markers-as-scalars --strict`.

## 4. Docs

- [x] 4.1 Remove the TODO, and record in the proposal why its inline-link example is not a grapheme bug.
