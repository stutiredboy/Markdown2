## Context

Esc reaches the app three ways today: the find bars' SwiftUI `.onExitCommand` (fires only while a find text field has focus), the editor `NSTextView` delegate's `cancelOperation` interception (fires when the text view has focus and unconditionally calls `onEnterPreview`), and nothing in the preview web view. `ContentView` owns `editorFindVisible`/`previewFindVisible` and already has dismiss helpers that restore focus via surface focus tokens. The Esc mode gesture is spec'd in `document-presentation-mode` and must keep working when no find bar is shown; `document-find` already requires Esc dismissal but its scenario only covered the focused-find-bar case.

## Goals / Non-Goals

**Goals:**
- One rule, applied everywhere in a document window: visible find bar + Esc = dismiss find, nothing else; no find bar + Esc = existing mode gesture (editor, single-pane only).
- Focus returns to the surface the user was in, matching the existing dismiss-and-refocus helpers.

**Non-Goals:**
- No change to the Cmd+double-click preview gesture, configurable mode shortcuts, or find-bar internals.
- No global Esc event monitor; routing stays within the existing responder paths.

## Decisions

- **Decide at the owner, not in the text view.** The editor pane's `onEnterPreview` closure in `ContentView` becomes "Esc pressed in editor": if `editorFindVisible`, call `dismissEditorFind(refocusEditor: true)`; else, in single-pane write mode, `requestMode(.read)` (split keeps ignoring it). `ContentView` is the only place that knows both the find state and the mode, so the priority rule lives there as a small pure helper (`EscRouting.action(findVisible:isSplit:) -> dismissFind | switchMode | none`) for direct unit testing. Alternative considered: teaching `MarkdownSourceTextView` about find state — rejected: duplicates state downward and leaves the preview path unsolved.
- **Give the preview web view an Esc hook.** `PreviewWebView` overrides `cancelOperation`/`performKeyEquivalent` for Esc and reports it via the existing find-action callback path (a `.dismiss` case on `FindCommand.Action` or a dedicated closure); `ContentView` dismisses the preview find bar when visible, otherwise ignores it (Esc has no mode meaning in read mode today, which stays true).
- **Find-bar-focused Esc keeps using `.onExitCommand`** — it already implements dismiss-and-refocus; the new routing only covers the cases where focus is outside the bar.

## Risks / Trade-offs

- [WKWebView may consume Esc before `cancelOperation` in some focus states] → also check in `performKeyEquivalent` (key code 53) as the fallback path; verified manually in the functional pass.
- [Found during implementation] `NSResponder` declares but does not implement `cancelOperation:`, so an override must never call `super` — doing so crashed with an unrecognized selector, delivered through WebKit's `_web_superDoCommandBySelector` path (which confirms Esc really does reach the override). An unconsumed Esc ends in the override doing nothing, matching pre-override behavior.
- [Users accustomed to the old behavior (Esc always leaves write mode) lose one path while find is open] → intended: it matches the spec's promise that Esc dismisses find; a second Esc still switches, so the cost is one extra keypress exactly when a bar is visibly open.

## Open Questions

- None.
