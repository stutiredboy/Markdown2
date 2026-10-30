## MODIFIED Requirements

### Requirement: Inline destination classification is linear in text size

`protectAutolinks` SHALL determine whether a match sits inside a link or image destination from a precomputed destination index, and the verbatim-span scan SHALL classify each `\(` opener with the same rule tracked incrementally over its output prefix; neither SHALL scan backward from every match. Both SHALL apply one nearest-opener rule over Unicode scalars, the unit the inline patterns match, in O(text): no opener means outside; a destination that closes before the position means outside; a raw `](` opens a destination even when its `]` is escaped; escaped characters, nested parentheses, and unterminated destinations follow the existing rules; a combining mark after a parenthesis does not hide it. In the scan, an already-claimed code or math span SHALL read as one opaque unit, as its placeholder token does for later passes. Each index lookup SHALL be O(1) or O(log M) for M openers, and each scan step SHALL be O(1).

#### Scenario: Many angle autolinks on one line scale linearly

- **WHEN** a single line contains 1,000 `<https://…>` autolinks and no `](` opener
- **AND** the same line contains 2,000
- **THEN** the 2,000 case takes less than 3× the 1,000 case
- **AND** every autolink is rendered as an anchor

#### Scenario: Link-destination boundaries stay exact

- **WHEN** an autolink follows a closed link destination, sits inside an open one, or follows an escaped or nested parenthesis
- **THEN** it is classified by the nearest-opener rule
- **AND** the no-opener, unterminated-destination, and multiple-destination cases are covered by tests

#### Scenario: A combining mark after a closing parenthesis

- **WHEN** a paragraph contains `[a](b)`, then U+0301, then `<https://example.com>` or `\(x\)`
- **THEN** the destination closes at the parenthesis
- **AND** the autolink renders as an anchor and the paren math as an inline math span

#### Scenario: Many paren-math spans on one line scale linearly

- **WHEN** a single line contains 1,000 `\(…\)` math spans and no `](` opener
- **AND** the same line contains 2,000
- **THEN** the 2,000 case takes less than 3× the 1,000 case
- **AND** every span is rendered as inline math

### Requirement: Scaling regressions are covered by default tests

The non-GUI test suite SHALL include automated scaling tests for URL autolinks, Markdown links, `mailto:` email autolinks, HTML entities, bare URLs, bare URLs with entities, reference links, reference links with protected keys, paren-math spans, mixed verbatim spans (code spans with both inline math forms), unpaired currency dollars, and unterminated `\(` openers. Each test SHALL render N and 2N fragments in one inline pass, assert that the 2N elapsed time is less than 3× the N elapsed time plus at most 2 ms of timer resolution, and assert that all N constructs appear correctly in the rendered output. The entity-bearing bare-URL and reference-key cases SHALL exercise `source(in:)` expansion. A one-fragment-per-line paragraph case SHALL cover the reported reference-list input shape for URL autolinks and bare URLs; on the current whole-paragraph inline pass this case is quadratic before the fix. These tests SHALL run under plain `swift test` without GUI opt-in.

#### Scenario: URL autolinks are covered

- **WHEN** the scaling suite renders 500 and 1,000 `<https://…>` autolinks on one line
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** the body contains 1,000 rendered anchors
- **AND** the destination classifier does not scan backward per autolink

#### Scenario: Markdown links are covered

- **WHEN** the scaling suite renders 500 and 1,000 `[link](https://…)` links on one line
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** the body contains 1,000 rendered anchors
- **AND** the link-candidate matching path is exercised

#### Scenario: Email autolinks are covered

- **WHEN** the scaling suite renders 500 and 1,000 `<mailto:…>` autolinks on one line
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** the body contains 1,000 `mailto:` anchors

#### Scenario: HTML entities are covered

- **WHEN** the scaling suite renders 500 and 1,000 `&nbsp;` entities on one line
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** every entity is restored as `&nbsp;`, not double-escaped

#### Scenario: Bare URLs are covered

- **WHEN** the scaling suite renders 500 and 1,000 bare `https://…` URLs on one line
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** the body contains 1,000 rendered anchors

#### Scenario: Bare URLs with entities are covered

- **WHEN** the scaling suite renders 500 and 1,000 bare URLs containing protected entity spellings
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** every recovered URL matches the authored spelling exactly
- **AND** the `source(in:)` expansion path is exercised

#### Scenario: Reference links are covered

- **WHEN** the scaling suite renders 500 and 1,000 `[label][key]` reference links with definitions
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** the body contains 1,000 rendered anchors

#### Scenario: Reference links with protected keys are covered

- **WHEN** the scaling suite renders 500 and 1,000 reference links whose keys contain protected entities
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** every key resolves to its definition
- **AND** the `source(in:)` and `restore(in:)` paths for reference links are exercised

#### Scenario: One-fragment-per-line paragraphs are covered

- **WHEN** the scaling suite renders 1,000 and 2,000 URLs written one per line in a single paragraph
- **THEN** the 2,000 case completes in less than 3× the 1,000 case
- **AND** the body contains the expected number of rendered links

#### Scenario: Paren-math spans are covered

- **WHEN** the scaling suite renders 500 and 1,000 `\(…\)` math spans on one line
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** the body contains 1,000 inline math spans
- **AND** the paren-math destination classifier is exercised

#### Scenario: Verbatim spans are covered

- **WHEN** the scaling suite renders 500 and 1,000 groups of one code span, one `$…$` span, and one `\(…\)` span on one line
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** the body contains 1,000 code spans and 2,000 inline math spans

#### Scenario: Unpaired currency dollars are covered

- **WHEN** the scaling suite renders 500 and 1,000 currency amounts such as `costs $5 today` on one line
- **THEN** the 1,000 case completes in less than 3× the 500 case
- **AND** no math span is produced and every `$` stays literal

#### Scenario: Unterminated paren-math openers are covered

- **WHEN** the scaling suite renders 500 and 1,000 `\(` openers with no closer on one line
- **THEN** the 1,000 case completes in less than 3× the 500 case, where rereading the line from every opener is about 4×
- **AND** no math span is produced and every opener stays visible

#### Scenario: The guards run in the default suite

- **WHEN** a contributor runs `swift test` without `MD2_RUN_GUI_TESTS`
- **THEN** all scaling tests execute and report pass or fail
