## Purpose

Define how the viewport position is captured and restored across presentation-mode switches so the user stays on the same content.
## Requirements
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

### Requirement: Preview blocks expose source-line anchors
The rendered preview SHALL expose stable source-line metadata on block-level
elements that can be used for mode-switch anchoring. The metadata SHALL identify
the first source line that produced the rendered block and SHOULD identify the
last source line when the renderer can determine the span. The metadata SHALL be
placed on the block's own opening tag, never on a closing tag or a descendant
element. That SHALL hold when the block's content starts with a scalar that joins
the opening tag's `>` into one grapheme cluster: a combining mark, a zero-width
joiner, a variation selector, or a spacing mark. Every item of a regular list,
nested items included, SHALL carry its first source line, and its last source
line when it spans more than one. An item's span SHALL run through the last line
of its deepest, latest descendant, including that descendant's continuation
lines.

#### Scenario: Paragraphs and lists carry source metadata
- **WHEN** a Markdown document renders paragraphs and list blocks
- **THEN** the corresponding preview block elements include source-line metadata
  suitable for mapping the preview viewport back to editor lines

#### Scenario: Each list item carries its own span
- **WHEN** a list has a one-line item on line 1, an item on lines 2 and 3, and an
  item on lines 4 through 7 whose nested item spans lines 5 and 6
- **THEN** the items carry the start lines 1, 2, 4 and 5
- **AND** the multi-line items carry the end lines 3, 7 and 6, and the one-line
  item carries none

#### Scenario: A list item at the top of the preview anchors a switch to the editor
- **WHEN** a long list item sits above the viewport and a one-line item of the
  same tight list is at the top of the Read-mode preview
- **AND** the user switches to Write mode
- **THEN** the editor shows that item's source line at the top of its viewport,
  rather than a line interpolated across the whole list

#### Scenario: Content that starts with a joining scalar
- **WHEN** a paragraph, a multi-line paragraph, a paragraph inside a blockquote,
  or a heading has content that starts with U+0301, U+200D, U+FE0F or U+093F
- **THEN** the source-line metadata is on that block's opening tag
- **AND** no closing tag carries an attribute
- **AND** the preview gutter numbers the block

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

