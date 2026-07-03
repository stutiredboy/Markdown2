## Why

With the find bar open and keyboard focus in the editor text (the normal state after clicking back into the text to keep working), pressing Esc does not close the find bar — it triggers the editor's Esc mode gesture and yanks the window into Preview, dismissing find as a side effect of the mode switch. The user asked to close a bar and instead lost their editing surface. The same gap exists in Read mode: Esc with focus in the preview does nothing while the find bar is open.

## What Changes

- While a find bar is visible, Esc pressed anywhere in that document surface (find field, editor text, or preview page) dismisses the find bar and returns focus to the surface — and does nothing else.
- The Esc write→preview mode gesture only fires when no find bar is visible; the first Esc closes find, a second Esc switches modes.
- Existing behaviors are unchanged otherwise: the close button, dismissal on mode switch or document change, and the Esc gesture itself when find is closed.

## Capabilities

### New Capabilities

### Modified Capabilities
- `document-find`: The dismiss-find requirement now guarantees Esc closes the find bar regardless of which part of the surface has focus, and that dismissal takes priority over the Esc mode-switch gesture.

## Impact

- `Sources/MD2App/ContentView.swift`: the editor pane's `onEnterPreview` closure consults find-bar visibility (dismiss + refocus instead of `requestMode(.read)`).
- `Sources/MD2App/MarkdownPreviewView.swift`: the preview web view routes Esc to a dismiss callback when the preview find bar is visible.
- `openspec/specs/document-presentation-mode` is not modified: the Esc mode gesture remains available whenever no find bar is shown.
- Tests: the priority rule (find visible → dismiss, else mode gesture) as a pure decision helper with unit coverage.
