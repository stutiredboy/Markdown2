# Inline Render Performance

## Purpose

Define the performance contract for inline Markdown rendering: protected fragments and authored spellings resolve in linear time, inline link and image destination classification is linear, and match substitution is linear, while rendered output, URL safety, and figure numbering stay unchanged. Guard each property with non-GUI scaling tests.
## Requirements
### Requirement: Placeholder restoration and source lookup are linear in text size

The inline renderer SHALL resolve protected fragments by scanning the text once, looking each fragment up by the numeric index embedded in its placeholder token, instead of performing one whole-text search per fragment. The same resolver SHALL serve both `restore(in:)` (rendered HTML) and `source(in:)` (the authored spelling). A nested entry SHALL be expanded at most once per protect/resolve cycle. Only entries reachable from the resolved text SHALL be expanded; an entry that no resolved text references SHALL NOT be materialized. The token grammar SHALL be scanned as Unicode scalars, so combining marks adjacent to a token do not change it. The token grammar SHALL be defined once and read by one scan: the resolver, the bare-URL cut, and the bare-URL continuation guard SHALL all locate tokens with it, so text the resolver emits literally (a spelling with leading zeros, non-ASCII digits, or an overflowing index) is never a token for any of them. The scan SHALL consume a token whole and read any other sentinel as one literal scalar. Literal text between tokens SHALL be copied in bulk runs, not one scalar at a time. Each run SHALL keep exact Unicode-scalar bounds even when a grapheme cluster spans the token boundary, and the copy SHALL NOT mark all-ASCII restored output as non-ASCII, which would move every later range conversion over that output off the string library's ASCII fast path. Resolution time SHALL be linear in the size of the text plus the size of the resolved entries and SHALL NOT grow with the product of fragment count and text length. The same guarantee SHALL apply to restores and source lookups performed mid-pipeline for URL safety checks, reference-link matching, bare-URL matching, and raw-HTML sanitization. The `isLiteral` set SHALL remain a bare-URL matching input and SHALL NOT suppress restoration.

#### Scenario: Doubling fragments does not quadruple render time

- **WHEN** a paragraph renders 1,000 protected URL fragments in a single inline pass
- **AND** the same paragraph is rendered with 2,000 fragments
- **THEN** the 2,000-fragment render takes less than 3× the 1,000-fragment render time, rather than approximately 4×

#### Scenario: Nested fragments restore before the URL safety check

- **WHEN** a link destination contains an entity-obfuscated unsafe scheme such as `javascript&#58;void%200`
- **THEN** the restore performed before `HTMLSafety.isSafeURL` resolves the nested entity token
- **AND** the link is rendered as inert text rather than an active anchor

#### Scenario: Discarded fragments are not expanded

- **WHEN** a crafted token DAG sits in an attribute the renderer discards
- **THEN** only the entries the final text references are expanded
- **AND** the render completes without materializing the discarded entries

#### Scenario: Marks that join a token's grapheme cluster

- **WHEN** a combining mark follows a closing placeholder sentinel
- **OR** a prepended concatenation mark such as U+0600 precedes an opening placeholder sentinel
- **THEN** the token still resolves and the mark is preserved exactly

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

#### Scenario: A spelling the resolver emits literally never cuts a bare URL

- **WHEN** a bare URL contains a token spelling with leading zeros, non-ASCII digits, or an overflowing index
- **THEN** the bare-URL cut does not end the URL there, and the spelling is URL text like any other
- **AND** in a URL's host, the existing host check still rejects it and leaves the URL literal

#### Scenario: A malformed spelling does not hide the next token

- **WHEN** a malformed token spelling shares its closing sentinel with a following well-formed structural token inside a bare URL
- **THEN** the structural token still ends the URL
- **AND** the structural token renders after the link, rather than its authored source joining the link

#### Scenario: The continuation guard reads a malformed spelling as text

- **WHEN** the text after a bare URL contains a malformed token spelling
- **THEN** the continuation guard reads it as the visible characters it is
- **AND** a sentinel fused into a grapheme with a neighbouring mark fails the guard closed, leaving the URL literal

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

### Requirement: Inline match substitution is linear in text size

The inline renderer's match-substitution routine SHALL build its result by appending unchanged source slices and transformed matches in source order, without repeatedly replacing a growing result string. Substitution time SHALL be linear in the source length plus the total size of the replacements. Match order and non-overlap semantics SHALL be preserved, and a transform SHALL receive the original source and SHALL NOT depend on replacements produced for other matches. Stateful transforms SHALL keep a deterministic call order; figure numbering SHALL be pre-assigned in document order before the transforms, and the output SHALL be assembled forward.

#### Scenario: Many matches on one line scale linearly

- **WHEN** a single line contains 1,000 matches for one inline pass (for example autolinks, links, bare URLs, or entity references)
- **AND** the same line is rendered with 2,000 matches
- **THEN** the 2,000-match render takes less than 3× the 1,000-match render time
- **AND** every match is transformed and the text between matches is preserved

#### Scenario: Zero matches return the input unchanged

- **WHEN** an inline pass runs over text that contains no match
- **THEN** the pass returns the original text without altering it

#### Scenario: Figure numbering follows document order

- **WHEN** a paragraph contains two labeled images and a forward `\ref` to the first
- **THEN** the first image renders as Figure 1 and the second as Figure 2
- **AND** the forward `\ref` resolves to 1, matching the caption

### Requirement: The optimized paths preserve rendered output and safety

The linear restoration, source lookup, inline destination classification, and substitution paths SHALL produce HTML byte-identical to the previous implementation for documents that do not contain private-use sentinel characters and do not contain multiple labeled figures in one paragraph. The placeholder token grammar, fragment nesting order, literal private-use text handling, `isLiteral` behavior, authored-spelling recovery, and URL-safety behavior SHALL NOT change. The D4 boundary for tokens constructed after restoration and for shared sentinels, and the corrected document-order figure numbering, are declared and tested.

#### Scenario: Mixed inline content renders identically

- **WHEN** a document mixes code spans, math, HTML entities, autolinks, Markdown links, reference links, bare URLs, images, emphasis, and allowlisted raw HTML
- **THEN** the rendered body is byte-identical to the previous implementation
- **AND** no placeholder token or `MD2-` marker remains in the output

#### Scenario: Unsafe URL behavior is unchanged

- **WHEN** a document contains `javascript:`, `vbscript:`, `data:`, or entity-obfuscated variants in a link, reference link, or image destination
- **THEN** the destination is rendered inert exactly as before the optimization

#### Scenario: Authored tokens cannot splice markup into a destination

- **WHEN** a link or image destination, including a reference definition, contains a well-formed authored placeholder token
- **THEN** the restored destination is rejected if it contains raw `<`, `>`, or `"`
- **AND** no renderer fragment is emitted inside the href/src attribute
- **AND** angle-bracket destinations may still contain spaces
- **AND** entity-encoded `&quot;`, `&lt;`, and `&gt;` remain allowed

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

