## Purpose

Define how live preview updates re-render diagrams without flicker or viewport jumps while the user edits in Side by Side mode.

## Requirements

### Requirement: Diagram placeholder hides raw source while loading
A diagram block (`mermaid`, `flow`, `sequence`) SHALL NOT display its raw diagram source as visible text in the Read-mode preview while waiting for its engine to render. The verbatim source SHALL remain available to the rendering engine, but SHALL not be shown to the reader as code during the load/render window.

#### Scenario: Mermaid source is not shown before rendering
- **WHEN** a document with a `mermaid` block is previewed and the Mermaid engine has not yet finished rendering
- **THEN** the reader does NOT see the raw `mermaid` source text rendered as visible content
- **AND** once rendering completes the diagram SVG is shown

#### Scenario: Engine still receives the verbatim source
- **WHEN** a diagram block is rendered
- **THEN** the engine receives the exact diagram source from the block
- **AND** the rendered output matches that source

### Requirement: Smooth transition to the rendered diagram
When a diagram engine finishes rendering, the block SHALL transition to the rendered SVG without an abrupt source-to-diagram swap (for example, by revealing the rendered content with a short fade). The transition SHALL not depend on network access.

#### Scenario: Rendered diagram reveals smoothly
- **WHEN** a diagram engine completes rendering a block
- **THEN** the rendered diagram becomes visible via a brief reveal rather than an instantaneous replacement of visible source text

### Requirement: Errors and missing engines still reveal the source
If a diagram cannot be rendered — its source fails to parse, or its engine is unavailable — the block SHALL reveal the raw source (or an inline error) rather than remaining blank, preserving the existing error fallback.

#### Scenario: Malformed diagram reveals its source
- **WHEN** a `mermaid` block contains malformed source that the engine cannot parse
- **THEN** the block becomes visible showing the raw source or an inline error
- **AND** it is not left blank
- **AND** the rest of the document renders normally

#### Scenario: Diagram with no available engine reveals its source
- **WHEN** a diagram block's engine is not available at render time
- **THEN** the block reveals its raw source rather than staying hidden
