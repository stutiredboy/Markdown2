# Daily writing: portable attachments, copies, precise find

Status: implementation authorized; work-package design and acceptance contract.
Baseline: `aac08c90cae5c0d8c11652b9278adafd76198c36` (PR #55 merged).

## Product outcome and priorities

Complete a normal writing task: insert local pictures, keep the document and its
assets portable, preserve a draft as a separate file, and replace exactly the
intended text. Source Markdown remains ordinary, editable text.

| Package | Priority | Deliverable | Required acceptance |
| --- | --- | --- | --- |
| A: portable attachments | First | Copy dropped/pasted image files into the configured relative attachment folder by default; explicit link-in-place option; collect supported existing local image references; report missing or unsupported resources. | Copy the complete document directory elsewhere, remove access to the original fixture, reopen and render every collected image. Preserve source syntax outside rewritten destinations. Missing, invalid, remote and unsupported references stay intact and are reported. |
| B: create copy | First | File > Create Copy… creates a new Markdown file beside an existing local document from its current in-memory text. Clearly explain that attachments are shared, not duplicated. Open the new file independently. | Preserve encoding, BOM and line endings. Original URL, disk bytes, dirty state, undo and recovery identity remain unchanged. No existing entry is overwritten. Cancel and failure create no apparent successful copy. |
| C: precise find | Second | Case-sensitive and whole-word options; source selection scope; replace-all states scope and count and is one undo operation. | Source and rendered searches honor matching options. A frozen source selection bounds replacements as lengths change. Hidden-bar navigation, mode changes, multiple windows and native field ownership still work. Every control fits 360 pt in English and Chinese. |

The copy feature deliberately keeps the copy beside its source so relative image
links remain valid. It is not Save As or an attachment bundle. An untitled draft
must first be saved; the UI explains this instead of silently saving the original.
An existing conflict does not prevent copying the current in-memory text, but
the original conflict remains unresolved. Missing sources, unrepresentable
encodings and composition-in-progress must be handled explicitly without
modifying the original. After success, an explicit Open Copy action opens an
independent store without adopting a stale recovery draft at the new path.

Case and word options are document-local. Default matching remains case- and
diacritic-insensitive. Selection scope refers to an explicit source selection;
rendered selections are not guessed back into source ranges. Switching to Read
must not silently turn a selection-only replace into a whole-document replace.
Regular expressions are deferred.

Whole-word boundaries use Unicode letters, marks, numbers and connector
punctuation (including underscore), not natural-language Chinese segmentation.
Matches cannot split a grapheme cluster. Case sensitivity changes only case
matching; the existing diacritic-insensitive behavior remains. Non-find source
edits invalidate an active selection scope with a visible explanation; they
never silently widen a replacement to the whole document.

For attachment collection, success means the report describes the precise scope.
Only safely mapped Markdown image destinations are rewritten. Code, literal
examples, HTML images, diagram internals and remote resources must not be
silently rewritten or claimed as collected. Reference-style image handling must
preserve any shared link-definition semantics or report that occurrence as
unsupported. Never fetch remote images automatically.

## Shared safety and interaction contract

- Reuse the PR #55 image content validation, read/decode budgets, external-folder
  authorization and descriptor-based exclusive writes. Never copy disguised
  nonimages, overwrite unrelated files, or broaden implicit filesystem access.
- A delayed operation captures document identity and revision. Do not apply a
  stale rewrite after user edits, closes, switches documents or changes paths.
  Report completed file writes honestly even if a later UI adoption is canceled.
- Source rewrites and replacements preserve native undo/redo, dirty state,
  autosave, line endings, UTF-16 ranges and marked-text input. Undoing inserted
  references must not delete files that another document might use.
- Use English and Chinese labels, keyboard-operable controls and accessible
  names. Tests must observe actual readiness; do not relax existing assertions,
  add unconditional retries, expand expected skips or mask crashes.
- Heavy filesystem/image work belongs off the main actor. Document-local
  approvals and settings cannot leak across windows.

## Isolated development and independent review

1. Each package has its own branch/worktree, specification, focused tests and
   `HANDOFF.md`. No worker changes another package's worktree.
2. Prefer new, focused files. Shared integration surfaces (`DocumentStore`,
   `AppSettings`, menus, editor and content view) are declared in handoffs and
   integrated sequentially. Never share a Swift build directory across worktrees.
3. A different agent reviews each completed package against this contract and
   tests edge cases. The author fixes blockers, and the reviewer verifies them.
4. GUI tests and real app use hold one exclusive lease, assigned by the
   coordinator. Unit tests may run concurrently; timing gates run in isolation.
5. The coordinator keeps only package status, decisions, commit hashes, blockers
   and acceptance summaries in the chat. Full logs and reproduction details live
   in package evidence files. New work starts from these files rather than the
   entire conversation.
6. Integrate reviewed commits onto `codex/daily-writing-20261109`, then run the
   unified gates once. A failing gate reopens only the responsible package.

## Unified acceptance

- Focused new regression suites must test observable outcomes and the negative
  paths in A/B/C, including Unicode, CRLF, undo/redo and stale operations.
- Existing default Swift suites pass; inline performance and main-actor
  responsiveness gates pass separately; workflow/package Python tests pass.
- Full native GUI suite passes with only the existing documented skip list.
  Skips are reported separately from passes.
- Real keyboard exercise: copy/link an image, collect local references, create a
  copy, select a source range, replace only that range and undo. Inspect both
  narrow-language layouts and independent windows.
- Safe development packaging passes without installing the app, altering the
  current release app or changing Markdown file associations.
- Verify the macOS 15 build/CI gates against the final source commit and artifact
  identity. PR creation is allowed; merge, tag and release require a later user
  instruction. Developer ID signing/notarization remain deferred by agreement.

## Later batches

Table cell navigation, row/column editing, TSV/rich-text/plain-text paste form a
separate editing package. Remote-resource controls need one policy spanning
preview, PDF, print and HTML. Browseable version history, folder navigation and
progressive live editing follow separately. They are not acceptance conditions
for this bounded batch.
