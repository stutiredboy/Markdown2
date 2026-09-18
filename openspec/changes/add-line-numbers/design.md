## Context

Two independent surfaces show a document, and neither exposes line numbers today.

**Editor** (`Sources/MD2App/MarkdownEditorView.swift`) — an `NSViewRepresentable`
that builds a TextKit 1 stack by hand: `NSTextStorage` → `CodeBlockLayoutManager`
(a custom `NSLayoutManager` that draws full-width code bands) → `NSTextContainer`
→ `MarkdownSourceTextView` (a private `NSTextView` subclass), all inside an
`NSScrollView` whose clip view already posts `boundsDidChange` notifications
through the coordinator. There is no ruler of any kind. Two facts make this
feature cheap:

- `textView.textContainerInset = NSSize(width: 58, height: 48)` (line 124) already
  reserves 58pt of empty space left of the text. Only the **height** is read
  elsewhere (viewport anchoring at 978, content measurement at 1254), so the
  width is free real estate.
- The offset↔line helpers already exist and are unit-tested:
  `lineNumber(forCharacterIndex:in:)` (987), `characterRange(ofLine:in:)` (1123),
  `lineBoundingRect(line:in:)` (1102), `topVisibleLine(in:)` (1004).

Line heights vary (paragraph styling uses `lineSpacing = 4`, `paragraphSpacing = 7`;
headings are 17–30pt), so any gutter must position per line fragment, not per
fixed row.

**Preview** (`Sources/MD2App/MarkdownPreviewView.swift`) — an `NSViewRepresentable`
around `WKWebView`. Two distinct style layers matter here, and the distinction is
the whole export-safety story:

1. The **shared document CSS** embedded in `MarkdownRenderer.htmlDocument(...)`.
   This string *is* `rendered.html`, which both the PDF exporter and the HTML
   exporter consume. Anything added here ships in exports.
2. A **preview-only `WKUserScript`** injected at document end. It owns the
   front-matter hide rule (`html.md2-hide-front-matter` +
   `window.__md2SetFrontMatterVisible`), the find highlighter
   (`window.__md2Find`, a `TreeWalker` over `document.body` text nodes that
   rejects only `SCRIPT`/`STYLE`/`MARK`), and the broken-image styling. Its
   comment states the contract: injected only into the preview web view, so
   exported PDFs and prints are unaffected.

The enabling metadata is already there: `MarkdownRenderer` tags **every top-level
block** with `data-md2-source-line` / `data-md2-source-end-line`, unconditionally,
and `MetadataInvariantTests` asserts the coverage holds across the whole
conformance corpus. Two structural notes matter for scoping: nested `<li>`s do
**not** carry the attribute (only footnote `<li>`s do), and per-block boxes like
`<pre>` set `overflow-x: auto`, which would clip any number positioned outside
them.

Live updates in Side by Side replace `main.innerHTML` through
`window.__md2ApplyContent`, which destroys anything a previous pass injected.

The Settings pattern is established: `@Published var x: Bool { didSet { … } }`
loaded with a nil-check default in `AppSettings.init`, `L10nKey` cases with
English + Simplified Chinese strings, and `Toggle(settings.text(.key), isOn:)`
rows in `SettingsView`. The precedent for a preview-affecting preference is
`showsFrontMatter`: state on `ContentView`, pushed into the preview, applied by
flipping a class with no re-render or reload.

## Goals / Non-Goals

**Goals:**

- Two independent, persisted, **default-off** preferences — editor and preview —
  that can both be on at once.
- An editor gutter that numbers each logical line exactly once, staying aligned
  under soft wrapping, variable line heights, editing, and scrolling.
- A preview gutter that shows, beside each rendered block, the source line the
  block starts on, using the same numbering as the editor so a number read in
  the preview is the line to open.
- Toggling is instant and never re-renders or reloads the document.
- Line numbers cannot reach exported PDF, print, or exported HTML — by
  construction, not by cleanup.

**Non-Goals:**

- Numbering nested preview blocks (list items, paragraphs inside blockquotes).
  List items carry no source-line metadata today, so this would require a
  renderer change; deferred (see Open Questions).
- Clicking a gutter number to select or jump to that line.
- Per-visual-line numbering in the preview — blocks are numbered by their start
  line only, because rendered blocks are not source lines.
- Relative numbers, current-line emphasis, or numbers restricted to code blocks.
- Any change to the document's text, selection, find semantics, or exports.

## Decisions

