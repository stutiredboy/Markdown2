# markdown-compatibility-matrix

## Purpose

Define a single, checked-in compatibility matrix that serves as the enforceable
support contract for Markdown2's renderer — human-readable and machine-checkable,
recording every construct's tier, declared behaviour, boundary, and baseline
relationship.

## Requirements

### Requirement: Machine-checkable compatibility matrix

The project SHALL maintain a single checked-in compatibility matrix that is both
human-readable and machine-checkable. The matrix SHALL be the support contract
for Markdown2's renderer, not merely a prose checklist. Each matrix entry SHALL
include:

- a stable construct identifier
- the construct origin: CommonMark, GFM, or Markdown2 extension
- the upstream corpus `section` value(s), when the construct is represented in
  the vendored corpus
- exactly one support tier: **Supported**, **Best-effort**, or
  **Out-of-scope**
- the declared Markdown2 rendering behaviour, including the expected HTML shape
  for interpreted constructs
- the boundary and fallback behaviour for malformed, incomplete, or unsupported
  input
- the relationship to the conformance baseline: reference match, intentional
  reference divergence, known incomplete behaviour, or unsupported
- the user-facing documentation label used by `Docs/MarkdownSupport.md`

The matrix SHALL record the pinned upstream CommonMark/GFM corpus source,
version or commit, licence reference, and the matrix schema version so that
coverage is evaluated against a stable corpus rather than a floating upstream
definition.

#### Scenario: Matrix entry schema is complete

- **WHEN** the matrix validation reads any construct entry
- **THEN** the entry has a stable identifier, origin, tier, declared rendering behaviour, boundary behaviour, baseline relationship, and documentation label
- **AND** entries represented by the conformance corpus list the exact corpus `section` value(s) they cover

#### Scenario: Matrix provenance is pinned

- **WHEN** a developer inspects or validates the matrix
- **THEN** the CommonMark and GFM corpus source, pinned version or commit, licence reference, and matrix schema version are available from the checked-in matrix artifacts

### Requirement: Enforceable support-tier semantics

The compatibility tier SHALL describe Markdown2's product contract, while the
baseline relationship SHALL describe whether the rendered output matches the
upstream reference HTML. The two SHALL NOT be conflated.

**Supported** means Markdown2 intentionally interprets the construct and emits a
declared, stable HTML shape. A Supported entry MAY intentionally diverge from
CommonMark/GFM reference HTML only when the divergence is explicitly declared in
the matrix and pinned as an intentional baseline divergence.

**Best-effort** means Markdown2 attempts to render the construct usefully but has
known incomplete coverage, known edge-case divergence, or a declared fallback at
some boundaries. The entry SHALL identify the covered subset and the known edges
that are not part of the stable contract.

**Out-of-scope** means Markdown2 intentionally does not interpret the construct.
The entry SHALL declare that authored text is preserved as literal or escaped
content and SHALL NOT advertise semantic rendering for that construct.

#### Scenario: Supported construct has a stable declared shape

- **WHEN** a construct classified Supported is rendered within the matrix-declared boundary
- **THEN** the renderer emits the declared Markdown2 HTML shape
- **AND** the conformance baseline records each represented corpus example as either a reference match or an explicit intentional reference divergence

#### Scenario: Intentional reference divergence is visible

- **WHEN** Markdown2 intentionally differs from CommonMark/GFM reference output for an otherwise Supported behaviour, such as preserving soft line breaks as visible `<br>` elements
- **THEN** the matrix records the Markdown2 behaviour and rationale
- **AND** the dashboard/baseline reports the example as a known intentional divergence rather than a reference pass

#### Scenario: Best-effort construct states covered boundaries

- **WHEN** a construct is classified Best-effort
- **THEN** the matrix states which forms are expected to render usefully
- **AND** the matrix states which known forms may diverge, degrade to text, or remain unsupported

#### Scenario: Out-of-scope construct is not interpreted

- **WHEN** a construct is classified Out-of-scope, such as an unsupported raw HTML block form or an unresolved link-reference definition
- **THEN** the renderer preserves its authored text as literal or escaped content
- **AND** the matrix and user-facing docs do not claim semantic support for that construct

### Requirement: Complete construct coverage

The matrix SHALL be total over the vendored corpus categories used by
`markdown-conformance-suite`: every CommonMark/GFM `section` loaded from the
corpus SHALL map to exactly one matrix entry and exactly one support tier. A new
or renamed corpus section SHALL fail validation until it is classified.

The matrix SHALL also include Markdown2-specific Markdown extensions that are
advertised to users but not represented by the CommonMark/GFM corpus, including
YAML front matter, `[TOC]`, TeX math, diagram fences, footnotes, Pandoc-style
image size attributes, and image-attachment link behaviour. These extension
entries SHALL be excluded from upstream conformance pass-rate calculations but
SHALL still have local tests, declared rendering behaviour, and graceful
degradation behaviour.

#### Scenario: Corpus section maps exactly once

