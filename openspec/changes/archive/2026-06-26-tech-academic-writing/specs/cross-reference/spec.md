## ADDED Requirements

### Requirement: Cross-reference detection and resolution
The system SHALL detect `\ref{label}` in inline text and SHALL resolve it to the number of the referenced labeled element (figure, table, or equation). If the label is not found — including a `\ref{}` that names a heading slug, since heading/section references are out of scope for this change — `\ref{label}` SHALL remain as literal text. Cross-reference syntax inside inline code or code blocks SHALL remain literal text.

#### Scenario: Equation cross-reference resolves to number
- **WHEN** a document contains a display equation with `\label{eq:euler}` and inline text `as shown in \ref{eq:euler}`
- **THEN** the inline text renders the equation's number (e.g. `1`)
- **AND** the literal `\ref{eq:euler}` does not appear as plain text

#### Scenario: Figure cross-reference resolves to number
- **WHEN** a document contains a figure with `{#fig:diagram}` and inline text `see \ref{fig:diagram}`
- **THEN** the inline text renders the figure's number (e.g. `2`)

#### Scenario: Table cross-reference resolves to number
- **WHEN** a document contains a table with `{#tbl:results}` and inline text `in \ref{tbl:results}`
- **THEN** the inline text renders the table's number (e.g. `1`)

#### Scenario: Undefined label renders as literal text
- **WHEN** inline text contains `\ref{nonexistent}` and no label `nonexistent` exists
- **THEN** the literal text `\ref{nonexistent}` is rendered as plain text

#### Scenario: Heading-slug reference is not resolved (sections out of scope)
- **WHEN** a document has a heading `## Methods` (slug `methods`) and inline text `see \ref{methods}`
- **THEN** the literal text `\ref{methods}` is rendered as plain text
- **AND** no section number is produced

#### Scenario: Cross-reference inside code stays literal
- **WHEN** a paragraph contains `` use `\ref{eq:foo}` to reference ``
- **THEN** the output shows the literal text `\ref{eq:foo}` styled as code
- **AND** no cross-reference resolution occurs

### Requirement: Figure auto-numbering and labeling
The system SHALL auto-number figures sequentially in document order. A figure is defined as an image with a Pandoc-style attribute containing an ID: `![caption](src){#fig:label}`. The system SHALL assign the next sequential figure number and SHALL render the caption with the prefix "Figure N: " where N is the assigned number. The figure's label SHALL be registered for cross-reference resolution.

#### Scenario: Figure with label is numbered and captioned
- **WHEN** a document contains `![Flow diagram](flow.png){#fig:flow}`
- **THEN** the image renders with a caption "Figure 1: Flow diagram"
- **AND** `\ref{fig:flow}` resolves to `1`

#### Scenario: Multiple figures are numbered sequentially
- **WHEN** a document contains `![First](a.png){#fig:a}` followed by `![Second](b.png){#fig:b}`
- **THEN** the first figure is captioned "Figure 1: First" and the second "Figure 2: Second"
- **AND** `\ref{fig:a}` resolves to `1` and `\ref{fig:b}` resolves to `2`

#### Scenario: Figure without label is not numbered
- **WHEN** a document contains `![Diagram](diagram.png)` without an `{#fig:...}` attribute
- **THEN** the image renders without a numbered caption
- **AND** no cross-reference target is created

### Requirement: Table auto-numbering and labeling
The system SHALL auto-number tables sequentially in document order. A table label is defined by a caption line immediately following a pipe table, in the format `: caption text {#tbl:label}`. The system SHALL assign the next sequential table number and SHALL render the caption with the prefix "Table N: " where N is the assigned number. The table's label SHALL be registered for cross-reference resolution.

#### Scenario: Table with caption is numbered
- **WHEN** a document contains a pipe table followed by `: Results summary {#tbl:results}`
- **THEN** the table renders with a caption "Table 1: Results summary"
- **AND** `\ref{tbl:results}` resolves to `1`

#### Scenario: Table without caption is not numbered
- **WHEN** a document contains a pipe table with no caption line
- **THEN** the table renders without a numbered caption

### Requirement: Equation auto-numbering and labeling
The system SHALL auto-number display equations that contain a `\label{}` command. An equation with `\label{eq:foo}` SHALL be assigned the next sequential equation number, SHALL render with the number right-aligned, and SHALL register the label for cross-reference resolution. Display equations without `\label{}` SHALL be unnumbered by default. A configurable setting MAY enable numbering for all display equations regardless of `\label{}` presence.

#### Scenario: Labeled equation is numbered
- **WHEN** a document contains `$$E = mc^2 \label{eq:energy}$$`
- **THEN** the display equation renders with a right-aligned number `(1)`
- **AND** `\ref{eq:energy}` resolves to `1`

#### Scenario: Unlabeled equation is not numbered by default
- **WHEN** a document contains `$$E = mc^2$$` without a `\label{}`
- **THEN** the display equation renders without a number

#### Scenario: Number-all-equations setting numbers unlabeled equations
- **WHEN** the "number all display equations" setting is enabled
- **AND** a document contains `$$E = mc^2$$` without a `\label{}`
- **THEN** the display equation renders with a right-aligned number

#### Scenario: Multiple equations are numbered sequentially
- **WHEN** a document contains `$$a = b \label{eq:a}$$` followed by `$$c = d \label{eq:b}$$`
- **THEN** the first equation is numbered `(1)` and the second `(2)`

### Requirement: Cross-reference code precedence
The system SHALL give inline code, code blocks, and inline math precedence over cross-reference detection. The `\ref{}` syntax appearing inside inline code, fenced or indented code blocks, or inline/display math SHALL remain literal and SHALL NOT be resolved.

#### Scenario: Ref syntax inside inline math stays literal
- **WHEN** a paragraph contains `$\ref{eq:foo}$`
- **THEN** the `\ref{eq:foo}` is passed to the math engine as TeX source
- **AND** no cross-reference resolution occurs

#### Scenario: Ref syntax inside fenced code block stays literal
- **WHEN** a fenced code block contains the line `\ref{eq:foo}`
- **THEN** the code block shows the literal `\ref{eq:foo}`
- **AND** no cross-reference resolution occurs

### Requirement: Offline cross-reference rendering and legibility
The system SHALL render cross-references and numbered captions using only the renderer's in-memory state, without any runtime network access. Cross-reference text and caption labels SHALL be legible in both light and dark color schemes, inheriting the preview's foreground and link colors.

#### Scenario: Cross-references render without network
- **WHEN** the preview is shown for a document with cross-references while the machine is offline
- **THEN** all cross-references and numbered captions render fully

#### Scenario: Cross-references are readable in dark mode
- **WHEN** the system appearance is dark and a document with cross-references is previewed
- **THEN** reference numbers and caption text use the preview foreground/link colors and are clearly readable
