## MODIFIED Requirements

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
- U+FE10–U+FE19 `︐︑︒︓︔︕︖︗︘︙` (vertical forms)
- U+FE30–U+FE4F `︰︱︲︳︴︵︶︷︸︹︺︻︼︽︾︿﹀﹁﹂﹃﹄﹅﹆﹇﹈﹉﹊﹋﹌﹍﹎﹏` (CJK compatibility forms)
- U+FE50–U+FE52, U+FE54–U+FE66, U+FE68–U+FE6B `﹐﹑﹒﹔﹕﹖﹗﹘﹙﹚﹛﹜﹝﹞﹟﹠﹡﹢﹣﹤﹥﹦﹨﹩﹪﹫` (small form variants; U+FE53 and U+FE67 are unassigned and excluded)
- U+200B ZERO WIDTH SPACE
- U+00AD SOFT HYPHEN, U+2060 WORD JOINER, U+FEFF ZERO WIDTH NO-BREAK SPACE
- U+061C ARABIC LETTER MARK, U+200E–U+200F LEFT-TO-RIGHT MARK and RIGHT-TO-LEFT MARK, U+2066–U+2069 LEFT-TO-RIGHT ISOLATE through POP DIRECTIONAL ISOLATE

The invisible format characters in the set render nothing (or only a hyphenation or direction hint) and never belong in a URL. U+200C ZERO WIDTH NON-JOINER and U+200D ZERO WIDTH JOINER (IDNA context joiners, emoji sequences), variation selectors, and the bidi embedding and override controls U+202A–U+202E SHALL NOT be in the set: a URL that contains one keeps it as URL content, and none of them is a valid left boundary.

The structural lookalikes are the boundary characters whose compatibility form (NFKC) is `.`, `/`, `#`, `@`, `?`, `-` or `_`: the full-width `．` (U+FF0E), `／` (U+FF0F), `＃` (U+FF03), `＠` (U+FF20), `？` (U+FF1F), `－` (U+FF0D) and `＿` (U+FF3F); the vertical `︖` (U+FE16), `︳` (U+FE33) and `︴` (U+FE34); the low lines `﹍` (U+FE4D), `﹎` (U+FE4E) and `﹏` (U+FE4F); and the small `﹒` (U+FE52), `﹖` (U+FE56), `﹟` (U+FE5F), `﹣` (U+FE63) and `﹫` (U+FE6B). They SHALL NOT terminate a bare URL; they remain valid left boundaries and stay in the URL body, so `https://evil.com．trusted.com` and `https://evil.com﹒trusted.com` do not link a shorter host than the text appears to show. The forms of `-` and `_` are host-valid, which is why they are in this set.

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

#### Scenario: Every normative character terminates a URL

- **WHEN** a bare URL with a path is followed by any terminator character in the normative set
- **THEN** the anchor ends before that character
- **AND** the character and the following text appear outside the anchor

#### Scenario: Zero-width space terminates a URL path

- **WHEN** the source contains `https://example.com/a\u{200B}tail`
- **THEN** the anchor destination is `https://example.com/a`
- **AND** the U+200B character and `tail` appear outside the anchor

#### Scenario: Small comma after a URL

- **WHEN** the source contains `https://example.com﹐tail`
- **THEN** `https://example.com` is rendered as an anchor rather than left literal
- **AND** `﹐tail` follows the anchor as text outside the link

#### Scenario: Vertical full stop after a URL

- **WHEN** the source contains `见 https://example.com/docs﹐然后继续︒` or `https://example.com︒然后`
- **THEN** the anchor ends before `﹐` or `︒`
- **AND** the compatibility form and the following text appear outside the anchor

#### Scenario: Invisible format character ends a URL path

- **WHEN** the source contains `见\u{FEFF}https://example.com/path\u{FEFF}。`
- **THEN** the anchor destination is `https://example.com/path`, with no invisible character in it
- **AND** the U+FEFF character and `。` appear outside the anchor

#### Scenario: Excluded format characters stay URL content

- **WHEN** the source contains `https://example.com/a\u{200D}tail` or `https://example.com/a\u{202E}tail`
- **THEN** the anchor destination includes the joiner or override control and `tail`
- **AND** neither character is a valid left boundary before `https://example.com`

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

