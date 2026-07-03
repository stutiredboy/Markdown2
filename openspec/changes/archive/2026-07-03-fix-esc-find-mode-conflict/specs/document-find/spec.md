## MODIFIED Requirements

### Requirement: Dismiss find
The system SHALL dismiss the find affordance when the user presses Esc or
activates its close control, returning keyboard focus to the document surface.
Esc SHALL dismiss a visible find affordance regardless of whether keyboard focus
is in the find affordance itself, the editor text, or the preview page, and
while a find affordance is visible Esc SHALL NOT trigger any mode-switch
gesture — dismissing find takes priority, and only a subsequent Esc (with no
find affordance visible) performs the mode gesture.
The system SHALL also dismiss the find affordance when the document mode changes
or a different document is loaded.

#### Scenario: Close with Esc
- **WHEN** the find bar is open and focused and the user presses Esc
- **THEN** the find bar closes and focus returns to the document

#### Scenario: Esc in the editor closes find instead of switching modes
- **WHEN** the find bar is open in edit mode, keyboard focus is in the editor text, and the user presses Esc
- **THEN** the find bar closes and focus stays in the editor
- **AND** the document remains in edit mode

#### Scenario: Second Esc switches modes
- **WHEN** the user presses Esc again in the editor after the find bar has closed
- **THEN** the existing Esc mode gesture applies (single-pane edit switches to preview)

#### Scenario: Esc in the preview closes the preview find bar
- **WHEN** the preview find bar is open in read mode, keyboard focus is in the preview page, and the user presses Esc
- **THEN** the find bar closes and focus returns to the preview

#### Scenario: Close on mode switch
- **WHEN** the find bar is open and the user switches between edit and preview
- **THEN** the find bar is dismissed
