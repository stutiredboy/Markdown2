# Citation Rendering

## Purpose

Render Pandoc-style citations (`[@key]`) in the Read-mode preview using a parsed BibTeX bibliography file, supporting both author-year and numeric citation styles.

## Requirements

### Requirement: Inline citation detection and rendering
The system SHALL detect Pandoc-style citation syntax in inline text: `[@key]` for a parenthetical citation, `@key` (preceded by a non-word character or start of line) for an in-text citation, `[-@key]` for suppressing the author, `[@key1; @key2]` for multiple citations, and `[@key, p. 42]` for citations with locators. Each citation SHALL be rendered as formatted text in the Read-mode preview according to the configured citation style (author-year or numeric). Citation syntax inside inline code or code blocks SHALL remain literal text.

#### Scenario: Parenthetical citation renders in author-year style
- **WHEN** a paragraph contains `As shown by [@smith2023], the result holds.`
- **AND** a bibliography file with entry `smith2023` (author: Smith, year: 2023) is associated
- **THEN** the preview renders `(Smith, 2023)` in place of `[@smith2023]`
- **AND** the literal characters `[@smith2023]` do not appear as plain text

#### Scenario: In-text citation renders author outside parentheses
- **WHEN** a paragraph contains `@smith2023 showed that the result holds.`
- **AND** a bibliography file with entry `smith2023` (author: Smith, year: 2023) is associated
- **THEN** the preview renders `Smith (2023)` in place of `@smith2023`

#### Scenario: Suppressed author citation renders year only
- **WHEN** a paragraph contains `As shown previously [-@smith2023].`
- **AND** a bibliography file with entry `smith2023` (author: Smith, year: 2023) is associated
- **THEN** the preview renders `(2023)` in place of `[-@smith2023]`

#### Scenario: Multiple citations render semicolon-separated
- **WHEN** a paragraph contains `Several studies [@smith2023; @jones2024] confirm this.`
- **AND** bibliography entries for both keys exist
- **THEN** the preview renders `(Smith, 2023; Jones, 2024)` in author-year style
- **OR** renders `[1, 2]` in numeric style

#### Scenario: Citation with locator renders appended detail
- **WHEN** a paragraph contains `See [@smith2023, p. 42] for details.`
- **AND** a bibliography file with entry `smith2023` is associated
- **THEN** the preview renders `(Smith, 2023, p. 42)` in author-year style

#### Scenario: Numeric citation style renders bracketed numbers
- **WHEN** the citation style is set to numeric
- **AND** a paragraph contains the first citation `[@smith2023]` followed by a second `[@jones2024]`
- **THEN** the first renders as `[1]` and the second as `[2]`
- **AND** numbers reflect first-citation order across the document

#### Scenario: Citation syntax inside code stays literal
- **WHEN** a paragraph contains `` use `[@key]` to cite ``
- **THEN** the output shows the literal text `[@key]` styled as code
- **AND** no citation rendering occurs

### Requirement: Avoid false-positive citation detection
The system SHALL NOT treat ordinary `@` usage as an in-text citation. A bare `@key` SHALL be recognized only when the `@` is at the start of a line or preceded by whitespace or an opening punctuation boundary, AND is immediately followed by a citation-key character. An `@` immediately preceded by a word character (as in an email address) SHALL NOT start a citation. An `@` immediately followed by whitespace or end of line SHALL NOT start a citation. A recognized `@key` or `[@key]` whose key has no matching bibliography entry SHALL remain literal text and SHALL NOT create a bibliography entry.

#### Scenario: Email address is not a citation
- **WHEN** a paragraph contains `Contact john@example.com for details.`
- **THEN** the text renders unchanged with the literal email address
- **AND** no citation is rendered and no bibliography entry is created

#### Scenario: At-sign followed by whitespace is not a citation
- **WHEN** a paragraph contains `Let us meet @ noon.`
- **THEN** the text renders unchanged with the literal `@`
- **AND** no citation is rendered

#### Scenario: Bare at-key with no bibliography entry stays literal
- **WHEN** a paragraph contains `@todo revisit this` and no entry `todo` exists in the bibliography
- **THEN** the literal text `@todo` is rendered as plain text
- **AND** no bibliography entry is created

### Requirement: Bibliography file loading
The system SHALL load a BibTeX bibliography file (`.bib`) associated with the document. The bibliography file path SHALL be determined from the `bibliography:` field in YAML front matter, or by auto-detecting a `references.bib` file in the document's directory when no front matter field is present. The system SHALL parse BibTeX entries into structured data (key, entry type, title, author list, year, and other fields). If the bibliography file cannot be found or parsed, citations SHALL fall back to rendering the raw citation key as text.

#### Scenario: Bibliography loaded from front matter field
- **WHEN** a document has YAML front matter containing `bibliography: refs.bib`
- **AND** the file `refs.bib` exists in the document's directory
- **THEN** citations referencing keys in `refs.bib` render with author and year data

