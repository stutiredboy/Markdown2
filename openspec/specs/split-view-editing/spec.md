## Purpose

Define the Side by Side presentation mode where the editor and live preview appear together, covering live re-rendering, two-pane scroll synchronization, reading-position preservation across mode switches, and toolbar/shortcut access.
## Requirements
### Requirement: Side by Side shows the editor and preview together
The app SHALL provide a presentation mode named "Side by Side" (internal
identifier `split`) that displays the editable source and the rendered preview
simultaneously in one document window: the editor in a left pane and the live
preview in a right pane, separated by a vertical divider. Both panes SHALL be
visible and usable at the same time without any mode toggle. The outline sidebar
and status bar SHALL remain available exactly as in the single-pane modes.

#### Scenario: Entering Side by Side shows both panes
- **WHEN** the user selects Side by Side mode for a document
- **THEN** the window shows the Markdown editor on the left and the rendered
  preview on the right at the same time
- **AND** the outline sidebar (when enabled) and the status bar remain visible

#### Scenario: The split divider is adjustable
- **WHEN** the user drags the divider between the editor and preview panes
- **THEN** the relative widths of the two panes change accordingly
- **AND** neither pane collapses below a usable minimum width

#### Scenario: Editor is interactive in Side by Side
- **WHEN** the document is shown in Side by Side mode
- **THEN** the user can type, select, and edit text in the left pane just as in
  Edit mode

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

