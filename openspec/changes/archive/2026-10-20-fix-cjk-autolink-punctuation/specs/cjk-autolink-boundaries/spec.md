## ADDED Requirements

### Requirement: Literal CJK and typographic punctuation terminates bare URLs

The bare-URL pass SHALL treat the following literal source characters as URL terminators. The set is normative:

- U+00B7 `·`
- U+2013–U+2014 `–—`
- U+2018–U+201D `‘’‚‛“”`
- U+2026 `…`
- U+3001–U+3003 `、。〃`
- U+3008–U+3011 `〈〉《》「」『』【】`
- U+3014–U+301F `〔〕〖〗〘〙〚〛〜〝〞〟`
- U+3030 `〰`, U+303D `〽`, U+30FB `・`
- U+FF01–U+FF0F `！＂＃＄％＆＇（）＊＋，－．／`
- U+FF1A–U+FF20 `：；＜＝＞？＠`
- U+FF3B–U+FF40 `［＼］＾＿｀`
- U+FF5B–U+FF65 `｛｜｝～｟｠｡｢｣､･`
- U+200B ZERO WIDTH SPACE

The full-width structural lookalikes `．` (U+FF0E), `／` (U+FF0F), `＃` (U+FF03), `＠` (U+FF20), `？` (U+FF1F), `－` (U+FF0D) and `＿` (U+FF3F) SHALL NOT terminate a bare URL; they remain valid left boundaries and stay in the URL body, so `https://evil.com．trusted.com` does not link a shorter host than the text appears to show. `－` and `＿` fold to the host-valid `-` and `_`, which is why they are in this set.

Full-width letters and digits (U+FF10–U+FF19, U+FF21–U+FF3A, U+FF41–U+FF5A) are content, not punctuation. They SHALL NOT terminate a bare URL and SHALL NOT be valid left boundaries; a bare URL that contains them SHALL include them in the anchor text and destination. The rule SHALL apply to literal source characters; authored HTML entity spellings SHALL keep the existing entity-recovery behavior defined by the preserved-behavior requirement. The existing trailing ASCII punctuation cleanup, unmatched-closing-parenthesis handling, trailing entity spellings, and domain validation SHALL remain unchanged.

#### Scenario: Full-width comma after a URL path

- **WHEN** the source contains `见 https://example.com/docs，然后继续。`
- **THEN** the rendered anchor destination is `https://example.com/docs`
- **AND** the anchor text is `https://example.com/docs`
- **AND** `，然后继续。` follows the anchor as text outside the link

#### Scenario: Full-width punctuation without a URL path

- **WHEN** the source contains `见 https://example.com，然后继续。`
- **THEN** `https://example.com` is rendered as an anchor rather than left literal
- **AND** `，然后继续。` follows the anchor as text outside the link

#### Scenario: Han text stays in a Wikipedia-style path

- **WHEN** the source contains `参考 https://zh.wikipedia.org/wiki/北京。`
- **THEN** the anchor destination and text include `/wiki/北京`
- **AND** the trailing `。` is outside the anchor

#### Scenario: Punctuation in the middle of a path

- **WHEN** the source contains `https://example.com/wiki/北京，更多`
- **THEN** the anchor ends at `北京`
- **AND** `，更多` follows the anchor as text outside the link

#### Scenario: Every normative range terminates a URL

- **WHEN** a bare URL is followed by a terminator character tested at both endpoints of each normative range (and the single-character ranges)
- **THEN** the anchor ends before that character
- **AND** the character and the following text appear outside the anchor

#### Scenario: Zero-width space terminates a URL

- **WHEN** the source contains `https://example.com\u{200B}tail`
- **THEN** the anchor destination is `https://example.com`
- **AND** the U+200B character and `tail` appear outside the anchor

#### Scenario: ASCII trailing cleanup is unchanged

- **WHEN** the source contains `www.example.com/a.b.`
- **THEN** the rendered destination is `http://www.example.com/a.b`
- **AND** the final `.` is outside the anchor

### Requirement: CJK text, full-width punctuation, and U+200B are valid left boundaries

A bare URL (`http://`, `https://`, or `www.`) SHALL be recognized when immediately preceded by a Han character (`\p{sc=Han}`), by any character in the normative terminator set above, or by U+200B, in addition to the existing boundaries: start of text, whitespace, `*`, `_`, `~`, and `(`. A URL immediately preceded by any other character SHALL NOT be linked, preserving the existing ASCII identifier behavior. The left-boundary rule SHALL use the full normative boundary set: the URL-body terminator set plus the structural lookalikes that stay URL content.

#### Scenario: Han character immediately before the scheme

- **WHEN** the source contains `访问https://example.com`
- **THEN** `https://example.com` is rendered as an anchor
- **AND** `访问` remains text outside the anchor

#### Scenario: Full-width colon before the scheme

- **WHEN** the source contains `链接：https://example.com`
- **THEN** `https://example.com` is rendered as an anchor
- **AND** `链接：` remains text outside the anchor

#### Scenario: Full-width parentheses around the URL

