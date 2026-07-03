## Purpose

Define clickable task-list checkboxes in the preview that update the corresponding Markdown source line.

## Requirements

### Requirement: Clicking a preview checkbox toggles the source marker
The system SHALL, when the user clicks a task-list checkbox in preview mode, update the corresponding Markdown source line to the checkbox's new state: `[ ]` when unchecked and `[x]` when checked. The updated text SHALL flow through the standard document pipeline so the preview re-renders from source, the document is marked dirty, and the existing autosave behavior applies.

#### Scenario: Checking an unchecked item
- **WHEN** the source contains the line `- [ ] Draft` and the user clicks its checkbox in the preview
- **THEN** the source line becomes `- [x] Draft`
- **AND** the document is marked dirty and autosave is scheduled as for any edit

#### Scenario: Unchecking a checked item
- **WHEN** the source contains the line `- [x] Draft` and the user clicks its checkbox in the preview
- **THEN** the source line becomes `- [ ] Draft`

#### Scenario: Uppercase marker is preserved semantically
- **WHEN** the source contains the line `- [X] Draft` and the user clicks its checkbox in the preview
- **THEN** the source line becomes `- [ ] Draft`

### Requirement: Toggle targets the exact source line
The system SHALL map each clicked checkbox to its originating source line using the checkbox's source-line metadata, so toggling works for nested task items, task items inside blockquotes, and documents containing multiple identical task lines. Only the marker characters on the targeted line SHALL change; all other text, indentation, and prefixes SHALL be preserved.

#### Scenario: Nested task item toggles its own line
- **WHEN** the source contains `- [ ] parent` followed by `    - [ ] child` and the user clicks the child's checkbox
- **THEN** only the `    - [ ] child` line changes to `    - [x] child`

#### Scenario: Task item inside a blockquote
- **WHEN** the source contains the line `> - [ ] quoted task` and the user clicks its checkbox in the preview
- **THEN** the line becomes `> - [x] quoted task` with the blockquote prefix intact

#### Scenario: Identical task lines stay independent
- **WHEN** the source contains two separate lines that both read `- [ ] repeat` and the user clicks the second one's checkbox
- **THEN** only the second line's marker changes

### Requirement: Invalid toggle requests are ignored
The system SHALL validate a toggle request before mutating the document: the addressed line MUST exist and MUST contain a task-list marker. Requests that fail validation SHALL be ignored without modifying the document.

#### Scenario: Line is not a task item
- **WHEN** a toggle request addresses a line that contains no task-list marker
- **THEN** the document text is unchanged

#### Scenario: Line is out of range
- **WHEN** a toggle request addresses a line number beyond the end of the document
- **THEN** the document text is unchanged

### Requirement: Toggle applies an absolute state
The system SHALL apply the checkbox's reported target state rather than inverting the current marker, so repeated or duplicate toggle messages for the same state are idempotent.

#### Scenario: Duplicate message is harmless
- **WHEN** two toggle requests for the same line both request the checked state
- **THEN** the line reads `[x]` after both, identical to receiving the request once

### Requirement: Preview keeps its scroll position across a toggle
The system SHALL preserve the preview's scroll position when the document re-renders as a result of a checkbox toggle, using the viewport-anchor capture and restore mechanism, so the toggled item remains visible where it was.

#### Scenario: Toggling deep in a long document
- **WHEN** the user scrolls deep into a long document in preview mode and clicks a task checkbox there
- **THEN** after the re-render the viewport shows the same content region, not the top of the document
