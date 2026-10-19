# Inline Render Performance — Delta

## ADDED Requirements

### Requirement: Placeholder restoration and source lookup are linear in text size

The inline renderer SHALL resolve protected fragments by scanning the text once, looking each fragment up by the numeric index embedded in its placeholder token, instead of performing one whole-text search per fragment. The same resolver SHALL serve both `restore(in:)` (rendered HTML) and `source(in:)` (the authored spelling). A nested entry SHALL be expanded at most once per protect/resolve cycle. Resolution time SHALL be linear in the size of the text plus the size of the resolved entries and SHALL NOT grow with the product of fragment count and text length. The same guarantee SHALL apply to restores and source lookups performed mid-pipeline for URL safety checks, reference-link matching, bare-URL matching, and raw-HTML sanitization. The `isLiteral` set SHALL remain a bare-URL matching input and SHALL NOT suppress restoration.

#### Scenario: Doubling fragments does not quadruple render time

- **WHEN** a paragraph renders 1,000 protected URL fragments in a single inline pass
- **AND** the same paragraph is rendered with 2,000 fragments
- **THEN** the 2,000-fragment render takes less than 3× the 1,000-fragment render time, rather than approximately 4×

#### Scenario: Nested fragments restore before the URL safety check

- **WHEN** a link destination contains an entity-obfuscated unsafe scheme such as `javascript&#58;void%200`
- **THEN** the restore performed before `HTMLSafety.isSafeURL` resolves the nested entity token
- **AND** the link is rendered as inert text rather than an active anchor

#### Scenario: Authored spelling is recovered for bare URLs and reference links

- **WHEN** a bare URL contains an entity spelling, or a reference-link key contains an entity
- **THEN** `source(in:)` returns the authored spelling for matching and safety checks
- **AND** a token marked `isLiteral` still terminates bare-URL matching exactly as before

#### Scenario: Author text that resembles a token stays literal

- **WHEN** the document text contains a lone private-use sentinel, a malformed token, a token with leading zeros, or a token whose index is out of range
- **THEN** that text is emitted literally
- **AND** the surrounding content still renders normally

#### Scenario: Constructed and shared-sentinel tokens follow the declared boundary

- **WHEN** an escaped hyphen restores into a sequence that forms a valid token, or two token spellings share a sentinel
- **THEN** the constructed token is emitted literally, and the shared-sentinel overlap resolves by the leftmost well-formed token
- **AND** the previous expansion/highest-index behavior is not silently reintroduced

### Requirement: Autolink destination classification is linear in text size

`protectAutolinks` SHALL determine whether an angle autolink sits inside a link destination from a precomputed destination index, not by scanning backward from every autolink. The precomputation SHALL run in O(text) and SHALL preserve the current nearest-opener rule: no opener means outside; a destination that closes before the autolink means outside; escaped characters, nested parentheses, and unterminated destinations follow the existing rules. Each lookup SHALL be O(1) or O(log M) for M openers.

#### Scenario: Many angle autolinks on one line scale linearly

- **WHEN** a single line contains 1,000 `<https://…>` autolinks and no `](` opener
- **AND** the same line contains 2,000
- **THEN** the 2,000 case takes less than 3× the 1,000 case
- **AND** every autolink is rendered as an anchor

#### Scenario: Link-destination boundaries stay exact

- **WHEN** an autolink follows a closed link destination, sits inside an open one, or follows an escaped or nested parenthesis
- **THEN** it is classified exactly as before the optimization
- **AND** the no-opener, unterminated-destination, and multiple-destination cases are covered by tests

### Requirement: Inline match substitution is linear in text size

The inline renderer's match-substitution routine SHALL build its result by appending unchanged source slices and transformed matches in source order, without repeatedly replacing a growing result string. Substitution time SHALL be linear in the source length plus the total size of the replacements. Match order and non-overlap semantics SHALL be preserved, and a transform SHALL receive the original source and SHALL NOT depend on replacements produced for other matches. Stateful transforms, such as figure numbering, SHALL be evaluated in the same order as the previous implementation; the output SHALL be assembled forward.

#### Scenario: Many matches on one line scale linearly

- **WHEN** a single line contains 1,000 matches for one inline pass (for example autolinks, links, bare URLs, or entity references)
- **AND** the same line is rendered with 2,000 matches
- **THEN** the 2,000-match render takes less than 3× the 1,000-match render time
- **AND** every match is transformed and the text between matches is preserved

#### Scenario: Zero matches return the input unchanged

- **WHEN** an inline pass runs over text that contains no match
- **THEN** the pass returns the original text without altering it

#### Scenario: Figure numbering is unchanged

- **WHEN** a paragraph contains two labeled images
- **THEN** the figures receive the same numbers as before the substitution rewrite
- **AND** the numbering is derived from the same transform evaluation order

### Requirement: The optimized paths preserve rendered output and safety

The linear restoration, source lookup, autolink classification, and substitution paths SHALL produce HTML byte-identical to the previous implementation for documents that do not contain private-use sentinel characters. The placeholder token grammar, fragment nesting order, literal private-use text handling, `isLiteral` behavior, authored-spelling recovery, figure numbering, and URL-safety behavior SHALL NOT change. The D4 boundary for tokens constructed after restoration and for shared sentinels is declared and tested.

#### Scenario: Mixed inline content renders identically

- **WHEN** a document mixes code spans, math, HTML entities, autolinks, Markdown links, reference links, bare URLs, images, emphasis, and allowlisted raw HTML
- **THEN** the rendered body is byte-identical to the previous implementation
- **AND** no placeholder token or `MD2-` marker remains in the output

#### Scenario: Unsafe URL behavior is unchanged

- **WHEN** a document contains `javascript:`, `vbscript:`, `data:`, or entity-obfuscated variants in a link, reference link, or image destination
- **THEN** the destination is rendered inert exactly as before the optimization

### Requirement: Scaling regressions are covered by default tests

The non-GUI test suite SHALL include automated scaling tests for URL autolinks, Markdown links, `mailto:` email autolinks, HTML entities, bare URLs, bare URLs with entities, reference links, and reference links with protected keys. Each test SHALL render N and 2N fragments in one inline pass, assert that the 2N elapsed time is less than 3× the N elapsed time, and assert that all N constructs appear correctly in the rendered output. The entity-bearing bare-URL and reference-key cases SHALL exercise `source(in:)` expansion. A one-fragment-per-line paragraph case SHALL cover the reported reference-list input shape for URL autolinks and bare URLs; on the current whole-paragraph inline pass this case is quadratic before the fix. These tests SHALL run under plain `swift test` without GUI opt-in.

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

#### Scenario: The guards run in the default suite

- **WHEN** a contributor runs `swift test` without `MD2_RUN_GUI_TESTS`
- **THEN** all scaling tests execute and report pass or fail
