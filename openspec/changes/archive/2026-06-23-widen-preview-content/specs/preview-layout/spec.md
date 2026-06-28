## ADDED Requirements

### Requirement: Preview content column uses the available window width
The rendered preview SHALL lay out document content in a centered column whose width grows with the window so that wide displays use substantially more horizontal space than the previous fixed 860px column. The column SHALL be capped at a maximum width that keeps line length comfortable for reading; beyond that cap the column SHALL stop growing and the remaining space SHALL appear as balanced left/right margins. This layout SHALL apply to every rendered document, including the single-pane preview and the preview pane of Side by Side mode.

#### Scenario: Wide window uses more horizontal space than before
- **WHEN** the preview is shown in a window noticeably wider than the old 860px column (for example a typical laptop or desktop display)
- **THEN** the content column is wider than 860px, occupying more of the window's horizontal space
- **AND** the content remains horizontally centered with balanced left and right margins

#### Scenario: Very wide window caps the column for readability
- **WHEN** the preview is shown in a window wider than the column's maximum width
- **THEN** the content column does not exceed its maximum width
- **AND** the extra space is distributed as equal left and right margins so the text stays centered

### Requirement: Preview column remains responsive on narrow windows
The preview content column SHALL shrink to fit windows narrower than its maximum width without introducing horizontal scrolling of the page, preserving the existing narrow-window behavior. Side gutters SHALL scale with the window so that narrow windows keep a smaller gutter and wider windows keep a larger one, rather than a single fixed gutter at every size.

#### Scenario: Narrow window fits without horizontal page scroll
- **WHEN** the preview is shown in a window narrower than the column's maximum width
- **THEN** the content column shrinks to fit the window
- **AND** the page does not scroll horizontally

#### Scenario: Gutters scale with window width
- **WHEN** the window is resized from narrow to wide while the column has not yet reached its maximum width
- **THEN** the side gutter between the window edge and the text grows as the window widens rather than staying a fixed width

### Requirement: PDF export layout is unaffected by the preview column width
Changing the preview content column width SHALL NOT change the layout of exported PDFs. The PDF export path SHALL continue to override the preview column sizing during capture so that printed output keeps its own page margins and full-width content flow.

#### Scenario: Exported PDF keeps its print layout
- **WHEN** a document is exported to PDF after the preview column width changes
- **THEN** the exported PDF uses the PDF export's own page margins and full-width content flow
- **AND** its layout is unchanged from before the preview column width change
