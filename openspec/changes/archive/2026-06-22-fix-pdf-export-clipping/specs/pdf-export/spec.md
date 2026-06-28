## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Paginated, print-ready output

The exported PDF SHALL be paginated to A4 paper size so it can be printed or read
page by page, rather than emitted as a single unbounded page. The output SHALL use
print-oriented density (compact page margins and a document-scale base font)
rather than the on-screen reading layout, so each page holds a normal amount of
content. A page break SHALL NOT slice through a line of text or through an atomic
block (image, table, code block, or diagram); each page SHALL end at a safe
boundary between lines or blocks. This guarantee SHALL hold at the bottom of a
page: the last line or block on a page SHALL be rendered whole, never clipped by
the page boundary. A table row that fits within a page SHALL be kept whole and SHALL
NOT be sliced across a page boundary. An atomic block (or a single table row) taller
than a single page MAY be divided as a last resort.

#### Scenario: Multi-page document paginates

- **WHEN** a document whose rendered height exceeds one page is exported
- **THEN** the resulting PDF contains multiple pages
- **AND** the pages are A4 sized

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
