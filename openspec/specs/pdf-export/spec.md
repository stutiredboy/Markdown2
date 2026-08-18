## Purpose

Define the requirements for exporting documents to PDF format with correct pagination, page-fit, and print-ready output.
## Requirements
### Requirement: Exported content fits the printable page width

The exported PDF SHALL fit all content within the printable width of the page. No
table, code block, diagram, image, or math block may extend past the right page
margin or be clipped horizontally. Content that is wider than the printable column
SHALL be wrapped to fit at the print base font size: wide tables use a fixed layout
whose cells wrap, long code-block lines wrap onto the following line, long inline
tokens (paths/URLs) break, and wide diagrams/images/formulas scale down to the page
width. The exporter SHALL NOT silently drop any content that overflows the column.

#### Scenario: Wide table keeps all columns

- **WHEN** a document containing a table wider than the printable column is exported
- **THEN** every column of the table appears in the PDF within the page width
- **AND** no column is cut off at the right page margin

#### Scenario: Long code line is not truncated

- **WHEN** a fenced code block contains a line longer than the printable width is exported
- **THEN** the full line text appears in the PDF, wrapped onto additional lines as needed
- **AND** no characters are lost at the right page margin

#### Scenario: Wide diagram scales to the page

- **WHEN** a document containing a diagram wider than the printable column is exported
- **THEN** the diagram appears scaled to fit within the page width
- **AND** is not clipped at the right page margin

#### Scenario: Wide display math scales to the page

- **WHEN** a document containing a display-math formula wider than the printable column is exported
- **THEN** the full formula appears in the PDF, scaled down to fit within the page width
- **AND** no part of the formula is clipped at the right page margin

### Requirement: Paginated, print-ready output

