## MODIFIED Requirements

### Requirement: Long documents scroll to the anchored position
The system SHALL scroll the destination to the captured viewport-context anchor
when its content is taller than the viewport. The system SHALL prefer a
block/source-line anchor representing the content nearest the top of the source
viewport, including an intra-block position when available. The system SHALL use
the section heading or proportional fallback only when a block/source-line anchor
cannot be resolved. The resulting offset MUST be clamped so it never exceeds
`contentHeight - viewportHeight`, is never negative, and never leaves the
destination with an empty or invalid visible range after settling.

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

## ADDED Requirements

### Requirement: Preview blocks expose source-line anchors
The rendered preview SHALL expose stable source-line metadata on block-level
elements that can be used for mode-switch anchoring. The metadata SHALL identify
the first source line that produced the rendered block and SHOULD identify the
last source line when the renderer can determine the span.

#### Scenario: Paragraphs and lists carry source metadata
- **WHEN** a Markdown document renders paragraphs and list blocks
- **THEN** the corresponding preview block elements include source-line metadata
  suitable for mapping the preview viewport back to editor lines

#### Scenario: Code fences do not create false heading anchors
- **WHEN** a fenced code block contains lines beginning with `#`
- **THEN** those lines are treated as code for mode-switch anchoring
- **AND** they do NOT become heading anchors that can pull the destination
  viewport to the wrong location

#### Scenario: Missing block metadata falls back gracefully
- **WHEN** the preview contains content whose source-line metadata cannot be
  resolved
- **THEN** mode switching falls back to the nearest heading anchor or
  proportional scroll fraction
- **AND** the destination does NOT reset to the top solely because block metadata
  is unavailable

### Requirement: Mode switches use fresh viewport anchors
The system SHALL capture the outgoing surface's current viewport anchor at the
time the user requests a mode switch. Cached scroll anchors MAY be used as a
fallback, but they MUST NOT override a fresher live anchor from the outgoing
editor or preview when that live anchor is available.

#### Scenario: Immediate switch after editor scroll
- **WHEN** the user scrolls the editor and immediately switches to Read mode
- **THEN** the preview uses the editor's current visible source line or source
  block as the anchor
- **AND** it does NOT use a stale anchor from an earlier scroll position

#### Scenario: Immediate switch after preview scroll
- **WHEN** the user scrolls the preview and immediately switches to Write mode
- **THEN** the editor uses the preview's current top rendered block or
  source-line anchor
- **AND** it does NOT use a stale heading captured before the latest scroll

#### Scenario: Programmatic mode-switch scroll settles before recapture
- **WHEN** a mode switch applies a programmatic destination scroll
- **THEN** anchor reporting caused by that programmatic scroll is suppressed
  until the destination has reached the requested position
- **AND** the final settled position is reported as the next cached anchor
