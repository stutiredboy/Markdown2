## ADDED Requirements

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
