## MODIFIED Requirements

### Requirement: KaTeX macro configuration
The system SHALL support `\newcommand` and `\def` macros declared inside any math block, making them available globally to all subsequent math rendering in the document. The system SHALL additionally support an optional `math-macros:` field in YAML front matter for predefined macros that apply to all math in the document. Macros SHALL be processed by KaTeX without requiring a network connection. A live re-render in Side by Side SHALL apply the current `math-macros:` field and the current in-document definitions to every formula, the same as a full load of the same text.

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

#### Scenario: Editing front matter macros updates Side by Side
- **WHEN** the user changes, adds or removes a `math-macros:` entry in Side by Side
- **THEN** every formula that uses it renders with the new definition once the live re-render settles

#### Scenario: A definition added in a new block reaches existing formulas
- **WHEN** the user adds `$$\newcommand{\R}{\mathbb{R}}$$` above an existing `$$x \in \R$$` in Side by Side
- **THEN** the existing equation renders `\R` as the blackboard-bold R symbol

#### Scenario: Removing a definition updates existing formulas
- **WHEN** the user deletes the block that defines a macro in Side by Side
- **THEN** formulas that used the macro render it as undefined, as a full load of the same text would
