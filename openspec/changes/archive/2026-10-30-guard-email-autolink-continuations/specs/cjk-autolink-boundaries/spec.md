## ADDED Requirements

### Requirement: Lookalike continuations do not retarget an email autolink

An email autolink candidate SHALL NOT be anchored when its visible continuation reads as more of its domain. The visible continuation SHALL be computed by the same walk as the bare-URL guard (restoring protected tokens/entities/escapes including image alt text, skipping footnote reference markers, stripping inline HTML, treating emphasis/strikethrough/highlight/sup/sub delimiters as markup, skipping invisible characters, and folding IDNA/fullwidth forms), and the walk SHALL end at the first visible character that is neither a host-label character (letter, digit, `-` or `_`) nor a dot, so the check reads only the host-shaped prefix. A candidate SHALL stay literal when the continuation begins with an `@`; when a label of the host-shaped prefix begins with a host-label character outside the Han, Hiragana, Katakana and Hangul scripts (the first label extends the final domain label; each later label follows a dot); or when the walk fails closed (scan budget, protected math, provisional cross-reference) before the prefix ends. A label that begins with a Han, Hiragana, Katakana or Hangul character SHALL NOT block the link, so CJK prose written flush against an address stays linked. The email match pattern and its left boundary SHALL remain unchanged, and the `gfm-autolinks` matrix entry and `Docs/MarkdownSupport.md` SHALL declare the guard.

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

- **WHEN** the source contains `foo@evil.com@trusted.com` or `foo@evil.com＠trusted.com`
- **THEN** no `mailto:` anchor is produced

#### Scenario: CJK prose after an address still links

- **WHEN** the source contains `联系 foo@example.com。然后继续。`, `邮箱：foo@example.com获取`, `foo@example.comまでご連絡ください`, or `foo@example.com으로 보내주세요`
- **THEN** `foo@example.com` is rendered as a `mailto:` anchor
- **AND** the prose follows the anchor as text

#### Scenario: Address lists still link

- **WHEN** the source contains `foo@example.com、bar@example.com` or `foo@example.com，bar@example.com`
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

## MODIFIED Requirements

### Requirement: Lookalike continuations do not retarget a bare URL

A bare-URL candidate SHALL NOT be anchored when the visible continuation, after restoring protected tokens/entities/escapes (including image alt text), skipping footnote reference markers (a generated note number, never authority text, so what follows the marker is checked as if adjacent), stripping inline HTML, treating emphasis/strikethrough/highlight/sup/sub delimiters as markup, skipping invisible characters (Unicode format/control/combining and default-ignorable scalars, including ZWSP/ZWNJ/ZWJ, bidi marks and tag characters, plus blank-rendering fillers), and folding IDNA/fullwidth forms, would change the apparent authority. A protected math span in the continuation SHALL leave the candidate literal, and a block-level or void HTML boundary SHALL end the continuation. The guard SHALL apply when the authority (host with optional port) ends the URL (no path, query, or fragment), SHALL read the continuation from the visible text of any protected token rather than after it, and SHALL bound the continuation scan (failing closed when the bound is reached before a delimiter). A candidate SHALL stay literal when the continuation contains an ASCII `@` before the next `/`, `?`, `#`, or whitespace; when it begins with one or more IDNA dots followed by a host label that is ASCII or is followed by another dot; when it begins with a fullwidth percent followed by `2e`/`2E`; when it begins with a host-label character (letter, digit, `-` or `_`); or when it begins with a letter or digit and contains a dot. Ordinary prose continuations (`https://example.com。然后`, `https://example.com：然后`, `https://example.com％然后`) SHALL remain linked.

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

#### Scenario: Long hostile line stays bounded

- **WHEN** a line repeats `www.a。` thousands of times
- **THEN** rendering completes in linear time (pinned by a timing regression test)

#### Scenario: Ordinary prose continuation still links

- **WHEN** the source contains `https://example.com。然后`
- **THEN** `https://example.com` is rendered as an anchor

### Requirement: Existing bare-autolink behavior is preserved

The change SHALL NOT alter the protection of code spans, math spans, existing Markdown links/images, reference links, footnote/citation/cross-reference anchors, or raw HTML; SHALL NOT alter angle-bracket autolinks (`<https://…>`, `<mailto:…>`) or the email autolink pattern and its left boundary (the email continuation guard is defined by its own requirement); and SHALL NOT alter domain validation, authored-entity recovery, or the trailing ASCII cleanup. Authored HTML entity spellings SHALL keep the existing behavior even when they encode a terminator or a left-boundary character. All GFM extension corpus examples SHALL keep their current baseline relationship.

#### Scenario: Protected content still suppresses bare linking

- **WHEN** a URL appears in a code span, a math span, a Markdown link label or destination, or an image destination
- **THEN** no additional anchor is produced for it

#### Scenario: Email autolink matching is unchanged

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
