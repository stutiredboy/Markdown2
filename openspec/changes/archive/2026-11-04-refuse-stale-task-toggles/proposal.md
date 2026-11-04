## Why

A checkbox click from a preview older than the text can change a different task (F05 in `Docs/Review-2026-10-15.md`). The click sends the source line the page knows, and `DocumentStore.toggleTask` only checks that the line is a task now. Confirmed on `main`: after the text goes from `- [ ] A\n- [ ] B` to `- [ ] N\n- [ ] A\n- [ ] B`, a click on A sends line 1, and N gets checked.

The preview trails the text by the render debounce, the live-update debounce and the rewrite off the main thread, and a reload or an external change opens the same window. Being a task proves nothing: the line has to be the task that was clicked.

## What Changes

- **A click from a stale preview is refused.** The document counts the text changes that can move a task to another line. Each page knows the count of the text it was rendered from and sends it with the click. `toggleTask` refuses a click whose count is not the current one.
- **A refused click puts its checkbox back.** The click flips the box on the page, and nothing else would flip it back: no edit means no re-render, and a live update keeps a block whose HTML did not change, with the flipped box in it. The preview resets the boxes from their `checked` attribute.
- **A toggle does not count as a line change.** It rewrites one character and moves no line, so ticking down a list faster than the preview re-renders works as it does today.
- **The count stays out of page script's reach.** It lives in the bridge's isolated content world, set by native. It is not in the DOM, so page script can neither read nor rewrite it, and it does not reach exported PDF or HTML.
- **Tests:**
  - `DocumentStoreTests`, headless: the audit's probe, a stale click on a textually identical line, deleted and moved tasks, a replaced document, a second click before the re-render, a duplicate click, an undone toggle, and the rendered revision trailing the text.
  - The new `PreviewTaskToggleGUITests`: real clicks on a preview held on old text, for Side by Side and Read mode. They cover the box going back (including in a kept block, when the refusal arrives after the update), every way the page's label moves, and `ContentView`'s own wiring.

**Non-goals:**

- A stale click is not moved to the task it meant, see `design.md`. The user clicks again once the preview has caught up, which takes a fraction of a second.
- No message tells the user a click was refused. The box going back is the feedback.
- `PreviewSecurityGUITests`' trust boundary does not change: the bridge still lives in the isolated world and takes only trusted events.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `preview-task-toggle`: a click from a stale preview is refused, a refused or invalid click puts its checkbox back, and the page's source revision stays out of page script's reach.

## Impact

- `Sources/MD2App/DocumentStore.swift`: `sourceLineRevision`, `renderedSourceLineRevision`, and `toggleTask(atLine:to:renderedAt:)` in place of `toggleTask(atLine:to:)`.
- `Sources/MD2App/MarkdownPreviewView.swift`: the revision in the toggle message, the page's label, restoring the boxes.
- `Sources/MD2App/WebDocumentLoader.swift`: `currentNavigation`.
- `Sources/MD2App/ContentView.swift`: passes the revision and restores on a refusal.
- `Tests/MD2CoreTests/`: `DocumentStoreTests`, `PreviewSecurityGUITests`, the new `PreviewTaskToggleGUITests`, and the test-only `DocumentStoreTaskToggle` for tests of a current page.
- No change to rendered HTML or exports. A normal click behaves as before, including its one undo step.