The exported PDF SHALL be paginated to a configurable page **size** and
**orientation** drawn from the active export profile so it can be printed or read
page by page, rather than emitted as a single unbounded page. The default profile
SHALL be **A4, portrait**, so output is unchanged unless the user opts in. The
output SHALL use print-oriented density — page **margins** from the active profile
(default **narrow, ~0.5", on every side**) and a document-scale base font — rather
than the on-screen reading layout, so each page holds a normal amount of content
and little page area is wasted to whitespace. A page break SHALL NOT slice through
a line of text or through an atomic block (image, table, code block, or diagram);
each page SHALL end at a safe boundary between lines or blocks. This guarantee
SHALL hold at the bottom of a page: the last line or block on a page SHALL be
rendered whole, never clipped by the page boundary. A table row that fits within a
page SHALL be kept whole and SHALL NOT be sliced across a page boundary. An atomic
block (or a single table row) taller than a single page MAY be divided as a last
resort.

#### Scenario: Multi-page document paginates

- **WHEN** a document whose rendered height exceeds one page is exported
- **THEN** the resulting PDF contains multiple pages
- **AND** the pages match the configured page size (A4 by default)

#### Scenario: Default geometry is A4 with narrow margins

- **WHEN** a document is exported with the default (unconfigured) export profile
- **THEN** the pages are A4 portrait with narrow (~0.5") margins on every side
- **AND** the output matches the behavior from before this change

#### Scenario: Configured page size is applied

- **WHEN** the export profile selects a non-default page size (e.g. Letter) and a document is exported
- **THEN** every page of the resulting PDF is the selected size
- **AND** content is laid out and paginated to that size's printable area

#### Scenario: Configured orientation is applied

- **WHEN** the export profile selects landscape orientation and a document is exported
- **THEN** every page of the resulting PDF is wider than it is tall
- **AND** content is wrapped and paginated to the landscape printable width

#### Scenario: Configured margins are applied

- **WHEN** the export profile selects a margin preset other than the default (e.g. Wide) and a document is exported
- **THEN** the content is laid out within the selected margins on every side
- **AND** the printable column width reflects the selected margins

#### Scenario: Lines and blocks are not split across pages

- **WHEN** a document's content crosses a page boundary
- **THEN** no line of text is cut in half across two pages
- **AND** an image, table, code block, or diagram that fits within one page is kept whole on a single page

#### Scenario: The last line of a full page is not clipped

- **WHEN** a page is filled to near its printable height and the next content starts a new page
- **THEN** the last line of text on the full page shows its full glyph height, with no descenders sliced by the page boundary

#### Scenario: Table rows are not sliced at a page boundary

- **WHEN** a multi-row table spans a page boundary
- **THEN** each row that fits within a page is rendered whole on one page
- **AND** no row is cut horizontally across two pages

### Requirement: Exported PDF includes a navigable heading outline

The exported PDF SHALL include an outline (bookmark tree) built from the document's
headings, generated by default for every export with no configuration required. The
outline SHALL reflect the heading hierarchy: each `#`…`######` heading becomes an
entry, nested under the nearest preceding heading of a shallower level, in document
order. Each outline entry SHALL link to the page on which its heading appears, so
selecting it in a PDF reader navigates to that heading. A document that contains no
headings SHALL produce a valid PDF with no outline (and SHALL NOT fail the export).

#### Scenario: Headings produce a bookmark tree

- **WHEN** a document containing multiple headings is exported
- **THEN** the resulting PDF contains an outline with one entry per heading, in document order
- **AND** the entry text matches each heading's title

#### Scenario: Outline nesting follows heading levels

- **WHEN** a document has a level-1 heading followed by level-2 and level-3 headings beneath it
- **THEN** the level-2 entries are nested under the level-1 entry in the PDF outline
- **AND** the level-3 entries are nested under their parent level-2 entry

#### Scenario: Outline entries link to the correct page

- **WHEN** a multi-page document is exported and an outline entry is selected in a PDF reader
- **THEN** the reader navigates to the page on which that heading is rendered

#### Scenario: Document without headings still exports

- **WHEN** a document that contains no headings is exported
- **THEN** the export succeeds and produces a valid PDF
- **AND** the PDF has no outline rather than a malformed or empty-titled one

### Requirement: Exported and printed diagrams match the preview

The offscreen render used for PDF export and Print SHALL render every diagram that
the live preview renders, so that a `mermaid`, `flow`, or `sequence` block that
appears as a diagram in the preview also appears as that diagram in the exported
PDF and in printed output. The export SHALL begin capturing pages only after the
document's asynchronous diagram and math rendering has settled, rather than after a
fixed delay alone, bounded by the existing overall export timeout. A diagram that
fails to render SHALL fall back to showing its source text (as in the preview) and
SHALL NOT blank the diagram or fail the export.

#### Scenario: Mermaid diagram appears in the exported PDF

- **WHEN** a document containing a Mermaid diagram that renders in the preview is exported to PDF
- **THEN** the rendered Mermaid diagram appears in the PDF
- **AND** the diagram is not blank or missing

#### Scenario: Diagram-bearing document prints faithfully

- **WHEN** a document containing diagrams is printed
- **THEN** the printed output shows the same rendered diagrams as the preview

#### Scenario: Export waits for diagram rendering to settle

- **WHEN** a document with diagrams that take time to render is exported
- **THEN** page capture begins only after the diagrams have finished rendering (or the overall timeout is reached)
- **AND** no page is captured while a diagram is still blank

#### Scenario: A failing diagram does not break export

- **WHEN** a document contains a malformed diagram that cannot be rendered
- **THEN** the export still succeeds
- **AND** that diagram shows its source text in the PDF rather than blanking the page

### Requirement: Optional page numbers and headers/footers in exported output

The exported PDF SHALL be able to include page numbers and header/footer text
drawn from the active export profile. When enabled, header and footer text SHALL
support left, center, and right zones, and SHALL resolve substitution tokens for
the document title, the current date, the page number, and the total page count,
evaluated per page. Page numbers and header/footer text SHALL be drawn within the
page margin so they never overlap document content; when enabled with a margin
preset that leaves no room, a minimum text band SHALL be reserved so content is
not clipped. When page numbers and headers/footers are disabled (the default), the
output SHALL contain none and match the prior behavior.

#### Scenario: Page numbers appear on every page

- **WHEN** the profile enables page numbers and a multi-page document is exported
- **THEN** each page of the PDF shows its page number in the configured position
- **AND** the numbering reflects the correct page and total page count

#### Scenario: Header and footer text with tokens

- **WHEN** the profile sets a footer center template using the title and page tokens and a document is exported
- **THEN** each page's footer shows the resolved document title and page number
- **AND** the left/center/right zones are positioned independently

#### Scenario: Running text does not overlap content

- **WHEN** headers/footers are enabled and a document is exported
- **THEN** the header/footer text is drawn inside the page margin
- **AND** no document content is overlapped or clipped by the running text

#### Scenario: Disabled by default

- **WHEN** a document is exported with the default profile
- **THEN** the PDF contains no page numbers, header, or footer
- **AND** the output matches the behavior from before this change

### Requirement: Mermaid diagrams keep their natural size in exported output

The print-time width override SHALL NOT override Mermaid's own inline `max-width`
cap. A Mermaid diagram whose natural width is less than the printable column
SHALL render at its natural size rather than stretched to the printable width; a
Mermaid diagram whose natural width exceeds the printable column SHALL be scaled
down to fit within the printable column without horizontal clipping.

#### Scenario: Narrow Mermaid flowchart keeps natural size

- **WHEN** a document containing a narrow Mermaid flowchart (natural width less than the printable column) is exported to PDF
- **THEN** the diagram appears at its natural size
- **AND** the diagram is not stretched to fill the printable column width

#### Scenario: Wide Mermaid diagram scales to fit the column

- **WHEN** a document containing a Mermaid diagram whose natural width exceeds the printable column is exported to PDF
- **THEN** the diagram is scaled down to fit within the printable column width
- **AND** the diagram is not clipped at the right page margin

### Requirement: Exported output is rendered light independent of system appearance

The offscreen render used for PDF export and Print SHALL use a light appearance
regardless of the host system's appearance, so the composed PDF is always dark
text and dark diagram strokes on a white page. Mermaid SHALL render with its
light `default` theme during export and print even when the system is in Dark
Mode.

#### Scenario: Exporting in Dark Mode produces a light PDF

- **WHEN** a document containing text and a Mermaid diagram is exported while the host system is in Dark Mode
- **THEN** the PDF shows dark text and dark diagram strokes on a white background
- **AND** the output is not inverted, and no content is light-on-white or low contrast

