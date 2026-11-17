# Real-document compatibility

This package uses four original, offline documents to check how Markdown2
handles a README, a technical note, Chinese long-form writing and a math note.
The [corpus inventory](../../../Tests/MD2CoreTests/Corpus/README.md) records their
provenance and the behaviors each document exercises. The normative CommonMark
and GFM corpus remains a separate gate.

| Use case | Before | Accepted behavior |
| --- | --- | --- |
| Resume a deployment checklist at step 10 | The rendered list started at 1. | The first marker sets the displayed ordinal, including in nested lists and PDF. |
| Link to a path such as `windows_(portable).md` | The first closing parenthesis cut off the URL. | Preview, HTML and source styling recognize the whole link; an incomplete destination does not consume the next ordinary link. |
| Label a shell snippet `~~~sh filename=bootstrap.sh` | The filename made the entire language identifier unrecognized. | The first word selects the code language. Trailing info stays in source; it does not activate a diagram. |
| Start `## Results \| next steps` immediately after a table | Preview and HTML rendered the heading as a row while the outline listed it as a heading. The missing heading target could also fail PDF export. | The table ends before the heading. Table editing preserves the heading, both rendered formats include it, and the PDF has a matching bookmark. |

The native suite opens each fixture in the editor, compares the preview and
reopened standalone HTML using WebKit, and checks PDF bookmarks and content with
PDFKit. It selects a Chinese outline row and verifies that both editor and
preview reveal it. All four source files are checked byte for byte after opening,
navigation where applicable, export, and save. The math document checks KaTeX
rendering, an equation reference and the printed equation marker. Visual
review also caught an existing loss of square-root signs in PDF. The print
style now preserves KaTeX's internal SVG geometry while keeping the existing
width constraint on the whole equation. A WebKit geometry test guards the
typographic feature that was missing even when text extraction passed.

On macOS 27.2.1, WebKit PDF capture can map some Chinese glyphs to equivalent
Unicode radical code points during text extraction. This reproduced on the
pre-change app (`fd2c791`). The text content check treats those radical aliases
as equivalent; source, HTML, and PDF bookmark labels are compared exactly.
Readers may therefore still differ when copying or searching some characters in
the PDF.

The [compatibility matrix](../../CompatibilityMatrix.md) describes the supported
syntax and remaining boundaries. The 676-example baseline changed in six
ordered-list cases (265–268, 296–297) and two inline-link cases (497, 508), all
to reference matches. Independent review checked that the revised link bounds
cannot expose image-looking text in a malformed title to attachment collection.
It also caught a Unicode boundary regression in image detection, now covered
by a test with a combining mark at the start of the alt text. List grouping,
render budgets and export resource policy retain their existing behavior.

An optimized three-sample inline probe on macOS 27.2.1 rendered 500, 1,000 and
2,000 mixed valid and unfinished links with minimum times of 13.81, 27.26
and 55.34 ms. The probe checks the full destination and output count before
timing. This workload is now in the existing inline scaling gate.

Local acceptance on macOS 27.2.1:

| Gate | Result |
| --- | --- |
| Default Swift suites, conformance and generated matrix | 1,100 Swift Testing cases and 46 ungated XCTest cases passed. |
| Full native regression before the print-style correction | 338 passed; one allowlisted manual PDF probe skipped. |
| Final native export and security regression | 66 passed without skips, including all corpus checks, KaTeX geometry, PDF and Mermaid, and resource isolation. |
| Isolated timing gates | Inline and block scaling plus the render and HTML export main-thread responsiveness checks passed. |
| Workflow tests and isolated package | 43 Python tests passed. The app signature, resource bundle, macOS 15 minimum and DMG checksum verified. |

Run the acceptance fixtures from a checkout without installing
the app:

```sh
swift test --filter 'RealDocument(Corpus|Syntax)Tests|MarkdownOrderedListTests'
MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing --filter RealDocumentCompatibilityGUITests
swift test --filter 'MarkdownConformance|CrossArtifactConsistencyTests'
swift test --filter InlineRenderingPerformanceTests
swift test --filter BlockRenderingPerformanceTests
```
