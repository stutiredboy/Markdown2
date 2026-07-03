## Purpose

Define find and replace behavior across the editor and preview surfaces: invocation, navigation, replacement, match reporting, and dismissal.
## Requirements
### Requirement: Invoke find with ⌘F
The system SHALL open a find affordance for the active document surface when the
user presses ⌘F, and SHALL provide an Edit/Find menu item carrying the same
shortcut. The find affordance SHALL receive keyboard focus on its query field so
the user can type a query immediately.

#### Scenario: Open find in edit mode
- **WHEN** the document is in edit mode and the user presses ⌘F
- **THEN** the editor's find bar appears with the query field focused

#### Scenario: Open find in preview mode
- **WHEN** the document is in preview mode and the user presses ⌘F
- **THEN** a find bar appears over the preview with the query field focused

#### Scenario: Find menu item is available
- **WHEN** the user opens the Edit menu
- **THEN** a "Find" item is shown with the ⌘F shortcut

### Requirement: Find matches in edit mode
In edit mode the system SHALL search the markdown source text for the current
query, highlight matches, and scroll the current match into view. Search SHALL be
case-insensitive by default and SHALL wrap around at the end of the document.

#### Scenario: Query has matches
- **WHEN** the user types a query that occurs in the source
- **THEN** the first match is highlighted and scrolled into view

#### Scenario: Query has no matches
- **WHEN** the user types a query that does not occur in the source
- **THEN** the find bar indicates that there are no matches

### Requirement: Find matches in preview mode
In preview mode the system SHALL search the rendered page text for the current
query, highlight matches, and scroll the current match into view. Search SHALL be
case-insensitive by default and SHALL wrap around. Preview mode SHALL NOT offer
replace.

#### Scenario: Query has matches in preview
- **WHEN** the user types a query that occurs in the rendered page
- **THEN** the first match is highlighted and scrolled into view

#### Scenario: No replace control in preview
- **WHEN** the preview find bar is shown
- **THEN** no replace field or replace action is present

### Requirement: Navigate between matches
While the find bar is open the system SHALL allow moving to the next and previous
match via the bar's controls and via ⌘G (next) and ⇧⌘G (previous). The system
SHALL report the current match position relative to the total (for example
"2 of 7"). Each invocation of Find Next or Find Previous SHALL advance the
selection by exactly one match; the system SHALL NOT replay a single navigation
request into a repeating loop, and submitting the query field with Return SHALL
move to one match without continuously re-triggering.

#### Scenario: Move to next match
- **WHEN** matches exist and the user invokes Find Next (or ⌘G)
- **THEN** the selection advances to the next match and the status updates

#### Scenario: Move to previous match
- **WHEN** matches exist and the user invokes Find Previous (or ⇧⌘G)
- **THEN** the selection moves to the previous match and the status updates

#### Scenario: Wrap around at the end
- **WHEN** the current match is the last match and the user invokes Find Next
- **THEN** the selection wraps to the first match

#### Scenario: A single Find Next advances exactly one match
- **WHEN** matches exist and the user invokes Find Next once (via Return, the ▼
  control, or ⌘G)
- **THEN** the selection advances by exactly one match and then stays put
- **AND** the find affordance does not keep navigating on its own (no runaway
  loop or repeated re-rendering)

### Requirement: Replace in edit mode
In edit mode the find affordance SHALL let the user enter replacement text and
replace either the current match or all matches of the current query. Replacing
SHALL update the document text and mark the document as having unsaved changes.

#### Scenario: Replace the current match
- **WHEN** a match is selected and the user invokes Replace
- **THEN** that match is replaced with the replacement text and the next match
  is located

#### Scenario: Replace all matches
- **WHEN** a query has matches and the user invokes Replace All
- **THEN** every match is replaced with the replacement text in one operation

### Requirement: Dismiss find
The system SHALL dismiss the find affordance when the user presses Esc or
activates its close control, returning keyboard focus to the document surface.
Esc SHALL dismiss a visible find affordance regardless of whether keyboard focus
is in the find affordance itself, the editor text, or the preview page, and
while a find affordance is visible Esc SHALL NOT trigger any mode-switch
gesture — dismissing find takes priority, and only a subsequent Esc (with no
find affordance visible) performs the mode gesture.
The system SHALL also dismiss the find affordance when the document mode changes
or a different document is loaded.

#### Scenario: Close with Esc
- **WHEN** the find bar is open and focused and the user presses Esc
- **THEN** the find bar closes and focus returns to the document

#### Scenario: Esc in the editor closes find instead of switching modes
- **WHEN** the find bar is open in edit mode, keyboard focus is in the editor text, and the user presses Esc
- **THEN** the find bar closes and focus stays in the editor
- **AND** the document remains in edit mode

#### Scenario: Second Esc switches modes
- **WHEN** the user presses Esc again in the editor after the find bar has closed
- **THEN** the existing Esc mode gesture applies (single-pane edit switches to preview)

#### Scenario: Esc in the preview closes the preview find bar
- **WHEN** the preview find bar is open in read mode, keyboard focus is in the preview page, and the user presses Esc
- **THEN** the find bar closes and focus returns to the preview

#### Scenario: Close on mode switch
- **WHEN** the find bar is open and the user switches between edit and preview
- **THEN** the find bar is dismissed

