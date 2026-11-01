## MODIFIED Requirements

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
- **AND** the line is at the top of the editor once the editor has styled its text, also when the editor is shown for the first time

#### Scenario: Only real clicks on numbers count
- **WHEN** a page script dispatches a synthetic click on a number, or the user clicks the text beside it
- **THEN** no line is sent to the app
- **AND** page scripts cannot see the bridge's message handler
