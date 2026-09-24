# TODOS

Tracked work considered and explicitly deferred from in-flight changes. Each item carries its reasoning so a future picker-upper has the context.

## Headless-GUI CI lane for `MD2_RUN_GUI_TESTS`

**What:** Add a macOS GUI-capable CI runner that runs `MD2_RUN_GUI_TESTS=1 swift test` on every PR.

**Why:** All regression guards for the PDF/print Mermaid fix (and the existing offscreen/E2E tests in `Tests/MD2CoreTests/`) are GUI-gated and skipped by plain `swift test`. CI never runs them, so a silent regression — dark/inverted PDFs, disappearing Mermaid diagrams, clipped flow/sequence/KaTeX media — lands green unless a human ran the GUI suite. The fixes fail SILENTLY (no error thrown), which is exactly the failure class CI-blindness makes dangerous. The `settings-window-presentation` guard from `fix-settings-window-on-launch` adds a second reason: all its behavioral evidence was gathered on macOS 26, and this lane — landing on `macos-15` runners, the same image `release.yml` builds on — is the planned place to verify the suppression behavior on macOS 15 itself.

**Current state (the in-scope guard shipped with the fix):** A pre-ship checklist note in CLAUDE.md's testing section plus load-bearing comments at the two silent-failure lines in `PDFExporter.swift` (the `printStyleScript` selector and `hostWindow.appearance = .aqua`). These rely on humans following the note.

**Pros:** Every PR automatically runs the silent-failure guards; no reliance on human memory.
**Cons / cost:** Real macOS CI infra — a self-hosted runner with a window-server session, or a macOS-cloud runner; non-trivial setup and maintenance. (human: ~1-2 days / CC: ~30min)

**Depends on:** nothing blocking; pure CI infrastructure work, independent of any code fix.

**Start here:** pick a runner strategy (self-hosted mac with a `loginwindow`/`launchctl` GUI session vs. macOS-cloud), wire `MD2_RUN_GUI_TESTS=1` into the test step, and gate merge on it.

## Click a line-number gutter number to jump to that line

**What:** Make gutter numbers interactive. In the editor, clicking a number selects that source line and scrolls it into view; in the preview, clicking a block's number opens/selects that line in the editor pane (relevant in Side by Side and on mode switch).

**Why:** Completes the "locate" story the line-numbers feature starts. Preview numbers are block-start annotations by design (a 400-line code block shows one number), so precise in-block location has no affordance today; click-to-jump is the deferred follow-up named in the feature's proposal and Open Questions.

**Current state:** The `add-line-numbers` change ships gutters as display-only (`pointer-events: none` in the preview; plain drawing in the editor inset). No interaction surface exists.

**Pros:** Turns passive numbers into navigation; directly answers "I see line 214 in the preview, take me there"; small AppKit hit-test + focus-routing change.
**Cons / cost:** New interaction semantics must coexist with existing editor gestures (Esc, find, mode shortcuts — the reason the feature deferred it); preview-side click needs a focus handoff from WKWebView to the editor. (human: ~2-4h / CC: ~30-60min)

**Depends on:** `add-line-numbers` implemented and archived (the gutter geometry and preview spans are the substrate).

**Start here:** editor side: hit-testing `x < textContainerInset.width` in `MarkdownSourceTextView` (mouseDown override, mirroring the existing `performKeyEquivalent` interception pattern); preview side: make spans `pointer-events: auto` with a JS bridge to the coordinator, reusing the existing `evaluateJavaScript` round-trip pattern.

## Number nested preview blocks (list items) in the gutter

**What:** Emit `data-md2-source-line` on regular list items (today only footnote `<li>`s carry it) and render a gutter number beside each `<li>` in the preview.

**Why:** A 60-item list is the same locate problem as a 400-line code block: one number for the whole block, nothing for the items inside. The feature's Open Questions deferred it rather than expanding the renderer mid-feature.

**Current state:** `MarkdownRenderer` stamps top-level blocks only (plus footnote `<li>`s, `MarkdownRenderer.swift:980`); `MetadataInvariantTests` invariant-tests the coverage and documents the footnotes/bibliography wrapper exceptions.

**Pros:** Fills the biggest remaining coverage gap in the preview gutter; the overlay mechanism (direct-children spans) extends naturally to `li` anchors.
**Cons / cost:** Renderer change (Decision 6 of the feature said "no renderer change" — this deliberately revisits that for a scoped case); the metadata invariant corpus and tests need extending; exported-HTML neutrality must be re-verified (attribute-only emission is safe — it ships today for footnotes); an open product call: is a number on every list item signal or noise? (human: ~1-2 days / CC: ~2-3h)

**Depends on:** `add-line-numbers` implemented first; a product decision on per-item density (maybe limit to items above a length threshold, or multi-line items only).

**Start here:** extend the top-level block emitter to stamp `li` elements (mirroring the footnote `li` path at `:980`), update `MetadataInvariantTests`' exception list, then extend `__md2RenderLineNumbers`' eligibility rules to nested `li` anchors.

## GUI suites crash when run in one combined invocation (window-animation teardown)

**What:** Running `FindFindDeleteGUITests` and the line-number GUI suites (`EditorLineNumberGutterGUITests` / `LineNumberGutterGUITests`) in the SAME `xctest` process segfaults: `objc_release` on a deallocated `_NSWindowTransformAnimation` during a CoreAnimation transaction commit, right when the suite after the find tests creates its own host window.

