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

The initial priorities were preview Find and editing a paragraph from the
preview. Together they cover finding a passage, reading its context and
correcting it in the source.

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
  Keep the existing per-window pause control. Verify that scrolling to a
  summary and typing on the left holds the table in place on the right.
  Resuming from either pane must align the other pane once and restore
  bidirectional scrolling. A second window must still scroll independently.

  **Close only when all three native regressions also pass.** With sync paused,
  record the reference's top edge in the preview before editing. After the
  update settles, the same reference must still be visible and its top edge
  must be within 2 CSS px of its original viewport position.

  1. **Active Find result.** Find a word twice in the preview, advance to the
     second match, and leave Find open. Edit the first paragraph in the source
     so both matches survive. The second occurrence must remain highlighted
     as current. On `83a1ed2`, Find selected the first occurrence again and
     the second moved from y=273 to 4238 in a 573 px viewport.
  2. **A row inside a long table.** Read the row labeled `Record 60`, then
     insert 20 rows immediately below the header in the source. Locate the
     original record by its label after all 20 render. On `83a1ed2`, it moved
     from y=71 to 948 in a 653 px viewport.
  3. **The second of two large local images.** Scroll partway into the second
     image, then insert the document's first Mermaid block above both images.
     After the full preview reload and layout, the same part of the second
     image must be visible. On `83a1ed2`, its top moved from y=−90 to 878
     while the first image took its former position.

- [x] **P2 — Compare external changes before resolving a save conflict.**
  The ordinary conflict dialog offers “Keep My Version”, which resumes autosave,
  and “Reload from Disk”, which discards pending edits. Show the changed
  passages, label the editor and disk versions, and offer to save the editor's
  changes as a separate copy. **Verify** by editing one paragraph in Markdown2
  and another on disk. Both differences should be visible, writes to the
  original should stay paused during comparison, and saving a copy should
  leave both versions available. See the [document lifecycle](Docs/DocumentLifecycle.md).

- [x] **P1 — Make “Keep My Version” report the true save state.** Open an
  unmodified file containing `base`. Write `theirs` to it externally and
  invoke Save before the file watcher delivers the change. Choose **Keep My
  Version**. On both `eeb15a6` and `83a1ed2`, the document model cleared the
  conflict and reported a clean document while the editor held `base` and
  the original file still contained `theirs`.

  **Verify** this sequence in the document window. While the original still
  contains `theirs`, the window must show that the editor version needs
  saving. Once it reports the document saved, read the original file and
  reopen it. Both must show the chosen editor version, `base`.

- [x] **P2 — Give the status bar a hierarchy for reading and editing.**
  Reopened after PR #101. At 720 pt, the deferred-conflict button clips
  selection information that was fully visible on `8dac595`.

  **Reproduce.** Set the interface to English and open a 720 pt Write window.
  Use a document with 1,260 lines, each starting with `Row N ` followed by
  `word ` repeated 28 times. End the saved file with a remote image and allow
  remote images for this document so the status bar shows “Remote Images”.
  Append `Local draft edit.` as a new paragraph. Select from line 1000,
  column 124 to line 1120, column 114, then change the file externally
  while the editor has unsaved changes. Choose “Later”. On `9f65cb4`,
  the end position reads “Ln 112…” and the selection
  count ends at “37803 wor…”, hiding the 17,869 selected characters.

  **Verify** at the same width with “Remote Images” and “Autosave paused ·
  View conflict” both present. Both endpoints, the selected word count and
  the character count must be readable together. The conflict button must
  reopen the comparison. While the conflict is deferred the original must
  retain its external contents. Check that Read emphasizes word count and
  reading time, and Document Info exposes the full path of a deeply nested
  file along with its encoding and line endings.

  Repeat with a DOCX export in progress when the external write occurs.
  Verify that progress and Cancel are reachable while exporting. After the
  export stops and the user chooses “Later”, the full reason for stopping
  must be readable. The user must be able to dismiss the notice and reopen
  the conflict.

### Follow-ups from the 2026-11-26 recheck

The following cases reproduced on `9f65cb4` and on an earlier revision.

- [x] **P2 — Hold the visible table row when the header grows with scroll sync paused.**
  **Reproduce.** Open a two-column table with 150 numbered data rows in Side
  by Side. Use the toolbar to pause scroll sync. Scroll the preview until the
  first cell of `Record 60` is about 71 CSS px from the preview's top edge.
  Record its `getBoundingClientRect().top` as `y0`. Start each of these
  scenarios from the same `| Key | Value |` header and reading position.

  1. In the source, replace `Key` in one edit with
     `Key<br>Region<br>Office<br>Department<br>Owner`.
  2. Append each of the four `<br>` lines in a separate source edit. Wait for
     each new header line to render and measure before appending the next one.
  3. Apply the five-line header in one edit and restore `Key` in the next edit.
     Repeat six times, letting the layout settle and measuring after each edit.
  4. Put `Needle Spot` in the second column of `Record 35` and `Record 60`.
     Search in the preview, advance to the second match, pause scroll sync,
     and leave Find open. Record the top of the cell labeled `Record 60` and
     the top of its highlighted text. Repeat the four separate header edits
     from scenario 2.

  At `1f88d99` on a 2× display, the one-edit case moved the cell by +0.50 CSS
  px. The four separate edits ended at +3.50 CSS px, and the sixth restoration
  ended at +6.00 CSS px relative to `y0`.
  With Find active at `dbd5ff6`, both the cell and the highlighted text moved
  by +0.875, +1.750, +2.625 and +3.500 CSS px.

  **Verify** in the native split window. After each edit settles, locate
  `Record 60` by its cell text. It must still be visible and its top edge must
  be within 2 CSS px of that scenario's initial `y0`, including after the sixth
  restoration. In the Find scenario, require two matches and keep the second
  current and visible. After every edit, both the cell and its highlight must
  be within 2 CSS px of their respective positions before the first edit.
  While still paused, scroll the preview to a different record,
  record its top edge and edit the header again. The new record must stay
  visible within 2 CSS px of its own recorded position. Rerun the paused Find,
  table row and list item insertion, and Mermaid image reload cases, along
  with resuming sync and window isolation.

