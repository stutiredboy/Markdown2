## Context

Markdown2 already has a strong rendering pipeline: `MarkdownRenderer` emits the full preview document, `MarkdownPreviewView` hosts it in a `WKWebView`, `ContentView` owns the editor/read/split mode state, and `OutlineSidebar` exposes heading navigation. Manual testing of the installed app showed that the core rendering works, but several reader-facing surfaces are ambiguous: remote-image failures use the same "missing image" wording as local files, front matter dominates the first screen in read mode, icon-only toolbar controls require prior knowledge, outline row activation is not robust for accessibility, and Side by Side with the outline visible leaves both panes cramped.

## Goals / Non-Goals

**Goals:**
- Make image diagnostics distinguish local missing files from remote image load failures.
- Keep YAML front matter out of the default reading flow while preserving an explicit inspection path.
- Make primary toolbar actions and mode selection understandable without requiring hover-only discovery.
- Make outline navigation reliable for mouse, keyboard, and assistive technology users.
- Keep Side by Side usable when the outline is visible by adapting layout and window sizing behavior.

**Non-Goals:**
- Do not expose or implement DOCX/EPUB export in this change.
- Do not add a remote image download/cache subsystem.
- Do not rewrite the Markdown parser or replace the existing SwiftUI/AppKit split architecture.
- Do not change PDF export page layout or self-contained HTML export semantics.

## Decisions

### Distinguish image failures at the preview layer

Keep authored Markdown image rendering unchanged and classify failures in `MarkdownPreviewView` when the browser reports an image error. Local `file`, absolute path, and relative path failures SHALL keep the missing-local-file wording; `http` and `https` failures SHALL use remote-unavailable wording. This avoids introducing network policy or cache state into `MarkdownRenderer`.

Alternative considered: download and cache remote images before rendering. Rejected for this change because it adds network lifecycle, cache invalidation, privacy, and offline behavior questions that are not necessary to fix the misleading diagnostic.

### Treat front matter as metadata in reader surfaces

Continue parsing front matter for bibliography and math macros, but hide it from normal read/preview output by default. Provide an explicit way to show it for users who need to inspect document metadata, preferably via a lightweight view setting rather than changing Markdown source.

Engineering review decision: implement this as a per-window live preview display state in `ContentView`/`MarkdownPreviewView`, not as a default change to `MarkdownRenderer`. The shared `RenderedDocument.html` remains unchanged so PDF export, Print, self-contained HTML export, and conversion paths keep current front matter semantics. The preview may hide the existing `.front-matter` block with injected preview-only CSS/JavaScript while leaving source-line metadata in the DOM for navigation.

Design review decision: default to hidden on document open and expose a small labeled metadata toggle in reader-capable toolbar states when valid leading front matter exists. The toggle is transient per window, resets to hidden when the document identity changes, and is not a global Settings preference in this change.

Alternative considered: always render front matter as a styled preformatted block. Rejected because read mode should prioritize document content, and current behavior pushes the title below metadata on the first screen.

### Improve toolbar discoverability without abandoning compact macOS controls

Keep icon buttons and segmented mode controls, but add visible text when horizontal space permits and ensure every action has a stable accessibility label/help string. The compact state can remain icon-only, but it must not be the only discoverability path.

Alternative considered: replace the toolbar with a large labeled command bar. Rejected because Markdown2's existing interface is intentionally compact and native.

### Make outline rows first-class navigation controls

Keep the outline derived from rendered headings, but make each row expose an explicit activation action, selection state, and keyboard navigation. The visible row and accessibility tree should agree on what is selected and what action will occur.

Alternative considered: rely on the generated `[TOC]` links for all navigation. Rejected because the persistent outline is the primary navigation surface for long documents.

### Adapt split layout when outline is visible

When the outline and Side by Side mode compete for horizontal space, prefer a usable editor/preview pair over keeping every surface visible at fixed widths. The implementation can widen the window, temporarily collapse the outline, or provide a clear control state that preserves minimum pane widths.

