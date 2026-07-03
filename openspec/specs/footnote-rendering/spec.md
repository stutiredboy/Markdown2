## Purpose

Define rendering of footnote references and definitions: numbered superscript links, a trailing footnotes section, back-references, and graceful fallbacks.

## Requirements

### Requirement: Inline footnote reference rendering
The system SHALL detect inline footnote references written as `[^id]` within paragraph and other inline text, where `id` is a non-empty label containing no whitespace or closing bracket, and SHALL render each reference as a small superscript anchor link in the Read-mode preview. The rendered reference SHALL link to the corresponding footnote definition at the bottom of the document and SHALL display a sequential number reflecting the order in which footnotes are first referenced, regardless of the literal label text.

#### Scenario: Reference is rendered as a numbered superscript link
- **WHEN** a paragraph contains `Here is a statement.[^1] And more text.`
- **AND** a definition `[^1]: The supporting detail.` exists in the document
- **THEN** the preview renders a superscript `1` immediately after `statement.`
- **AND** the superscript is a link whose target is the matching footnote definition
- **AND** the literal characters `[^1]` do not appear as plain text

#### Scenario: Named labels are numbered by reference order
- **WHEN** the document references `[^note]` before `[^alpha]`
- **AND** both have matching definitions
- **THEN** `[^note]` renders as superscript `1` and `[^alpha]` renders as superscript `2`
- **AND** the displayed numbers reflect first-reference order, not the label text

### Requirement: Footnote definition collection
The system SHALL detect footnote definitions written at the start of a line as `[^id]: text`, SHALL remove them from the main document body so they do not render in place, and SHALL collect their content for emission in the footnotes section. A definition's content MAY span multiple lines: lines following the definition that are indented (or blank lines between indented continuation lines) SHALL be treated as a continuation of that definition's content.

#### Scenario: Definition is removed from body flow
- **WHEN** the source contains a paragraph followed by a line `[^1]: The footnote text.`
- **THEN** the line `[^1]: The footnote text.` does not appear as a paragraph in the document body
- **AND** its content appears only in the footnotes section at the bottom

#### Scenario: Multi-line definition content is preserved
- **WHEN** a definition `[^long]: First line.` is followed by an indented continuation line `    Second line.`
- **THEN** the footnotes section entry for `long` contains both `First line.` and `Second line.`

### Requirement: Footnotes section emission
The system SHALL emit a footnotes section at the end of the document body whenever at least one footnote definition is referenced. The section SHALL list referenced definitions ordered by first reference, render each definition's content with normal inline Markdown formatting, and include in each entry a back-reference link that navigates from the definition to the location of its reference in the text.

#### Scenario: Footnotes section appears with back-references
- **WHEN** a document contains one reference `[^1]` and its definition `[^1]: Detail.`
- **THEN** the rendered output ends with a footnotes section containing an entry for footnote `1`
- **AND** that entry renders the text `Detail.` with inline Markdown applied
- **AND** the entry includes a back-reference link that targets the reference location in the body

#### Scenario: No section when no footnotes are referenced
- **WHEN** a document contains no footnote references
- **THEN** no footnotes section is emitted

### Requirement: Footnote edge-case handling
The system SHALL handle incomplete or unusual footnote usage without corrupting the rest of the document. A reference with no matching definition SHALL remain literal text. A definition that is never referenced SHALL NOT appear in the footnotes section. Multiple references to the same label SHALL all link to the single shared definition, and the definition SHALL provide back-references for each referencing location.

#### Scenario: Reference without definition stays literal
- **WHEN** a paragraph contains `Dangling.[^missing]` and no definition for `missing` exists
- **THEN** the literal text `[^missing]` is rendered as plain text
- **AND** no superscript link and no footnotes section entry are created for it

#### Scenario: Unreferenced definition is omitted
- **WHEN** a document defines `[^unused]: Never cited.` but contains no `[^unused]` reference
- **THEN** the footnotes section does not contain an entry for `unused`

#### Scenario: Duplicate references share one definition
- **WHEN** a document references `[^1]` twice and defines `[^1]: Shared.` once
- **THEN** both references render as the same footnote number and link to the same definition
- **AND** the single footnotes entry provides a back-reference for each of the two reference locations

### Requirement: Code content is never treated as footnotes
The system SHALL give inline code and code blocks precedence over footnote detection. Footnote-like syntax appearing inside inline code (`` `...` ``) or inside fenced or indented code blocks SHALL remain literal source text and SHALL NOT produce references, definitions, or footnotes-section entries.

#### Scenario: Footnote syntax inside inline code stays literal
- **WHEN** a paragraph contains `` use `[^1]` as a label ``
- **THEN** the output shows the literal text `[^1]` styled as code
- **AND** no superscript reference is produced

#### Scenario: Footnote definition inside a fenced code block stays literal
- **WHEN** a fenced code block contains the line `[^1]: not a footnote`
- **THEN** the code block shows the literal `[^1]: not a footnote`
- **AND** no footnotes-section entry is created from it

### Requirement: Offline footnote rendering and legibility
The system SHALL render footnote references and the footnotes section using only assets bundled with the application, without any runtime network access. Footnote references and the footnotes section SHALL be legible in both light and dark color schemes, inheriting the preview's foreground and link colors.

#### Scenario: Footnotes render without network
- **WHEN** the preview is shown for a document containing footnotes while the machine is offline
- **THEN** the references and footnotes section render fully

#### Scenario: Footnotes are readable in dark mode
- **WHEN** the system appearance is dark and a document with footnotes is previewed
- **THEN** the superscript references and footnotes section text use the preview foreground/link colors and are clearly readable against the dark background
