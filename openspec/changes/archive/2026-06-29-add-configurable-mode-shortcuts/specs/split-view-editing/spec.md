## ADDED Requirements

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
