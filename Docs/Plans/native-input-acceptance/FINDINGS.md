# Native writing findings

## URL paste treats a marked Pinyin clause as a link label

In source, copy a plain URL and start a composition with a selected clause.
Paste the URL before committing. The old editor's URL shortcut wrapped the
provisional selection as a Markdown link. With marked `nihao` and `ni`
selected, the native regression produced
`正文🙂 [ni](https://example.com)hao 结尾`.

The editor now skips only the URL wrapping step while text is marked. AppKit
commits and pastes the URL as plain text, with the surrounding content intact.
The same regression fails before the change and passes afterward. The existing
committed-selection assertion still verifies normal URL link creation; image
paste retains its own policy checks.

## Source and find fields lack distinct spoken names

Focus source, then open Find and Replace and populate both fields. The prior
source editor reported a text area and its value without a name. The two find
fields exposed placeholder-only descriptions, and the replacement field
shared its visible wording with the Replace button.

The native source view and both fields now have explicit localized names.
Cross-process AX tests check the named source and populated fields in both
languages without relying on the labels to locate the fields.

## Keyboard focus cannot enter the remote image confirmation

In Side by Side, navigate backward with Control+Shift+Tab until the permission
button has focus, then open it with Space. The previous SwiftUI popover leaves
focus on the button. Tab and Control+Tab continue through the underlying
document while the popover remains visible. A FocusState-only adjustment
reproduced the same behavior on macOS 27.2.1.

The confirmation now uses a native sheet on the owning document. Cancel has
initial focus. Tab reaches the grant button, Escape cancels, and the same
document control remains available as the allow/revoke state changes. Return
does not grant permission. A changed document context invalidates any pending
confirmation.

## Replace All drops keyboard focus after the last match is gone

Fill both fields, Tab to Replace All and press Space. The original button
disables as the result count drops to zero; focus can fall back to the window,
where Escape no longer reaches the find bar. Typing also has no active field.

Now a replacement initiated from its focused button moves focus to the
replacement field. Escape dismisses the bar and returns to the source; one Undo
restores the replacements. The keyboard path was verified in a live window.

## Separate baseline finding: repeated save with unavailable hard-link recovery

Use a disposable hard-linked source and a recovery repository whose path is
occupied by a regular file. Open the source, dismiss the initial recovery
alert, make an edit, then save explicitly. A DocumentStore probe on the
unchanged baseline returns `false` with no second alert. The document stays
dirty and both linked names retain the original bytes. This requires a failed
recovery repository in addition to a hard link. It is different from the
ordinary permission failure that the native acceptance drills exercise.
Track the feedback edge separately from this input package.