- **WHEN** the source contains `（https://example.com）`
- **THEN** `https://example.com` is rendered as an anchor
- **AND** both full-width parentheses remain outside the anchor

#### Scenario: U+200B immediately before the scheme

- **WHEN** the source contains `\u{200B}https://example.com`
- **THEN** `https://example.com` is rendered as an anchor
- **AND** the U+200B character remains outside the anchor

#### Scenario: Every normative range is a valid left boundary

- **WHEN** each terminator character tested at both endpoints of its normative range immediately precedes `https://example.com`
- **THEN** the URL is rendered as an anchor

#### Scenario: `www.` variants use the same boundaries

- **WHEN** the source contains `访问www.example.com` or `www.example.com。`
- **THEN** `www.example.com` is rendered as an anchor in both cases

#### Scenario: ASCII identifier boundary still blocks

- **WHEN** the source contains `abchttps://example.com` or `abcwww.example.com`
- **THEN** neither URL is rendered as an anchor

#### Scenario: Existing ASCII boundaries still work

- **WHEN** the source contains `**https://example.com**` and `(https://example.com)`
- **THEN** both URLs are rendered as anchors inside the strong element and the ASCII parentheses

### Requirement: Han after the authority is absorbed into the hostname, not a path

Han text following a URL path separator SHALL remain part of the URL path. Han text immediately following the authority (with no `/`, `?`, or `#` between) SHALL be absorbed into the hostname. Hostname absorption is a declared trade-off of this change: the rendered link SHALL point at the absorbed hostname as the domain validator computes it, and the documentation SHALL NOT describe it as path content. Preventing absorption is out of scope.

#### Scenario: Han text in a path is preserved

- **WHEN** the source contains `https://example.com/wiki/北京`
- **THEN** the anchor destination is `https://example.com/wiki/北京`
- **AND** the hostname is `example.com`

#### Scenario: Han text after the authority is absorbed

- **WHEN** the source contains `https://example.com然后继续`
- **THEN** the anchor destination is `https://example.com然后继续`
- **AND** the hostname is `example.com然后继续`, not `example.com`

#### Scenario: Han left boundary exposes hostname absorption

- **WHEN** the source contains `访问https://example.com然后继续`
- **THEN** the URL is rendered as an anchor
- **AND** the anchor destination is `https://example.com然后继续`

### Requirement: Existing bare-autolink behavior is preserved

The change SHALL NOT alter the protection of code spans, math spans, existing Markdown links/images, reference links, footnote/citation/cross-reference anchors, or raw HTML; SHALL NOT alter angle-bracket autolinks (`<https://…>`, `<mailto:…>`) or email autolinks; and SHALL NOT alter domain validation, authored-entity recovery, or the trailing ASCII cleanup. Authored HTML entity spellings SHALL keep the existing behavior even when they encode a terminator or a left-boundary character. All GFM extension corpus examples SHALL keep their current baseline relationship.

#### Scenario: Protected content still suppresses bare linking

- **WHEN** a URL appears in a code span, a math span, a Markdown link label or destination, or an image destination
- **THEN** no additional anchor is produced for it

#### Scenario: Email autolinks are unchanged

- **WHEN** the source contains `first.last+tag@example.com`
- **THEN** it is rendered as a `mailto:` anchor exactly as before
- **AND** an email address preceded by a Han character remains unlinked (declared boundary of this change)

#### Scenario: Entity-encoded terminator stays in the destination

- **WHEN** the source contains `https://example.com/a&#xff0c;然后`
- **THEN** the decoded `，` remains inside the anchor destination and anchor text
- **AND** the literal-character terminator rule does not apply to the entity spelling

#### Scenario: Entity-encoded left boundary stays literal

- **WHEN** the source contains `&#xff1a;https://example.com`
- **THEN** no anchor is produced for `https://example.com`
- **AND** the authored text remains visible

#### Scenario: Angle-bracket and HTML boundaries are unchanged

- **WHEN** the source contains `https://example.com<em>end</em>` or `<https://example.com>`
- **THEN** the bare URL ends at `<` and the angle-bracket autolink is handled by the existing pass

#### Scenario: Domain validation is unchanged

- **WHEN** the source contains `www.bad_domain.com`
- **THEN** it is not rendered as an anchor

### Requirement: The boundary rule is declared in the compatibility matrix and docs

The `gfm-autolinks` entry in the machine-checked compatibility matrix SHALL record in its declared behavior and boundary text that CJK/typographic punctuation (including full-width forms) and U+200B terminate a bare URL, that Han characters and the same set are valid left boundaries, that the rule is an intentional adjustment to GFM, and that the known trade-offs are URL truncation, hostname absorption, and the literal-only entity exception. The generated `Docs/CompatibilityMatrix.md` SHALL be regenerated from the matrix data rather than hand-edited, and `Docs/MarkdownSupport.md` SHALL describe the same behavior and trade-offs. The entry's support tier SHALL remain `Supported`. The divergence SHALL be declared in the entry text rather than by reclassifying corpus examples, because the vendored GFM examples are ASCII and do not exercise it.

