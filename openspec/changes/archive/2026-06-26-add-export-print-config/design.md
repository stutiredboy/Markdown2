## Context

Export today is a fixed pipeline. `PDFExporter` (offscreen `WKWebView` →
per-band `createPDF` → `PDFPaginator` composition → PDFKit outline) hard-codes A4
(`a4PageSize`) and a uniform 36pt ("Narrow") margin in its `init`, computing
`printableWidth`/`printableHeight` from those constants. `DocumentPrinter` reuses
the same exporter to render a temp PDF and prints it through PDFKit, so print and
PDF output are identical by construction. The rendered HTML (`MarkdownRenderer`)
is already self-contained for the preview: CSS, KaTeX, mhchem, and the diagram
engines are inlined, math renders synchronously, and diagrams render via
`window.__md2RenderDiagrams` after load.

Two gaps motivate this change:

1. **No configurability.** Page size, orientation, margins, page numbers, and
   headers/footers are not adjustable, and there is no non-PDF hand-off format.
2. **A latent fidelity bug.** The archived `fix-pdf-export-clipping/design.md`
   (Out-of-scope section) records that **Mermaid diagrams render blank in the
   offscreen export web view** while KaTeX math renders. This reproduces on
   pre-change code, so it is an engine-execution problem in the window-less
   `WKWebView`, not a pagination one. It must be fixed first, because every other
   improvement here is about making export output *better* — it should also be
   *correct*.

Constraints: keep the native pipeline dependency-free and lightweight (no new
bundled libraries); preserve current default output exactly (A4 + narrow, outline
on); keep pure geometry/text logic testable without AppKit/WebKit; honor the
project's existing localization (EN/zh-Hans) and Settings patterns; all export
operations (PDF, Print, HTML, DOCX/EPUB) remain mutually exclusive.

## Goals / Non-Goals

**Goals:**
- Make PDF/print page geometry configurable (size, orientation, margins) with the
  current A4/narrow output as the unchanged default.
- Add optional page numbers and headers/footers with positional zones and tokens.
- Persist these choices as a single "export profile" surfaced in Settings — the
  "configuration center" — and apply it to both PDF export and Print.
- Fix offscreen diagram rendering so exported/printed diagrams match the preview,
  by awaiting an explicit diagram-completion signal instead of a blind delay.
- Add self-contained single-file HTML export.
- Provide optional DOCX/EPUB export via an external Pandoc binary, inert when
  Pandoc is absent.

**Non-Goals:**
- Bundling a DOCX/EPUB engine or any new dependency in the app.
- Per-export one-off override dialogs in this change — the profile supplies the
  settings; an export-time override sheet can come later (the model is designed to
  allow it without rework).
- WYSIWYG page-layout preview, custom fonts/themes for export, watermarks, or
  cover pages.
- Changing the live preview's diagram rendering (only the offscreen path is in
  scope; the preview already works).

## Decisions

### 1. A pure `ExportProfile` value model (in `MD2App`, with the export pipeline)

Introduce a `Codable`, `Equatable`, `Sendable` value model with no AppKit/WebKit
dependency (Foundation + CoreGraphics only):
- `PageSize` enum (`a4`, `letter`, `legal`, …) → point dimensions at 72dpi.
- `PageOrientation` (`portrait`/`landscape`) — swaps width/height.
- `PageMargins` with presets (`none`, `narrow`, `normal`, `wide`) and a `custom`
  case carrying per-side points.
- Header/footer config: left/center/right text templates per zone, a page-number
  toggle + alignment, and a running-text font size.
- A pure token resolver: `{title}`, `{date}`, `{page}`, `{pageCount}` → concrete
  strings (the caller supplies an already-formatted, locale-aware date).

`PDFExporter`/`PDFPaginator` derive `pageSize`, `margins`, `printableWidth`,
`printableHeight` from this model rather than from the `static let` constants
(the constants become the *default* profile, not the only one).