#### Scenario: Every normative character is a valid left boundary

- **WHEN** any character in the normative boundary set, terminator or structural lookalike, immediately precedes `https://example.com`
- **THEN** the URL is rendered as an anchor

#### Scenario: Bidi-wrapped and BOM-prefixed URLs

- **WHEN** the source contains `\u{2067}https://example.com\u{2069}`, `زر \u{200F}https://example.com\u{200F} الآن`, or `见\u{FEFF}https://example.com`
- **THEN** `https://example.com` is rendered as an anchor
- **AND** the isolate, mark, or U+FEFF characters remain outside the anchor

#### Scenario: Vertical colon before the scheme

- **WHEN** the source contains `链接︓https://example.com﹔`
- **THEN** `https://example.com` is rendered as an anchor
- **AND** `链接︓` and `﹔` remain outside the anchor

#### Scenario: `www.` variants use the same boundaries

- **WHEN** the source contains `访问www.example.com` or `www.example.com。`
- **THEN** `www.example.com` is rendered as an anchor in both cases

#### Scenario: ASCII identifier boundary still blocks

- **WHEN** the source contains `abchttps://example.com` or `abcwww.example.com`
- **THEN** neither URL is rendered as an anchor

#### Scenario: Existing ASCII boundaries still work

- **WHEN** the source contains `**https://example.com**` and `(https://example.com)`
- **THEN** both URLs are rendered as anchors inside the strong element and the ASCII parentheses

### Requirement: The boundary rule is declared in the compatibility matrix and docs

The `gfm-autolinks` entry in the machine-checked compatibility matrix SHALL record in its declared behavior and boundary text that CJK/typographic punctuation (including full-width forms and the vertical and small forms U+FE10–U+FE19, U+FE30–U+FE4F and U+FE50–U+FE6B), U+200B, and the enumerated invisible format characters (U+00AD, U+2060, U+FEFF, and the bidi marks and isolates U+061C, U+200E–U+200F and U+2066–U+2069) terminate a bare URL, that Han characters and the same set are valid left boundaries, that the rule is an intentional adjustment to GFM, which format characters stay outside the set (U+200C/U+200D and the bidi embedding and override controls U+202A–U+202E), and that the known trade-offs are URL truncation, hostname absorption, and the literal-only entity exception. The generated `Docs/CompatibilityMatrix.md` SHALL be regenerated from the matrix data rather than hand-edited, and `Docs/MarkdownSupport.md` SHALL describe the same behavior and trade-offs. The entry's support tier SHALL remain `Supported`. The divergence SHALL be declared in the entry text rather than by reclassifying corpus examples, because the vendored GFM examples are ASCII and do not exercise it.

#### Scenario: Matrix entry declares the intentional adjustment

- **WHEN** a developer reads the `gfm-autolinks` entry
- **THEN** its declared behavior or boundary text states that full-width/CJK punctuation and U+200B terminate bare URLs
- **AND** it names the vertical and small form ranges and the enumerated invisible format characters as part of the set, not as outside it
- **AND** it names U+202A–U+202E as outside the set
- **AND** it states that Han characters and full-width punctuation are valid left boundaries
- **AND** it identifies the rule as an intentional adjustment to GFM
- **AND** it states the hostname-absorption and entity-exception trade-offs

#### Scenario: Generated matrix doc stays current

- **WHEN** `CrossArtifactConsistencyTests` regenerates the expected matrix document
- **THEN** it matches the committed `Docs/CompatibilityMatrix.md`

#### Scenario: User-facing support doc agrees and is guarded

- **WHEN** a reader opens `Docs/MarkdownSupport.md`
- **THEN** the autolinks entry mentions that full-width punctuation ends a bare URL, that U+200B is handled, and that Han text after the authority is absorbed into the hostname
- **AND** it names the vertical and small form ranges, U+FEFF, and the excluded U+202A–U+202E controls
- **AND** a consistency test fails if those phrases disappear

### Requirement: Lookalike continuations do not retarget a bare URL

