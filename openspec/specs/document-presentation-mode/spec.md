## Purpose

Define the Write / Read / Side by Side presentation modes: defaults for opened and new documents, switching commands and gestures, and configurable mode shortcuts.

## Requirements

### Requirement: Separate default mode for new documents and opened files
The app SHALL maintain two independent preferences for a document's initial editor mode: one for new/blank documents and one for documents opened from a file. New/blank documents SHALL use the new-document preference; documents opened from a file SHALL use the opened-file preference. The selection SHALL be resolved from whether the document is backed by a file.

#### Scenario: Direct launch opens a blank document in the new-document mode
- **WHEN** the app launches with no file argument and presents a new blank document
- **THEN** the document is shown in the configured new-document mode

#### Scenario: Opening a file uses the opened-file mode
- **WHEN** a Markdown file is opened (via file argument, the Open panel, or Finder)
- **THEN** the document is shown in the configured opened-file mode regardless of the new-document mode

#### Scenario: New command uses the new-document mode
- **WHEN** the user creates a document with the New command
- **THEN** the document is shown in the configured new-document mode

#### Scenario: Reusable blank window adopts the opened-file mode when a file loads into it
- **WHEN** an untouched blank window is reused to load an opened file
- **THEN** the document switches to the configured opened-file mode

### Requirement: New documents default to Edit mode
When no new-document mode preference has been saved, the app SHALL default new/blank documents to Edit mode.

#### Scenario: First run, no saved preference
- **WHEN** the app opens a new/blank document and no new-document mode preference exists
- **THEN** the document is shown in Edit mode

#### Scenario: Existing opened-file preference is preserved
- **WHEN** a user already has a saved default-mode preference from before this change
- **THEN** that preference continues to apply to documents opened from a file
- **AND** new/blank documents default to Edit mode

### Requirement: Both modes are configurable in Settings
The Settings window SHALL expose both the new-document mode and the opened-file
mode as separate, clearly labeled controls offering Edit, Side by Side, and
Preview, with labels localized in English and Simplified Chinese. Changes SHALL
persist across launches.

#### Scenario: User changes the new-document mode
- **WHEN** the user sets the new-document mode to Preview in Settings
- **THEN** subsequently created new/blank documents are shown in Preview mode
- **AND** the choice persists after relaunching the app

#### Scenario: Opened-file mode is independent
- **WHEN** the user sets the opened-file mode to Preview and leaves the new-document mode at Edit
- **THEN** opened files are shown in Preview while new/blank documents remain in Edit

#### Scenario: User selects Side by Side as a default mode
- **WHEN** the user sets the new-document mode (or the opened-file mode) to
  Side by Side in Settings
- **THEN** subsequently created new/blank documents (or opened files) are shown
  in Side by Side mode
- **AND** the choice persists after relaunching the app

### Requirement: Side by Side is an available presentation mode
The app SHALL support Side by Side as a third presentation mode value that both
the new-document mode preference and the opened-file mode preference can hold.
When either preference is set to Side by Side, the document SHALL be resolved to
Side by Side mode on open using the same file-backed vs. new-document resolution
as the other modes. A previously saved Edit or Preview preference SHALL continue
to resolve unchanged.

#### Scenario: Opened-file preference set to Side by Side
- **WHEN** the opened-file mode preference is Side by Side and a Markdown file is
  opened
- **THEN** the document is shown in Side by Side mode

#### Scenario: Existing Edit/Preview preferences are unaffected
- **WHEN** a user already has a saved Edit or Preview mode preference from before
  this change
- **THEN** that preference continues to resolve to the same mode

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
