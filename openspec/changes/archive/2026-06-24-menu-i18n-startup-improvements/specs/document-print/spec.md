## ADDED Requirements

### Requirement: Print command in the File menu

The application SHALL provide a **Print** command in the File menu, placed in the standard print location and bound to the ⌘P keyboard shortcut, that prints the current (frontmost) document. The command's title SHALL be localized in English and Simplified Chinese.

#### Scenario: Print from the menu

- **WHEN** the user selects File ▸ Print with a document window frontmost
- **THEN** the system print dialog is presented for that document

#### Scenario: Print via shortcut

- **WHEN** the user presses ⌘P with a document window frontmost
- **THEN** the system print dialog is presented for that document

#### Scenario: No document focused

- **WHEN** the user invokes Print while no document window is focused
- **THEN** the application does not crash and no print dialog is presented unexpectedly

### Requirement: Print reflects the rendered document content

Printing SHALL produce the document's rendered (formatted) output — the same content as the preview and PDF export — rather than the raw Markdown source. The latest edits SHALL be reflected: any pending render is flushed before printing.

#### Scenario: Print shows formatted output

- **WHEN** the user prints a document containing Markdown formatting
- **THEN** the printed output shows the rendered, formatted content rather than the raw Markdown text

#### Scenario: Recent edits are included

- **WHEN** the user edits the document and immediately invokes Print
- **THEN** the printed output reflects the latest edits

#### Scenario: Printing does not alter document state

- **WHEN** the user prints a document
- **THEN** the document's file URL and unsaved-changes (dirty) state are unchanged by printing

### Requirement: Print failures are surfaced, not silent

When the document cannot be prepared for printing, the application SHALL surface an error to the user through the normal document alert path rather than failing silently.

#### Scenario: Preparation failure is reported

- **WHEN** preparing the document for printing fails
- **THEN** the user is shown an error describing that the document could not be printed
