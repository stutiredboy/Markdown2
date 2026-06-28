## Why

Opening find and pressing Return — or clicking Find Next (the ▼ button), or
pressing ⌘G — put the UI into a rapid, infinite flicker: the "next" navigation
replayed continuously ("不停的下一个"), pinning a CPU core. This happened in
both edit (editor) and preview surfaces, making find effectively unusable.

The root cause is the way the one-shot find/replace commands were consumed. The
editor and preview `updateNSView` ran the command and then cleared the bound
state inline (`self.findNavigation = nil`). Mutating an observed SwiftUI binding
*during* `updateNSView` is not reliably visible to the next update pass, and the
command's own side effect (reporting the new match count, which writes `@State`)
re-triggers `updateNSView` before the `nil` lands — so the same command is
consumed on every render, forever.

## What Changes

- Consume the find-navigation command (`FindCommand`) and the replace command
  (`FindReplaceCommand`) by recording the command's `token` in the view
  coordinator and acting only when the token changes — the same dedup pattern the
  surfaces already use for `lastFocusToken`. Each command now runs exactly once.
- Remove the in-`updateNSView` binding mutations (`self.findNavigation = nil`,
  `self.replaceCommand = nil`) on both the editor and preview surfaces.
- No user-facing API or shortcut changes; find / next / previous / replace behave
  as before, minus the runaway loop.

## Capabilities

### Modified Capabilities

- `document-find`: clarify that each Find Next / Find Previous invocation advances
  exactly one match (and each Replace acts once), and that the find affordance
  never enters a self-repeating navigation loop.

## Impact

- Code: `Sources/MD2App/MarkdownEditorView.swift` and
  `Sources/MD2App/MarkdownPreviewView.swift` — the command-consumption sites plus
  two new coordinator fields (`lastFindNavigationToken`, and on the editor
  `lastReplaceCommandToken`). `FindCommand`/`FindReplaceCommand` are unchanged
  (the `token` they already carried is now the dedup key).
- No new dependencies, no data or settings migration, no spec-format break.
