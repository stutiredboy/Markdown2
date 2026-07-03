## Purpose

Define the visual styling of fenced code blocks in the Markdown editor, including the continuous block panel.

## Requirements

### Requirement: Continuous code-block shading in the editor

The source editor SHALL shade each fenced code block as a single continuous
panel. The shading MUST cover the full width of the text container and MUST
include the vertical line-spacing and paragraph-spacing gaps between code lines,
so no unshaded ("white isolation band") gaps appear between consecutive code
lines.

#### Scenario: Multi-line code block has no inter-line gaps

- **WHEN** the editor displays a fenced code block spanning several lines
- **THEN** the background shading is continuous from the top of the opening fence
  line to the bottom of the closing fence line
- **AND** no unshaded horizontal strip appears in the spacing between any two
  adjacent code lines

#### Scenario: Shading spans the full editor width

- **WHEN** a code line is shorter than the editor width (or wraps)
- **THEN** the shading still extends across the full width of the text container,
  not only behind the glyphs

### Requirement: Empty and short code lines are fully shaded

The editor SHALL shade empty lines and short lines inside a fenced code block to
the same extent as full lines, leaving no small unshaded blocks.

#### Scenario: Blank line inside a code block

- **WHEN** a fenced code block contains a blank line
- **THEN** that blank line is shaded across the full width like the surrounding
  code lines

#### Scenario: Switching from preview to edit mode

- **WHEN** the user switches from preview mode to edit mode while a code block is
  visible
- **THEN** the code block is shaded continuously with no small white blocks at the
  start of, or within, the block

### Requirement: Code-block shading is consistent with the preview

The editor code-block shading color SHALL be consistent with the preview's code
background and adapt to light and dark appearance.

#### Scenario: Appearance adaptation

- **WHEN** the system appearance is light or dark
- **THEN** the editor code-block shading uses a tone matching the preview code
  background for that appearance

### Requirement: Inline code and find highlights remain visible over the panel

The continuous code-block shading SHALL NOT obscure inline-code shading or
find/replace match highlights. Those highlights MUST remain visible on top of the
code-block panel.

#### Scenario: Find match inside a code block

- **WHEN** a find query matches text inside a fenced code block
- **THEN** the match highlight is drawn on top of the code-block panel and remains
  visible
