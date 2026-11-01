## MODIFIED Requirements

### Requirement: Long documents scroll to the anchored position
The system SHALL scroll the destination to the captured viewport-context anchor
when its content is taller than the viewport. The system SHALL prefer a
block/source-line anchor representing the content nearest the top of the source
viewport, including an intra-block position when available. The system SHALL use
the section heading or proportional fallback only when a block/source-line anchor
cannot be resolved. The resulting offset MUST be clamped so it never exceeds
`contentHeight - viewportHeight`, is never negative, and never leaves the
destination with an empty or invalid visible range after settling. The
destination SHALL still show the anchored content after its own asynchronous
layout work, including the editor's first styling of a text view it has not
shown before: a restyle that changes line heights SHALL keep the editor on the
line the anchor placed, not at the same scroll offset.

#### Scenario: Switch a long document from editor body text to preview
- **WHEN** a multi-page document is scrolled in Write mode so body text inside a
  long section is near the top of the editor viewport
- **AND** the user switches to Read mode
- **THEN** the preview shows the rendered block corresponding to that body text
  near the top of the viewport
- **AND** the preview does NOT snap back to only the section heading unless that
  heading is itself the captured viewport content

#### Scenario: Switch a long document from preview body text to editor
- **WHEN** a multi-page document is scrolled in Read mode so a paragraph, list
  item, table, or code block inside a long section is near the top of the
  preview viewport
- **AND** the user switches to Write mode
- **THEN** the editor shows the source line or source block for that rendered
  content near the top of the viewport
- **AND** the editor does NOT scroll merely to the section heading when a more
  precise source-line anchor is available

#### Scenario: Long code block keeps local position
- **WHEN** the viewport is positioned partway through a long fenced or indented
  code block
- **AND** the user switches modes
- **THEN** the destination lands within the corresponding code block rather than
  at the beginning of the containing section

#### Scenario: Anchor beyond the bottom is clamped
- **WHEN** the captured anchor resolves to a target below the last scrollable
  position
- **THEN** the destination scrolls to the maximum offset
  (`contentHeight - viewportHeight`) rather than past the end
- **AND** the destination still reports a non-empty visible range once layout has
  settled

#### Scenario: The first switch to the editor survives its styling
- **WHEN** a long document is opened in Read mode and scrolled so a heading
  inside a long section is near the top of the preview
- **AND** the user switches to Write mode, which shows the editor for the first
  time in that window
- **THEN** once the editor has styled its text, the heading's source line is at
  the top of the editor, below the editor's top margin
