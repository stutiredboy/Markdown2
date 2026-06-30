## Context

Markdown2 uses a custom Swift renderer for Markdown blocks and an AppKit/WKWebView split editor for Side by Side mode. Existing list tests already cover four-space and ordered-marker-aligned nesting, but the reported monthly-report file uses the common two-space child bullet shape under `- ` parents. The current nesting heuristic treats two columns as the same list level, so those child bullets render as siblings.

Side by Side mode already coalesces renders and swaps preview `<main>` content in place. Caret jumps can still occur if preview anchor messages during an edit are interpreted as preview-driven sync, if a full reload caused by an edit emits an anchor, or if the editor representable rewrites the text view while the user is typing.

## Goals / Non-Goals

**Goals:**
- Treat child list indentation relative to the parent marker's content column: two spaces under `- `, three under `1. `, four under `10. `, and tab/four-space forms all nest.
- Preserve existing mixed ordered/unordered/task list behavior, loose-list continuity, source-line metadata, and indented-code handling.
- Ensure Side by Side live preview updates never move editor focus, selection, caret, or viewport during an active edit burst.
- Add targeted regression coverage for the reported monthly-report list shape and for edit-window scroll-sync suppression.

**Non-Goals:**
- Replacing the custom renderer with a full CommonMark parser.
- Redesigning Side by Side layout, find behavior, outline navigation, or export output.
- Changing the user's source Markdown formatting.

## Decisions

- Use parent content-column indentation for nesting instead of a fixed three-column threshold. The renderer already records `contentIndent`; nesting should compare a candidate child marker's indent against the previous open item's content column. This matches common Markdown authoring while preserving ordered-marker alignment.
- Keep non-list continuation rules separate from list-item nesting. A non-list line still must reach the item's content column before it becomes part of that item, so indented-code and short continuation edge cases stay controlled.
- Preserve visual indentation in CSS for all nested lists, including task lists. Task-list styling should remove the marker without collapsing nested padding; nested task lists should still show hierarchy.
- Treat editor edits as the strongest Side by Side ownership signal. During the edit-follow window, preview anchor reports and full-reload settle reports are ignored for preview-to-editor sync; live preview swaps may move only the preview, and only to keep the caret's rendered line visible.
- Remove stray debug logging from split synchronization while fixing this path, because per-scroll logging can worsen perceived typing jitter and pollute runtime diagnostics.

## Risks / Trade-offs

- Two-space child bullets under unordered lists may change rendering for documents that relied on the previous nonstandard same-level interpretation. Mitigation: add explicit tests for the intended nesting and retain strict handling for non-list continuation lines.
- The nesting algorithm has more state than a fixed threshold. Mitigation: keep it localized to list-level derivation and cover unordered, ordered, mixed, task, tab, and dedent cases.
- Side by Side cursor jitter is partly UI-timing dependent and hard to fully prove headlessly. Mitigation: cover the pure coordination rules in unit tests where possible, run the app/build, and manually exercise the provided document in split mode.
