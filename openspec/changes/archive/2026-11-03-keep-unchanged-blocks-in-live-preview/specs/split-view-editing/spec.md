## MODIFIED Requirements

### Requirement: The preview re-renders live as the user edits
In Side by Side mode the right preview pane SHALL reflect edits made in the left editor pane, re-rendering from the same render pipeline used by single-pane Preview. The preview SHALL preserve its current scroll position across these re-renders so that ongoing typing does not reset the preview to the top or cause visible flashing of the whole document. A live re-render SHALL keep every top-level rendered block whose HTML did not change, apart from its source-line metadata, together with its rendered math, diagrams and images, and SHALL insert and render only the blocks that are new or changed. A kept block SHALL take the new source-line metadata, so line numbers, mode-switch anchors and task toggles keep identifying the right source lines. A live re-render triggered by an edit SHALL NOT change the editor pane's focus, selected range, caret position, or scroll position: because the edit originates in the editor, the re-render and any preview anchor it produces SHALL NOT be treated as a preview-driven scroll that moves the editor. Typing SHALL remain responsive — the editor SHALL accept and display input without being blocked waiting on a full-document re-render of the preview, so the work that feeds the preview MAY be coalesced across a burst of keystrokes. As the user types, the preview SHALL keep the rendered output of the editing position (the caret's source line) in view, scrolling to reveal newly added content when that position would otherwise fall off-screen, while leaving the preview undisturbed when the editing position is already visible. This preview follow SHALL run after the coalesced re-render lands and SHALL NOT move the editor pane.

#### Scenario: Typing updates the preview
- **WHEN** the user types Markdown in the left editor pane
- **THEN** the right preview pane updates to show the rendered result of the new text

#### Scenario: Live re-render preserves preview scroll position
- **WHEN** the preview is scrolled away from the top and the user edits text whose rendered output is above the current preview viewport
- **THEN** the preview re-renders without jumping back to the top of the document
- **AND** the content the user was viewing remains in view

#### Scenario: Editing a paragraph leaves diagrams alone
- **WHEN** a document shows rendered diagrams in the preview and the user edits a paragraph outside them
- **THEN** the diagrams stay on screen as they are
- **AND** no diagram returns to its loading placeholder or renders again

#### Scenario: Editing the first line after entering Side by Side leaves other blocks alone
- **WHEN** the user enters Side by Side on a document with rendered diagrams and makes a first edit to a paragraph
- **THEN** the diagrams stay on screen as they are

#### Scenario: Inserting lines keeps kept blocks on their new lines
- **WHEN** the user inserts lines above unchanged blocks, including a task item
- **THEN** the unchanged blocks stay in the page
- **AND** their line numbers in the preview gutter show their new source lines
- **AND** clicking the task's checkbox toggles the task on its new line

#### Scenario: Unchanged images do not reload
- **WHEN** the preview shows a local image and the user edits another block
- **THEN** the image element stays in the page with the same URL

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
