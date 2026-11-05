## MODIFIED Requirements

### Requirement: Mermaid diagrams wrap long node labels to a bounded width

The system SHALL wrap long plain-text node labels in Mermaid diagrams — including CJK text that has no word-boundary characters — to a bounded width before rendering, so a diagram's natural width is driven by its structure rather than the longest label's un-wrapped length. A node label that is plain text and exceeds a length threshold SHALL be broken into multiple display lines. The wrapping SHALL NOT alter the graph topology, edge labels, styling statements (`classDef` / `style` / `linkStyle` / `class` / `click`), `%%` comments and directives, front matter, subgraph titles, or any label that contains HTML or markdown markup.

#### Scenario: Long CJK node label wraps to a bounded width

- **WHEN** a `mermaid` block contains a node whose label is a plain CJK sentence longer than the wrapping threshold
- **THEN** the rendered diagram's natural width is bounded and does not grow to the label's full un-wrapped length
- **AND** the label is displayed on multiple lines within the node

#### Scenario: Long latin node label wraps at word boundaries

- **WHEN** a `mermaid` block contains a node whose label is a plain latin sentence longer than the wrapping threshold
- **THEN** the label is broken into multiple lines at word boundaries
- **AND** the node's width is bounded to roughly the wrapping width rather than the full sentence length

#### Scenario: Short labels are left unchanged

- **WHEN** a `mermaid` block contains nodes whose labels are shorter than the wrapping threshold
- **THEN** those labels are rendered exactly as written, unmodified

#### Scenario: HTML and markdown labels are left unchanged

- **WHEN** a `mermaid` block contains a node label that already contains HTML markup (such as an explicit `<br/>`) or markdown emphasis
- **THEN** the label is rendered exactly as written and is not re-wrapped by the system

#### Scenario: Edge labels, subgraph titles, and style directives are not wrapped

- **WHEN** a `mermaid` block contains a long edge label (`A -->|label| B`), a long subgraph title (`subgraph id [title]`), or a `style`/`classDef` directive
- **THEN** the graph's edge labels, subgraph titles, and directives are passed through unchanged
- **AND** only the plain-text node labels are subject to wrapping

#### Scenario: A long value in a styling statement is not wrapped

- **WHEN** a `classDef`, `style`, `linkStyle`, `class` or `click` statement holds a long `word(...)` value such as `url(...)`, whether the statement starts its line or follows a `;`
- **THEN** the statement reaches the engine exactly as written, through the end of its line
- **AND** in a diagram type whose grammar accepts the value, it reaches the rendered SVG intact

#### Scenario: A long value in a comment, directive or front matter is not wrapped

- **WHEN** a long `word(...)` value appears in a `%%` comment, in a `%%{init: ...}%%` directive on one line or several, or in front matter at the start of the block
- **THEN** that text reaches the engine exactly as written
- **AND** a config value the engine accepts reaches the rendered SVG intact

#### Scenario: Labels beside styling and config text still wrap

- **WHEN** a `mermaid` block has long plain node labels on the lines around styling statements, comments, directives and front matter
- **THEN** those labels wrap as they would on their own
- **AND** a node whose id starts with a statement keyword, such as `style-guide[...]`, is treated as a node