#### Scenario: Matrix entry declares the intentional adjustment

- **WHEN** a developer reads the `gfm-autolinks` entry
- **THEN** its declared behavior or boundary text states that full-width/CJK punctuation and U+200B terminate bare URLs
- **AND** it states that Han characters and full-width punctuation are valid left boundaries
- **AND** it identifies the rule as an intentional adjustment to GFM
- **AND** it states the hostname-absorption and entity-exception trade-offs

#### Scenario: Generated matrix doc stays current

- **WHEN** `CrossArtifactConsistencyTests` regenerates the expected matrix document
- **THEN** it matches the committed `Docs/CompatibilityMatrix.md`

#### Scenario: User-facing support doc agrees and is guarded

- **WHEN** a reader opens `Docs/MarkdownSupport.md`
- **THEN** the autolinks entry mentions that full-width punctuation ends a bare URL, that U+200B is handled, and that Han text after the authority is absorbed into the hostname
- **AND** a consistency test fails if those phrases disappear

### Requirement: Lookalike continuations do not retarget a bare URL

A bare-URL candidate SHALL NOT be anchored when the visible continuation, after restoring protected tokens/entities/escapes (including image alt text), stripping inline HTML, treating emphasis/strikethrough/highlight/sup/sub delimiters as markup, skipping invisible characters (Unicode format/control/combining scalars, including ZWSP/ZWNJ/ZWJ, bidi marks and tag characters, plus blank-rendering fillers), and folding IDNA/fullwidth forms, would change the apparent authority. The guard SHALL apply when the authority (host with optional port) ends the URL (no path, query, or fragment), SHALL read the continuation from the visible text of any protected token rather than after it, and SHALL bound the continuation scan (failing closed when the bound is reached before a delimiter). A candidate SHALL stay literal when the continuation contains an ASCII `@` before the next `/`, `?`, `#`, or whitespace; when it begins with one or more IDNA dots followed by a host label that is ASCII or is followed by another dot; when it begins with a fullwidth percent followed by `2e`/`2E`; when it begins with a host-label character (letter, digit, `-` or `_`); or when it begins with a letter or digit and contains a dot. Ordinary prose continuations (`https://example.com。然后`, `https://example.com：然后`, `https://example.com％然后`) SHALL remain linked.

#### Scenario: Invisible terminator before a dot stays literal

- **WHEN** the source contains `https://evil.com\u{200B}.trusted.com`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: IDNA dot before a host label stays literal

- **WHEN** the source contains `https://evil.com。trusted.com` or `https://evil.com｡trusted.com`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: Userinfo lookalike stays literal

- **WHEN** the source contains `https://evil.com` followed by a full-width colon (or a port `:443`) and then an `@` sign and `trusted.com`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: Encoded dot stays literal

- **WHEN** the source contains `https://evil.com％2etrusted.com`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: Inline HTML token before a dot stays literal

- **WHEN** the source contains `https://evil.com<span>.trusted.com</span>`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: Entity-masked invisible continuation stays literal

- **WHEN** the source contains `https://evil.com。&#x200b;trusted.com`, `&#x2060;`, `&#x200d;`, `&zwj;`, `&commat;`, or `&#xff20;` between the terminator and `trusted.com`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: Protected token does not hide the continuation

- **WHEN** the source contains `https://evil.com`x`。trusted.com` or `https://evil.com[label](/x)。trusted.com`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: Emphasis and image markup do not hide the continuation

- **WHEN** the source contains `https://evil.com。*trusted.com*`, `https://evil.com。~~trusted.com~~`, or `https://evil.com。![trusted.com](x.png)`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: Scalar-attached invisible continuation stays literal

- **WHEN** the source contains `https://evil.com。\u{200C}trusted.com`, `https://evil.com。\u{FE0F}trusted.com`, or `https://evil.com。\u{061C}trusted.com`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: Split final label stays literal

- **WHEN** the source contains `https://evil.co\u{200B}m` or `https://evil.co<span></span>m`
- **THEN** no anchor is produced for `https://evil.co`

#### Scenario: Long hostile line stays bounded

- **WHEN** a line repeats `www.a。` thousands of times
- **THEN** rendering completes in linear time (pinned by a timing regression test)

#### Scenario: Ordinary prose continuation still links

- **WHEN** the source contains `https://example.com。然后`
- **THEN** `https://example.com` is rendered as an anchor

### Requirement: Regression coverage runs in the default suite

The non-GUI test suite SHALL cover the reported CJK cases, one terminator and one left-boundary character from each normative range (both endpoints where a range has typo risk, plus the single-character ranges), `www.` variants, hostname-vs-path absorption, the entity exceptions, and U+200B. These tests SHALL run under plain `swift test` without GUI opt-in.

#### Scenario: CJK cases are covered by default tests

- **WHEN** a contributor runs `swift test`
- **THEN** the CJK autolink cases execute and assert both the emitted anchor destination and the text left outside the anchor
