## ADDED Requirements

### Requirement: Mode switch shortcuts are configurable
The app SHALL maintain one configurable keyboard shortcut for each document presentation mode: Edit, Preview, and Side by Side. When no user configuration exists, the app SHALL use `Command-1` for Edit, `Command-2` for Preview, and `Command-3` for Side by Side. These shortcuts SHALL be stored in app configuration and SHALL persist across launches. Invoking a configured mode shortcut SHALL switch the frontmost document directly to the corresponding presentation mode using the same mode-switch behavior as the toolbar mode control.

#### Scenario: First launch uses safe default mode shortcuts
- **WHEN** the app starts with no stored mode shortcut configuration
- **THEN** Edit is assigned `Command-1`
- **AND** Preview is assigned `Command-2`
- **AND** Side by Side is assigned `Command-3`

#### Scenario: Default shortcut switches to Preview
- **WHEN** a document is open in Edit mode
- **AND** the user presses `Command-2`
- **THEN** the document switches to Preview mode
- **AND** the mode control reflects Preview as the active mode

#### Scenario: Default shortcut switches to Edit
- **WHEN** a document is open in Preview mode
- **AND** the user presses `Command-1`
- **THEN** the document switches to Edit mode
- **AND** the mode control reflects Edit as the active mode

#### Scenario: User shortcut configuration persists
- **WHEN** the user changes the Preview mode shortcut to `Command-Option-2` in Settings
- **AND** the app is relaunched
- **THEN** Preview mode remains assigned to `Command-Option-2`
- **AND** `Command-2` no longer switches the document to Preview mode

#### Scenario: Invalid stored shortcut configuration falls back to defaults
- **WHEN** stored mode shortcut configuration is missing, malformed, or cannot be decoded
- **THEN** the app uses the default `Command-1`, `Command-2`, and `Command-3` mode shortcuts

### Requirement: Mode shortcut configuration prevents conflicts
The app SHALL validate customized mode shortcuts before applying them. The app SHALL NOT accept duplicate mode shortcuts, shortcuts already assigned to Markdown2 commands, or shortcuts known to be reserved or high-risk on macOS, including system app switching, Spotlight, window/app management, force quit, screenshots, Mission Control/Spaces, and bare Escape. Rejected shortcuts SHALL leave the previous valid shortcut active.

#### Scenario: Duplicate mode shortcut is rejected
- **WHEN** Edit is assigned `Command-1`
- **AND** the user attempts to assign Preview to `Command-1`
- **THEN** the app rejects the Preview shortcut change
- **AND** Edit remains assigned to `Command-1`
- **AND** Preview keeps its previous valid shortcut

#### Scenario: Existing app command shortcut is rejected
- **WHEN** the user attempts to assign Edit mode to `Command-S`
- **THEN** the app rejects the shortcut because `Command-S` is already used for Save
- **AND** the previous valid Edit shortcut remains active

#### Scenario: macOS reserved shortcut is rejected
- **WHEN** the user attempts to assign Preview mode to `Command-Space`
- **THEN** the app rejects the shortcut because it conflicts with a system-level shortcut
- **AND** the previous valid Preview shortcut remains active

#### Scenario: Existing mode entry gestures remain available
- **WHEN** mode shortcuts are configured
- **THEN** the existing Escape and Cmd+double-click mode entry or exit gestures continue to behave as before
- **AND** the configured direct shortcuts provide additional mode switching paths rather than replacing those gestures
