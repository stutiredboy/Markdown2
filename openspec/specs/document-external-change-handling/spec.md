# document-external-change-handling Specification

## Purpose

Define how a document window detects and responds to external modification, replacement, or deletion of its backing file: automatic reload (preserving viewport) when clean, a conflict choice when dirty, and overwrite protection on every write.

## Requirements
### Requirement: File-backed documents are watched for external changes
The app SHALL observe the backing file of every file-backed document window for external modification, replacement (write-rename/atomic saves), and deletion, from load or first save until the window closes. Events caused by the app's own writes SHALL be recognized (by comparing against the last content the app read or wrote) and ignored. Untitled documents SHALL NOT be watched.

#### Scenario: Own save does not trigger change handling
- **WHEN** the app saves or autosaves the document to its backing file
- **THEN** the resulting file-system event is recognized as the app's own write
- **AND** no reload or conflict prompt occurs

#### Scenario: Atomic-save replacement is detected
- **WHEN** an external editor saves the file by writing a temporary file and renaming it over the original
- **THEN** the app detects the replacement and handles it as an external modification

### Requirement: Clean documents reload external changes automatically
WHEN the backing file's content changes externally and the document has no unsaved edits, the app SHALL reload the document from disk in place: the window SHALL keep its current mode, outline visibility, and viewport position (anchored to the same content), and the rendered preview, outline, and statistics SHALL reflect the new content.

#### Scenario: External edit refreshes a clean window
- **WHEN** the file is modified externally while the document has no unsaved edits
- **THEN** the window updates to show the new file content without user interaction
- **AND** the current mode and scroll position are preserved

#### Scenario: Metadata-only touch does not reload
- **WHEN** the file's modification date changes but its content bytes are identical
- **THEN** no reload occurs

### Requirement: Dirty documents get a conflict choice instead of silent loss
WHEN the backing file changes externally while the document has unsaved edits, the app SHALL NOT modify the in-memory text and SHALL NOT autosave over the external change. It SHALL present a localized conflict prompt on the affected window offering to reload from disk (discarding the in-memory edits) or keep the in-memory version (after which the next save overwrites the file). While the conflict is unresolved, autosave SHALL remain suspended for that document.

#### Scenario: Conflict prompt on external change with unsaved edits
- **WHEN** the file changes externally while the document is dirty
- **THEN** a prompt offers "Reload from Disk" and "Keep My Version" in the app language
- **AND** the document text is unchanged until the user chooses

#### Scenario: Keep My Version then save overwrites
- **WHEN** the user chooses to keep their version and then saves
- **THEN** the file is overwritten with the in-memory content and the conflict is cleared

#### Scenario: Reload from Disk discards edits
- **WHEN** the user chooses to reload from disk
- **THEN** the document shows the on-disk content, is no longer dirty, and the viewport is preserved

### Requirement: Writes never silently overwrite unseen external changes
Every write of the document to its backing file (manual save and autosave) SHALL first verify that the on-disk state still matches the last content the app read from or wrote to that file. On mismatch the write SHALL be aborted and the conflict handling SHALL run instead of overwriting.

#### Scenario: Autosave aborts on unseen external change
- **WHEN** the autosave timer fires after the file was changed externally
- **THEN** the file is not overwritten
- **AND** the conflict prompt is presented

### Requirement: Renames and moves preserve file identity
The app SHALL resolve the document bookmark before evaluating external events and before writing. A Finder rename or move SHALL update the window title, represented URL, relative-resource base directory, and file watcher without resetting the document identity or undo history. Autosave SHALL write to the resolved location even when the watcher has not delivered the rename yet.

#### Scenario: Rename immediately followed by Save
- **WHEN** the open file is renamed and the user saves before the watcher event arrives
- **THEN** the renamed file receives the edits and the old path is not recreated

#### Scenario: The old name is reused
- **WHEN** another file appears at the original path after a rename
- **THEN** the document follows its bookmark and does not overwrite the unrelated file

### Requirement: External deletion keeps the user's content safe
WHEN the backing file is deleted or moved to Trash, the app SHALL keep its content in memory and recovery storage, mark it dirty, and suspend autosave to that file. Manual save SHALL ask for a destination, and cancellation SHALL leave the disk unchanged.

#### Scenario: Deleted file is not recreated by autosave
- **WHEN** the backing file is deleted and the user continues typing
- **THEN** the edits are recoverable and no file is automatically written at the old path

#### Scenario: User chooses a location after deletion
- **WHEN** the user explicitly chooses a destination for Save
- **THEN** the document is saved there and normal watching resumes
