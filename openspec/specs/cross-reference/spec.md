# Cross-Reference

## Purpose

Resolve `\ref{label}` inline references to auto-numbered figures, tables, and equations in the Read-mode preview, providing technical and academic documents with cross-referencing capabilities.

## Requirements

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

#### Scenario: Undefined label keeps its authored text
- **WHEN** inline text contains `\ref{eq:a_b_c}` and no label `eq:a_b_c` exists
- **THEN** the literal text `\ref{eq:a_b_c}` is rendered, with no emphasis applied inside it

#### Scenario: Reference inside link syntax acts as the anchor it may become
- **WHEN** a `\ref{label}` appears inside a link or image destination, or inside reference-link text
- **THEN** the destination is treated as unsafe and the link text stays inert, as for any anchor fragment, whether or not `label` exists

### Requirement: One numbering authority for every container
The system SHALL number figures, tables, and equations in the order the rendered document displays them — top-level blocks, blockquotes and alerts, list items, and table captions in place, and footnote content after the body — and SHALL resolve every `\ref{label}` after the whole document is numbered. A `\ref{}` SHALL render the number its target displays, whether it appears before or after the target and whichever container either sits in. When a label is defined more than once, every `\ref{}` to it SHALL resolve to the last definition. An element inside a code block SHALL NOT be numbered or become a reference target.

#### Scenario: Forward reference into a container resolves
- **WHEN** a paragraph contains `see \ref{eq:quoted}` and a later blockquote contains `$$a = 1 \label{eq:quoted}$$`
- **THEN** the reference renders the quoted equation's number

#### Scenario: Container content shifts later numbers consistently
- **WHEN** a blockquote equation labeled `eq:quoted` precedes a top-level equation labeled `eq:top`
- **THEN** the top-level equation displays `(2)`
- **AND** `\ref{eq:top}` resolves to `2`

#### Scenario: Footnote figures are numbered after body figures
- **WHEN** a footnote contains `![Note](n.png){#fig:note}` and the body contains `![Body](b.png){#fig:body}` after the footnote definition
- **THEN** the body figure is captioned "Figure 1: Body" and the footnote figure "Figure 2: Note"
- **AND** `\ref{fig:body}` resolves to `1` and `\ref{fig:note}` to `2`

#### Scenario: Image inside a quoted code fence is not a target
- **WHEN** a blockquote holds a fenced code block containing `![Code](c.png){#fig:code}`
- **THEN** no figure number is consumed by it
- **AND** `\ref{fig:code}` renders as literal text

#### Scenario: Duplicate label resolves to its last definition
- **WHEN** two figures carry `{#fig:x}` and `\ref{fig:x}` appears before, between, and after them
- **THEN** every reference resolves to `2`

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
