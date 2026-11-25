# TODOS

The earlier backlog was reviewed on 2026-11-13 against main `51c74a2` after
PR #58. Priorities below order future work; they do not identify unresolved
release-blocking defects.
Each selected item needs a bounded design, an isolated implementation package,
non-author review and acceptance against its final source.

## Visual and interaction review (2026-11-25)

Reviewed against `eeb15a6`. Window sizes and occlusion were observed in the
native app. Text contrast, reflow and diagram dimensions were measured in
WebKit using the app's preview styles. Priority reflects the impact on the
task. Usage frequency has not been measured.

### First priorities

If the next iteration has room for two items, start with preview Find and
editing a paragraph from the preview. Together they cover finding a passage,
reading its context and correcting it in the source.

- [x] **P1 — Keep preview Find readable and clear of the document.** At a
  window width of 980 pt, opening Find covered the visible section heading
  and the first line below it. In dark appearance, ordinary body text had a
  contrast ratio of 1.87:1 on the current match and 1.18:1 on the other
  matches. Give the bar its own layout space in Read and Side by Side. Pair
  text and background colors for each appearance, outline the current match,
  and remove the horizontal padding that changes line breaks.
  **Verify** the first-line match in a short file and a mid-document match
  in a long file both remain visible and the scrollbar stays usable. Check
  both appearances against [4.5:1 for ordinary text](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).
  At 420 CSS px, searching for `任务` in `启动任务，核对任务状态。` repeated 50 times
  increased paragraph height from 753 to 779 px. All 100 matches should be
  highlighted with the original line breaks.

- [x] **P1 — Make half-screen reading and narrow previews usable.** A request
  for a 720 pt single-pane window stopped at 780 pt. Switching to Side by Side
  with the outline visible widened the window to 1046 pt. Let Write and Read
  fit in half of a 1440 pt display and collapse the sidebar when space is tight.
  Address two content cases in a 420 CSS px preview:
  - A 64-character hexadecimal hash in inline code widened the page to 589 px.
    Wrap a long inline token where needed. Verify the copied hash is exact,
    prose fits the pane, and wide tables and fenced code scroll within their blocks.
  - The [eight-node Mermaid flowchart](Tests/MD2CoreTests/MermaidOffscreenRenderingTests.swift)
    shrank from about 1106 to 372 px, leaving a nominal 16 px label at about
    5.4 px even when body text increased from 16 to 32 px. Offer an actual-size
    view with panning. Verify that every node can be read and Esc returns to
    the same place in the document.

- [x] **P1 — Edit the paragraph selected in the preview.** Cmd-double-click
  currently switches to Write using the reading position. The gesture omits
  the clicked location. Preview line numbers already support source navigation,
  but they are off by default. Route the gesture and an “Edit This Paragraph
  in Source” context-menu command to the clicked source block. Place the caret
  at the corresponding text where the mapping is reliable, or at the start of
  the block otherwise. **Verify** with line numbers hidden and an identical
  sentence in two paragraphs. Acting on the second occurrence must put the
  caret in the second paragraph before any text is changed.

### Further interaction improvements

- [x] **P2 — Show how to keep a folder preview open.** Selecting another file
  replaces the temporary document. With the tab bar hidden, the italic preview
  title is unavailable and the sidebar button still says “Open”. When the
  selection is the current temporary preview, label that button “Keep Document
  Open ↵” (“保留此文档 ↵”). **Verify** that clicking A then B reuses one preview,
  while pressing Return, using the button, or editing A keeps it open when B
  is selected. See the [folder workflow](Docs/FolderWorkflow.md).

- [x] **P2 — Let a writer hold a reference in place in Side by Side.**
  Scrolling and typing normally move the other pane. Add a per-window
  “Pause Synchronized Scrolling” control in Side by Side. **Verify** that a
  table stays visible on the right while the writer scrolls to a summary and
  types on the left. Resuming should align the panes once from the active pane
  and restore their usual bidirectional scrolling.

