## Purpose

Define the requirements for the preview content column layout, ensuring it uses available window width while keeping readable line lengths, and that it does not affect PDF export layout.
## Requirements
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

### Requirement: Side by Side remains usable with the outline visible
When Side by Side mode and the outline are both visible, the app SHALL preserve usable editor and preview pane widths. The editor pane SHALL remain at least 360 pt wide and the preview pane SHALL remain at least 420 pt wide in Side by Side mode. The layout SHALL avoid placing the outline, editor, and preview into a window width that causes the editor or preview pane to collapse below its minimum usable width.

#### Scenario: Default window enters Side by Side with outline
- **WHEN** a document window is at the app's default size
- **AND** the outline is visible
- **AND** the user switches to Side by Side mode
- **THEN** the editor and preview panes both remain at or above their minimum usable widths
- **AND** neither pane overlaps the outline or status bar

#### Scenario: Constrained window adapts layout
- **WHEN** the window is too narrow to show the outline, editor pane, and preview pane at their minimum usable widths
- **AND** the user switches to Side by Side mode
- **THEN** the app adapts by widening the window, temporarily collapsing the outline, or otherwise preserving both pane minimum widths
- **AND** the user can still restore the outline explicitly

#### Scenario: Window minimum accounts for visible outline
- **WHEN** Side by Side mode and the 230 pt outline are both visible
- **THEN** the document window minimum width accounts for the outline, split divider, editor minimum width, and preview minimum width
- **AND** the app does not silently change the user's explicit outline visibility preference

#### Scenario: Split divider preserves minimum panes
- **WHEN** the user drags the Side by Side divider
- **THEN** the editor pane cannot be resized below its minimum usable width
- **AND** the preview pane cannot be resized below its minimum usable width

### Requirement: Layout adaptation is reversible and predictable
Any automatic layout adaptation triggered by Side by Side with the outline visible SHALL be reversible and SHALL not permanently change the user's outline preference unless the user explicitly changes that preference.

#### Scenario: Leaving Side by Side restores previous outline context
- **WHEN** the app temporarily hides or collapses the outline to preserve Side by Side pane widths
- **AND** the user leaves Side by Side mode
- **THEN** the outline visibility returns to the user's prior explicit state when there is enough space

#### Scenario: User explicitly hides outline
- **WHEN** the user hides the outline from the toolbar or menu
- **THEN** the app treats the outline as explicitly hidden
- **AND** later Side by Side layout adaptation does not re-show it without user action

#### Scenario: Window resize keeps panes readable
- **WHEN** the user resizes a Side by Side document window while the outline is visible
- **THEN** the layout preserves the editor and preview minimum usable widths
- **AND** the app applies the same adaptation rules consistently as the available width changes

