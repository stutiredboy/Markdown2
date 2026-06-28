## ADDED Requirements

### Requirement: Export as self-contained HTML

The app SHALL provide a command to export the rendered document as a single
self-contained HTML file. The exported file SHALL open and display correctly with
no external files and no network access — all styles and the math and diagram
engines SHALL be embedded in the file. Like PDF export, HTML export SHALL be a
derived artifact: it SHALL NOT change the document's `fileURL`, dirty state, or
autosave, and the pending render SHALL be flushed first so the export reflects the
latest text.

#### Scenario: Export produces a single file

- **WHEN** the user invokes Export as HTML and chooses a destination
- **THEN** a single `.html` file is written to that destination
- **AND** no sidecar asset files are created next to it

#### Scenario: Exported HTML opens offline

- **WHEN** the exported HTML file is opened in a browser with no network access
- **THEN** the document content, styles, math, and diagrams all display correctly

#### Scenario: Export does not alter the document

- **WHEN** the user exports HTML
- **THEN** the document's saved file, dirty indicator, and autosave are unaffected

### Requirement: Local images are inlined; remote images preserved

The self-contained HTML export SHALL inline images referenced by local relative or
absolute paths as embedded data so they display without the original files.
Images referenced by remote `http`/`https` URLs SHALL be left as URLs (not
required to be inlined). When the document has no file location (untitled),
local image paths cannot be resolved and SHALL be left as-is rather than failing
the export.

#### Scenario: Local image is embedded

- **WHEN** a document references a local image by a relative path and is exported to HTML
- **THEN** the image is embedded in the HTML and displays when the file is opened elsewhere

#### Scenario: Remote image URL is preserved

- **WHEN** a document references an image by an `https` URL and is exported to HTML
- **THEN** the exported HTML keeps the `https` URL for that image

#### Scenario: Untitled document exports without failing on images

- **WHEN** an untitled document containing a relative image reference is exported to HTML
- **THEN** the export succeeds
- **AND** the image reference is left as-is (not inlined, since the file path cannot be resolved)

### Requirement: Math and diagrams render in exported HTML

The math and diagram engines embedded in the exported HTML SHALL render the
document's formulas and diagrams when the file is opened in a browser, matching
the preview.

#### Scenario: Math renders in the opened file

- **WHEN** a document containing math is exported to HTML and opened in a browser
- **THEN** the formulas render the same as in the preview

#### Scenario: Diagrams render in the opened file

- **WHEN** a document containing a Mermaid diagram is exported to HTML and opened in a browser
- **THEN** the diagram renders the same as in the preview
