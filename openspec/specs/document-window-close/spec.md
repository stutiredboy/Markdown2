## Purpose

Define close and quit confirmation for documents with unsaved changes so user content is never silently discarded.

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

### Requirement: ⌘Q quit behavior preserved

Adding the ⌘W close command SHALL NOT change the existing ⌘Q quit behavior, which walks every open document window with unsaved changes and prompts to save or discard before the application terminates.

#### Scenario: Quit with multiple dirty documents

- **WHEN** the user presses ⌘Q with more than one document window holding unsaved changes
- **THEN** the application brings each dirty window to the front and prompts to save or discard, and termination is cancelled if the user cancels any prompt