*Where it lives:* `PDFExporter` and `PDFPaginator` both live in `MD2App`, and the
test target already unit-tests `MD2App` types directly (`PDFPaginatorTests` via
`@testable import MD2App`). So the model sits in `MD2App` next to the pipeline that
consumes it, kept as a pure value type so geometry math, margin resolution, and
token substitution stay unit-testable without an offscreen render. `AppSettings`
(also `MD2App`) persists it.

*Alternative considered:* `MD2Core`. Rejected — the renderer and HTML export do
not need page geometry, so the type would be orphaned in the core; keeping it with
`PDFExporter`/`PDFPaginator` is more cohesive and equally testable.

### 2. Persist the profile in `AppSettings`; apply it automatically

`AppSettings` gains the profile (loaded/stored in `UserDefaults` under new
`MD2.Export*` keys, following the existing `didSet`-persist pattern), with a
localized Settings UI (a new "Export" section, plus EN/zh-Hans `L10nKey`s).
`DocumentStore.exportPDF()`/`print()` read the current profile and pass it to the
exporter factory. The `PDFExporting`/`DocumentPrinting` protocols (and the
factories on `DocumentStore`/`DocumentPrinter`) gain an `ExportProfile` parameter.

*Why a persistent profile, not a per-export dialog:* the feature is framed as a
configuration *center* — configure once, every hand-off is consistent — and it
keeps the export command flow (which already routes through an `NSSavePanel`)
unchanged. The model is structured so a future override sheet can pass a modified
`ExportProfile` to the same factory.

### 3. Fix offscreen diagrams by awaiting a completion signal

Root-cause analysis: KaTeX renders **synchronously** inside `__md2RenderMath`, so
it is always done by the time `createPDF` runs. Mermaid renders **asynchronously**
(`mermaid.render(...).then(...)`) and internally relies on layout/text
measurement and animation-frame scheduling. In a window-less / non-visible
`WKWebView`, animation-frame and rendering work is throttled, so the promise chain
can stall or simply not finish within the fixed 2.5s `settleDelay` — leaving the
`.diagram` boxes blank when the band capture starts. The parked off-screen host
window (added for `createPDF` warm-up) helps WebKit lay out, but the exporter
still *guesses* at completion with a fixed delay.

Approach:
1. **Expose an explicit signal.** Extend `__md2RenderDiagrams` to track the
   outstanding diagram renders and resolve a promise / set a
   `window.__md2DiagramsSettled` flag (with a count of failures) once every
   diagram has either rendered or fallen back. Math is already synchronous, so a
   single "render pass complete" signal covers both.
2. **Await it before capture.** Replace the blind `settleDelay` in
   `webView(_:didFinish:)` with a poll/`evaluateJavaScript` wait on that signal,
   bounded by the existing `overallTimeout`, so capture begins only once diagrams
   have settled (fast documents no longer pay a flat 2.5s, slow ones no longer get
   captured early).
3. **Confirm the engine path.** Verify Mermaid actually executes offscreen (e.g.
   `mermaid.render` returning, font measurement non-zero); if rAF starvation is
   the blocker, drive the render so it does not depend on a throttled animation
   frame. The exact engine-level cause is confirmed during implementation against
   a known Mermaid document; the *contract* (diagrams in the PDF match the
   preview) is what the spec pins down.

*Why a signal over a longer fixed delay:* a longer delay is both slower for simple
documents and still unreliable for complex ones; an explicit settle signal is
correct and faster. Flow/sequence diagrams render synchronously via Raphael but
are audited under the same signal so the pipeline has one completion contract.

### 4. Headers / footers / page numbers drawn in `composePDF`

`composePDF` already draws each captured band into a fixed-size CG page. Draw the
header/footer text there, into the page-margin band (above the top content edge /
below the bottom content edge) using Core Text, with left/center/right alignment
per zone and tokens resolved per page (`page`/`pageCount` known at compose time).
When headers/footers are enabled, the effective top/bottom margin is expanded to
reserve a text band so glyphs never overlap content — including when the margin
preset is `none` (a minimum reserved band is enforced).

*Why at compose time, not in the HTML:* the HTML is captured as content bands;
running headers/footers must repeat on every page with live page numbers, which
only exist after pagination. Drawing them in CG keeps them independent of content
flow and identical across PDF and Print (Print consumes this same PDF).