### Decision 1: Two independent `Bool` preferences, not a scope enum
Add `showsLineNumbersInEditor` and `showsLineNumbersInPreview` to `AppSettings`
(keys `MD2.ShowsLineNumbersInEditor` / `MD2.ShowsLineNumbersInPreview`, both
defaulting to `false` on a missing key).

- **Why:** "both scopes can be on at once" is the natural state of two
  independent booleans, so the requested behavior needs no extra modeling, and
  the Settings UI is two checkboxes. It mirrors the existing
  `showsOutlineByDefault` property exactly (published, `didSet` → `UserDefaults`,
  nil-check default in `init`).
- **Alternative — a single enum (`off` / `editor` / `preview` / `both`):** cannot
  be presented as two independent toggles and forces a four-way picker for what
  users think of as two switches. Rejected.
- **Alternative — an `OptionSet` bitmask:** the same information with more
  machinery, and it encodes poorly in `UserDefaults`. Rejected.

### Decision 2: The editor gutter is drawn inside the text view's existing left inset
`MarkdownSourceTextView` overrides `draw(_:)`, and after `super.draw(_:)` draws
the line numbers for the line fragments intersecting the dirty rect, within
`x ∈ [0, textContainerInset.width)`. No ruler, no new view, and **no change to
any geometry**.

- **Why:** zero layout impact. Because `textContainerInset.width` is 58pt and
  untouched elsewhere, the gutter is pure empty space that already exists. The
  text container keeps its exact width, so enabling or disabling numbers cannot
  re-wrap the document, shift the reading column, or disturb the mode-switch
  anchor. It also sits *inside* the vertically scrolling document view, so
  numbers scroll with their lines and need no scroll synchronization at all —
  AppKit redraws newly exposed regions on its own.
- **Why 58pt suffices:** five-digit line numbers at the existing body font cost
  well under 58pt, so no dynamic sizing is needed.
- **Alternative — an `NSRulerView` as `scrollView.verticalRulerView`:** the
  textbook AppKit idiom, and the first candidate. Rejected because the ruler
  consumes clip-view width, which narrows the text container and **re-wraps the
  whole document** the moment numbers are enabled — while also requiring its own
  scroll/height plumbing. Trading a reflow of the document for a gutter is a bad
  bargain when the space already exists.
- **Alternative — a sibling `NSView` beside the scroll view:** must manually
  replicate vertical scroll sync and content-height tracking. Rejected.

Drawing per line fragment is what makes Decision 3's "one number per logical
line" true and keeps numbers aligned to variable line heights. Two mechanical
notes the draw must honor:

- **The fragment query uses the container's width, not the strip's.** The
  gutter strip lies left of the text container (container origin x = 58); a
  dirty rect limited to the strip translates into container coordinates that
  intersect no glyphs. The draw enumerates fragments over the dirty rect's
  *vertical interval extended across the full container width* (the same
  origin conversion `topVisibleLine` performs at MarkdownEditorView.swift:1012)
  and then clips painting to the strip.
- **Line numbers are carried incrementally across the pass.** Fragments arrive
  in document order; the draw carries `(lineNumber, lastScannedOffset)` forward
  and scans each inter-fragment gap once — one O(documentLength) pass per
  redraw, not O(visible × documentLength) independent scans of the
  `lineNumber(forCharacterIndex:)` helper (which stays for tests and
  single-shot callers).

### Decision 3: A soft-wrapped line is numbered once
A line is numbered when a line fragment **starts** at that line's first
character; continuation fragments are skipped, so a paragraph wrapping across
four visual rows shows a single number at its first row.

- **Why:** the number identifies a *source* line, and a wrapped row is the same
  source line. Numbering each visual row would produce repeated or misleading
  numbers and break the "read a number in the preview, open that line in the
  editor" contract.

Two parity rules complete the contract:

- **The trailing empty line is numbered.** A document ending in `\n` has a
  final empty line, which TextKit 1 presents as the layout manager's
  `extraLineFragment` (no glyphs). When that fragment is valid it is numbered
  like any other line, so the gutter's last number always equals the line
  count the status bar, find, and outline report
  (`lineNumber(forCharacterIndex:)` already counts it — see its doc comment at
  MarkdownEditorView.swift:985).
- **The numbering convention is the renderer's.** `normalizedMarkdownLines`
  (String+Markdown.swift:4) treats LF, CRLF, and bare CR alike as one line
  break when it numbers blocks for `data-md2-source-line`. The new pure
  "which lines get a number" helper adopts that convention (not raw `\n`
  counting) so the preview and editor agree on every document, including
  bare-CR files. Existing helpers keep their current behavior; only the new
  helper changes convention.

