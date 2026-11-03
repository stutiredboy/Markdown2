# editor-formatting-commands Specification

## Purpose
Define when a formatting command from the Format and Paragraph menus applies: at once in Read mode, to the editor's kept selection, before the window switches to the editor; and in Write and Side by Side, only while the editor has keyboard focus.
## Requirements
### Requirement: A formatting command from Read mode formats the document and opens the editor
When a formatting command from the Format or Paragraph menu is sent while the window is in Read mode, the app SHALL apply it to the document's source text at the editor's kept selection, and SHALL then switch the window to Write. The command SHALL be applied when it is sent. It SHALL NOT depend on when the editor gets its window or keyboard focus after the switch. The edit SHALL be one undo step. The editor shown after the switch SHALL NOT apply the command a second time. When the document's text changed without reaching the editor, the command SHALL be applied to the document's current text.

#### Scenario: Bold from Read mode
- **WHEN** the editor's kept selection is "text" in the document "some text", and the user chooses Bold in Read mode
- **THEN** the document is "some **text**"
- **AND** the window switches to Write

#### Scenario: The editor takes focus late
- **WHEN** the user chooses Bold in Read mode and the editor gets keyboard focus only after it has been shown
- **THEN** the document still contains the bold text, formatted once

#### Scenario: Undo reverts the format
- **WHEN** the user chooses Undo after a format sent from Read mode
- **THEN** the document returns to its text before the format

#### Scenario: The document changed without the editor
- **WHEN** the document's text changed without reaching the editor, and the user then chooses Bold in Read mode
- **THEN** the format is applied to the document's current text, and the change is kept

### Requirement: A formatting command while editing needs the editor's keyboard focus
In Write and Side by Side, the app SHALL apply a formatting command only while the editor has keyboard focus. When another control has it, such as a find field, the command SHALL do nothing, and the editor SHALL NOT apply it later.

#### Scenario: A find field has the keyboard
- **WHEN** the editor is shown and a find field has keyboard focus, and the user chooses Italic
- **THEN** the document does not change

