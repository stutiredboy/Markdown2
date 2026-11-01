## MODIFIED Requirements

### Requirement: The preview shows the source line of each rendered block
When preview line numbers are enabled, the preview SHALL display, in a left margin beside each top-level rendered block, the 1-based source line on which that block begins in the Markdown source. Numbers SHALL use the same numbering as the editor gutter, so a number read in the preview identifies the line to open in the editor. Because a rendered block corresponds to a source range rather than to a single line, a block SHALL show only the source line it starts on. Numbers SHALL be regenerated whenever the rendered content changes, including live re-renders while editing in Side by Side. Numbers SHALL also follow a block whose height changes after it is rendered, such as math or a diagram that settles, so each number stays beside its block. While the content, the window size and every block's size stay the same, the preview SHALL NOT rebuild the numbers.

A list item of a top-level list SHALL also be numbered when it spans more than one source line, nested items included. Its number SHALL be its first source line, shown beside the top of the item. A list item on a single source line SHALL NOT be numbered. A source line SHALL be shown at most once, so a list's first item shares the list's number. A list item inside a blockquote, an alert, or the footnotes SHALL NOT be numbered, including a quote or alert that sits inside a list item. A list item's number SHALL behave like a block's number when clicked.

#### Scenario: A heading shows its source line
- **WHEN** preview line numbers are enabled and a heading is written on source line 42
- **THEN** the preview shows 42 beside that heading

#### Scenario: A multi-line block shows only its starting line
- **WHEN** a fenced code block spans source lines 47 through 52
- **THEN** the preview shows 47 beside that code block

#### Scenario: Multi-line list items show their starting lines
- **WHEN** a top-level list starts on line 3 with a one-line item, followed by an item on lines 4 and 5 and an item on lines 6 through 9 that holds a nested item on lines 7 and 8
- **THEN** the preview shows 3 beside the list, and 4, 6 and 7 beside the tops of those items
- **AND** no one-line item is numbered

#### Scenario: A list's first item shares the list's number
- **WHEN** a top-level list starts with an item on lines 15 and 16
- **THEN** the preview shows 15 once

#### Scenario: Items inside quotes and alerts stay unnumbered
- **WHEN** a multi-line list item sits inside a blockquote or an alert, at the top level or inside another list item
- **THEN** the preview shows no number for that item

#### Scenario: A list item's number selects its line
- **WHEN** the user clicks the number beside a multi-line list item
- **THEN** the item's first source line is requested, as for a block's number

#### Scenario: Preview and editor numbers agree
- **WHEN** the same document is shown in Side by Side with line numbers enabled for both panes
- **THEN** the number beside a rendered block in the preview is the source line that the editor numbers identically

#### Scenario: Numbers survive live re-rendering
- **WHEN** the user edits the document in Side by Side with preview line numbers enabled
- **THEN** the preview shows correct line numbers once the live re-render settles
- **AND** the existing preview scroll position is preserved

#### Scenario: Numbers follow a block that changes height
- **WHEN** a block grows after the preview is rendered, before or after a live re-render
- **THEN** the numbers of the blocks below it move by the same amount

#### Scenario: An idle preview keeps its numbers
- **WHEN** preview line numbers are shown and nothing in the preview changes
- **THEN** the preview does not rebuild the numbers
- **AND** a click on a number reaches that number

#### Scenario: Numbers follow a mode switch into the preview
- **WHEN** the user switches from Edit to Preview with preview line numbers enabled
- **THEN** the preview shows line numbers for the blocks it displays