Engineering and design review decision: use minimum-width enforcement/window widening as the first implementation, not automatic outline collapse. Auto-collapse risks making the app feel like it changed a user preference. The minimum usable editor pane width is 360 pt, the minimum usable preview pane width is 420 pt, and the outline remains 230 pt. When Side by Side and outline are both visible, the document window's minimum width must account for those panes plus dividers and chrome.

Alternative considered: only lower `splitPaneMinWidth`. Rejected because very narrow panes degrade both Markdown editing and math/table preview readability.

## Risks / Trade-offs

- [Risk] Hiding front matter may surprise users who expect to see raw metadata in preview. -> Mitigation: provide an explicit show metadata control and keep source mode unchanged.
- [Risk] Remote image failure classification may be wrong for unusual custom schemes. -> Mitigation: classify only known local and `http`/`https` cases; fall back to generic image-load failure wording.
- [Risk] Toolbar text can make the toolbar crowded on small windows. -> Mitigation: use responsive labels and keep accessibility/help labels stable in compact mode.
- [Risk] Split minimum-width enforcement can widen or constrain the document window. -> Mitigation: only apply the larger minimum while Side by Side needs it, and do not silently change outline visibility.
- [Risk] Accessibility improvements may require AppKit bridging beyond plain SwiftUI `List` behavior. -> Mitigation: keep changes narrow and add interaction tests where possible.
- [Risk] Hiding front matter via preview-only DOM state can diverge from exported artifacts. -> Mitigation: make this explicit in UI copy and tests; this change improves live reading, not export semantics.

## Migration Plan

No user data migration is required. Existing settings remain valid. Front matter visibility is transient per window and does not add a new persisted preference in this change.

Rollback is straightforward: revert the UI and preview changes. Markdown file contents, export profiles, and existing app preferences remain compatible.

## Review-Resolved Decisions

- Front matter visibility is per-window, transient UI state. It defaults to hidden in reader surfaces and resets on document identity changes.
- The renderer continues to emit `.front-matter`; live previews hide/show that block through preview-only script/style state. Export paths stay unchanged.
- Split+outline adaptation uses window minimum width and pane minimum constraints. It does not auto-hide a user-visible outline in this change.
- Toolbar discoverability uses native macOS `Label` title+icon controls where space permits. Compact fallback may remain icon-only, but accessibility labels and help text must remain stable.
- Outline navigation keeps the existing sidebar surface, but rows become full-width navigation controls with selection state, keyboard navigation, and accessibility activation.

## Information Architecture

```
Document Window
├─ Toolbar
│  ├─ Outline toggle
│  ├─ Open / Save
│  ├─ Metadata toggle (only when reader surface + valid front matter)
│  └─ Mode picker: Edit | Side by Side | Preview
├─ Main area
│  ├─ Outline sidebar (optional, 230 pt)
│  └─ Document surface
│     ├─ Edit: source text only
│     ├─ Preview: rendered body, front matter hidden unless toggled
│     └─ Side by Side: source editor + rendered preview
└─ Status bar
```

Priority on first scan: current document content first, navigation second, document commands third. Metadata is available but subordinate to body content.

## Interaction State Coverage

| Feature | Empty | Error | Success | Partial / Constrained |
| --- | --- | --- | --- | --- |
| Front matter metadata | Toggle is hidden or disabled when no valid leading front matter exists. | Malformed front matter remains rendered as normal Markdown/source behavior; no fake metadata panel appears. | Toggle shows/hides the rendered `.front-matter` block without changing source. | Hidden block keeps DOM/source-line metadata so anchors still resolve. |
| Broken image diagnostics | No placeholder is shown for images that load. | Local failures say local image could not be found/loaded; remote `http/https` failures say remote image could not be loaded; unknown schemes use a generic image-load failure label. | Valid local/remote images render normally. | Failed source is inserted as text only and wraps without overflowing. |
| Toolbar labels | Labels are still localized for accessibility when compacted. | Labels must not overlap content panes. | Default-width toolbar identifies Outline, Open, Save, Metadata when present, and mode options. | Compact toolbar keeps icons plus stable help/accessibility text. |
| Outline navigation | No headings shows localized empty state. | Missing destination is ignored without crashing. | Mouse, keyboard Return, and accessibility activation scroll to the heading and select the row. | Long headings truncate visually but expose the full title to accessibility clients. |
| Split with outline | Not applicable. | Window cannot shrink below usable pane constraints. | Editor and preview stay at or above minimum widths. | The app widens/enforces minimum width rather than silently hiding the outline. |

