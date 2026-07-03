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
