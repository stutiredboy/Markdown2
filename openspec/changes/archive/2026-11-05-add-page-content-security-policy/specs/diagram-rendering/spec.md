## MODIFIED Requirements

### Requirement: Offline rendering with graceful error handling
The system SHALL render diagrams without any runtime network access, using engine assets bundled with the application. A diagram whose own source names a remote image, such as an `<img>` in a Mermaid label or a CSS `url()`, SHALL load that image when the diagram is shown, as a Markdown image does; the diagram itself SHALL still render without it. A `<video>` or `<audio>` in diagram source SHALL NOT load. While an engine has not yet rendered a block, the system SHALL NOT display the block's raw source as visible text; the source SHALL remain available to the engine. When diagram source cannot be parsed by its engine, or no engine is available, the system SHALL surface the offending source or an inline error and SHALL continue to render the rest of the document.

#### Scenario: Diagram renders without network
- **WHEN** the preview is shown for a document containing a `mermaid` block while the machine is offline
- **THEN** the diagram is fully rendered using bundled assets

#### Scenario: Remote image named in diagram source
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

### Requirement: Mermaid source cannot run script

The system SHALL treat Mermaid source as author data, as it treats raw HTML. Nothing in a diagram's source SHALL run script in the preview, in the page that PDF export and Print render, or in an exported HTML file, whether or not the reader clicks anything. The system SHALL render Mermaid at the engine's `strict` security level, and a diagram SHALL NOT be able to lower that level from its own source. This requirement is Mermaid's own boundary and holds without the page's Content-Security-Policy; that policy covers every engine, and it is what stops a `flow` link.

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
