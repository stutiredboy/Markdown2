## ADDED Requirements

### Requirement: Mermaid diagrams keep their natural size in exported output

The print-time width override SHALL NOT override Mermaid's own inline `max-width`
cap. A Mermaid diagram whose natural width is less than the printable column
SHALL render at its natural size rather than stretched to the printable width; a
Mermaid diagram whose natural width exceeds the printable column SHALL be scaled
down to fit within the printable column without horizontal clipping.

#### Scenario: Narrow Mermaid flowchart keeps natural size

- **WHEN** a document containing a narrow Mermaid flowchart (natural width less than the printable column) is exported to PDF
- **THEN** the diagram appears at its natural size
- **AND** the diagram is not stretched to fill the printable column width

#### Scenario: Wide Mermaid diagram scales to fit the column

- **WHEN** a document containing a Mermaid diagram whose natural width exceeds the printable column is exported to PDF
- **THEN** the diagram is scaled down to fit within the printable column width
- **AND** the diagram is not clipped at the right page margin

### Requirement: Exported output is rendered light independent of system appearance

The offscreen render used for PDF export and Print SHALL use a light appearance
regardless of the host system's appearance, so the composed PDF is always dark
text and dark diagram strokes on a white page. Mermaid SHALL render with its
light `default` theme during export and print even when the system is in Dark
Mode.

#### Scenario: Exporting in Dark Mode produces a light PDF

- **WHEN** a document containing text and a Mermaid diagram is exported while the host system is in Dark Mode
- **THEN** the PDF shows dark text and dark diagram strokes on a white background
- **AND** the output is not inverted, and no content is light-on-white or low contrast
