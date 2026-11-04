# document-toolbar-discoverability Specification

## Purpose
TBD - created by archiving change improve-preview-reader-ux. Update Purpose after archive.
## Requirements
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

### Requirement: The presentation-mode control stays in the toolbar
The presentation-mode control SHALL stay directly reachable in the toolbar, and never in its overflow menu, at every width a document window can take, in English and Simplified Chinese, with and without front matter, in Edit, Side by Side and Read modes, and whatever the length of the document's file name. When the toolbar is short of space, its secondary controls SHALL collapse first: Line Numbers and the metadata control SHALL drop to their icons before the presentation-mode control gives up its text, and the presentation-mode control MAY then show icon-only segments. If the toolbar still cannot fit, Open and Save SHALL move to the overflow menu before the presentation-mode control does.

#### Scenario: Narrow window keeps the mode control
- **WHEN** a document window is 800 pt wide, in Side by Side, with a document that has front matter
- **THEN** the toolbar shows the presentation-mode control directly
- **AND** the user can switch mode from it without opening the overflow menu

#### Scenario: Default-width window keeps the mode control and its text
- **WHEN** a document window is shown at the app's default window width, in either language, with or without front matter
- **THEN** the presentation-mode control is in the toolbar
- **AND** its segments show the localized names of the modes

#### Scenario: Secondary controls collapse first
- **WHEN** the window narrows from a width that shows every toolbar label
- **THEN** Line Numbers and the metadata control lose their text first
- **AND** the presentation-mode control loses its text only at a narrower width

#### Scenario: Long file name
- **WHEN** the document's file name is too long to show in full
- **THEN** the window title truncates
- **AND** the presentation-mode control stays in the toolbar

#### Scenario: Icon-only segments keep their names
- **WHEN** the presentation-mode control shows icon-only segments
- **THEN** each segment exposes the mode's name as its accessibility label, in the app's language
- **AND** the control keeps its help text

### Requirement: Switching mode does not move the presentation-mode control
Switching between Edit, Side by Side and Read at a given window width SHALL NOT move the presentation-mode control or change whether it shows text, so that a pointer resting on the control stays on the same segment after a switch. Which toolbar labels show text SHALL depend on the window width only.

#### Scenario: The metadata control appears with the mode
- **WHEN** the document has front matter and the user switches from Edit to Side by Side at a width where nothing has to overflow
- **THEN** the metadata control appears
- **AND** the presentation-mode control stays where it was

