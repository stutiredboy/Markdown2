# TODOS

Reassessed on 2026-11-13 against main `51c74a2` after PR #58. Priorities below
order future work; they do not identify unresolved release-blocking defects.
Each selected item needs a bounded design, an isolated implementation package,
non-author review and acceptance against its final source.

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

- [ ] **Refresh the standalone P1 benchmark.** The runner for the 0.6.0
  measurements compiles its own list of app sources, which has drifted from
  the current editor and typography code. Update the runner or document how
  to reproduce those measurements at the matching revision. The Swift test
  suite and release workflow still check the render and HTML export
  main-thread heartbeats.
- [ ] **Improve recovery after an interrupted hard-linked save.** The draft
  is persisted before an in-place write so edited text remains recoverable.
  If the process stops mid-write, the linked paths can temporarily expose
  partial bytes. Design how to reconcile those paths from the recovery record.
- [ ] **Reduce layout cost when returning to deep positions in large documents.**
  TextKit still measures the wrapped document for nonzero scroll clamps. Keep
  the exact reading position and caret while reducing layout work in that path.

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
