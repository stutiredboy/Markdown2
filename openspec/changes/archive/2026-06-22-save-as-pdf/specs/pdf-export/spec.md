## ADDED Requirements

### Requirement: Export as PDF command in the File menu

The application SHALL provide an **Export as PDF…** command in the File menu,
placed immediately after the **Save As…** command. The command label SHALL be
localized (English: "Export as PDF…", Simplified Chinese: "导出为 PDF…") and
SHALL act on the document shown in the frontmost window. The command SHALL NOT
bind a default keyboard shortcut, so it never conflicts with existing Save
shortcuts.

#### Scenario: Command is present and localized

- **WHEN** the File menu is opened with the app language set to Simplified Chinese
- **THEN** an entry reading "导出为 PDF…" appears directly after the "另存为..." entry

#### Scenario: Command targets the frontmost document

- **WHEN** multiple document windows are open and the user invokes Export as PDF
- **THEN** the export operates on the document in the frontmost (key) window

### Requirement: Choosing the destination file

Invoking Export as PDF SHALL present a save panel whose default file name is the
current document's name with its extension replaced by `.pdf` (or `Untitled.pdf`
for an unsaved document), restricted to the PDF content type and allowing
directory creation. If the user cancels the panel, no file SHALL be written and
the document SHALL be left unchanged.

#### Scenario: Default file name derives from the document

- **WHEN** the document is saved as `notes.md` and the user invokes Export as PDF
- **THEN** the save panel's default file name is `notes.pdf`

#### Scenario: Unsaved document default name

- **WHEN** the document has never been saved and the user invokes Export as PDF
- **THEN** the save panel's default file name is `Untitled.pdf`

#### Scenario: Cancelling the save panel

- **WHEN** the user dismisses the save panel without choosing a destination
- **THEN** no PDF file is created
- **AND** the document's file URL and dirty state are unchanged

### Requirement: Exported PDF matches the rendered preview

The exported PDF SHALL reproduce the Read-mode preview of the current document
content, including rendered KaTeX math, diagrams (Mermaid, flow, sequence),
syntax-highlighted code blocks, and images referenced by paths relative to the
document. The export SHALL reflect the latest editor content even when a render
is still pending, and SHALL produce correct output regardless of which editor
mode (Edit, Preview, or Side by Side) is currently active. The export SHALL wait
for asynchronous rendering engines to settle before producing the PDF.

#### Scenario: Math and diagrams are rendered, not shown as source

- **WHEN** a document containing a KaTeX expression and a Mermaid diagram is exported
- **THEN** the PDF shows the rendered formula and the rendered diagram
- **AND** does not show their raw source text

#### Scenario: Relative images resolve

- **WHEN** a document on disk references an image by a relative path and is exported
- **THEN** the image appears in the PDF

#### Scenario: Export reflects unsaved edits

- **WHEN** the user types new content and immediately invokes Export as PDF before the debounced preview render runs
- **THEN** the PDF includes the just-typed content

#### Scenario: Export works from Edit mode

- **WHEN** the document is in Edit mode with no preview web view mounted and the user exports
- **THEN** a faithful rendered PDF is still produced

### Requirement: Paginated, print-ready output

The exported PDF SHALL be paginated to A4 paper size so it can be printed or read
page by page, rather than emitted as a single unbounded page. The output SHALL use
print-oriented density (compact page margins and a document-scale base font)
rather than the on-screen reading layout, so each page holds a normal amount of
content. A page break SHALL NOT slice through a line of text or through an atomic
block (image, table, code block, or diagram); each page SHALL end at a safe
boundary between lines or blocks. An atomic block taller than a single page MAY be
divided as a last resort.

#### Scenario: Multi-page document paginates

- **WHEN** a document whose rendered height exceeds one page is exported
- **THEN** the resulting PDF contains multiple pages
- **AND** the pages are A4 sized

#### Scenario: Lines and blocks are not split across pages

- **WHEN** a document's content crosses a page boundary
- **THEN** no line of text is cut in half across two pages
- **AND** an image, table, code block, or diagram that fits within one page is kept whole on a single page

### Requirement: Export does not alter document state

Exporting to PDF SHALL NOT change the document's on-disk Markdown representation,
its `fileURL`, or its unsaved-changes (dirty) state. PDF is a derived artifact and
the Save As… command SHALL continue to write Markdown source.

#### Scenario: Dirty state preserved after export

- **WHEN** a document with unsaved changes is exported to PDF
- **THEN** the document still shows unsaved changes after the export completes
- **AND** its file URL still points to the Markdown file (or remains unset)

### Requirement: Export failures are surfaced

If the export cannot complete — for example the rendered page fails to settle in
time or the PDF cannot be written to the chosen location — the application SHALL
inform the user via the document alert mechanism and SHALL NOT leave a corrupt or
partial file presented as a successful export.

#### Scenario: Write failure reports an alert

- **WHEN** the PDF cannot be written to the chosen destination
- **THEN** the user is shown an alert describing the failure
- **AND** no success is implied
