## Purpose

Define offline rendering of mermaid, flow, and sequence code blocks into diagrams in the preview and exported output.
## Requirements
### Requirement: Offline rendering with graceful error handling
The system SHALL render diagrams without any runtime network access, using engine assets bundled with the application. A diagram whose own source names a remote resource, such as an `<img>` in a Mermaid label or a CSS `url()`, SHALL load that resource when the diagram is shown, as a Markdown image does; the diagram itself SHALL still render without it. While an engine has not yet rendered a block, the system SHALL NOT display the block's raw source as visible text; the source SHALL remain available to the engine. When diagram source cannot be parsed by its engine, or no engine is available, the system SHALL surface the offending source or an inline error and SHALL continue to render the rest of the document.

#### Scenario: Diagram renders without network
- **WHEN** the preview is shown for a document containing a `mermaid` block while the machine is offline
- **THEN** the diagram is fully rendered using bundled assets

#### Scenario: Remote resource named in diagram source
- **WHEN** a Mermaid label contains an `<img>` with a remote URL
- **THEN** the image element stays in the rendered diagram and the resource is requested when the diagram is shown
- **AND** the diagram renders whether or not the request succeeds

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

### Requirement: Mermaid source cannot run script

The system SHALL treat Mermaid source as author data, as it treats raw HTML. Nothing in a diagram's source SHALL run script in the preview, in the page that PDF export and Print render, or in an exported HTML file, whether or not the reader clicks anything. The system SHALL render Mermaid at the engine's `strict` security level, and a diagram SHALL NOT be able to lower that level from its own source. This requirement covers Mermaid only; the `flow` and `sequence` engines have their own link and label handling.

Labels SHALL keep their line breaks, inline formatting and `$$…$$` math, and an `http` or `https` link target SHALL stay a link. A sequence actor's `link` or `links` menu SHALL NOT open, because Mermaid opens it with an inline event handler.

#### Scenario: Event attribute in a label does not run

- **WHEN** a Mermaid label contains an element with an event attribute, such as `<img src=x onerror=…>`
- **THEN** the handler does not run, and no element in the page carries an event attribute
- **AND** the diagram still renders

#### Scenario: Event attribute in a math label does not run

- **WHEN** a sequence diagram message, actor or note contains `$$…$$` and an element with an event attribute
- **THEN** the handler does not run
- **AND** the diagram still renders

#### Scenario: Markup in a state classDef does not run

- **WHEN** a state diagram `classDef` value closes its style block and adds an element with an event attribute
- **THEN** the handler does not run
- **AND** the diagram still renders

#### Scenario: Script link in a click directive does not run

- **WHEN** a flowchart or class diagram gives a `click` or `link` target with the `javascript:` scheme
- **THEN** the page holds no `javascript:` link, and clicking the node runs nothing

#### Scenario: Click callback does not run

- **WHEN** a diagram declares `click A call fn()`
- **THEN** clicking the node calls nothing

#### Scenario: A diagram cannot lower the security level

- **WHEN** a diagram's `init` directive or front matter sets `securityLevel` to `loose`, or clears the `secure` keys
- **THEN** the diagram still renders at `strict`

#### Scenario: Script does not run in any output

- **WHEN** a document holding any of these diagrams is shown in the preview, exported to PDF, or exported to HTML and opened in a browser
- **THEN** no script from the diagram source runs

#### Scenario: Formatting in a label survives

- **WHEN** a label contains `<br/>`, inline formatting tags, a `<span>` with a color, or `$$…$$` math
- **THEN** the label renders with that formatting

#### Scenario: A web link stays a link

- **WHEN** a diagram gives a `click` target of `https://example.com`
- **THEN** the node is a link to that URL

