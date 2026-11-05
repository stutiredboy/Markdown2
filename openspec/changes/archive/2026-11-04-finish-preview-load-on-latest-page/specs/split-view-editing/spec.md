## ADDED Requirements

### Requirement: A preview load ends only with its own page
From the moment a full preview load starts until the page of the latest load finishes, the preview SHALL treat itself as loading, whatever other page finishes in that time. A page that finishes while a newer load is on its way SHALL NOT open the live-update path and SHALL NOT receive the work done after a load: typography, the pending scroll target and the pending search SHALL wait for the page of the latest load. An edit made while a load is on its way SHALL reach the preview through a load of its own, so that the page which lands shows the newest text and carries the source-line revision of that text. A navigation no load started, such as the Reload in the web view's context menu, SHALL finish as before when no load is on its way.

#### Scenario: An edit during a load is not overwritten by that load
- **WHEN** a full preview load is on its way, the older page finishes, and the user edits the document before the new page commits
- **THEN** the edit does not go into the older page
- **AND** the page that lands shows the edited text
- **AND** that page carries the source-line revision of the edited text

#### Scenario: A page on its way out does not use up the work after a load
- **WHEN** a scroll target and a search are pending and a page that a newer load will replace finishes
- **THEN** the scroll target and the search stay pending and that page gets no typography
- **AND** the page of the latest load gets all three when it finishes

#### Scenario: A reload no load started still finishes
- **WHEN** the user chooses Reload in the preview's context menu and no load is on its way
- **THEN** the preview counts as loaded once the page finishes
- **AND** the page gets its typography
