## Purpose

Define the requirements for optional, independently configurable line-number display in the editor and the preview: how numbers are shown and kept aligned on each surface, how Side by Side honors each pane's own scope, and how line numbers stay display-only so they never reach exports, find, or the document text.
## Requirements
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

### Requirement: Clicking a line number selects its source line in the editor
A shown line number SHALL be a way to reach its source line.

In the editor, a click on the gutter SHALL select the source line beside it, together with its line break. That SHALL hold for a click beside any visual row of a soft-wrapped line. Lines SHALL be numbered as the gutter numbers them: LF, CRLF and a bare CR each end a line. A Shift-click SHALL extend the current selection to the clicked line, and dragging along the gutter SHALL extend the selection line by line. With editor numbers hidden, or while an input method holds marked text, the gutter area SHALL behave as ordinary text-view margin.

In the preview, a click on a block's number SHALL select that block's first source line in the editor:
- In Side by Side, the editor SHALL select the line, take focus, and scroll the line's start into view if it is off screen. The preview SHALL stay where it was.
- In Read mode, the app SHALL switch to Write mode with that line at the top of the editor and selected.

Only a trusted click on the gutter's own numbers SHALL send a line to the app, through the preview's isolated-world bridge, and page scripts SHALL NOT be able to reach that bridge. A click SHALL NOT change the document's text, and line numbers SHALL still never reach exports, find, or copied text.

#### Scenario: A gutter click selects its line
- **WHEN** editor numbers are shown and the user clicks the number of a line
- **THEN** that line and its line break are selected

#### Scenario: A click beside a wrapped row selects the whole line
- **WHEN** the user clicks the gutter beside the second visual row of a soft-wrapped line
- **THEN** the whole source line is selected

#### Scenario: Shift-click and drag extend the selection
- **WHEN** a line is selected and the user Shift-clicks the number of a later line
- **THEN** the selection runs from the first line through the clicked line
- **AND** dragging along the gutter from one number to another selects every line in between

#### Scenario: A hidden gutter is ordinary margin
- **WHEN** editor numbers are hidden and the user clicks the left margin beside a line
- **THEN** the caret is placed as for any click in the text view, and no line is selected

#### Scenario: A preview number selects its line in Side by Side
- **WHEN** the user clicks a block's number in the Side by Side preview
- **THEN** the editor selects the block's first source line, takes focus, and shows that line
- **AND** the preview stays where it was

#### Scenario: A preview number opens the editor from Read mode
- **WHEN** the user clicks a block's number in Read mode
- **THEN** the app switches to Write mode with the block's first source line selected and visible

#### Scenario: Only real clicks on numbers count
- **WHEN** a page script dispatches a synthetic click on a number, or the user clicks the text beside it
- **THEN** no line is sent to the app
- **AND** page scripts cannot see the bridge's message handler

