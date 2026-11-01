## MODIFIED Requirements

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