#### Scenario: Auto-detected bibliography file
- **WHEN** a document has no `bibliography:` front matter field
- **AND** a file named `references.bib` exists in the document's directory
- **THEN** the system loads `references.bib` and citations render with author and year data

#### Scenario: Missing bibliography file falls back gracefully
- **WHEN** a document references `[@smith2023]` but no bibliography file is found
- **THEN** the citation renders as the literal text `smith2023`
- **AND** no bibliography section is emitted
- **AND** the rest of the document renders normally

#### Scenario: Malformed BibTeX entry does not break parsing
- **WHEN** a `.bib` file contains a malformed entry alongside valid entries
- **THEN** the valid entries are parsed and available for citations
- **AND** the malformed entry is skipped without crashing the renderer

### Requirement: Bibliography section emission
The system SHALL emit a bibliography section at the end of the document body whenever at least one citation is rendered and a bibliography file is loaded. The section SHALL list cited entries ordered alphabetically by first author surname (author-year style) or by first-citation order (numeric style). Each entry SHALL render the author(s), year, and title at minimum. The bibliography section SHALL appear after the footnotes section if both are present.

#### Scenario: Bibliography section appears with cited entries
- **WHEN** a document contains `[@smith2023]` and `[@jones2024]` with a loaded bibliography
- **THEN** the rendered output ends with a bibliography section containing entries for both keys
- **AND** each entry shows the author, year, and title

#### Scenario: Alphabetical ordering in author-year style
- **WHEN** a document cites `[@zhang2023]` then `[@abbott2024]` in author-year style
- **THEN** the bibliography section lists `abbott2024` before `zhang2023`

#### Scenario: Citation-order ordering in numeric style
- **WHEN** a document cites `[@zhang2023]` then `[@abbott2024]` in numeric style
- **THEN** the bibliography section lists `zhang2023` (entry 1) before `abbott2024` (entry 2)

#### Scenario: No bibliography section when no citations
- **WHEN** a document has a loaded bibliography file but contains no citations
- **THEN** no bibliography section is emitted

### Requirement: Citation edge-case handling
The system SHALL handle incomplete or unusual citation usage without corrupting the rest of the document. A citation key with no matching bibliography entry SHALL render the raw key as text. A citation in an unsupported format SHALL remain literal text. Duplicate citations to the same key SHALL all render consistently and SHALL share a single bibliography entry.

#### Scenario: Unknown citation key renders as raw text
- **WHEN** a paragraph contains `[@unknownkey]` and no matching entry exists in the bibliography
- **THEN** the text `unknownkey` is rendered as plain text
- **AND** no bibliography entry is created for it

#### Scenario: Duplicate citations share one bibliography entry
- **WHEN** a document cites `[@smith2023]` twice
- **THEN** both citations render the same formatted text
- **AND** the bibliography section contains exactly one entry for `smith2023`

### Requirement: Citation code precedence
The system SHALL give inline code and code blocks precedence over citation detection. Citation-like syntax appearing inside inline code or inside fenced or indented code blocks SHALL remain literal source text and SHALL NOT produce citation rendering or bibliography entries.

#### Scenario: Citation syntax inside inline code stays literal
- **WHEN** a paragraph contains `` use `[@smith2023]` to cite ``
- **THEN** the output shows the literal text `[@smith2023]` styled as code
- **AND** no citation is rendered and no bibliography entry is created

#### Scenario: Citation syntax inside fenced code block stays literal
- **WHEN** a fenced code block contains the line `[@smith2023]`
- **THEN** the code block shows the literal `[@smith2023]`
- **AND** no citation rendering or bibliography entry occurs

### Requirement: Offline citation rendering and legibility
The system SHALL render citations and the bibliography section using only data from the parsed `.bib` file, without any runtime network access. Citations and bibliography text SHALL be legible in both light and dark color schemes, inheriting the preview's foreground and link colors.

#### Scenario: Citations render without network
- **WHEN** the preview is shown for a document with citations while the machine is offline
- **THEN** citations and the bibliography section render fully using the pre-parsed `.bib` data

#### Scenario: Citations are readable in dark mode
- **WHEN** the system appearance is dark and a document with citations is previewed
- **THEN** citation text and bibliography entries use the preview foreground/link colors and are clearly readable

### Requirement: Pandoc export integration for formal citations
When exporting via Pandoc (DOCX/EPUB), the system SHALL pass the associated `.bib` file and `--citeproc` flag to Pandoc so that citations are processed with full CSL formatting. The citation syntax in the source (`[@key]`) SHALL be passed through to Pandoc unmodified.

#### Scenario: DOCX export uses citeproc for citations
- **WHEN** a document with citations and a `.bib` file is exported to DOCX
- **THEN** Pandoc is invoked with `--citeproc` and `--bibliography=<file.bib>`
- **AND** the exported DOCX contains CSL-formatted citations and bibliography

#### Scenario: HTML export contains pre-rendered citations
- **WHEN** a document with citations is exported to self-contained HTML
- **THEN** the exported HTML contains the pre-rendered citation text and bibliography section
- **AND** no external citation processing is required
