## ADDED Requirements

### Requirement: Primary toolbar actions are discoverable
The document toolbar SHALL make the primary actions for Outline, Open, Save, and presentation mode discoverable without relying only on icon recognition. At the default document window width, each primary action SHALL have either visible text in the toolbar or an adjacent visible label that identifies the action. In compact layouts, each action SHALL retain a stable accessibility label and help text.

#### Scenario: Default-width toolbar identifies actions
- **WHEN** a document window is shown at the app's default window width
- **THEN** the toolbar exposes user-visible labels or adjacent text identifying Outline, Open, Save, and presentation mode controls
- **AND** the labels match the active app language

#### Scenario: Compact toolbar keeps accessible labels
- **WHEN** the document window is too narrow to show all toolbar text
- **THEN** toolbar controls use icon-only presentation when needed
- **AND** each collapsed control still exposes a localized accessibility label and help text

#### Scenario: Toolbar labels do not resize content panes unexpectedly
- **WHEN** toolbar labels appear or collapse because the window width changes
- **THEN** the editor, preview, outline, and status bar keep stable layout constraints
- **AND** document content does not overlap the toolbar

### Requirement: Mode switching is self-explanatory
The presentation-mode control SHALL identify the available Edit, Side by Side, and Read modes and SHALL expose the currently selected mode through visible or accessible state. The control SHALL preserve the existing mode-switch behavior and shortcuts.

#### Scenario: Mode options are labeled
- **WHEN** the user inspects the presentation-mode control
- **THEN** Edit, Side by Side, and Read modes are identifiable by localized text or accessible labels
- **AND** the selected mode is distinguishable from the unselected modes

#### Scenario: Mode switching behavior is preserved
- **WHEN** the user changes between Edit, Side by Side, and Read modes from the toolbar
- **THEN** the document switches to the chosen mode
- **AND** existing viewport anchoring behavior is preserved

### Requirement: Toolbar command names match menu commands
Toolbar labels, help text, and accessibility labels SHALL use the same localized terminology as the corresponding application menu commands where a matching command exists.

#### Scenario: Open and Save names match
- **WHEN** the app language is English or Simplified Chinese
- **THEN** the toolbar Open and Save controls use the same localized action names as the File menu commands

#### Scenario: Outline naming is consistent
- **WHEN** the outline is visible or hidden
- **THEN** the toolbar outline control uses localized labels that clearly communicate Show Outline or Hide Outline
