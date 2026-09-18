## 1. Settings and localization

- [x] 1.1 Add `showsLineNumbersInEditor` and `showsLineNumbersInPreview` to `AppSettings` as `@Published var … Bool` with `didSet` persistence under `MD2.ShowsLineNumbersInEditor` / `MD2.ShowsLineNumbersInPreview`, loaded in `init` with a nil-check that defaults both to `false` (mirroring `showsOutlineByDefault`).
- [x] 1.2 Add the `L10nKey` cases (group label, editor scope, preview scope, toolbar help) with English and Simplified Chinese strings in the `L10n` dictionaries.
- [x] 1.3 Add the two toggles to the General section of `SettingsView`, bound to the new preferences.
- [x] 1.4 Add `Tests/MD2CoreTests/LineNumberSettingsTests.swift` (Swift Testing, isolated `UserDefaults` suite) covering: both default to off; enabling one leaves the other untouched; both can be on at once; values persist across `AppSettings` instances; a missing key resolves to `false`.
- [x] 1.5 Add an all-keys L10n completeness test: iterate `L10nKey.allCases` and assert every key has both an `english` and a `zhHans` entry — `L10n.text` falls back silently (`zhHans[key] ?? english[key] ?? key.rawValue`, `AppSettings.swift:407`), so a missing entry otherwise ships as English text for Chinese users or a raw enum string in the UI. Guards all existing keys plus every future one.

## 2. Editor gutter

- [x] 2.1 Add a `showsLineNumbers: Bool` input to `MarkdownEditorView` and thread it from `ContentView` through to the coordinator and `MarkdownSourceTextView`.
- [x] 2.2 Expose the "which lines get a number" decision as a pure helper — given the line fragments' character ranges, return the subset whose location starts a source line — so it is testable without a window (the existing `lineBoundingRect`/`topVisibleLine` geometry helpers are not). The helper implements the **renderer's numbering convention** (`normalizedMarkdownLines`, `String+Markdown.swift:4`: LF, CRLF, and bare CR each count as one line break), so preview and editor agree on every document; existing helpers are untouched.
- [x] 2.3 Implement the gutter in `MarkdownSourceTextView.draw(_:)`: after `super.draw(_:)`, draw each numbered row's number right-aligned inside `x ∈ [0, textContainerInset.width)`, reusing `Coordinator.lineNumber(forCharacterIndex:in:)`'s semantics through the new convention helper. Do not change `textContainerInset` or any other geometry. Two mechanics are load-bearing:
  - Enumerate fragments over the dirty rect's **vertical interval extended across the full container width** (the same container-origin conversion `topVisibleLine` performs at `MarkdownEditorView.swift:1012`), then clip painting to the strip — the strip itself translates into container coordinates that intersect no glyphs, so a strip-rect fragment query would paint nothing.
  - Carry `(lineNumber, lastScannedOffset)` forward across fragments in document order — one O(documentLength) scan per redraw instead of O(visible × documentLength) independent scans.
- [x] 2.4 Invalidate the gutter strip explicitly (there is no existing view-level invalidation to hook — text redraws are TextKit-internal and glyph-rect-scoped): when numbers are on, `setNeedsDisplay` the strip over the affected y-range at the shared edit choke points — after `MarkdownTextStyler.apply(to:)` (`:138` load, `:196` programmatic replacement, `:1209` typing), in `textDidChange`, and in `updateNSView` when `showsLineNumbers` changes. Scrolling needs nothing extra (exposed regions arrive as full-width dirty rects).
- [x] 2.5 Extend the non-GUI editor tests (`MarkdownEditorLineRangeTests` patterns) over the 2.2 helper: a soft-wrapped line yields exactly one number; continuation fragments yield none; the computed numbers are 1-based and match their lines; the last line of the document is numbered; a document ending in `\n` numbers the trailing empty line (parity with the status bar count); a document with CRLF and bare-CR line breaks numbers identically to the renderer's `normalizedMarkdownLines`.
- [x] 2.6 GUI-gated checks (`MD2_RUN_GUI_TESTS=1`): with numbers on, the gutter is visible in the left inset and legible in both appearances; a wrapped paragraph shows one number; numbers stay aligned after scrolling and after an edit above the viewport; with numbers off, no gutter is drawn and the text sits exactly where it does today.

## 3. Preview gutter

