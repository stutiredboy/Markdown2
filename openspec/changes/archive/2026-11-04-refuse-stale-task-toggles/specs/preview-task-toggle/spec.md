## ADDED Requirements

### Requirement: A click from a stale preview is refused
The system SHALL apply a checkbox click only when the page it was made on shows the source lines of the current document text. A click from a page rendered before a change that can move a task to another line SHALL be refused without modifying the document, whatever the addressed line now contains. Every text change counts as such a change except a toggle from the preview, which moves no line, so a click made before an earlier toggle's re-render lands is not stale. The check SHALL run when the document would be changed, not when the click arrives. A page whose content is current SHALL accept clicks even when the text changed without changing the rendered page.

#### Scenario: A task lands above the clicked one
- **WHEN** the preview shows `- [ ] A` on line 1, the source changes to `- [ ] N` followed by `- [ ] A`, and the user clicks A before the preview updates
- **THEN** the document text is unchanged

#### Scenario: The addressed line reads the same as the clicked one
- **WHEN** the preview shows `- [ ] repeat` on line 1, an identical line is inserted above it, and the user clicks the box before the preview updates
- **THEN** the document text is unchanged

#### Scenario: The clicked task was deleted or moved
- **WHEN** the task a stale preview shows has been deleted or moved, and another task now sits on its line
- **THEN** a click on it leaves the document text unchanged

#### Scenario: The document was replaced
- **WHEN** a click comes from a page of text that a reload, an external change or an open has replaced
- **THEN** the document text is unchanged

#### Scenario: Ticking down a list faster than the preview re-renders
- **WHEN** the user clicks one task and then another before the first click's re-render lands
- **THEN** both tasks are toggled

#### Scenario: The preview has caught up
- **WHEN** a click was refused and the preview has since updated
- **THEN** a click on the same task toggles that task

#### Scenario: New text renders to the same page
- **WHEN** the source changes in a way that does not change the rendered page, such as a trailing line break, and the preview has caught up
- **THEN** a click toggles its task

### Requirement: The preview's source revision is out of page script's reach
The system SHALL keep what identifies the source a page was rendered from in the bridge's isolated content world, set by native. Page script SHALL NOT be able to read it or change the value a click sends, and it SHALL NOT appear in the DOM or in exported PDF or HTML. It SHALL be updated on full loads and on live updates alike, and never before the content it describes is in the page.

#### Scenario: Page script looks for the revision
- **WHEN** page script reads the page's globals and DOM attributes
- **THEN** it finds no source revision

#### Scenario: Page script writes a revision
- **WHEN** page script sets the same global to the current revision on a stale page and the user clicks a box
- **THEN** the click is refused

#### Scenario: A live update is on its way
- **WHEN** new content has been handed to the preview but is not in the page yet
- **THEN** a click on the page is judged by the revision of what it still shows

#### Scenario: A newer load replaces a page
- **WHEN** a page commits while a newer load is being prepared
- **THEN** the page has no revision, and a click on it is refused

## MODIFIED Requirements

### Requirement: Invalid toggle requests are ignored
The system SHALL validate a toggle request before mutating the document: the addressed line MUST exist and MUST contain a task-list marker. Requests that fail validation SHALL be ignored without modifying the document. When a click is refused or ignored for any reason, the system SHALL put the preview's checkbox back to the state the page was rendered with, because no re-render follows and a live update keeps a block whose HTML did not change.

#### Scenario: Line is not a task item
- **WHEN** a toggle request addresses a line that contains no task-list marker
- **THEN** the document text is unchanged

#### Scenario: Line is out of range
- **WHEN** a toggle request addresses a line number beyond the end of the document
- **THEN** the document text is unchanged

#### Scenario: A refused click's box goes back
- **WHEN** a click on an unchecked box is refused
- **THEN** the box shows unchecked again

#### Scenario: The refusal reaches a block the update kept
- **WHEN** a click is refused and a live update that keeps the box's block lands before the refusal does
- **THEN** the box shows the state of the source once the refusal arrives

#### Scenario: A click on a page with no revision
- **WHEN** a click's message carries no source revision
- **THEN** the document text is unchanged and the box goes back
