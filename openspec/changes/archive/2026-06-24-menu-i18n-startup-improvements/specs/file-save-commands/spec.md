## ADDED Requirements

### Requirement: File menu provides Save without a separate Save As command

The File menu SHALL provide a single **Save** command bound to ⌘S and SHALL NOT provide a separate **Save As…** menu command (nor the ⇧⌘S shortcut for it). Relocating an already-saved file is left to the Finder.

#### Scenario: Save As is absent from the File menu

- **WHEN** the user opens the File menu
- **THEN** there is no "Save As…" command
- **AND** the ⇧⌘S shortcut is not bound to a Save As action

#### Scenario: Save command remains available

- **WHEN** the user opens the File menu with a document frontmost
- **THEN** a Save command bound to ⌘S is present

### Requirement: Saving an untitled document prompts for a destination

When the user saves a document that has never been saved to disk, the application SHALL prompt for a save location before writing, so removing the Save As menu item does not prevent first-time saves. Saving a document that already has a file SHALL write to that file without prompting.

#### Scenario: First save of an untitled document prompts for location

- **WHEN** the user invokes Save on a document that has no file on disk
- **THEN** a save-location panel is presented and the document is written to the chosen location

#### Scenario: Saving an existing document writes in place

- **WHEN** the user invokes Save on a document that is already backed by a file
- **THEN** the document is written to its existing file without prompting for a location
