## Purpose

Define explicit-close confirmation and durable recovery on Quit so user content is never silently discarded.

## Requirements

### Requirement: Close active document with ⌘W

The application SHALL provide a **Close** command in the File menu, bound to the ⌘W keyboard shortcut, that closes the frontmost document window.

#### Scenario: Close a saved document

- **WHEN** the user presses ⌘W while a document window with no unsaved changes is frontmost
- **THEN** that document window closes immediately without any prompt

#### Scenario: Close from the menu bar

- **WHEN** the user selects File ▸ Close
- **THEN** the frontmost document window closes following the same behavior as the ⌘W shortcut

#### Scenario: No document window focused

- **WHEN** the user presses ⌘W while no document window is the key window
- **THEN** the application does not crash and no document window is closed unexpectedly

### Requirement: Unsaved-changes protection on close

When closing a document window that has unsaved changes, the application SHALL prompt the user to Save, Cancel, or Don't Save before the window is closed, reusing the same confirmation flow already used by the window's close button.

#### Scenario: Close a dirty document and save

- **WHEN** the user presses ⌘W on a document with unsaved changes
- **AND** chooses **Save** in the confirmation prompt
- **THEN** the document is saved and the window closes

#### Scenario: Close a dirty document and discard

- **WHEN** the user presses ⌘W on a document with unsaved changes
- **AND** chooses **Don't Save** in the confirmation prompt
- **THEN** the window closes and the unsaved changes are discarded

#### Scenario: Cancel closing a dirty document

- **WHEN** the user presses ⌘W on a document with unsaved changes
- **AND** chooses **Cancel** in the confirmation prompt
- **THEN** the window stays open and the document is unchanged

### Requirement: Quit preserves the open session
The application SHALL flush safe edits to named files and atomically persist all open windows and drafts before quitting. It SHALL cancel Quit if a recovery flush fails. Untitled drafts and edits blocked by a conflict or encoding choice SHALL remain recoverable without a save-location prompt. Explicit window close SHALL still ask Save / Cancel / Don't Save when dirty, then delete the recovery record and cancel pending writes only after close is confirmed.

#### Scenario: Quit with multiple dirty documents
- **WHEN** the user presses ⌘Q with several dirty document windows
- **THEN** their content and window geometry are persisted, safe named edits are written back, and relaunch restores the windows

#### Scenario: Confirmed close discards its recovery copy
- **WHEN** the user chooses Don't Save while closing a dirty document
- **THEN** that window's recovery record is removed and no queued autosave can recreate it

#### Scenario: Quit cannot write recovery data
- **WHEN** a final recovery snapshot cannot be written
- **THEN** termination is cancelled and the affected document remains open with an error
