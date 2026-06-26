# Math Rendering

## Purpose

Detect inline (`$...$`) and block (`$$...$$`) TeX math in Markdown source, emit it safely into the preview HTML, and typeset it offline with KaTeX so technical and academic documents render correctly in the Read-mode preview without any network access.

## Requirements

### Requirement: Inline math rendering
The system SHALL detect inline TeX math delimited by single dollar signs (`$...$`) within a line of Markdown and SHALL render it as typeset math in the Read-mode preview. The math content SHALL be treated literally and SHALL NOT be processed by inline Markdown rules (emphasis, links, autolinks) nor HTML-escaped in a way that alters the TeX source seen by the math engine.

#### Scenario: Inline math is typeset
- **WHEN** a paragraph contains `The mass is $E = mc^2$ today.`
- **THEN** the preview renders `E = mc^2` as typeset inline math inline with the surrounding text
- **AND** the literal characters `$`, `=`, `^` do not appear as plain text in the output

#### Scenario: Markdown is not applied inside inline math
- **WHEN** a paragraph contains `$a_*b_*c$`
- **THEN** the underscores and asterisks are passed to the math engine as TeX source
- **AND** no `<em>`/`<strong>` emphasis is produced from the math content

### Requirement: Block (display) math rendering
The system SHALL detect block/display math delimited by double dollar signs (`$$...$$`), including content that spans multiple lines, and SHALL render it as a centered display equation in the Read-mode preview. The block SHALL NOT be treated as a paragraph or code block. Display equations containing a `\label{key}` command SHALL be assigned a sequential equation number, rendered right-aligned alongside the equation, and the label SHALL be registered for cross-reference resolution. The `\label{}` command itself SHALL be removed before typesetting and SHALL NOT appear in the rendered output. Display equations without `\label{}` SHALL be unnumbered by default, unless a "number all display equations" setting is enabled. The `\tag{n}` command SHALL set a manual equation number, overriding auto-numbering.

#### Scenario: Multi-line display block is typeset
- **WHEN** the source contains a block opening with a line `$$`, then `\int_0^1 x^2 \, dx`, then a closing line `$$`
- **THEN** the preview renders the integral as a centered display equation
- **AND** the `$$` delimiters are not shown as literal text

#### Scenario: Single-line display block is typeset
- **WHEN** the source contains a line `$$a^2 + b^2 = c^2$$`
- **THEN** the preview renders it as a centered display equation

#### Scenario: Labeled display equation is numbered
- **WHEN** the source contains `$$E = mc^2 \label{eq:energy}$$`
- **THEN** the preview renders the equation centered with a right-aligned number `(1)`
- **AND** the label `eq:energy` is registered for `\ref{}` resolution

#### Scenario: Label command is not shown in the typeset equation
- **WHEN** the source contains `$$E = mc^2 \label{eq:energy}$$`
- **THEN** the typeset equation shows `E = mc^2` alongside its number
- **AND** the literal text `\label{eq:energy}` does not appear in the output

#### Scenario: Unlabeled display equation is unnumbered by default
- **WHEN** the source contains `$$E = mc^2$$` without `\label{}`
- **THEN** the preview renders the equation without a number

#### Scenario: Manual tag overrides auto-numbering
- **WHEN** the source contains `$$a = b \tag{3.1}$$`
- **THEN** the preview renders the equation with the manual number `(3.1)` right-aligned

### Requirement: Avoid false-positive math detection
The system SHALL NOT treat ordinary dollar-sign usage as math. An escaped `\$`, a dollar sign immediately followed by whitespace at the open, a dollar sign immediately preceded by whitespace at the close, and an unmatched lone `$` on a line SHALL all remain literal text.

#### Scenario: Currency text is not math
- **WHEN** a paragraph contains `It costs $5 today and $10 tomorrow.`
- **THEN** the text renders unchanged with literal dollar signs
- **AND** no math typesetting occurs

#### Scenario: Escaped dollar sign is literal
- **WHEN** a paragraph contains `Price: \$x`
- **THEN** a literal `$x` is rendered as text
- **AND** no math span is created

### Requirement: Code content is never treated as math
The system SHALL give inline code and code blocks precedence over math detection. Dollar-delimited content inside inline code (`` `...` ``) or fenced/indented code blocks SHALL remain literal source text.

#### Scenario: Dollar math inside inline code stays literal
- **WHEN** a paragraph contains `` use `$x$` here ``
- **THEN** the output shows the literal text `$x$` styled as code
- **AND** no math typesetting occurs

#### Scenario: Dollar math inside a fenced code block stays literal
- **WHEN** a fenced code block contains the line `$$x^2$$`
- **THEN** the code block shows the literal `$$x^2$$`
- **AND** no display equation is rendered

### Requirement: Offline rendering with graceful error handling
The system SHALL typeset math without any runtime network access, using assets bundled with the application. When a TeX expression contains commands the engine cannot render, the system SHALL display the offending source visibly rather than failing to render the rest of the document.

#### Scenario: Math renders without network
- **WHEN** the preview is shown for a document containing math while the machine is offline
- **THEN** the math is fully typeset using bundled assets

#### Scenario: Invalid TeX does not break the page
- **WHEN** a document contains an unsupported or malformed TeX expression such as `$\unknowncmd{}$`
- **THEN** the rest of the document still renders normally
- **AND** the problematic expression is shown (e.g. highlighted as an error) instead of crashing or blanking the preview

### Requirement: Math legibility in light and dark mode
Typeset math SHALL be legible in both light and dark color schemes, inheriting the preview's foreground text color.

#### Scenario: Math is readable in dark mode
- **WHEN** the system appearance is dark and a document with math is previewed
- **THEN** the typeset math uses the preview foreground color and is clearly readable against the dark background

### Requirement: KaTeX macro configuration
The system SHALL support `\newcommand` and `\def` macros declared inside any math block, making them available globally to all subsequent math rendering in the document. The system SHALL additionally support an optional `math-macros:` field in YAML front matter for predefined macros that apply to all math in the document. Macros SHALL be processed by KaTeX without requiring a network connection.

#### Scenario: Newcommand in one block is available in later blocks
- **WHEN** a document contains `$$\newcommand{\R}{\mathbb{R}}$$` followed by `$$x \in \R$$`
- **THEN** the second equation renders with `\R` typeset as the blackboard-bold R symbol

#### Scenario: Front matter macros apply to all math
- **WHEN** a document has YAML front matter `math-macros: { "\\vec": "\\mathbf" }`
- **AND** the document contains `$\vec{x}$`
- **THEN** the inline math renders `\vec{x}` as bold x

#### Scenario: Macros work without network
- **WHEN** the preview is shown for a document with `\newcommand` macros while the machine is offline
- **THEN** the macros are applied correctly using bundled KaTeX assets
