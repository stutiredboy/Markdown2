## MODIFIED Requirements

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

## ADDED Requirements

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
