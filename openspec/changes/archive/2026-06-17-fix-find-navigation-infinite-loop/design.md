## Context

The find affordance relays one-shot actions (next, previous, replace, replace
all) from SwiftUI `@State` into the AppKit editor and WebKit preview surfaces
through `@Binding` properties on `MarkdownEditorView` and `MarkdownPreviewView`.
Each surface reads the binding in `updateNSView`, performs the action, and
previously marked it consumed by clearing the binding inline
(`self.findNavigation = nil`).

Reproduced with `MD2DBG` instrumentation against the packaged app: a single Find
Next pinned a CPU core. `updateNSView` consumed the *same* command repeatedly —
~882 times per run in the editor and ~5,600+ in the preview — while the user
trigger fired exactly once. The editor's reported match index climbed
(1→11→12→…) confirming navigation was re-running, matching the user's "不停的
下一个" description.

## Goals / Non-Goals

**Goals:**
- Each find-navigation and replace command executes exactly once per user
  invocation.
- No runaway re-render / CPU spin from the find affordance.
- Preserve existing behavior: wrap-around, "i of n" status, match highlighting,
  focus handling.

**Non-Goals:**
- Redesigning the find command relay or `FindCommand`/`FindReplaceCommand`.
- Reworking the other one-shot bindings (mode-switch jump anchors). They share
  the inline-clear shape but did not reproduce a loop, because — unlike find —
  consuming them does not write `@State` on every pass, so nothing re-dirties the
  view to drive a repeat.

## Decisions

**Decision: consume one-shot commands by token dedup in the coordinator, never by
mutating the binding inside `updateNSView`.**

Both command types already carry a fresh `token = UUID()` (originally so that
repeating the same action still registers as a distinct value). The coordinator
object persists across `updateNSView` calls, so it records the last-consumed
token and acts only when the incoming command's token differs. Consumption is
then idempotent no matter how many times `updateNSView` re-runs with the same
command. This is the exact pattern the same files already use for
`lastFocusToken`.

Rationale: mutating observed SwiftUI state during the view-update pass is
undefined behavior; the cleared `nil` is not reliably visible to the very next
update — and that next update is scheduled by the command's own side effect
(`reportFindResult` → `onFindResult` writes the match-count `@State`). So the
binding reads back as non-nil and the command replays endlessly.

Alternatives considered:
- **Async clear** (`DispatchQueue.main.async { self.findNavigation = nil }`):
  moves the mutation out of the update pass, but leaves a window where several
  `updateNSView` passes consume the same command before the clear lands →
  multiple navigations per keypress. Rejected as racy.
- **`onChange(of:)` observation** of the command: still needs a stable dedup key
  to avoid double-firing; token dedup is simpler and local to the surface.

## Risks / Trade-offs

- **The binding is no longer cleared, so it retains the last command** →
  Harmless: consumption is gated by token, and the binding is reset to `nil` on
  find dismissal and mode switch (`dismissEditorFind` / `dismissPreviewFind`). A
  reopened find issues a fresh token, so the next navigation runs.
- **Coordinator token state across view recreation** → On a single-pane mode
  switch the surface (and its coordinator) is recreated and the find bar is
  dismissed; the fresh coordinator starts with a `nil` token and any new command
  carries a new UUID, so the first post-recreation navigation still fires.