- [x] 3.1 Add `showsLineNumbers: Bool` to `MarkdownPreviewView`, store it on the coordinator, and push it in `updateNSView` following the existing `showsFrontMatter` precedent.
- [x] 3.2 Add `window.__md2RenderLineNumbers()` to the preview `WKUserScript`: build or replace a single `<div class="md2-line-gutter" aria-hidden="true">` inside `<main>` holding one empty `<span data-md2-gutter="N">` per eligible block, each positioned against that block's top from `getBoundingClientRect()`. Never emit digits as text nodes. Eligibility is explicit:
  - Selection is **direct children of `main`** filtered by `data-md2-source-line` — never a subtree `querySelectorAll`, because footnote `<li>`s carry the attribute too (`MarkdownRenderer.swift:980`) and must not be numbered.
  - Skip blocks with a zero rect or hidden `offsetParent` — the hidden front-matter block is `display:none` (`MarkdownPreviewView.swift:157`) and would otherwise pin a garbage number at the document top.
  - The footnotes and bibliography wrapper sections get no number (documented wrapper exceptions in `MetadataInvariantTests`; their entries' metadata lives on the `<li>`s / `.bib` file, not document lines).
- [x] 3.3 Add the preview-only style block (in the injected user script, **never** in `MarkdownRenderer.htmlDocument`): `main { position: relative }`, `.md2-line-gutter { position: absolute; inset: 0; pointer-events: none }`, and `span::before { content: attr(data-md2-gutter) }` colored with the existing `--muted` token so dark appearance is handled by `light-dark()`.
- [x] 3.4 Add the `--md2-gutter-width` custom property and the `html.md2-line-numbers` switch class, and reserve gutter space in **pure CSS** (no JS width function): `html.md2-line-numbers main { padding-left: max(clamp(28px, 4vw, 64px), var(--md2-gutter-width)) }` and `.md2-line-gutter span { left: max(clamp(28px, 4vw, 64px) - var(--md2-gutter-width), 0px) }`. Wide windows (clamp = 64 ≥ G) see zero reflow; narrow windows raise the padding by at most G − 28px inside the border-box; JS keeps only the per-span vertical `top`.
- [x] 3.5 Wire regeneration through one idempotent entry point: on script load, at the end of `__md2ApplyContent` (the Side by Side live swap destroys the layer), on window resize, and from a `ResizeObserver` observing **`main`'s top-level blocks** (not just `main` — a block can grow while another shrinks by the same amount, leaving `main`'s box unchanged while numbers below go stale) so asynchronously rendered math and diagrams are picked up once their heights settle. Add `window.__md2SetLineNumbersVisible(Bool)` to flip the switch class without reloading or re-rendering.
- [x] 3.6 Add `Tests/MD2CoreTests/LineNumberGutterGUITests.swift` (XCTest, `XCTSkipUnless(MD2_RUN_GUI_TESTS == "1")`) asserting over a real offscreen `WKWebView`, on a test document that includes a footnote list, a bibliography reference, a long soft-wrapped paragraph, and a trailing newline:
  - numbers match the source line of a heading, a paragraph, and a fenced code block;
  - the number of gutter entries equals the number of eligible top-level blocks; the footnotes and bibliography sections produce **no** entries and no `<li>`-level duplicates;
  - numbers survive a `__md2ApplyContent` swap;
  - a `__md2Find` for a number that appears only in the gutter reports no match;
  - the flip path: `__md2SetLineNumbersVisible(true)` shows numbers with **no content swap** (assert `main.innerHTML` unchanged), `false` hides them, and a fresh load with the preference on shows numbers at first paint;
  - window-width invariants: at a narrow frame with numbers on there is no horizontal scroll (`scrollWidth ≤ clientWidth`); past the column cap, `main`'s computed `max-width` is unchanged and the padding raise is zero; toggling off restores the base computed padding.
- [x] 3.7 Add an export-isolation test asserting that `rendered.html` carried through the export path contains no gutter layer or gutter styling, and — driving the **real `PDFExporter`** with numbers on — that the rasterized PDF matches the numbers-off export with **region-specific** assertions (sample the left-margin region on a sized document, per the `global-darkpixel-assertion-false-pass` learning; never a global pixel count), and that exported HTML contains no gutter markup.

## 4. Wiring and toolbar control

- [x] 4.1 Add the line-number `Menu` beside the outline control in `ContentView`'s toolbar, with two checkmarked items (editor scope, preview scope) bound to the two preferences, and localized labels.
- [x] 4.2 Point each pane at its own scope: the editor pane follows `showsLineNumbersInEditor`, the preview pane follows `showsLineNumbersInPreview`, so Side by Side honors both independently and toggling one leaves the other pane untouched.
- [x] 4.3 Confirm the Settings toggles and the toolbar menu cannot disagree (both bind to `AppSettings`, which is the single source of truth).

## 5. Verification and wrap-up

- [x] 5.1 Run the non-GUI suite: `swift test`.
- [x] 5.2 Run the GUI suite for the new surface and the paths it touches: `MD2_RUN_GUI_TESTS=1 swift test --filter LineNumberGutterGUITests --filter MermaidOffscreenRenderingTests --filter PDFExportEndToEndVerification`.
- [x] 5.3 Manually verify export isolation: export the same document to PDF and to HTML with numbers on and off, and confirm the layout is identical and no gutter appears.
- [x] 5.4 Manually verify the mode-switch and Side by Side scroll sync still behave (numbers on and off), since the preview script gained a new injection pass.
- [x] 5.5 Update the feature lists in `README.md` / `README.zh-CN.md` if they enumerate display preferences.
- [x] 5.6 Run `openspec validate add-line-numbers` and confirm it passes.
- [x] 5.7 Add the CLAUDE.md Testing-section note for the new GUI guards (same pattern as the `FindFindDeleteGUITests` note): after changing the line-number surfaces (`MarkdownSourceTextView` draw path, preview `__md2RenderLineNumbers`, export-isolation assertions), run `MD2_RUN_GUI_TESTS=1 swift test --filter LineNumberGutterGUITests` locally before landing — the guarded failures are silent (stale numbers after edits, export leak).
