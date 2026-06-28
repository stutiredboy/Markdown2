## Context

Markdown2 is a SwiftUI/AppKit macOS app. Documents are backed by `DocumentStore`
(`@MainActor`), which owns the source `text` and a debounced `rendered`
(`RenderedDocument`) carrying the full preview `html`, the `<main>` `body`, the
outline, and stats. The Read-mode preview is a `WKWebView` (`MarkdownPreviewView`)
that loads `rendered.html`. For documents on disk, the preview is written to a
temporary `.md2-preview-*.html` file inside the document's directory and loaded
via `loadFileRequest(_:allowingReadAccessTo:)` so that relative image paths
resolve under granted read access; documents without a file URL load via
`loadHTMLString`. Math (KaTeX) and diagrams (Mermaid/flow/sequence) render
asynchronously in-page over up to a couple of seconds after load.

File-menu commands live in `MD2App.swift` and dispatch to
`appDelegate.currentDocumentStore`. Menu labels come from `AppSettings.text(_:)`
backed by the `L10nKey`/`L10n` tables in `AppSettings.swift`.

The preview web view is only mounted when the current mode shows a preview (Read
or Side by Side). In Edit-only mode there is no live web view to print from.

## Goals / Non-Goals

**Goals:**
- Add an **Export as PDF…** File-menu command that writes a paginated PDF
  faithful to the Read-mode preview.
- Work in every editor mode, including Edit-only where no preview is mounted.
- Resolve relative images and fully render async math/diagrams before export.
- Surface failures through the existing `DocumentStore.alert` path.
- Leave the document's Markdown representation, `fileURL`, and dirty state
  untouched.

**Non-Goals:**
- Page size / margin / orientation configuration UI (use the fixed A4 export default).
- Headers, footers, or page numbering.
- Other export formats (HTML, DOCX, image).
- Reusing the live on-screen preview web view (a dedicated offscreen render is
  simpler and mode-independent).

## Decisions

### Decision: Render into a dedicated offscreen `WKWebView`, not the live preview

A new `PDFExporter` (`@MainActor`) owns a freshly created `WKWebView` sized to a
print-page width, loads the same `rendered.html`, waits for it to settle, and
produces the PDF. Rationale:
- The live preview may not exist (Edit-only mode), and even when it does, its
  scroll position and find highlights are user state we should not perturb.
- A purpose-built web view gives a clean, full-document layout independent of the
  on-screen viewport.

Alternative considered: print the live `WKWebView` when available and fall back
otherwise. Rejected — two code paths, and the fallback (offscreen) must exist
anyway, so the live path adds complexity for no benefit.