### Decision 4: The preview gutter is an absolutely-positioned overlay inside `main`, with digits as CSS generated content
`window.__md2RenderLineNumbers()` builds (or rebuilds) a single
`<div class="md2-line-gutter" aria-hidden="true">` inside `<main>`, holding one
empty `<span data-md2-gutter="42">` per eligible top-level block, each
absolutely positioned against the block's top. Eligibility is explicit:

- **Selection is direct children of `main`** (`main.children` filtered by
  `data-md2-source-line`), never a subtree `querySelectorAll` — footnote
  `<li>`s carry the attribute too (MarkdownRenderer.swift:980), and a subtree
  sweep would number them in addition to their section.
- **Blocks with a zero rect are skipped.** The hidden front-matter block is
  `display:none` (MarkdownPreviewView.swift:157), and hidden elements report a
  zero `getBoundingClientRect()` — numbering it would pin a garbage number at
  the document top.
- **The footnotes and bibliography wrapper sections get no number.** They are
  documented wrapper exceptions in `MetadataInvariantTests` (their entries'
  metadata lives on the `<li>`s, and bibliography entries come from a `.bib`
  file, not document lines). The visible digits come from
  `::before { content: attr(data-md2-gutter) }`.

- **Why an overlay and not per-block `::before`:** blocks such as `<pre>` set
  `overflow-x: auto`, so a pseudo-element positioned outside them is clipped and
  would scroll away with the code. An overlay sibling of the blocks is immune.
- **Why generated content rather than text nodes:** the preview's find walks
  `document.body` text nodes with a `TreeWalker`. Real text nodes for the digits
  would be matched by find (searching `42` would hit the gutter) and would be
  merged by `clearFind`'s `parent.normalize()`. Generated content is not in the
  text node tree, so find, selection, and copy stay untouched.
- **Why a dedicated `data-md2-gutter` attribute:** the anchor and scroll-sync
  code selects `[data-md2-source-line]`; giving the overlay its own attribute
  guarantees it cannot be picked up as an anchor target.
- **Why `position: absolute` inside `main`:** the overlay is laid out relative to
  `main`'s padding box with `getBoundingClientRect()`, so the page scroll moves
  numbers and content together and no scroll listener is needed.

Regeneration is a single idempotent entry point re-run on: script load,
`__md2ApplyContent` (the Side by Side live swap destroys the layer), window
resize, and a `ResizeObserver` — observing **`main`'s top-level blocks**, not
just `main`: math and diagram rendering settle asynchronously, and a block can
grow while another shrinks by the same amount, leaving `main`'s own box
unchanged while every number below the pair goes stale. Watching the blocks
the gutter positions against closes that blind spot declaratively (no timers,
no debounces).

Visibility is a class on `documentElement` (`md2-line-numbers`), matching the
existing `md2-hide-front-matter` idiom, so toggling is a class flip.

### Decision 5: The preview reserves gutter space in pure CSS
A single custom property (`--md2-gutter-width`, `0` when off, `G` when on)
drives both where numbers sit and how much space is reserved — as two CSS
declarations, with no JavaScript width function:

```css
html.md2-line-numbers main {
  padding-left: max(clamp(28px, 4vw, 64px), var(--md2-gutter-width));
}
.md2-line-gutter span {
  left: max(clamp(28px, 4vw, 64px) - var(--md2-gutter-width), 0px);
}
```

The reservation decision is a pure function of viewport width *computed by the
layout engine*: when the existing clamp padding can host the gutter (`clamp` ≥
G; the cap is 64px and G ≈ 46px for five digits), `max()` keeps today's padding
and **nothing reflows**; on narrower windows the padding is raised by at most
G − 28px inside the existing `width: 100%` border-box, so the column still
shrinks to fit and no horizontal scrolling can appear. The JS keeps only the
per-span vertical `top` (JS never needs to know the width).

- **Why CSS rather than a JS function of `innerWidth`:** every input to the
  decision — the `clamp()`, the border-box, the max-width — is already CSS
  (`MarkdownRenderer.swift:1810`). One CSS formula cannot drift from a
  duplicated JS copy (drift manifests as overlap or dead space at specific
  window widths), and the layout engine recomputing it every pass makes
  oscillation impossible by construction — the same guarantee the JS approach
  sought, with less machinery.
- **Why the column keeps its `max-width` and centering:** the spec requires the
  wide-window cap and balanced margins to survive; the raise applies inside the
  existing box, so no horizontal scroll can be introduced. With numbers off the
  class is absent and the base rule applies byte-identically.

