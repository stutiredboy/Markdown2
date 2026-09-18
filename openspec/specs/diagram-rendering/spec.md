## Purpose

Define offline rendering of mermaid, flow, and sequence code blocks into diagrams in the preview and exported output.

## Requirements

### Requirement: Offline rendering with graceful error handling
The system SHALL render diagrams without any runtime network access, using engine assets bundled with the application. While an engine has not yet rendered a block, the system SHALL NOT display the block's raw source as visible text; the source SHALL remain available to the engine. When diagram source cannot be parsed by its engine, or no engine is available, the system SHALL surface the offending source or an inline error and SHALL continue to render the rest of the document.

#### Scenario: Diagram renders without network
- **WHEN** the preview is shown for a document containing a `mermaid` block while the machine is offline
- **THEN** the diagram is fully rendered using bundled assets

#### Scenario: Raw source is not shown while waiting to render
- **WHEN** a document with a diagram block is previewed before its engine finishes rendering
- **THEN** the raw diagram source is not displayed as visible code to the reader
- **AND** the rendered diagram is shown once the engine completes

#### Scenario: Invalid diagram source does not break the page
- **WHEN** a `mermaid` block contains malformed source such as `graph TD; A-->`
- **THEN** the rest of the document still renders normally
- **AND** the problematic block is shown as an error or its raw source instead of blanking the preview

### Requirement: Mermaid diagrams preserve their engine-assigned colors
The system SHALL preserve the colors Mermaid assigns to its diagram output, whether those colors are set through Mermaid's internal stylesheet or through SVG presentation attributes on individual shapes. The preview's diagram legibility overrides (forcing geometry stroke and text fill to the foreground color) SHALL apply only to non-Mermaid diagram engines, and the system SHALL NOT apply a `stroke`/`fill` override to Mermaid elements that resolves a presentation-attribute color back to the SVG initial value (rendering the shape invisible).

#### Scenario: xychart-beta data series render visibly
- **WHEN** the preview renders a Mermaid `xychart-beta` block whose plot lines and
  bars are colored via SVG presentation attributes
- **THEN** the plotted line and bar series are visible with their Mermaid-assigned
  colors
- **AND** the chart's axes, ticks, title, and labels also render

#### Scenario: Mermaid keeps its own colors, non-Mermaid engines stay legible
- **WHEN** the preview renders a Mermaid flowchart or sequence diagram
- **THEN** the diagram keeps the colors Mermaid's engine assigned to it
- **AND** a non-Mermaid (`flow` / `sequence`) diagram still has its geometry and
  text rendered in the preview foreground color for legibility against the
  light/dark background

### Requirement: Mermaid diagrams wrap long node labels to a bounded width

The system SHALL wrap long plain-text node labels in Mermaid diagrams — including CJK text that has no word-boundary characters — to a bounded width before rendering, so a diagram's natural width is driven by its structure rather than the longest label's un-wrapped length. A node label that is plain text and exceeds a length threshold SHALL be broken into multiple display lines. The wrapping SHALL NOT alter the graph topology, edge labels, styling directives (`classDef` / `style` / `linkStyle`), subgraph titles, or any label that contains HTML or markdown markup.

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
