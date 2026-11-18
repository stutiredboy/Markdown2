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

- [ ] **P2 — A lightweight folder workflow.** Start with an explicitly opened
  directory, a file tree and quick open; directory search and rename/link-impact
  handling need a subsequent bounded contract. Decide root/symlink boundaries,
  indexing limits, excluded files, cancellation and external-change handling.
  Acceptance: index only the authorized scope without following an unapproved
  external target, keep large folders responsive, open ordinary Markdown files
  without duplication, and never silently rewrite or overwrite linked files.

- [x] **P2 — Explain remote resource origins and blocked content.** The Remote
  Images details show origins and counts for supported HTTP(S) image references
  in the current rendered document. The sheet identifies incomplete inspections
  and explains that actual blocks and redirect destinations are unknown. The
  report is read-only and invalidated on reload or permission change. See the
  [inspection scope and permission policy](Docs/RemoteResources.md).

- [ ] **P2 — Regular-expression find and replace.** Literal matching is complete;
  regex is an opt-in extension. First define source/preview scope, capture-group
  replacement, zero-length matches and an enforceable work/cancellation budget.
  Acceptance: malformed or pathological patterns fail visibly without blocking
  typing; Unicode/UTF-16, frozen selection scope and stale requests remain safe;
  Replace All shows its scope/count and is one Undo operation. Keep the literal
  search defaults unchanged.

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

- [ ] **P3 — Expose DOCX/EPUB conversion deliberately.** The bounded Pandoc
  backends exist; only PDF/HTML are in the Export menu. Decide dependency
  discovery, unsupported-content notices and destination/cancel UX before menu
  integration. Acceptance: test actual menu invocation with/without Pandoc,
  fail-closed network confinement, stale-document cancellation and preservation
  of an existing destination. Do not claim independent Word/EPUB readers are
  offline, or add automatic executable downloads.

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