A bare-URL candidate SHALL NOT be anchored when the visible continuation, after restoring protected tokens/entities/escapes (including image alt text), skipping footnote reference markers (a generated note number, never authority text, so what follows the marker is checked as if adjacent), stripping inline HTML, treating emphasis/strikethrough/highlight/sup/sub delimiters as markup, skipping invisible characters (Unicode format/control/combining and default-ignorable scalars, including ZWSP/ZWNJ/ZWJ, bidi marks and tag characters, plus blank-rendering fillers), and folding IDNA/fullwidth forms and the vertical and small forms in the boundary set to their single-scalar compatibility form (`︒` reads as an IDNA dot, `﹒` as `.`, `﹫` as `@`, `﹪` as `%`, `﹣` as `-`), would change the apparent authority. A protected math span in the continuation SHALL leave the candidate literal, and a block-level or void HTML boundary SHALL end the continuation. The guard SHALL apply when the authority (host with optional port) ends the URL (no path, query, or fragment), SHALL read the continuation from the visible text of any protected token rather than after it, and SHALL bound the continuation scan (failing closed when the bound is reached before a delimiter). A candidate SHALL stay literal when the continuation contains an ASCII `@` before the next `/`, `?`, `#`, or whitespace; when it begins with one or more IDNA dots followed by a host label that is ASCII or is followed by another dot; when it begins with a fullwidth percent followed by `2e`/`2E`; when it begins with a host-label character (letter, digit, `-` or `_`); or when it begins with a letter or digit and contains a dot. Ordinary prose continuations (`https://example.com。然后`, `https://example.com：然后`, `https://example.com％然后`) SHALL remain linked.

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

#### Scenario: Footnote marker after a URL keeps the link

- **WHEN** the source contains `https://example.com[^1].` and the footnote is defined
- **THEN** `https://example.com` is rendered as an anchor followed by the footnote marker
- **AND** `https://evil.com[^1].trusted.com` and `https://evil.co[^1]m` produce no anchor for the shorter host
- **AND** an authored superscript (`https://evil.co<sup>m</sup>`) is still read as visible text

#### Scenario: Vertical and small forms fold in the continuation

- **WHEN** the source contains `https://evil.com︒trusted.com`, `https://evil.com︒ｔｒｕｓｔｅｄ`, `https://evil.com，﹫trusted`, `https://evil.com﹪2e中国`, or `https://evil.co\u{200B}﹣m`
- **THEN** no anchor is produced for the shorter host

#### Scenario: Added invisible boundaries keep the label-extension rule

- **WHEN** the source contains `https://example.com\u{FEFF}tail`, `https://evil.co\u{2060}m`, `https://evil.co\u{00AD}m`, or `https://evil.co\u{200E}m`
- **THEN** no anchor is produced for the shorter host, because the visible text reads as one longer host label

#### Scenario: Long hostile line stays bounded

- **WHEN** a line repeats `www.a。` thousands of times
- **THEN** rendering completes in linear time (pinned by a timing regression test)

#### Scenario: Ordinary prose continuation still links

- **WHEN** the source contains `https://example.com。然后`
- **THEN** `https://example.com` is rendered as an anchor

### Requirement: Regression coverage runs in the default suite

The non-GUI test suite SHALL cover the reported CJK cases, every character in the normative set as a left boundary and every terminator as a URL terminator, the structural-lookalike rule (the lookalikes are exactly the boundary characters whose compatibility form is URL-structural), the code points adjacent to each range together with the unassigned gaps and the excluded format characters, `www.` variants, hostname-vs-path absorption, the entity exceptions, U+200B, and the vertical/small-form folds in both continuation guards. These tests SHALL run under plain `swift test` without GUI opt-in.

#### Scenario: CJK cases are covered by default tests

- **WHEN** a contributor runs `swift test`
- **THEN** the CJK autolink cases execute and assert both the emitted anchor destination and the text left outside the anchor

### Requirement: Lookalike continuations do not retarget an email autolink

