## Context

A task checkbox carries `data-md2-task-line`. The click listener in `interactionScript`, in the isolated `.defaultClient` world, posts `{line, checked}` for trusted events. `ContentView` captures the viewport, which is asynchronous, and then calls `DocumentStore.toggleTask`.

Content reaches the page in two ways. A live update (Side by Side) rewrites the body off the main thread, waits out `liveUpdateDebounce`, and calls `__md2ApplyContent` in the page world, which keeps blocks whose HTML did not change and copies line attributes onto them. A full load (Read mode, a new diagram engine, a new base URL) rewrites off the main thread as well, then navigates to a fresh `md2-doc://` URL. A newer full load makes an older one stale.

## Decisions

### Refuse a stale click rather than move it

A stale click could be relocated by diffing the page's source against the current text. It would have to name a task the text may no longer hold, and the answer is a guess exactly when it matters: with two identical lines (`preview-task-toggle` has a scenario for those) a diff cannot say which one survived, and it cannot tell an edited task from a deleted one plus a new one. A wrong guess is the bug being fixed, now with more code behind it.

Refusing costs a second click, and only in the moments after an edit, while the preview is visibly catching up. The box going back says what happened.

Because a stale click is refused, the message needs no task identity beyond the line. A revision pins the exact text, and a line in that text is exactly one task. Comparing the line's text as an extra identity would add nothing to a current click, and it is what a stale click on an identical line would pass.

### The revision counts what can move a line

`DocumentStore.sourceLineRevision` goes up on every text change except `toggleTask`'s. A plain text revision would refuse a second click made before the first one's re-render lands, and that click works today: a toggle rewrites one mark, so the page's line numbers are still right. In Read mode that re-render is a whole page load, so ticking down a list would lose clicks. The toggle restores the count after its edit, which reaches `text` synchronously through the text view.

Undo and redo go through the text view like typing, so they count even when they take back a toggle. That only refuses a click in the moments after an undo.

`renderedSourceLineRevision` is the revision of the text `rendered` was built from, read when the render starts and published with its result. The view takes that one, never the current count: a SwiftUI pass during typing would otherwise label an old page as current.

The check runs inside `toggleTask`, after the viewport capture, so a change that lands during the capture counts.

*Alternatives considered:*
- A hash of the text with task marks normalized, computed per render and per click. It needs no special case in `toggleTask` and survives A→B→A, but it is a second parser of task markers, and a page still has to be relabelled when new text renders to the same page.
- Inferring what the page shows from the order of native callbacks, with nothing in the message. It depends on the undocumented ordering of script messages against `evaluateJavaScript` replies, where a message carrying its revision proves what it was clicked on.

### The page's label lives in the isolated world

Native sets `window.__md2SourceLineRevision` with `evaluateJavaScript(in: .defaultClient)`, and the click listener reads it there. Each content world has its own `window`, so page script cannot read it or write the one the listener uses. An attribute on `<main>` or a block would be readable and writable by page script, would go stale on kept blocks unless added to `lineAttributes`, and would need keeping out of exports. With no attribute, none of that applies.

### The label follows its content and never leads it

`__md2ApplyContent` runs in the page world and the label is set in the isolated one, so they cannot be one step. The order is what matters: a label behind its content only refuses a click, while a label ahead of its content would pass a stale click as current. So the coordinator keeps `hasContentInFlight` from handing content over until it is in the page:

- A live update labels the page in the completion of `__md2ApplyContent`, and only when it is the latest update and the script did not throw. The scripts end in `true`, so a completion's error means an exception and not an unsupported result.
- A full load labels the page in `didCommit`, and only when the navigation is `WebDocumentLoader.currentNavigation`. A page that a newer load will replace stays unlabelled, and its clicks are refused. `currentNavigation` is `nil` from the start of `load` until the new navigation exists, so the check also covers a load that is still being prepared. `didFinish` would be too late: it waits for every image, while the boxes work from the end of parsing.
- Text that renders to the same HTML gets no content update, but the revision moved, and a page that kept the old label would refuse every click from then on. So `updateNSView` relabels when the HTML did not change, unless content is in flight, in which case the completion labels the page with the latest revision.

A click on a page with no label sends no revision. The coordinator refuses it without asking the document.

### Restore every box from its `checked` attribute

A refusal runs `box.checked = box.defaultChecked` for every task box, in the isolated world. `defaultChecked` is the `checked` attribute, which is what the page was rendered with. A kept block's attribute matches the new render, or the block would not have been kept, so this is also the source's state as of the latest update.

Every box and not one, because a refused click's line may by now name another box, and a live update can move the attribute before the refusal arrives. Restoring a box that was not refused is harmless: an accepted click always has a re-render on the way, which replaces its block.

The coordinator hands `onToggleTask` a closure for this. A `WKScriptMessageHandlerWithReply` would reach the clicked box directly, but WebKit raises if a reply handler is dropped, and this reply would wait on a viewport capture that a closing window can abandon.

## Risks / Trade-offs

- **A click just after an update is refused until the label arrives.** The label follows the update by one round trip to the page, a few milliseconds. The box goes back and a second click works.
- **A failed navigation leaves the old page labelled as it was.** Its clicks are refused once the text has moved on, which is correct for a page that shows old text.
- **A live update can race a full load that is still being prepared.** `didFinish` of an older page sets `isLoaded` even after a newer load began, so an update in that window of a few milliseconds goes in place and the load then replaces it with older text. That page already shows stale content until the next edit, as it did before this change, and it would now carry the newer label. Closing it means making `isLoaded` follow the latest navigation, which is a separate change.
- **Every path that delivers content must label the page.** A new path that does not would have clicks refused, which is loud rather than silent, and `PreviewTaskToggleGUITests` covers each existing path.