**Why:** Every documented per-surface command (CLAUDE.md guards, task 5.2) passes, so this hides today — but the headless-GUI CI lane, when built, will be tempted to run one combined `MD2_RUN_GUI_TESTS=1 swift test` invocation and will inherit a deterministic, confusing signal 11. Found by /qa on 2026-09-18 (2/2 deterministic reproductions with the 5-suite filter; each suite green alone; report: `.gstack/qa-reports/qa-report-markdown2-add-line-numbers-2026-09-18.md`).

**Fix shape:** either make each guard suite its own CI invocation step (cheap, matches today's documented convention), or harden the window teardown in the window-hosted tests (close windows without ordering animations, or spin the runloop to let `_NSWindowTransformAnimation` complete before the next suite starts — the same teardown fragility the 2026-08-20 QA documented).

**Depends on:** nothing; must be resolved before (or at the same time as) the headless GUI CI lane.

## Pandoc 3.11 broke `testRealConversionDeletesPartialOutputOnFailure`'s premise

**What:** The test expects pandoc to FAIL when the destination's parent directory does not exist; pandoc 3.11 now creates missing parent directories for `--output` (verified: `pandoc doc.md -t docx -o missing-subdir/out.docx` → exit 0, file created). The test fails deterministically on machines with pandoc 3.11 while passing wherever older pandoc is installed.

**Why:** A green local run and a red CI run (or vice versa) will disagree purely on installed pandoc version — an environment-flake trap. Found by /qa on 2026-09-18; the failure was present at that session's baseline (not caused by any in-flight change).

**Fix shape:** keep the partial-output-deletion guarantee tested but trigger failure via a mechanism no pandoc version can override — a read-only parent directory (chmod 0500) as the destination's parent — and assert the conversion fails and no partial file survives. Note: `PandocConverter` may also want to pre-validate the destination directory so the app gives a clean error instead of relying on pandoc's failure.

**Depends on:** nothing; one test edit plus optionally a converter guard.

## Pre-scan doesn't traverse containers (forward `\ref` into quoted/list equations unresolved)

**What:** Make `collectCrossReferenceLabels` (the whole-document pre-scan that pre-registers equation/figure/table numbers) walk blockquotes and dedented list content exactly as the render walk does, so labels inside containers are registered and forward `\ref{}`s to them resolve.

**Why:** The render walk descends into blockquotes (recursive render) and dedented list content; the label pre-scan (`Sources/MD2Core/MarkdownRenderer.swift:1452`) checks only fences, indented code, top-level math, and tables. An equation inside a blockquote renders numbered, but a `\ref{}` appearing earlier in the document stays a dead link, and numbering can disagree when nested equations precede top-level ones. Pre-existing for `$$` blocks; bare `\begin{env}` blocks inherit it. Surfaced by the Codex outside voice during the `add-latex-math-compat` eng review (2026-09-24) and documented there as a declared boundary rather than fixed.

**Current state:** The change's matrix boundary text scopes the numbering/`\ref{}` guarantee to top-level blocks, and a test pins the quoted-env limitation.

**Pros:** Forward references resolve everywhere; numbering is consistent in all containers; the pre-scan and render walk share one traversal shape.
**Cons / cost:** Traversal rework in the cross-reference path plus nested-numbering tests; must keep `resetCounters()` rewind semantics intact so render-walk numbers stay identical. (human: ~1 day / CC: ~1-2h)

**Depends on:** nothing; independent of the latex-math change (which only documents the limitation).

**Start here:** extract the render walk's container traversal (blockquote recursion, list dedent) into a shape the pre-scan can share, then assert pre-scan/render numbering parity for documents with equations inside containers.

## Left-to-right delimiter ownership scan (inline pipeline)

**What:** Replace the independent inline passes for code/math (`protectCodeSpans`, `protectInlineMath`, and the new `protectInlineParenMath`) with one left-to-right scan that establishes delimiter ownership by position, then applies each delimiter's own rules.

**Why:** Independent sequential passes cannot establish ownership. A `$...$` span inside a prospective `\(...\)` span is claimed first, and its protection token (`\u{E000}MD2-<n>\u{E000}`, `MarkdownRenderer.swift:2522`) restores as nested HTML — the outer math span's `textContent` then drops the inner markup, silently altering valid input (`\text{$x$}` reaches the engine as `\text{x}`). The same class exists today for code spans inside `$...$` math. Demonstrated against the bundled KaTeX by the Codex outside voice during the `add-latex-math-compat` eng review (2026-09-24).

**Current state:** Declared boundary in the change's design (cross-delimiter risk text) plus a test pinning current behavior (span produced, inner span nests on restore, no crash). That test is the regression baseline for this refactor.

**Pros:** The verbatim-TeX guarantee holds for every nesting combination; removes the whole silent-alteration class rather than one instance; one ownership scanner replaces N passes whose order is only comments.
**Cons / cost:** Touches the most regression-sensitive inline machinery in the renderer; every existing math/code-span test needs re-verification against the new scanner. (human: ~2-3 days / CC: ~2-4h)

**Depends on:** `add-latex-math-compat` landing (its boundary test is the before-state proof).

**Start here:** scan once for code spans and both math delimiter pairs in reading order; the earliest opener owns the span; apply the matched delimiter's guards (currency/`$$`/whitespace rules for `$`, none for `\(`).
