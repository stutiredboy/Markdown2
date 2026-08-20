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
Revealing a match SHALL place a collapsed caret at the end of the match rather
than selecting the whole match, so that an immediate Backspace deletes only the
character preceding the caret and never removes the entire matched word.
Revealing a match SHALL NOT move keyboard focus; the find query field keeps focus
until the user clicks into the editor. Editing the document while the find bar is
open SHALL NOT move the caret or change the scroll position as a result of the
re-index; the match highlights and the match count SHALL update to the new
document text, but the caret stays where the user's edit left it. Replacing the
document content externally (for example a reload after the file changed on
disk) while the find bar is open SHALL also re-index without moving the caret or
the scroll position. If a document edit creates a match at the caret (a match
that ends at or contains the caret), that match SHALL become the current match
without moving the caret or the scroll position.

#### Scenario: Query has matches
- **WHEN** the user types a query that occurs in the source
- **THEN** the first match is highlighted and scrolled into view

#### Scenario: Query has no matches
- **WHEN** the user types a query that does not occur in the source
- **THEN** the find bar indicates that there are no matches

#### Scenario: Revealed match is not selected as a whole word
- **WHEN** a query has matches and a match is revealed
- **THEN** the caret is collapsed at the end of the match rather than spanning the
  whole matched text
- **AND** the match itself remains visibly highlighted as the current match

#### Scenario: Backspace after a revealed match removes one character
- **WHEN** a query has matches, a match is revealed, the editor (not the find
  query field) has keyboard focus, and the user presses Backspace
- **THEN** only the character preceding the caret (the last character of the
  match) is deleted
- **AND** the remaining characters of the match stay in the document and the
  highlight updates to the new match set
- **AND** the caret does not jump to a later match as the index updates

#### Scenario: Editing the document does not move the caret to the next match
- **WHEN** the find bar is open, the user searches for a query that occurs more
  than once, and then edits the document at or near the current match (for
  example deleting a character from it)
- **THEN** the match highlights and the match count update to reflect the new
  document text
- **AND** the caret stays where the user's edit left it, not moved to the next
  match
- **AND** the scroll position does not change as a result of the re-index

#### Scenario: External content replacement re-indexes without moving the caret
- **WHEN** the find bar is open with matches shown and the document content is
  replaced externally (for example a reload after the file changed on disk)
- **THEN** the match highlights and the match count update to the new document
  text
- **AND** the caret and the scroll position are not moved as a result of the
  re-index

#### Scenario: An edit that creates a match at the caret promotes it to the current match
- **WHEN** the find bar is open with a query, and the user edits the document so
  that a match ends at or contains the caret
- **THEN** that match becomes the current match (distinct highlight, status
  reflects its position)
- **AND** the caret does not move and the scroll position does not change as a
  result of the re-index

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
"2 of 7"). Each invocation of Find Next or Find Previous SHALL move the caret to
the end of the next match and update which match is highlighted as current; the
system SHALL NOT replay a single navigation request into a repeating loop.
Submitting the query field with Return SHALL run/confirm the search for the
current query and SHALL NOT advance to the next match. Navigation and replace
SHALL operate on the current query's match set; a navigation or replace issued
while a query-driven search is pending SHALL flush that search first rather than
acting on the previous query's matches.

#### Scenario: Move to next match
- **WHEN** matches exist and the user invokes Find Next (or ⌘G)
- **THEN** the caret moves to the end of the next match, that match becomes the
  highlighted current match, and the status updates

#### Scenario: Move to previous match
- **WHEN** matches exist and the user invokes Find Previous (or ⇧⌘G)
- **THEN** the caret moves to the end of the previous match, that match becomes
  the highlighted current match, and the status updates

#### Scenario: Wrap around at the end
- **WHEN** the current match is the last match and the user invokes Find Next
- **THEN** the caret wraps to the first match

#### Scenario: A single Find Next advances exactly one match
- **WHEN** matches exist and the user invokes Find Next once (via the ▼ control
  or ⌘G)
- **THEN** the caret advances by exactly one match and then stays put
- **AND** the find affordance does not keep navigating on its own (no runaway
  loop or repeated re-rendering)

#### Scenario: Return confirms the search without advancing
- **WHEN** the query field is focused and the user presses Return
- **THEN** the search for the current query is run/confirmed (results appear
  without waiting for a pending debounced search)
- **AND** the caret does not advance to the next match

### Requirement: Keep find responsive during query entry
While the find bar is open the system SHALL keep interaction responsive while the
user types in the query field. Rapid successive query changes SHALL be coalesced
into a single document search, and a re-index SHALL NOT re-paint highlight
attributes for matches whose membership has not changed. On documents and queries
that yield many matches, search and highlight updates SHALL NOT block the main
thread on every keystroke.

#### Scenario: Rapid query typing coalesces searches
- **WHEN** the user types several characters into the query field in quick
  succession
- **THEN** the document is searched once after the typing settles
- **AND** the system does not run a full search and highlight rebuild for every
  intermediate partial query on its own

#### Scenario: Navigation repaints only changed highlights
- **WHEN** matches exist and the user moves to the next match
- **THEN** only the previous and new current-match highlight colors are updated
- **AND** the highlight attributes of the other matches are left untouched

#### Scenario: Settled search completes within a bound on large documents
- **WHEN** the user searches a single-letter query in a large document (~1 MB)
- **THEN** the settled search and highlight update complete within a bounded time,
  as measured by the responsiveness benchmark

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

