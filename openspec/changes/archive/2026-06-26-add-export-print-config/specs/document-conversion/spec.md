## ADDED Requirements

### Requirement: DOCX and EPUB export are available only when Pandoc is detected

The app SHALL offer "Export as DOCX" and "Export as EPUB" commands that are
available only when an external Pandoc binary is detected on the system. When
Pandoc is not detected, these commands SHALL be unavailable (disabled) rather than
failing at use, keeping the native pipeline dependency-free by default.

#### Scenario: Commands available with Pandoc installed

- **WHEN** Pandoc is installed and detectable and the user opens the export menu
- **THEN** the Export as DOCX and Export as EPUB commands are enabled

#### Scenario: Commands unavailable without Pandoc

- **WHEN** Pandoc is not installed or not detectable
- **THEN** the Export as DOCX and Export as EPUB commands are disabled

### Requirement: Conversion delegates to Pandoc from Markdown source

DOCX and EPUB export SHALL produce the output by invoking the external Pandoc
binary on the document's Markdown source, resolving relative image paths against
the document's directory, and writing to the user-chosen destination. The
conversion SHALL reflect the document's current content, including unsaved edits,
consistent with PDF and HTML export. Conversion SHALL be a derived artifact: it
SHALL NOT change the document's `fileURL`, dirty state, or autosave.

#### Scenario: DOCX is produced from the document

- **WHEN** the user invokes Export as DOCX with Pandoc available and chooses a destination
- **THEN** a `.docx` file containing the document's content is written to that destination

#### Scenario: EPUB is produced from the document

- **WHEN** the user invokes Export as EPUB with Pandoc available and chooses a destination
- **THEN** an `.epub` file containing the document's content is written to that destination

#### Scenario: Relative images resolve in conversion

- **WHEN** a document references a local image by a relative path and is exported to DOCX
- **THEN** the image is included in the produced DOCX

#### Scenario: Unsaved edits are included in conversion

- **WHEN** a titled document with unsaved edits is exported to DOCX
- **THEN** the produced DOCX reflects the current edited content, not only the last-saved version
- **AND** the document's dirty state is unchanged

### Requirement: Conversion failures surface guidance

The app SHALL surface a clear, localized message when a conversion is attempted
and Pandoc is missing or the Pandoc invocation fails, explaining the cause
(including that Pandoc is required) rather than failing silently or producing an
empty file. When Pandoc fails or times out, any partial output file SHALL be
deleted so a corrupt file is never presented as a success. The Pandoc invocation
SHALL be bounded by a timeout so a hung process cannot stall the app.

#### Scenario: Missing Pandoc explained

- **WHEN** a conversion is attempted in a state where Pandoc cannot be located
- **THEN** the app shows a message explaining that Pandoc is required to export DOCX/EPUB

#### Scenario: Pandoc error surfaced

- **WHEN** Pandoc is invoked but exits with an error
- **THEN** the app shows a message describing that the conversion failed
- **AND** no partial or empty output file is presented as a success

#### Scenario: Pandoc timeout

- **WHEN** Pandoc is invoked but does not complete within the timeout
- **THEN** the Pandoc process is terminated
- **AND** any partial output file is deleted
- **AND** the app shows a message describing that the conversion timed out

### Requirement: Untitled documents are saved before conversion

An untitled document (never saved) SHALL be saved to disk before DOCX/EPUB
conversion begins, so that Pandoc has a document directory against which to
resolve relative image paths. The app SHALL prompt the user to save; if the user
cancels the save, the conversion SHALL be aborted cleanly without invoking
Pandoc.

#### Scenario: Untitled document prompts to save

- **WHEN** the user invokes Export as DOCX on an untitled document
- **THEN** the app prompts to save the document first
- **AND** if the user saves, the conversion proceeds
- **AND** if the user cancels, no conversion is attempted

### Requirement: Pandoc availability is detected at use time

Pandoc availability SHALL be checked when the export menu is about to open or
when a DOCX/EPUB command is invoked, not solely at app launch. This ensures a
user who installs Pandoc while the app is running sees the commands enabled
without requiring a relaunch.

#### Scenario: Pandoc installed while app is running

- **WHEN** Pandoc is not installed at launch but is installed while the app is running
- **THEN** the Export as DOCX and Export as EPUB commands become enabled without a relaunch