## Test Coverage Map

```
CODE PATHS                                         USER FLOWS
[+] Preview front matter visibility               [+] Open Sample.md in Preview
  ├── [GAP] hidden by default                        ├── [GAP] title/body is first visible content
  ├── [GAP] explicit show/hide toggle                └── [GAP] toggle reveals metadata, source unchanged
  └── [GAP] export shared HTML unchanged
[+] Broken image diagnostics                       [+] Read document with mixed images
  ├── [GAP] local missing label                      ├── [GAP] local failure is not confused with remote
  ├── [GAP] remote unavailable label                 └── [GAP] injected-looking URL remains inert text
  └── [GAP] generic fallback label
[+] Toolbar / outline / split layout               [+] Navigate a long document
  ├── [GAP] localized toolbar labels                 ├── [GAP] keyboard outline selection + Return
  ├── [GAP] selected outline state                   └── [GAP] split+outline at default width
  └── [GAP] split pane minimums
```

Implementation should cover pure/localizable helpers with unit tests and use existing GUI/WebKit smoke tests for behavior that only exists in `WKWebView` or native SwiftUI focus handling.

## What Already Exists

- `MarkdownRenderer` already emits `.front-matter` and source-line metadata; reuse it and hide only in preview.
- `MarkdownPreviewView` already injects preview-only JavaScript for broken image placeholders and find/scroll helpers; extend that script instead of adding renderer state.
- `ContentView` already owns mode, outline visibility, and split synchronization; keep metadata visibility and split minimum width decisions there.
- `OutlineSidebar` already receives headings and selected heading ID; improve its row semantics rather than adding a second outline model.
- `AppSettings` already centralizes localized strings; add labels there so toolbar/help/menu terminology stays consistent.

## NOT In Scope

- DOCX/EPUB implementation or menu changes: explicitly deferred per user instruction.
- Remote image downloading, caching, retry UI, or offline mirroring: misleading diagnostics are fixed without adding network lifecycle.
- Global persistent front matter preference: per-window toggle is enough and keeps the diff smaller.
- Replacing the split-view architecture: minimum sizing solves the observed UX issue without a layout rewrite.
- Redesigning the whole toolbar into a custom command bar: native macOS toolbar behavior is retained.

## Failure Modes

- Preview script fails to apply front matter class: user sees existing renderer output; source/export remain safe.
- Live preview content swap replaces `<main>` and loses visibility state: update path must re-apply the front matter visibility class after body replacement.
- Remote/local image classification misreads an unusual scheme: fallback generic label avoids a false local-file claim.
- Outline keyboard selection has no row selected yet: first Down/Up should select a nearby row, and Return should no-op until a real row is selected.
- Split minimum width exceeds the current window: SwiftUI/NSWindow minimum width should widen or prevent further shrinking, preserving explicit outline state.

## Parallelization

Sequential implementation is recommended. The workstreams share `ContentView`, `MarkdownPreviewView`, and `AppSettings`, so parallel worktrees would create avoidable merge conflicts.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Architecture & tests | 1 | CLEAR | 3 decisions added: preview-only front matter, split width strategy, export invariant tests |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | CLEAR | 5 design decisions added: IA, state table, toolbar behavior, outline states, layout constraints |

- **UNRESOLVED:** 0. Interactive AskUserQuestion gates were unavailable in this Codex environment, and the user explicitly requested review completion followed by implementation, so reversible low-risk defaults were applied.
- **VERDICT:** ENG + DESIGN CLEARED — ready to implement `improve-preview-reader-ux`.