An email autolink candidate SHALL NOT be anchored when its visible continuation reads as more of its domain. The visible continuation SHALL be computed by the same walk as the bare-URL guard (restoring protected tokens/entities/escapes including image alt text, skipping footnote reference markers, stripping inline HTML, treating emphasis/strikethrough/highlight/sup/sub delimiters as markup, skipping invisible characters, and folding IDNA/fullwidth forms and the vertical and small forms in the boundary set), and the walk SHALL end at the first visible character that is neither a host-label character (letter, digit, `-` or `_`) nor a dot, so the check reads only the host-shaped prefix. A candidate SHALL stay literal when the continuation begins with an `@`; when a label of the host-shaped prefix begins with a host-label character outside the Han, Hiragana, Katakana and Hangul scripts (the first label extends the final domain label; each later label follows a dot); or when the walk fails closed (scan budget, protected math, provisional cross-reference) before the prefix ends. A label that begins with a Han, Hiragana, Katakana or Hangul character SHALL NOT block the link, so CJK prose written flush against an address stays linked. The email match pattern and its left boundary SHALL remain unchanged, and the `gfm-autolinks` matrix entry and `Docs/MarkdownSupport.md` SHALL declare the guard.

#### Scenario: IDNA dot before an ASCII label stays literal

- **WHEN** the source contains `foo@evil.com。trusted.com`, `foo@evil.com｡trusted.com`, or `foo@evil.com．trusted.com`
- **THEN** no `mailto:` anchor is produced
- **AND** the address remains visible as literal text

#### Scenario: Split or fullwidth final label stays literal

- **WHEN** the source contains `foo@evil.co\u{200B}m`, `foo@evil.co<span></span>m`, or `foo@evil.coｍ`
- **THEN** no `mailto:` anchor is produced for `foo@evil.co`

#### Scenario: Masked dot stays literal

- **WHEN** the source contains `foo@evil.com\u{200B}.trusted.com`, `foo@evil.com&#46;trusted.com`, `foo@evil.com\.trusted.com`, or `foo@evil.com<span>.trusted.com</span>`
- **THEN** no `mailto:` anchor is produced

#### Scenario: A later ASCII label stays literal

- **WHEN** the source contains `foo@evil.com然后.trusted.com`
- **THEN** no `mailto:` anchor is produced

#### Scenario: An at sign straight after the address stays literal

- **WHEN** the source contains `foo@evil.com@trusted.com`, `foo@evil.com＠trusted.com`, or `foo@evil.com﹫trusted.com`
- **THEN** no `mailto:` anchor is produced

#### Scenario: Vertical and small full stops fold to a dot

- **WHEN** the source contains `foo@evil.com︒trusted.com` or `foo@evil.com﹒trusted.com`
- **THEN** no `mailto:` anchor is produced

#### Scenario: CJK prose after an address still links

- **WHEN** the source contains `联系 foo@example.com。然后继续。`, `邮箱：foo@example.com获取`, `foo@example.comまでご連絡ください`, or `foo@example.com으로 보내주세요`
- **THEN** `foo@example.com` is rendered as a `mailto:` anchor
- **AND** the prose follows the anchor as text

#### Scenario: Address lists still link

- **WHEN** the source contains `foo@example.com、bar@example.com`, `foo@example.com，bar@example.com`, or `foo@example.com﹑bar@example.com`
- **THEN** both addresses are rendered as `mailto:` anchors

#### Scenario: An ASCII word after the address's full stop stays literal

- **WHEN** the source contains `foo@example.com。GitHub 上也可以`
- **THEN** no `mailto:` anchor is produced (declared trade-off shared with the bare-URL guard)

#### Scenario: Footnote marker after an address keeps the link

- **WHEN** the source contains `foo@example.com[^1]，然后` and the footnote is defined
- **THEN** `foo@example.com` is rendered as a `mailto:` anchor followed by the footnote marker
- **AND** `foo@evil.com[^1].trusted.com` produces no `mailto:` anchor

#### Scenario: A line of addresses stays bounded

- **WHEN** a line repeats `x@a.co然后、` thousands of times
- **THEN** every address is rendered as a `mailto:` anchor in linear time (pinned by a timing regression test)

#### Scenario: The guard is declared

- **WHEN** a developer reads the `gfm-autolinks` matrix entry or the autolinks entry in `Docs/MarkdownSupport.md`
- **THEN** it states that an email whose visible continuation reads as more of its domain stays literal and that CJK prose after an address keeps the link
- **AND** a token or phrase guard fails if that statement disappears
