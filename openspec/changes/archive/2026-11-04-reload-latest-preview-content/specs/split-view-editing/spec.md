## ADDED Requirements

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

## MODIFIED Requirements

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