- [x] **P2 — Compare external changes before resolving a save conflict.**
  The ordinary conflict dialog offers “Keep My Version”, which resumes autosave,
  and “Reload from Disk”, which discards pending edits. Show the changed
  passages, label the editor and disk versions, and offer to save the editor's
  changes as a separate copy. **Verify** by editing one paragraph in Markdown2
  and another on disk. Both differences should be visible, writes to the
  original should stay paused during comparison, and saving a copy should
  leave both versions available. See the [document lifecycle](Docs/DocumentLifecycle.md).

- [x] **P2 — Give the status bar a hierarchy for reading and editing.** Word
  count, character count, line count, reading time, zoom, encoding, line
  endings and path currently share the same visual weight. Emphasize word
  count and reading time in Read, and caret line/column and selection counts
  in Write. Put encoding, line endings and the full path in a “Document Info”
  control. **Verify** in a narrow window with a long path and an active
  selection. The primary values should remain legible, the full path and
  format should be retrievable, and conversion progress and Cancel should
  remain directly accessible during conversion.

## Already delivered

The eight reliability/security repairs landed in PR #55. Portable image
attachments, Create Copy and literal case/word/selection find landed in PR #56;
source table operations and explicit paste landed in PR #57; document-session
remote-image permissions and offline export safety landed in PR #58. Keep their
existing safety, native Undo and regression gates; do not reopen them as missing
features. See the [daily-writing](Docs/Plans/daily-writing/PLAN.md),
[structured-editing](Docs/Plans/structured-editing/PLAN.md) and
[remote-resource](Docs/Plans/remote-resources/PLAN.md) contracts.

