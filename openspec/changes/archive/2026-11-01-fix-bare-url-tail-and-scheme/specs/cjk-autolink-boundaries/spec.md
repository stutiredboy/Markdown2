## ADDED Requirements

### Requirement: Text cut from a bare URL renders as it would outside the URL

Text that the trailing rule removes from a bare URL SHALL render after the anchor exactly as the same text renders outside a URL. This covers trailing ASCII punctuation, excess closing parentheses, a trailing entity spelling, and everything from `<` on. An entity the renderer recognizes SHALL stay an entity, and a renderer escape or backslash escape SHALL keep its meaning. A named entity whose name HTML does not define SHALL render as text, as the GFM reference renders it (`&amp;hl;`). When the cut falls inside a backslash escape, the removed text SHALL keep its authored spelling as text. What the trailing rule removes SHALL NOT change.

#### Scenario: Trailing entity renders as the character it names

- **WHEN** the source contains `see https://example.com/a&amp; next`
- **THEN** the anchor is `https://example.com/a`
- **AND** `&amp;` follows the anchor as an entity, so the reader sees `&`, not `&amp;`

#### Scenario: Trailing entity before trailing punctuation

- **WHEN** the source contains `see https://example.com/a&amp;. next`
- **THEN** `&amp;.` follows the anchor `https://example.com/a`

#### Scenario: Text after `<` keeps its entities

- **WHEN** the source contains `see https://example.com/a<b&amp;c next`
- **THEN** the anchor ends before `<`
- **AND** `&lt;b&amp;c` follows it, so the reader sees `<b&c`

#### Scenario: Undefined entity name stays text

- **WHEN** the source contains `www.google.com/search?q=commonmark&hl;`
- **THEN** `&amp;hl;` follows the anchor
- **AND** GFM example 626 keeps its reference match

#### Scenario: Escaped ampersand stays text

- **WHEN** the source contains `see https://example.com/a\&amp; next`
- **THEN** the text after the anchor reads `&amp;`

### Requirement: Bare-URL scheme and terminator checks compare Unicode scalars

The checks that classify a bare-URL candidate as `http://`, `https://` or `www.`, and that end it at `<`, SHALL compare Unicode scalars. A combining mark that joins the scheme's last character or a `<` into one grapheme cluster SHALL NOT change the candidate's classification or where it ends. A candidate matched by the URL alternative SHALL NOT become a `mailto:` link.

#### Scenario: Combining mark after the scheme is not an email

- **WHEN** the source contains `http://`, `https://` or `www.`, then U+0301, then `x.com`
- **THEN** no `mailto:` anchor is produced
- **AND** no anchor is produced, because a host label cannot start with a mark
- **AND** the candidate stays visible as text

#### Scenario: Fused `<` ends the URL

- **WHEN** the source contains `see https://example.com/x<`, then U+0301, then `b next`
- **THEN** the anchor is `https://example.com/x`
- **AND** the `<`, the mark and `b` follow it as text

#### Scenario: A mark in the path stays URL content

- **WHEN** the source contains `see https://example.com/e`, then U+0301, then ` next`
- **THEN** the anchor's destination includes the mark

### Requirement: The continuation guard reads text cut from the URL as it renders

When the bare-URL continuation guard runs (the authority ends the URL), text that the trailing rule removed SHALL be read as the start of the visible continuation, in the form it renders. A trailing entity SHALL be read as the character it names. When the named-entity table is unavailable and the removed text contains a named entity spelling, the candidate SHALL stay literal.

#### Scenario: Trailing entity dot before a token stays literal

- **WHEN** the source contains `` https://evil.com&period;`trusted` `` or `https://evil.com&period;[trusted](/x)`
- **THEN** no anchor is produced for `https://evil.com`

#### Scenario: Trailing no-break space ends the authority

- **WHEN** the source contains ``see https://example.com&nbsp;`user@host` next``
- **THEN** `https://example.com` is linked, as it is when a no-break space is typed in place of `&nbsp;`, although the code span after it contains `@`
- **AND** `&nbsp;` follows the anchor as an entity
