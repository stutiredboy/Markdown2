## MODIFIED Requirements

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

## ADDED Requirements

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