- [x] **P1 — Browseable local history and restore as a copy.** File → Browse Local
  History shows dated disk revisions and opens a selected revision as an
  independent copy. The copy preserves encoding, BOM and line endings and
  resolves shared attachments in the current folder. See the [history policy
  and verification coverage](Docs/DocumentLifecycle.md#本地历史版本).

- [x] **P1 — Real keyboard, Chinese IME and VoiceOver acceptance.** The
  maintainer completed the English and Simplified Chinese writing workflows
  with a physical keyboard and confirmed that Simplified Chinese Pinyin and
  VoiceOver passed. See the
  [acceptance record](Docs/Plans/native-input-acceptance/RESULTS.md),
  [acceptance plan](Docs/Plans/native-input-acceptance/PLAN.md),
  [findings](Docs/Plans/native-input-acceptance/FINDINGS.md), and
  [physical keyboard handoff](Docs/Plans/native-input-acceptance/HANDOFF.zh-CN.md).

## Next packages

- [x] **P1 — Stop the folder workflow from spawning a window per file.** Files
  and Quick Open live beside the editor in a Files | Outline sidebar. Click
  or press Space to skim in one replaceable native preview tab. Double-click,
  press Return, or edit to pin. The folder index refreshes after filesystem
  changes or on request, and the existing file verification and draft
  protection apply to every open. See the [folder workflow](Docs/FolderWorkflow.md).

- [x] **P2 — A lightweight folder workflow.** File → Open Folder shows a
  bounded Markdown tree for one explicitly selected folder. Quick Open filters
  filenames and relative paths, and opening a file reuses any existing document
  window. See the [scope, limits, refresh and link policy](Docs/FolderWorkflow.md).
  Directory content search and rename/link-impact handling need a subsequent
  bounded contract.

- [x] **P2 — Explain remote resource origins and blocked content.** The Remote
  Images details show origins and counts for supported HTTP(S) image references
  in the current rendered document. The sheet identifies incomplete inspections
  and explains that actual blocks and redirect destinations are unknown. The
  report is read-only and invalidated on reload or permission change. See the
  [inspection scope and permission policy](Docs/RemoteResources.md).

- [x] **P2 — Regular-expression find and replace.** Opt in from the source
  find bar. Regex supports captures, zero-width matches, frozen selection scope
  and a single Undo for Replace All. The bar reports invalid input and work
  limits. See [regular-expression matching and replacement](Docs/MarkdownEditing.md#regular-expressions-in-source).

- [x] **P2 — Native writing polish.** The Mode menu offers opt-in Typewriter
  Scrolling, and the toolbar help shows the current mode shortcuts. Switching
  modes preserves the source selection and working position. Narrow-window
  native fields, bilingual keyboard and VoiceOver operation, real Pinyin, and
  unchanged source and exports passed the
  [acceptance checks](Docs/Plans/native-writing-polish/RESULTS.md).

- [x] **P2 — Real-document compatibility corpus and targeted syntax improvements.**
  Added four original fixtures and checked source preservation, native outline
  navigation, preview, offline HTML and PDF. Fixed ordered list starts, links
  with balanced parentheses, fence language metadata, headings beside tables,
  and missing square-root signs in PDF. See the
  [acceptance record](Docs/Plans/real-document-compatibility/RESULTS.md) and
  [compatibility matrix](Docs/CompatibilityMatrix.md).

- [x] **P2 — Contributor and dependency documentation.** The
  [contributor guide](CONTRIBUTING.md) links the build and verification gates
  for a fresh checkout. The [third-party inventory](Docs/ThirdParty.md) records
  resource versions, sources and licenses. The release gate checks the notices
  in the signed app, and standalone HTML carries notices for its embedded
  resources. User-facing changes go in the [changelog](CHANGELOG.md).
  Confirm a private reporting route and its owner before adding `SECURITY.md`.

- [x] **P3 — Progressive direct editing with exact source mapping.** Preview
  edits one top-level single-line `$$…$$` formula through a native TeX dialog.
  Exact UTF-16 ranges preserve surrounding Markdown and line endings, and each
  edit is one native Undo step. Unsupported display formulas and ambiguous
  selections have a [source-editing route](Docs/MarkdownEditing.md#edit-a-formula-from-preview).

- [x] **P3 — Expose DOCX/EPUB conversion deliberately.** File → Export To offers
  DOCX and EPUB with a locally installed Pandoc. The save panel explains
  conversion limits, and the window supports cancellation while conversion
  runs. Conversion denies network access and preserves an existing destination
  on failure or cancellation. See the [user guide](Docs/RemoteResources.md#export-to-docx-or-epub)
  and [acceptance plan](Docs/Plans/docx-epub-export/PLAN.md).

## Follow-up from 0.9.0 verification

- [x] **Refresh the standalone P1 benchmark.** The runner uses the SwiftPM
  release targets and has a smoke test. The [benchmark notes](Docs/Benchmarks/v0.6.0/README.md)
  give commands for both current runs and the original 0.6.0 comparison.
- [x] **Improve recovery after an interrupted hard-linked save.** A verified
  interrupted write can resume in place after confirmation. See
  [save and recovery behavior](Docs/DocumentLifecycle.md#保存与恢复).
- [x] **Reduce layout cost when returning to deep positions in large documents.**
  Source restoration lays out through the destination viewport and uses the
  exact height for end-of-document clamps and proportional fallback.

## Explicitly deferred

- **Developer ID signing, notarization and stapling:** blocked on an Apple
  developer account/credentials, deferred by the maintainer. Do not make this a
  prerequisite for source builds, local installation or the items above. Resume
  with real signing/notarization and Gatekeeper verification when credentials
  are available; ad-hoc signing is not equivalent.
- Complex nested table edits, generalized rich-text import and attachment
  collection inside reference/container/HTML/diagram syntax require their own
  parser and source-preservation contracts. Current documented refusals are
  deliberate boundaries, not permission to weaken validation. Automatic updates
  and plugins likewise need explicit update-verification or file/network
  permission designs before entering the implementation queue.