- **WHEN** the conformance suite loads a CommonMark or GFM example with a `section`
- **THEN** matrix validation finds exactly one matrix entry covering that section
- **AND** the entry supplies the support tier and baseline relationship used by the dashboard

#### Scenario: Unknown corpus section blocks validation

- **WHEN** the vendored corpus is updated and introduces a section not covered by the matrix
- **THEN** matrix validation fails and names the unmapped section

#### Scenario: User-advertised Markdown2 extension is classified

- **WHEN** `Docs/MarkdownSupport.md` advertises a Markdown2 extension that is not part of the CommonMark/GFM corpus
- **THEN** the matrix contains a corresponding Markdown2-extension entry with a support tier, declared behaviour, and local test coverage reference

### Requirement: Declared boundary behaviour is specific enough to test

Each matrix entry SHALL describe the construct boundary at a level that can be
tested without reading renderer implementation details. For interpreted block
constructs, the entry SHALL declare the emitted top-level element(s), source-line
metadata expectations, and the treatment of nested Markdown. For interpreted
inline constructs, the entry SHALL declare precedence with code spans, math,
HTML escaping, links/images, and emphasis where applicable. For fallback
behaviour, the entry SHALL declare whether raw source markers are preserved,
escaped, or consumed.

#### Scenario: Block construct boundary is testable

- **WHEN** a block construct such as a list, blockquote, table, code fence, math block, diagram block, or footnote section is classified
- **THEN** the matrix declares the top-level HTML element(s) it emits
- **AND** the matrix declares whether the top-level block must carry `data-md2-source-line` and `data-md2-source-end-line`

#### Scenario: Inline precedence is testable

- **WHEN** an inline construct such as code, math, autolink, raw inline HTML, emphasis, link, image, or footnote reference is classified
- **THEN** the matrix declares its precedence relative to neighbouring inline constructs where precedence affects output

#### Scenario: Fallback preserves authored text

- **WHEN** a matrix entry declares fallback-to-text behaviour
- **THEN** tests can assert that authored content remains visible in the rendered output after HTML escaping and source-line metadata stripping

### Requirement: Graceful degradation for out-of-scope and malformed input

The renderer SHALL treat any out-of-scope, unterminated, or malformed construct
as readable content: it SHALL NOT blank the preview, SHALL NOT drop authored
text, and SHALL NOT crash or hang. Unrecognised or unterminated input SHALL fall
back to showing its text, HTML-escaped where required, consistent with the
existing diagram raw-text fallback.

This guarantee SHALL apply across all matrix tiers. Supported and Best-effort
entries SHALL define their malformed-input boundary, and Out-of-scope entries
SHALL define their literal/escaped fallback.

#### Scenario: Unterminated fenced code block

- **WHEN** the source contains a code fence that is never closed
- **THEN** the preview still renders the content that precedes the fence
- **AND** the unterminated region appears as text/code rather than vanishing
- **AND** the preview body is non-empty and no error is thrown

#### Scenario: Malformed pipe table

- **WHEN** a pipe-table-like block has rows whose cell counts do not match the header row
- **THEN** the authored text is preserved in the output as a table or as paragraph text according to the matrix entry
- **AND** the preview is not blanked

#### Scenario: Unsafe or unsupported raw HTML degrades safely

- **WHEN** the source uses raw HTML that is not in Markdown2's allowed inline HTML contract
- **THEN** the raw HTML is escaped or otherwise rendered inert
- **AND** authored text remains visible without executing script or dropping surrounding content

#### Scenario: Out-of-scope construct degrades to text

- **WHEN** the source uses a construct classified Out-of-scope
- **THEN** its literal text appears in the rendered output rather than being silently removed

### Requirement: Matrix, baseline, dashboard, and docs stay consistent

`Docs/MarkdownSupport.md` SHALL reflect the compatibility matrix and SHALL NOT
contradict it. The user-facing support list SHALL be derived from, or verified
against, the matrix tiers so the two cannot drift apart.

The conformance dashboard SHALL aggregate results using the matrix's construct
identifiers and tiers. A tier change SHALL require corresponding baseline and
documentation updates when those artifacts are affected.

#### Scenario: Docs agree with the matrix

- **WHEN** a construct is classified Out-of-scope in the matrix
- **THEN** `Docs/MarkdownSupport.md` does not advertise that construct as supported

#### Scenario: Best-effort support is labelled with its boundary

- **WHEN** a construct is classified Best-effort
- **THEN** user-facing documentation either labels it as Best-effort or states the same boundary/limitation captured by the matrix

#### Scenario: Dashboard uses matrix categories

- **WHEN** the conformance dashboard reports pass rates
- **THEN** results are grouped by the matrix construct identifier and tier, not only by raw upstream `section` strings

#### Scenario: Tier drift is caught

- **WHEN** the matrix tier for a construct changes
- **THEN** validation or tests flag any required baseline/dashboard/doc update so the artifacts are reconciled together
