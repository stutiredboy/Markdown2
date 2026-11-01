## MODIFIED Requirements

### Requirement: Placeholder restoration and source lookup are linear in text size

The inline renderer SHALL resolve protected fragments by scanning the text once, looking each fragment up by the numeric index embedded in its placeholder token, instead of performing one whole-text search per fragment. The same resolver SHALL serve both `restore(in:)` (rendered HTML) and `source(in:)` (the authored spelling). A nested entry SHALL be expanded at most once per protect/resolve cycle. Only entries reachable from the resolved text SHALL be expanded; an entry that no resolved text references SHALL NOT be materialized. The token grammar SHALL be scanned as Unicode scalars, so combining marks adjacent to a token do not change it. The token grammar SHALL be defined once and read by one scan: the resolver, the bare-URL cut, and the bare-URL continuation guard SHALL all locate tokens with it. Each token SHALL carry a nonce that is random per protector and never reaches the output, and the grammar SHALL accept only its own protector's nonce. A typed token spelling (well-formed or not, in range or not, or formed by restoring an escape) is therefore never a token for any of these readers and stays literal text, including inside a fragment rebuilt from authored source. The scan SHALL consume a token whole and read any other sentinel as one literal scalar. Literal text between tokens SHALL be copied in bulk runs, not one scalar at a time. Each run SHALL keep exact Unicode-scalar bounds even when a grapheme cluster spans the token boundary, and the copy SHALL NOT mark all-ASCII restored output as non-ASCII, which would move every later range conversion over that output off the string library's ASCII fast path. Resolution time SHALL be linear in the size of the text plus the size of the resolved entries and SHALL NOT grow with the product of fragment count and text length. The same guarantee SHALL apply to restores and source lookups performed mid-pipeline for URL safety checks, reference-link matching, bare-URL matching, and raw-HTML sanitization. The `isLiteral` set SHALL remain a bare-URL matching input and SHALL NOT suppress restoration.

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

#### Scenario: Typed token spellings stay literal

- **WHEN** the document text contains a lone private-use sentinel, or a typed token spelling: canonical and in range, malformed, with leading zeros, out of range, two spellings sharing a sentinel, or one that an escaped hyphen restores into canonical form
- **THEN** that text is emitted literally and names no fragment
- **AND** the surrounding content still renders normally

#### Scenario: Typed spellings cannot amplify the output

- **WHEN** a document contains one large protected fragment and many typed spellings of a token that would name it
- **THEN** the output grows with the input, not with the number of spellings times the fragment's size

#### Scenario: Typed spellings cannot repeat a link

- **WHEN** a typed token spelling would name the anchor a bare URL protects later in the same pass, such as `https://a.comm`, U+00A0, then a typed spelling, then `x.trusted.com`
- **THEN** only the one anchor renders, and the typed spelling stays text

#### Scenario: A typed spelling never cuts a bare URL

- **WHEN** a bare URL contains a typed token spelling, canonical or malformed
- **THEN** the bare-URL cut does not end the URL there, and the spelling is URL text like any other
- **AND** in a URL's host, the existing host check still rejects it and leaves the URL literal

#### Scenario: A typed spelling does not hide the next token

- **WHEN** a typed token spelling inside a bare URL ends right where a structural token begins
- **THEN** the structural token still ends the URL
- **AND** the structural token renders after the link, rather than its authored source joining the link

#### Scenario: The continuation guard reads a malformed spelling as text

- **WHEN** the text after a bare URL contains a malformed token spelling
- **THEN** the continuation guard reads it as the visible characters it is
- **AND** a sentinel fused into a grapheme with a neighbouring mark fails the guard closed, leaving the URL literal

### Requirement: The optimized paths preserve rendered output and safety

The linear restoration, source lookup, inline destination classification, and substitution paths SHALL produce HTML byte-identical to the previous implementation for documents that do not contain private-use sentinel characters and do not contain multiple labeled figures in one paragraph. The fragment nesting order, `isLiteral` behavior, authored-spelling recovery, and URL-safety behavior SHALL NOT change. Typed token spellings are literal text, as the restoration requirement declares; this replaces the earlier D4 boundary, under which a typed well-formed token resolved to the fragment it named. The corrected document-order figure numbering is declared and tested.

#### Scenario: Mixed inline content renders identically

- **WHEN** a document mixes code spans, math, HTML entities, autolinks, Markdown links, reference links, bare URLs, images, emphasis, and allowlisted raw HTML
- **THEN** the rendered body is byte-identical to the previous implementation
- **AND** no placeholder token or private-use sentinel remains in the output

#### Scenario: Unsafe URL behavior is unchanged

- **WHEN** a document contains `javascript:`, `vbscript:`, `data:`, or entity-obfuscated variants in a link, reference link, or image destination
- **THEN** the destination is rendered inert exactly as before the optimization

#### Scenario: Authored tokens cannot splice markup into a destination

- **WHEN** a link or image destination, including a reference definition, contains a typed placeholder spelling
- **THEN** the spelling stays literal text and no renderer fragment is emitted inside the href/src attribute
- **AND** a restored destination is still rejected if it contains raw `<`, `>`, or `"`
- **AND** angle-bracket destinations may still contain spaces
- **AND** entity-encoded `&quot;`, `&lt;`, and `&gt;` remain allowed

