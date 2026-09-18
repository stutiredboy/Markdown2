## ADDED Requirements

### Requirement: Line numbers are independently configurable per surface
The app SHALL maintain two independent display preferences: showing line numbers in the editor, and showing line numbers in the preview. Both SHALL default to off when no preference has been saved. Enabling or disabling one SHALL NOT change the other. Both preferences SHALL persist across launches. The Settings window SHALL expose both as separately labeled controls, localized in English and Simplified Chinese.

#### Scenario: First run shows no line numbers
- **WHEN** the app starts and no line-number preference has been saved
- **THEN** neither the editor nor the preview shows line numbers

#### Scenario: Enabling one surface leaves the other unchanged
- **WHEN** the user enables editor line numbers and leaves preview line numbers off
- **THEN** the editor shows line numbers
- **AND** the preview shows no line numbers

#### Scenario: Both surfaces can be enabled at the same time
- **WHEN** the user enables editor line numbers and preview line numbers
- **THEN** the editor shows line numbers
- **AND** the preview shows line numbers

#### Scenario: Preferences persist across launches
- **WHEN** the user enables preview line numbers, leaves editor line numbers off, and relaunches the app
- **THEN** preview line numbers are still enabled
- **AND** editor line numbers are still disabled

#### Scenario: Settings labels are localized
- **WHEN** the app language is Simplified Chinese
- **THEN** the line-number controls and their group label are shown in Simplified Chinese

### Requirement: The editor shows source line numbers in a gutter
When editor line numbers are enabled, the editor SHALL display a gutter to the left of the source text showing the 1-based source line number of each logical line of the document. A line that soft-wraps across multiple visual rows SHALL be numbered once, at its first visual row; continuation rows SHALL NOT be numbered. Numbers SHALL remain aligned with their lines as the user scrolls, edits, and resizes the window. When editor line numbers are disabled, no gutter SHALL be shown and the editor's text SHALL occupy the same horizontal position it occupied before the feature existed.

#### Scenario: Each logical line is numbered
- **WHEN** editor line numbers are enabled and the document has 120 lines
- **THEN** the gutter shows 1 through 120 beside the corresponding lines
- **AND** each number aligns with the first visual row of its line

#### Scenario: A soft-wrapped line is numbered once
- **WHEN** a single long source line occupies three visual rows because it wraps
- **THEN** the gutter shows one number for those rows
- **AND** the following line's number is not offset by the wrapped rows

#### Scenario: Numbers follow edits
- **WHEN** the user inserts a new line above the current viewport while line numbers are enabled
- **THEN** the gutter renumbers the lines below the insertion so every number still matches its line

#### Scenario: Numbers follow scrolling
- **WHEN** the user scrolls a long document with line numbers enabled
- **THEN** each visible line is shown beside its own number
- **AND** no stale numbers remain from the previous scroll position

#### Scenario: Disabling restores the previous text position
- **WHEN** the user disables editor line numbers after having them enabled
- **THEN** the gutter disappears
- **AND** the document text returns to the horizontal position it had before the gutter was introduced

### Requirement: The preview shows the source line of each rendered block
When preview line numbers are enabled, the preview SHALL display, in a left margin beside each top-level rendered block, the 1-based source line on which that block begins in the Markdown source. Numbers SHALL use the same numbering as the editor gutter, so a number read in the preview identifies the line to open in the editor. Because a rendered block corresponds to a source range rather than to a single line, a block SHALL show only the source line it starts on. Numbers SHALL be regenerated whenever the rendered content changes, including live re-renders while editing in Side by Side.

#### Scenario: A heading shows its source line
- **WHEN** preview line numbers are enabled and a heading is written on source line 42
- **THEN** the preview shows 42 beside that heading

#### Scenario: A multi-line block shows only its starting line
- **WHEN** a fenced code block spans source lines 47 through 52
- **THEN** the preview shows 47 beside that code block

#### Scenario: Preview and editor numbers agree
- **WHEN** the same document is shown in Side by Side with line numbers enabled for both panes
- **THEN** the number beside a rendered block in the preview is the source line that the editor numbers identically

#### Scenario: Numbers survive live re-rendering
- **WHEN** the user edits the document in Side by Side with preview line numbers enabled
- **THEN** the preview shows correct line numbers once the live re-render settles
- **AND** the existing preview scroll position is preserved

#### Scenario: Numbers follow a mode switch into the preview
- **WHEN** the user switches from Edit to Preview with preview line numbers enabled
- **THEN** the preview shows line numbers for the blocks it displays

### Requirement: Side by Side honors each pane's own scope
In Side by Side mode the editor pane SHALL show line numbers if and only if editor line numbers are enabled, and the preview pane SHALL show line numbers if and only if preview line numbers are enabled. Enabling numbers for one pane SHALL NOT cause them to appear in the other.

#### Scenario: Editor scope only
- **WHEN** a document is shown in Side by Side with editor line numbers enabled and preview line numbers disabled
- **THEN** the editor pane shows line numbers
- **AND** the preview pane shows none

#### Scenario: Both scopes enabled
- **WHEN** a document is shown in Side by Side with both scopes enabled
- **THEN** both panes show line numbers

#### Scenario: Toggling a scope while in Side by Side updates only its pane
- **WHEN** the document is shown in Side by Side and the user enables preview line numbers
- **THEN** the preview pane shows line numbers
- **AND** the editor pane's line numbers are unchanged

### Requirement: Line numbers are display-only and never reach exports
Line numbers SHALL be an affordance of the live surfaces only. They SHALL NOT appear in exported PDF, in printed output, or in exported HTML. They SHALL NOT be part of the document's text: they SHALL NOT be selectable or copyable as document content, SHALL NOT be matched by find, and SHALL NOT change the document's rendered content or the export layout.

#### Scenario: Exported PDF has no line numbers
- **WHEN** the user exports a document to PDF with line numbers enabled
- **THEN** the PDF contains no line-number gutter
- **AND** its layout matches an export of the same document made with line numbers disabled

#### Scenario: Printed output has no line numbers
- **WHEN** the user prints a document with line numbers enabled
- **THEN** the printed output contains no line-number gutter

#### Scenario: Exported HTML has no line numbers
- **WHEN** the user exports a document to HTML with line numbers enabled
- **THEN** the exported HTML shows no line numbers and contains no line-number styling

#### Scenario: Find does not match line numbers
- **WHEN** line numbers are enabled and the user searches the preview for a number that appears only in the gutter
- **THEN** find reports no match for that gutter number

#### Scenario: Copying the source does not include numbers
- **WHEN** the user selects all and copies in the editor with line numbers enabled
- **THEN** the copied text is the document's source without line numbers

### Requirement: Line numbers can be toggled without opening Settings
The document window SHALL provide a toolbar control beside the outline control that exposes both line-number scopes. Activating a scope from this control SHALL set the same preference that the Settings window sets, and both controls SHALL reflect the current state of each scope.

#### Scenario: Toolbar enables preview numbers
- **WHEN** the user enables preview line numbers from the toolbar control
- **THEN** the preview shows line numbers
- **AND** the corresponding control in the Settings window is on

#### Scenario: A Settings change is reflected in the toolbar
- **WHEN** the user enables editor line numbers in the Settings window
- **THEN** the toolbar control reflects that editor line numbers are on
- **AND** the editor shows line numbers

#### Scenario: The toolbar control is present in every mode
- **WHEN** a document is shown in Edit, Preview, or Side by Side mode
- **THEN** the toolbar control for line numbers is available