*Alternative considered:* CSS `@page` margin boxes. Rejected — `createPDF`
band-capture does not honor `@page` running elements, and page numbers are not
known to the page content.

### 5. Synchronize the print dialog paper size with the profile

`DocumentPrinter.runPrintOperation` currently uses `NSPrintInfo.shared`, which
defaults to the system paper size (locale-dependent). When the profile selects
Letter but the system default is A4, the print dialog shows A4 and
`.pageScaleDownToFit` scales the already-Letter PDF down to A4 — wasting space
and surprising the user. Before running the print operation, set the
`NSPrintInfo` (a copy of `.shared`, not the shared singleton itself) to match
the profile's page size and orientation, so the dialog opens pre-configured and
the PDF prints at 1:1. The auto-rotate flag already handles orientation
mismatches with the physical paper.

*Why not rely on `.pageScaleDownToFit` alone:* scaling down silently changes
the output geometry; the user configured a specific page size and expects the
print dialog to reflect it. Pre-setting the paper size makes the dialog
honest and avoids a wasteful downscale.

### 6. Self-contained HTML via a dedicated builder

Add a `SelfContainedHTMLBuilder` (pure, in `MD2App` alongside
`LocalImageHTMLRewriter`, which already resolves local image paths) that takes the
rendered HTML plus the document `baseURL` and returns a single portable file: CSS
and the math/diagram engines are already inlined by the renderer, so the builder's
job is to **inline images** referenced by relative/absolute *local* paths as base64
`data:` URIs (mirroring the path-resolution logic of `LocalImageHTMLRewriter`, and
additionally resolving *relative* paths against `baseURL`), leaving remote
`http(s)` images as URLs. The diagram/math engines run client-side
in the opened file, so no offscreen render is needed — this is a string transform.
`DocumentStore` gains `exportHTML()` mirroring `exportPDF()` (flush render →
`NSSavePanel` for `.html` → write). When the document has no `baseURL`
(untitled), local image paths cannot resolve — the builder skips inlining for
those images (they remain as-is) rather than failing the export, matching how
`exportPDF()` already handles untitled documents (images simply don't load).

*Why reuse the preview HTML:* it already guarantees offline math/diagrams; only
images leak to the filesystem, so inlining them is the whole remaining gap.

### 7. DOCX/EPUB delegated to external Pandoc, detected at runtime

Add a `PandocConverter` helper: detect a `pandoc` binary on `PATH` and common
install locations (e.g. Homebrew `/opt/homebrew/bin`, `/usr/local/bin`); when
found, expose "Export as DOCX…/EPUB…" menu items, otherwise keep them disabled
with guidance (a localized alert explaining Pandoc is required). Detection runs
on demand each time the export menu is about to open (or the command is
invoked), not just at launch — so a user who installs Pandoc while the app is
running sees the commands enabled without a relaunch. A lightweight file-exists
check (cached for ~60s) keeps this cheap.

Conversion feeds the **Markdown source** (not the rendered HTML) to Pandoc,
writing to the chosen output file via `Process`. To reflect the document's
*current* content (including unsaved edits) while resolving relative images and
without mutating the saved file or dirty state, it writes the in-memory text to a
temporary `.md` inside the document directory (mirroring how `PDFExporter` writes
its temp HTML), runs Pandoc with that directory as the **process working
directory** (so relative images resolve on every Pandoc version — `--resource-path`
is 2.0+), then deletes the temp file. The reader is the canonical `gfm` on Pandoc
2.0+, falling back to the legacy `markdown_github` alias only on older 1.x builds
that do not know `gfm` (chosen from the binary's reported `--version`, cached for
the process); the writer is inferred from the output extension (`.docx`/`.epub`). An untitled document has no
directory, so it is saved first — the flow prompts to save (reusing the existing
save-before-attachment pattern), and a cancelled save aborts the export cleanly.
The `Process` invocation is bounded by a timeout (e.g. 60s) so a hung Pandoc
cannot stall the app; on timeout or non-zero exit, the partial output file (if
any) is deleted and a localized error is surfaced. The flow is injected behind a
`DocumentConverting` protocol (with an availability provider and destination
picker), mirroring the PDF/HTML factories, so it is unit-testable without Pandoc.

*Why source → Pandoc, not HTML → Pandoc:* Pandoc's native Markdown reader yields
higher-fidelity DOCX/EPUB structure (headings, lists, tables) than round-tripping
through the preview HTML. *Why external, optional:* keeps the app dependency-free
and lightweight by default, exactly as the project intends; users who need
DOCX/EPUB opt in by installing Pandoc.

## Risks / Trade-offs

- **All export types share the derived-artifact guard** → PDF export, Print,
  HTML export, and DOCX/EPUB conversion are all mutually exclusive via the
  existing `isProducingDerivedArtifact` flag (extended to cover the new
  operations). HTML/DOCX/EPUB do not use an offscreen `WKWebView`, but they
  still produce a file from the document's current state — allowing two
  concurrent exports could confuse the save panels and produce inconsistent
  output. The guard is a single boolean check, kept simple.

- **Offscreen Mermaid root cause is engine-internal** → The fix targets a robust
  completion signal + render driving rather than a specific engine bug; mitigated
  by verifying against a known Mermaid document during implementation and keeping
  the spec contract behavioral ("export matches preview"). If a diagram still
  fails, the existing per-diagram fallback shows source rather than blanking.
- **Header/footer band eats content height** → Reserving a margin band reduces
  printable height; mitigated by enforcing the reserve only when enabled and
  feeding the adjusted printable height into pagination so nothing is clipped.
- **App sandbox blocks launching Pandoc** → Running an external `Process` requires
  the app not be sandboxed (or to hold the right entitlement). Mitigated: the app
  ships unsandboxed today; the DOCX/EPUB path is optional and fails gracefully, so
  a sandboxed build simply never shows the affordance.
- **Pandoc path/version variance** → Detection covers PATH + common locations and
  surfaces clear guidance when absent; version-specific flags are kept minimal
  (`--from gfm`, resource path) to maximize compatibility.
- **Pandoc process can hang or produce partial output** → The `Process` call is
  bounded by a timeout; on expiry the process is terminated, any partial output
  file is deleted, and a localized error is surfaced. This prevents a stuck
  Pandoc from hanging the app or leaving a corrupt `.docx`/`.epub` that looks
  like a success.
- **New `UserDefaults` keys / protocol params** → Internal-only surface; defaults
  reproduce current output, so existing users see no change until they opt in.
- **Awaiting a JS signal could hang** → The wait is bounded by the existing
  `overallTimeout`, so a stuck engine still fails the export cleanly rather than
  hanging the app.

## Migration Plan

- Land in phases (see tasks): (1) diagram-completion signal + offscreen fix;
  (2) `ExportProfile` model + parameterized geometry (defaults = today's output);
  (3) page numbers / headers / footers; (4) Settings UI + persistence + menu +
  print dialog paper-size sync; (5) self-contained HTML; (6) optional Pandoc
  DOCX/EPUB.
- Each phase keeps defaults equal to current behavior, so partial landing never
  regresses existing exports.
- Rollback: revert the change; new `UserDefaults` keys are ignored by old code and
  harmless. No data migration is required.

## Open Questions

- Exact set of page-size presets to ship first (A4 + Letter are certain; Legal /
  A3 / A5 are easy adds) — resolved during implementation, additive to the enum.
- Default header/footer template strings — pick sensible defaults during the
  Settings-UI phase; profile remains off-by-default so existing output is
  unchanged. The `date` token resolves to a locale-aware short date (e.g.
  `2026-06-25` or `6/25/26` per system locale); the `page` token resolves to the
  1-based page number and `pageCount` to the total, so a template like
  `{page} / {pageCount}` produces `3 / 12`. Page-number format is a simple
  toggle (on/off) with position (left/center/right) — no multi-format picker in
  this change; the template string covers custom formatting if needed.