The exporter's web view must still be hosted in a window: a window-less
`WKWebView` is treated as non-visible, so WebKit throttles it and the first load
can stall or `createPDF` can capture nothing (observed as "the first export of a
new window produced no file, a retry worked"). The exporter therefore parks its
web view in a borderless `NSWindow` positioned far off every screen
(`orderFrontRegardless`), so it never shows or takes focus but still renders.

### Decision: Load HTML the same way the preview does (temp file + read access)

To resolve relative images, mirror `MarkdownPreviewView.load`: when `baseURL` is
a file URL, write `rendered.html` to a temporary `.md2-preview-*.html` file in the
document directory and `loadFileRequest(_:allowingReadAccessTo: baseURL)`;
otherwise `loadHTMLString`. The temp file is deleted when the export completes
(success or failure). This reuses the proven access-granting approach and keeps
image behavior identical to the on-screen preview.

### Decision: Wait for engines to settle via `didFinish` + bounded delay

KaTeX/Mermaid/diagram rendering is asynchronous and has no single completion
callback. After `didFinish`, wait a bounded settle delay (≈1.5–2.5s) before
producing the PDF, with an overall timeout guarding against a page that never
loads. This matches the preview's own ~2.5s settle window for reflow. A precise
readiness probe (polling for absence of un-rendered diagram placeholders) is a
possible future refinement but is not required for a faithful result.

### Decision: Capture with `createPDF`, paginate with Core Graphics

`PDFPaginator.bands` computes the page bands (each at most a printable height,
ending at a safe break), then the exporter captures each band as its own vector
page via `WKWebView.createPDF(configuration:)` with `configuration.rect` set to
that band's region of the full content, and composes the captured pages onto A4
pages with Core Graphics. The web view is laid out at the printable width so
captured content maps 1:1 onto the page without down-scaling text. The band count
is bounded by a hard ceiling (`maxPages`).

Alternative considered and **rejected after it failed in practice**:
`WKWebView.printOperation(with:)` driving the offscreen web view (`NSPrintInfo`
with `jobDisposition = .save`). It produced a structurally invalid, ~700MB file
with millions of empty pages and no page-tree root — the print framework's
pagination of an offscreen, window-less `WKWebView` ran away. `createPDF` +
deterministic CG pagination avoids the print framework entirely; the pagination
math is bounded (`maxPages`) and unit-testable without a run loop.

### Decision: Content-aware page breaks via a JavaScript probe

Cutting at fixed intervals splits whatever lands on a page boundary (e.g. a text
line straddling two pages). Before capturing, the exporter runs a JavaScript probe
in the settled page that returns the document height plus the safe split offsets.
Because breaking *between* lines is safe, every line box contributes its top and
bottom edge (both sit in the inter-line leading, clear of glyphs) — so safe breaks
stay dense regardless of line spacing. Atomic blocks (code, tables, images,
diagrams, rules) must stay whole: their spans are merged and any candidate inside
one is dropped, leaving only their outer edges. `PDFPaginator.bands` ends each page
at the largest offset that fits.

An earlier probe treated every text line as an unsafe interval and merged adjacent
ones with a cushion; once the print density tightened line spacing, all lines
merged and safe breaks collapsed, so pages hard-cut mid-line. The edge-based probe
above avoids that failure mode.

### Decision: `DocumentStore.exportPDF()` owns the save panel; `PDFExporter` owns rendering

`exportPDF()` calls `flushPendingRender()` (so the PDF reflects the latest text),
presents an `NSSavePanel` restricted to `.pdf` with a default name derived from
`fileURL` (or `Untitled.pdf`), then hands `rendered.html`, `baseURL`, and the
chosen URL to a `PDFExporter`. The store retains the exporter for the lifetime of
the async operation and reports failures through `alert`. Export never mutates
`fileURL`, `isDirty`, or cancels autosave. A second invocation while an export is
still retained is a no-op, so a concurrent export can't replace and abandon the
first.

### Decision: A4 with print density; fail-closed on preparation errors

`PDFExporter` exports to **A4** with compact ~0.67" margins (a fixed, locale-
independent default), not the system paper size — the system default margins are
~1.5", which wastes most of the page. The rendered HTML is styled for on-screen
reading (a centered 860px column with ~58px side padding and a 16px/1.68 base
font); exporting that as-is double-margins the page and fits very little per page.
So before capture the exporter injects a print stylesheet that neutralizes the
content column padding/max-width (the page margin supplies the whitespace) and
tightens the base font, giving normal document density. The web view is laid out
at the printable width.

When the document is file-backed, the HTML is written to a temporary file in the
document directory and loaded with granted read access so relative images resolve.
If that write fails the export **fails** (`preparationFailed`) rather than falling
back to `loadHTMLString` — the fallback would silently drop relative images while
still reporting success, which is worse than a clear error.

## Risks / Trade-offs

- **Async engines may not be done when the fixed delay elapses** → use a delay at
  least as long as the preview's settle window (~2.5s) and bound it with an
  overall timeout; acceptable for v1. A readiness probe can tighten this later.
- **Offscreen web view must be retained until completion** → `DocumentStore`
  holds a strong reference to the live `PDFExporter` and clears it in the
  completion handler, preventing premature deallocation that would abort the load
  or print.
- **Writing to a sandbox-restricted location** → the save panel grants write
  access to the chosen URL; the exporter writes to that same user-selected URL,
  so no extra entitlement is needed.
- **Temp preview file collisions / leftovers** → reuse the existing
  `.md2-preview-*` naming with a unique id and delete on completion; the
  preview's existing stale-file sweep already tolerates these.
- **Large documents do WebKit/CG work on the main actor** → band capture and PDF
  composition are bounded by `maxPages`; acceptable for typical documents and
  consistent with the app's existing synchronous save path.
