## MODIFIED Requirements

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