### Requirement: Entering and leaving Side by Side preserves the reading position
When a document enters Side by Side mode the preview pane SHALL be aligned to the
position the user was at in the surface they came from, and the editor pane SHALL
keep that position. When a document leaves Side by Side mode for a single-pane
mode, the destination single-pane surface SHALL adopt the position of the
corresponding pane (the editor pane's position when entering Edit, the preview
pane's position when entering Preview).

#### Scenario: Switching Edit to Side by Side keeps the editor position
- **WHEN** the editor is scrolled to a position in Edit mode and the user
  switches to Side by Side
- **THEN** the editor pane stays at that position
- **AND** the preview pane is aligned to the same source content

#### Scenario: Switching Side by Side to Preview keeps the preview position
- **WHEN** the user is in Side by Side mode with the preview pane scrolled to a
  position and switches to Preview mode
- **THEN** the single-pane preview shows that same position

### Requirement: Per-pane features work in Side by Side
In Side by Side mode the editor and preview SHALL retain the per-surface
behaviors they have in single-pane modes. Find/Replace SHALL operate on the pane
that currently
has focus. Selecting an outline entry SHALL navigate both panes to that heading.
Clicking a task-list checkbox in the preview SHALL toggle the corresponding
source line and SHALL leave both panes at their current positions.

#### Scenario: Find operates on the focused pane
- **WHEN** the editor pane has focus and the user invokes Find
- **THEN** the find bar searches the editor source
- **WHEN** the preview pane has focus and the user invokes Find
- **THEN** the find bar searches the rendered preview

#### Scenario: Outline jump moves both panes
- **WHEN** the user selects a heading in the outline while in Side by Side mode
- **THEN** both the editor pane and the preview pane scroll to that heading

#### Scenario: Toggling a task checkbox keeps both panes in place
- **WHEN** the user clicks a task-list checkbox in the preview pane
- **THEN** the source line's task marker is updated and the editor reflects it
- **AND** both panes remain at their current scroll positions rather than
  jumping to the top

### Requirement: Side by Side is selectable from the toolbar
The document toolbar mode control SHALL offer Side by Side as a third option
alongside Edit and Preview, each represented by a distinct icon, and its
accessibility/help text SHALL be localized in English and Simplified Chinese.
Selecting it SHALL switch the active document to Side by Side mode.

#### Scenario: Selecting Side by Side from the toolbar
- **WHEN** the user picks the Side by Side segment in the toolbar mode control
- **THEN** the document switches to Side by Side mode
- **AND** the control reflects Side by Side as the active selection

### Requirement: Side by Side is reachable through its configured shortcut
The app SHALL provide a configured direct shortcut for Side by Side mode. The default Side by Side shortcut SHALL be `Command-3`. Invoking the Side by Side shortcut SHALL enter Side by Side mode through the same transition path as selecting Side by Side from the toolbar, preserving the document position and initializing both panes according to the existing Side by Side alignment requirements.

#### Scenario: Default shortcut enters Side by Side from Edit
- **WHEN** a document is open in Edit mode
- **AND** the user presses `Command-3`
- **THEN** the document switches to Side by Side mode
- **AND** the editor pane remains at the user's current editing position
- **AND** the preview pane aligns to the same source content

#### Scenario: Default shortcut enters Side by Side from Preview
- **WHEN** a document is open in Preview mode
- **AND** the user presses `Command-3`
- **THEN** the document switches to Side by Side mode
- **AND** both panes align to the content that was visible in Preview mode

#### Scenario: Customized Side by Side shortcut is used
- **WHEN** the user changes the Side by Side shortcut to `Command-Option-3` in Settings
- **AND** a document is open in Edit or Preview mode
- **AND** the user presses `Command-Option-3`
- **THEN** the document switches to Side by Side mode
- **AND** `Command-3` no longer switches the document to Side by Side mode

### Requirement: A preview load ends only with its own page
From the moment a full preview load starts until the page of the latest load finishes, the preview SHALL treat itself as loading, whatever other page finishes in that time. A page that finishes while a newer load is on its way SHALL NOT open the live-update path and SHALL NOT receive the work done after a load: typography, the pending scroll target and the pending search SHALL wait for the page of the latest load. An edit made while a load is on its way SHALL reach the preview through a load of its own, so that the page which lands shows the newest text and carries the source-line revision of that text. The Reload in the web view's context menu SHALL count as such a load.

#### Scenario: An edit during a load is not overwritten by that load
- **WHEN** a full preview load is on its way, the older page finishes, and the user edits the document before the new page commits
- **THEN** the edit does not go into the older page
- **AND** the page that lands shows the edited text
- **AND** that page carries the source-line revision of the edited text

#### Scenario: A page on its way out does not use up the work after a load
- **WHEN** a scroll target and a search are pending and a page that a newer load will replace finishes
- **THEN** the scroll target and the search stay pending and that page gets no typography
- **AND** the page of the latest load gets all three when it finishes

#### Scenario: A reload finishes like any load
- **WHEN** the user chooses Reload in the preview's context menu
- **THEN** the preview counts as loaded once the page finishes
- **AND** the page gets its typography

### Requirement: Reload in the preview shows the newest text
The Reload in the preview's context menu SHALL show the document's newest rendered text, never a page older than what the preview was last given, whether that text reached the preview through a live update or a full load. It SHALL do so by loading that text as a full preview load, at any moment, including while another load is on its way. The page that lands SHALL carry the source-line revision of its text, so that its checkboxes work. The Reload SHALL keep the reader's place, SHALL leave the next live update able to keep the blocks it does not change, and SHALL run an open search again on the new page.

#### Scenario: Reload after a live edit shows the edit
- **WHEN** the user edits the document in Side by Side, the edit reaches the preview in place, and the user chooses Reload in the preview's context menu
- **THEN** the preview shows the edited text
- **AND** the page carries the source-line revision of that text
- **AND** a click on a checkbox toggles its task

#### Scenario: Reload with no edit keeps the checkboxes working
- **WHEN** the user chooses Reload on a preview that has had no edit
- **THEN** the page carries the source-line revision of its text
- **AND** a click on a checkbox toggles its task

#### Scenario: Reload keeps the reader's place
- **WHEN** the user has scrolled the preview and chooses Reload
- **THEN** the page comes back at the same place

#### Scenario: An edit after a Reload keeps unchanged blocks
- **WHEN** the user chooses Reload and then edits one block
- **THEN** the blocks the edit did not change stay in the page

#### Scenario: Reload runs an open search again
- **WHEN** a search is open in the preview and the user chooses Reload
- **THEN** the new page shows that search's matches

#### Scenario: Reload during a load still lands the newest text
- **WHEN** a full preview load is on its way and the user chooses Reload
- **THEN** the page that lands shows the newest text
- **AND** that page carries the source-line revision of that text

