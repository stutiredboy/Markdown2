## MODIFIED Requirements

### Requirement: The preview re-renders live as the user edits
In Side by Side mode the right preview pane SHALL reflect edits made in the left editor pane, re-rendering from the same render pipeline used by single-pane Preview. The preview SHALL preserve its current scroll position across these re-renders so that ongoing typing does not reset the preview to the top or cause visible flashing of the whole document. A live re-render triggered by an edit SHALL NOT change the editor pane's focus, selected range, caret position, or scroll position: because the edit originates in the editor, the re-render and any preview anchor it produces SHALL NOT be treated as a preview-driven scroll that moves the editor. Typing SHALL remain responsive — the editor SHALL accept and display input without being blocked waiting on a full-document re-render of the preview, so the work that feeds the preview MAY be coalesced across a burst of keystrokes. As the user types, the preview SHALL keep the rendered output of the editing position (the caret's source line) in view, scrolling to reveal newly added content when that position would otherwise fall off-screen, while leaving the preview undisturbed when the editing position is already visible. This preview follow SHALL run after the coalesced re-render lands and SHALL NOT move the editor pane.

#### Scenario: Typing updates the preview
- **WHEN** the user types Markdown in the left editor pane
- **THEN** the right preview pane updates to show the rendered result of the new text

#### Scenario: Live re-render preserves preview scroll position
- **WHEN** the preview is scrolled away from the top and the user edits text whose rendered output is above the current preview viewport
- **THEN** the preview re-renders without jumping back to the top of the document
- **AND** the content the user was viewing remains in view

#### Scenario: Editing does not move the editor pane
- **WHEN** the editor is scrolled to the middle of a document in Side by Side mode and the user inserts a newline (for example pressing Enter after a `---` thematic break)
- **THEN** the editor pane stays at the position the user was editing
- **AND** the editor pane SHALL NOT scroll to the bottom or jump to any other position as a result of the preview re-rendering

#### Scenario: Editing preserves caret and selection
- **WHEN** the user types continuously in the left editor pane of Side by Side mode
- **THEN** each inserted character appears at the current caret location
- **AND** preview updates SHALL NOT move the caret, replace the selected range, or steal focus from the editor

#### Scenario: Typing keeps up with the user
- **WHEN** the user types continuously in the left editor pane of a moderately sized document
- **THEN** characters appear in the editor as they are typed without the editor stalling behind the keystrokes
- **AND** the preview converges to the rendered result once the typing burst settles

#### Scenario: The preview follows the editing position
- **WHEN** the user adds content in the left editor pane such that the caret's rendered output would fall below (or above) the visible region of the right preview pane
- **THEN** once the re-render settles, the preview scrolls so the rendered output of the editing position comes back into view
- **AND** the user does not need to scroll the preview manually to see what they are writing

#### Scenario: Editing in view does not disturb the preview
- **WHEN** the user edits text whose rendered output is already visible in the preview viewport
- **THEN** the preview does not scroll in response to the edit
- **AND** the editor pane is not moved by the preview follow

### Requirement: Scrolling keeps the two panes aligned
In Side by Side mode the editor and preview panes SHALL stay vertically aligned: scrolling the editor SHALL move the preview to the corresponding rendered content, and scrolling the preview SHALL move the editor to the corresponding source content. Alignment SHALL use the same source-line / block anchoring model as mode-switch scrolling, preferring a block/source-line anchor and falling back to heading or proportional position when block metadata cannot be resolved. During a continuous scroll of one pane, the following pane SHALL track the driver **smoothly** — moving progressively with the driver rather than snapping between discrete block positions or visibly reloading/flashing on each scroll tick. Preview anchor messages produced by live render/layout settling during an active editor edit burst SHALL NOT drive editor scrolling.

#### Scenario: Scrolling the editor follows in the preview
- **WHEN** the user scrolls the editor pane so a particular source block is near the top of the editor viewport
- **THEN** the preview pane scrolls so the rendered output of that block is near the top of the preview viewport

#### Scenario: Scrolling the preview follows in the editor
- **WHEN** the user scrolls the preview pane so a particular rendered block is near the top of the preview viewport
- **THEN** the editor pane scrolls so the source lines for that block are near the top of the editor viewport

#### Scenario: Continuous scrolling follows smoothly
- **WHEN** the user drags the editor's scrollbar continuously downward
- **THEN** the preview pane follows in a smooth, progressive motion that tracks the drag
- **AND** the preview SHALL NOT jump in discrete steps or visibly refresh/flash on each scroll tick

#### Scenario: Synchronized scrolling does not oscillate
- **WHEN** one pane is programmatically scrolled to follow the other
- **THEN** the followed pane SHALL NOT treat that programmatic scroll as a fresh user scroll that drives the originating pane back
- **AND** the two panes settle at the aligned position without visible jitter or feedback oscillation

#### Scenario: Preview layout settling during typing does not drive the editor
- **WHEN** the user is actively typing in the Side by Side editor
- **AND** the preview emits an anchor because live content was swapped, reloaded, or reflowed
- **THEN** that anchor SHALL NOT scroll the editor pane
- **AND** normal preview-to-editor synchronization resumes after the edit burst window expires and the user scrolls the preview
