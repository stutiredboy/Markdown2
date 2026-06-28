# reader-front-matter-presentation Specification

## Purpose
TBD - created by archiving change improve-preview-reader-ux. Update Purpose after archive.
## Requirements
### Requirement: Front matter is hidden in reader surfaces by default
The app SHALL treat YAML front matter at the start of a document as metadata in live rendered reader surfaces. Read mode and the preview pane of Side by Side mode SHALL hide front matter by default so the first visible document content is the rendered body content after the front matter block. Source editing SHALL continue to show the front matter as authored text. Shared renderer output used by PDF export, Print, self-contained HTML export, and conversion flows SHALL keep the existing front matter rendering semantics.

#### Scenario: Read mode starts with document content
- **WHEN** a Markdown file begins with a valid YAML front matter block followed by a heading
- **AND** the user opens the file in Read mode
- **THEN** the preview does not show the raw front matter block by default
- **AND** the first rendered content starts at the heading or body content after the front matter

#### Scenario: Side by Side preview hides metadata
- **WHEN** a Markdown file begins with a valid YAML front matter block
- **AND** the user switches to Side by Side mode
- **THEN** the editor pane still shows the front matter source text
- **AND** the preview pane does not show the raw front matter block by default

#### Scenario: Editor mode preserves source text
- **WHEN** a Markdown file begins with a valid YAML front matter block
- **AND** the user switches to Edit mode
- **THEN** the editor displays the front matter exactly as source text
- **AND** saving the document preserves the front matter unless the user edits it

### Requirement: Front matter can be inspected explicitly
The app SHALL provide an explicit per-window way to show and hide front matter metadata in rendered reader surfaces. The control SHALL be discoverable from the reader UI or application menu and SHALL NOT require editing the Markdown source. The control SHALL default to hidden for each opened document and SHALL NOT persist as a global preference in this change.

#### Scenario: User shows metadata in Read mode
- **WHEN** a document has front matter hidden in Read mode
- **AND** the user enables the metadata display control
- **THEN** the rendered preview shows the front matter metadata in a readable, non-editing presentation
- **AND** the Markdown source remains unchanged

#### Scenario: User hides metadata again
- **WHEN** front matter metadata is visible in the rendered preview
- **AND** the user disables the metadata display control
- **THEN** the rendered preview hides the front matter metadata
- **AND** the current document source remains unchanged

#### Scenario: Opening another document resets metadata visibility
- **WHEN** the user has enabled metadata display for one document
- **AND** another document is opened in the same reusable window
- **THEN** the rendered preview hides front matter by default for the new document

#### Scenario: No front matter
- **WHEN** a document has no valid front matter block
- **THEN** the metadata display control does not show an empty metadata block
- **AND** the rendered preview starts with the document's first Markdown block

#### Scenario: Export keeps existing front matter rendering
- **WHEN** a Markdown file begins with valid YAML front matter
- **AND** the user exports or prints the document
- **THEN** the export pipeline uses the shared rendered document semantics
- **AND** this live-reader visibility toggle does not remove front matter from the exported artifact

### Requirement: Hidden front matter preserves navigation fidelity
Hiding front matter in rendered reader surfaces SHALL NOT break outline navigation, source-line mapping, mode-switch scroll anchoring, or Side by Side scroll synchronization.

#### Scenario: Outline jump after hidden front matter
- **WHEN** front matter is hidden in the preview
- **AND** the user selects a heading in the outline
- **THEN** the preview scrolls to the selected heading
- **AND** the editor scrolls to the corresponding source heading when applicable

#### Scenario: Mode switch preserves position below front matter
- **WHEN** the user is reading content below a hidden front matter block
- **AND** the user switches between Read, Edit, and Side by Side modes
- **THEN** the destination surface lands near the same document content
- **AND** it does not jump to the hidden front matter block

