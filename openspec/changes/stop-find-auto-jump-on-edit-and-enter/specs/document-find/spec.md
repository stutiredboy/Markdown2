## MODIFIED Requirements

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
