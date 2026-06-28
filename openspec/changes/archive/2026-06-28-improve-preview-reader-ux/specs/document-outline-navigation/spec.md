## ADDED Requirements

### Requirement: Outline rows are reliable navigation controls
Each outline row SHALL behave as a navigation control for its corresponding heading. The row SHALL activate with a normal mouse click and SHALL expose an explicit accessibility activation action that performs the same navigation.

#### Scenario: Mouse click navigates to heading
- **WHEN** the outline is visible
- **AND** the user clicks a heading row
- **THEN** the active document surface scrolls to the selected heading
- **AND** the outline row becomes selected

#### Scenario: Accessibility activation navigates to heading
- **WHEN** an assistive technology activates an outline heading row
- **THEN** the app scrolls to the corresponding heading
- **AND** the action does not require coordinate-based clicking

#### Scenario: Long heading remains usable
- **WHEN** a heading title is longer than the outline width
- **THEN** the row remains activatable across its visible width
- **AND** the row exposes the full heading title through accessibility metadata

### Requirement: Outline supports keyboard navigation
The outline SHALL support keyboard navigation when it has focus. Users SHALL be able to move between heading rows and activate the selected row without using the mouse.

#### Scenario: Arrow keys move selection
- **WHEN** the outline has keyboard focus
- **AND** the user presses the Up or Down arrow key
- **THEN** the selected outline row changes to the previous or next visible heading row

#### Scenario: Return activates selected heading
- **WHEN** the outline has keyboard focus
- **AND** an outline row is selected
- **AND** the user presses Return
- **THEN** the app scrolls to that heading

#### Scenario: Keyboard navigation preserves document focus path
- **WHEN** the user activates a heading from the outline with the keyboard
- **THEN** the destination surface is scrolled to the heading
- **AND** the user can return focus to the editor or preview without losing the selected outline row

### Requirement: Outline selection tracks navigation state
The outline SHALL reflect the heading selected by an explicit outline activation. When the nearest visible heading can be determined from the document viewport, the outline SHALL update selection to that heading. At minimum, an outline-triggered jump SHALL leave the selected row visually and accessibly marked as selected.

#### Scenario: Selected row is visible after jump
- **WHEN** the user selects a heading from the outline
- **THEN** the selected row is visually distinct
- **AND** the selected row exposes selected state to accessibility clients

#### Scenario: Switching modes keeps selected heading context
- **WHEN** a heading is selected from the outline
- **AND** the user switches between Read, Edit, and Side by Side modes
- **THEN** the selected outline row remains associated with the same heading
- **AND** the destination mode scrolls near that heading when possible

### Requirement: Empty outline communicates state
When a document has no headings, the outline SHALL show a localized empty state and SHALL not expose inert heading rows.

#### Scenario: Document without headings
- **WHEN** the outline is visible for a document with no headings
- **THEN** the outline shows a localized no-headings message
- **AND** keyboard and accessibility navigation do not expose fake heading rows