### Decision 6: The renderer is not modified, and nothing re-renders on toggle
No `RenderConfig` flag, no renderer change. Toggling the editor invalidates the
text view's display; toggling the preview flips a class on the layer that is
already built.

- **Why:** `data-md2-source-line` is emitted unconditionally and is
  invariant-tested, so the metadata cost is already paid. Displaying it is a view
  concern. Adding a render flag would put a display preference inside the pure
  `Sendable` renderer, change the exported HTML for everyone, and force a
  full-document re-render on every toggle — which the Side by Side spec's
  "typing stays responsive" requirement argues against.
- **Alternative — `<span class="lineno">` elements emitted by the renderer:**
  would appear in exported HTML and PDF, needing an explicit strip step. Rejected;
  export safety by construction is worth more than the convenience.

### Decision 7: Settings gets two toggles; the toolbar gets a two-item menu
Settings ▸ General gains a labeled group with the two toggles. The toolbar
control beside the outline button is a `Menu` with two checkmarked items (Edit,
Preview) rather than one button.

- **Why not a single button:** one boolean cannot express two independent scopes.
  A single toggle would have to either overwrite the scope the user is not
  looking at, or guess in Side by Side where both panes are visible. A menu makes
  both scopes explicit and impossible to clobber by accident.
- **Why not Settings only:** the request asks for a control at hand; a menu is
  one click to open and one to flip, and it writes the same preferences, so
  Settings and the toolbar can never disagree.

### Decision 8: Localization follows the existing `L10n` pattern
New `L10nKey` cases with English and Simplified Chinese strings in the existing
dictionaries — the group label, the two scope labels, and the toolbar help text.

## Risks / Trade-offs

- [Gutter drawing on very large documents] → drawing is limited to the dirty
  rect, and `enumerateLineFragments(in: dirtyRect)` bounds the work to visible
  lines; cost is proportional to the viewport, not the document.
- [Numbers desyncing during IME composition or programmatic edits] → the gutter
  strip is invalidated **explicitly**, because there is no existing
  view-level invalidation to hook: text redraws today are TextKit-internal and
  glyph-rect-scoped (they start at the container origin and never cover the
  strip). When numbers are on, the draw invalidates the strip
  (`x ∈ [0, textContainerInset.width)`) at the shared edit choke points —
  after `MarkdownTextStyler.apply(to:)` (`:138` load, `:196` programmatic
  replacement, `:1209` typing), in `textDidChange`, and in `updateNSView` when
  `showsLineNumbers` changes. Scrolling needs nothing extra: exposed regions
  arrive as full-width dirty rects.
- [Preview numbers drifting while math/diagrams render asynchronously] → the
  `ResizeObserver` on `main` re-runs the idempotent pass once heights settle.
- [The gutter leaking into exported PDF or HTML] → the code lives in the preview
  `WKUserScript`, which the PDF exporter's own web view and the HTML builder never
  receive. A GUI-gated test asserts the export path produces no gutter artifacts.
- [Find matching gutter digits] → digits are generated content, not text nodes.
  A GUI-gated test searches the preview for a gutter-only number and asserts no
  match.
- [A document re-wrapping when the preview reserves gutter space on a narrow
  window] → the reservation applies only while numbers are on and is derived from
  viewport width; with numbers off, the layout is exactly today's. Wide windows
  use pre-existing margin and do not reflow at all.
- [Gutter numbers colliding with code-block bands in the editor] → bands are
  drawn inside the text container (`x ≥ inset`) while the gutter stays below
  `inset`; the two cannot overlap. Verified visually in the GUI lane.
- [Two toolbar scopes reading as clutter] → both items name their surface and
  mirror the Settings toggles one-to-one.

## Migration Plan

No data migration. Both preference keys are absent for existing users and
resolve to their `false` default, so the app behaves exactly as it does today
until a user opts in. Rollback is deleting the two keys and their wiring; nothing
else depends on them, and no persisted artifact (document, export, or recent-file
state) records line-number state.

## Open Questions

- Should nested blocks be numbered in the preview? List items carry no
  `data-md2-source-line` today, so this needs a renderer change and a decision
  about whether numbering every list item is signal or noise. Deferred.
- Should clicking a gutter number select that line in the editor (and scroll it
  into view)? A natural follow-up for the "locate" goal, deliberately out of
  scope here because it adds interaction and focus-routing behavior that the
  editor's existing gestures (Esc, find, mode shortcuts) would need to account
  for.
- Should the current caret line get emphasis in the gutter? Deferred; it would
  couple the gutter to caret movement rather than to text changes alone.
