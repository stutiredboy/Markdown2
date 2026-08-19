## MODIFIED Requirements

### Requirement: Find matches in edit mode
In edit mode the system SHALL search the markdown source text for the current
query, highlight matches, and scroll the current match into view. Search SHALL be
case-insensitive by default and SHALL wrap around at the end of the document.
Revealing a match SHALL place a collapsed caret at the end of the match rather
than selecting the whole match, so that an immediate Backspace deletes only the
character preceding the caret and never removes the entire matched word.
Revealing a match SHALL NOT move keyboard focus; the find query field keeps focus
until the user clicks into the editor.

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

### Requirement: Navigate between matches
While the find bar is open the system SHALL allow moving to the next and previous
match via the bar's controls and via ⌘G (next) and ⇧⌘G (previous). The system
SHALL report the current match position relative to the total (for example
"2 of 7"). Each invocation of Find Next or Find Previous SHALL move the caret to
the end of the next match and update which match is highlighted as current; the
system SHALL NOT replay a single navigation request into a repeating loop, and
submitting the query field with Return SHALL move to one match without
continuously re-triggering. Navigation and replace SHALL operate on the current
query's match set; a navigation or replace issued while a query-driven search is
pending SHALL flush that search first rather than acting on the previous query's
matches.

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
- **WHEN** matches exist and the user invokes Find Next once (via Return, the ▼
  control, or ⌘G)
- **THEN** the caret advances by exactly one match and then stays put
- **AND** the find affordance does not keep navigating on its own (no runaway
  loop or repeated re-rendering)

## ADDED Requirements

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