- [x] **P2 — Find text inside author highlights and respect its place in a sentence.**
  **Reproduce.** Enable highlight syntax and preview two paragraphs,
  `左==验收==右` and `普通验收`. Search for `验收`, then for `左右`. The first
  query finds only the plain occurrence. The second incorrectly selects
  the characters on either side of the highlighted word.

  **Verify** that `验收` yields two visible matches and Next and Previous
  visit both. Searching for `左右` must yield zero. Closing Find must leave
  the author's highlight visible.

- [x] **P2 — Make preview Find results inside a disclosure visible.**
  **Reproduce.** Preview
  `<details><summary>Summary</summary>collapsedkeyword</details>`.
  Leave it collapsed and search for `collapsedkeyword`. Find reports one
  match while the disclosure stays closed and the match has no visible area.

  **Verify** that every counted current match can be seen. If Find includes
  collapsed text, navigating to it must expand the disclosure and reveal the
  highlighted word. If Find searches visible text only, the collapsed
  fixture must yield zero. With the disclosure open, the same query must
  yield exactly one visible match in either case.

- [x] **P2 — Wrap bare hashes and long automatic links in a narrow preview.**
  **Reproduce.** Use 16 px body text and a 420 CSS px preview. Show
  `0123456789abcdef` repeated four times as one bare token. In a separate
  document, append the same token to `https://example.test/` as a bare URL.
  The page widths measured 601 and 749 CSS px respectively.

  **Verify** both documents at 420 CSS px. Each token must fit by wrapping,
  with no page-wide horizontal scrolling. Copying the hash or link text must
  preserve every character, and the link target must match the authored URL.
  Repeat with the backticked hash, a wide table and a fenced code block to
  confirm inline wrapping and block-local scrolling still work.

- [x] **P2 — Locate plain text immediately after an HTML block in the source.**
  **Reproduce.** With preview line numbers hidden, enter these three source
  lines with no blank lines between them.

  ```markdown
  Plain above
  <div>Mixed HTML</div>
  Plain after XYZ
  ```

  Right-click `XYZ` in the preview, then try Cmd-double-click at the same
  point. WebKit places the trailing text directly under `main`, so the
  paragraph lookup returns no source location.

  **Verify** each gesture independently in Read and Side by Side. The context
  menu must offer “Edit This Paragraph in Source”. Both that command and
  Cmd-double-click must place the caret at the clicked text on line 3 when
  the column can be mapped reliably, or at the start of line 3 otherwise.
  Acting on “Mixed HTML” must still locate line 2.

- [x] **P3 — Explain the conflict-copy limit for a symbolic link before naming the copy.**
  **Reproduce.** Create `Origin.md` containing `base` and a symbolic link
  `Alias.md` pointing to it. Open the alias, edit its text to `mine`, then
  write `theirs` to the target externally before autosave. Choose “Save
  Editor Copy…” in the conflict sheet. The sheet asks for a name and only
  rejects the source after confirmation.

  **Verify** that the sheet explains the ordinary-file requirement and the
  reason this alias is ineligible before asking for a filename. The link
  must still point to the same target, the target must contain `theirs`, the
  editor must retain `mine`, and the conflict must remain available for
  review with no copy created. Repeat via a regular file and verify that the
  editor copy succeeds. See the [copy policy](Docs/DocumentLifecycle.md#创建副本).

### Follow-up from the 2026-11-27 recheck

- [x] **P2 — Keep the latest reading position during a full preview reload.**
  **Reproduce.** In Side by Side with scroll sync paused, hold `Record 60`
  about 71 CSS px from the top of the preview. Use a 150-row table followed
  by `Closing note.` and 3,500 existing links to relative paths. Insert
  the document's first Mermaid block after `Closing note.`. In the old
  page's capture callback, send a native pixel wheel event and confirm it
  reached the old page and moved it. On `b4f6d87`, `Record 60` moved from
  70.95 to 329.95 CSS px on the old page, then returned to 70.95 CSS px
  after the new page drew the diagram.

  **Verify** in a native window. Require a trusted wheel and an actual scroll
  in the old page after capture. Once the replacement page and SVG settle,
  locate the same visible record by its text. Its top edge must be within
  2 CSS px of the position after the wheel. Repeat with two effective wheel
  events and use the position after the second. Also insert the first diagram
  above the table and keep the same record in place as the page height above
  it changes. A full reload without scrolling must keep the original position.
  For a live edit that adds four lines to the table header, the same wheel
  gesture must keep the post-scroll position on the same page. For Find, queue
  Previous after the old page captures the second match and require the new
  page to show the first match, `1 of 2`.

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
