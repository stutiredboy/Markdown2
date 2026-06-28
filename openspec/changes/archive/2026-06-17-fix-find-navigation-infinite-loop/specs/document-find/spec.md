## MODIFIED Requirements

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
