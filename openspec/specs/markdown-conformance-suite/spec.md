# markdown-conformance-suite

## Purpose

Define a conformance test suite that pins Markdown2's rendering behaviour against
the CommonMark and GFM reference corpora, produces a categorised compatibility
dashboard, and surfaces both regressions and unexpected improvements.

## Requirements

### Requirement: Vendored CommonMark and GFM conformance corpus

The test suite SHALL vendor the CommonMark reference examples and the GFM
extension examples in the reference example format (`spec.json` records with
`markdown`, `html`, `example`, and `section` fields). Each example SHALL be
addressable by its construct `section` so results can be aggregated by category.
The corpus SHALL be bundled as test resources and loadable offline at test time,
with its upstream source, version, and licence recorded alongside it.

#### Scenario: Corpus loads and is categorised

- **WHEN** the conformance suite runs
- **THEN** it loads the vendored CommonMark and GFM examples from bundled test resources without network access
- **AND** each example exposes its source Markdown and its construct category (`section`)

### Requirement: Categorised compatibility dashboard

Running the conformance suite SHALL produce a dashboard that aggregates results by
the compatibility matrix's construct identifier and tier (see
`markdown-compatibility-matrix`), not only by raw upstream `section` strings. For
each construct it SHALL report the number of represented corpus examples whose
rendered output matches the reference (under documented normalisation) and the
total, plus an overall upstream pass-rate. Markdown2-extension constructs that are
not represented in the CommonMark/GFM corpus SHALL be excluded from the upstream
pass-rate and tracked by their local tests instead. The dashboard SHALL be written
to a known artifact path and summarised in the test output.

#### Scenario: Dashboard groups by matrix construct and tier

- **WHEN** the conformance suite completes
- **THEN** a report is produced listing each matrix construct identifier and tier with its passed/total count and an overall upstream pass-rate
- **AND** the report is written to a known artifact path

#### Scenario: Extension constructs are excluded from the upstream pass-rate

- **WHEN** the dashboard computes the upstream conformance pass-rate
- **THEN** Markdown2-extension constructs not represented in the corpus are excluded from that pass-rate
- **AND** their status is reflected by their local tests rather than the upstream count

#### Scenario: Failures are inspectable

- **WHEN** an example does not match the reference
- **THEN** the report records the example's source, the expected reference HTML, and the actual rendered HTML so a human can inspect the divergence

### Requirement: Current boundary behaviour is characterized and pinned

The suite SHALL pin the renderer's current result for every corpus example
against a checked-in baseline that records each example's relationship to the
reference using the matrix's baseline vocabulary (see
`markdown-compatibility-matrix`): `reference-match`, `intentional-divergence`,
`known-incomplete`, or `unsupported`. This baseline relationship is distinct from
the construct's support tier and SHALL NOT be conflated with it. A change that
shifts a boundary SHALL fail the suite: an example recorded as `reference-match`
that stops matching SHALL fail, AND an example recorded as any divergence
(`intentional-divergence`, `known-incomplete`, or `unsupported`) that starts
matching SHALL also fail, so regressions and improvements alike are surfaced and
locked in by updating the baseline and the matrix rather than passing silently.

#### Scenario: Regression on a previously-passing example fails

- **WHEN** a code change causes a corpus example recorded as `reference-match` to stop matching the reference
- **THEN** the conformance suite fails and identifies the example

#### Scenario: A newly-matching divergence is surfaced

- **WHEN** a code change causes an example recorded as `intentional-divergence`, `known-incomplete`, or `unsupported` to start matching the reference
- **THEN** the suite fails so the baseline and matrix can be updated to record the improvement

### Requirement: Source-line and task-line metadata invariant across the corpus

The renderer SHALL carry source-line and task-line metadata on every block of
every corpus example. Each top-level content block emitted into the preview body
(headings, paragraphs, lists, tables, blockquotes, code blocks, math blocks,
diagrams, horizontal rules, footnote items) SHALL carry a `data-md2-source-line`
attribute (and `data-md2-source-end-line` for multi-line blocks), and every
task-list item SHALL carry a `data-md2-task-line` attribute. The suite SHALL fail
if a content block is missing its metadata. This invariant guards mode-switch
scroll anchoring and preview task toggling and SHALL hold regardless of how the
renderer is later re-implemented.

#### Scenario: Every rendered block carries source-line metadata

- **WHEN** any corpus example is rendered
- **THEN** each top-level content block element carries a `data-md2-source-line` attribute mapping it back to its source line
- **AND** the suite fails if such a block is missing it

#### Scenario: Task items remain togglable

- **WHEN** a corpus example contains GFM task-list items
- **THEN** each task item's checkbox carries a `data-md2-task-line` attribute mapping it to its source line
