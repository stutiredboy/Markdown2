## ADDED Requirements

### Requirement: Inline delimiter ownership follows reading order

The system SHALL recognize inline code spans, `$...$` math, and `\(...\)` math in one left-to-right scan in which the earliest opener with a valid closer owns its span, and the content of an owned span SHALL reach its renderer verbatim. Inside an owned math span, the other math form's delimiters SHALL be plain TeX source. Code spans SHALL bind tighter than math: a code span wholly inside a math span SHALL be part of that span's TeX source, and a math candidate whose closer falls inside a code span SHALL NOT become a math span. Each delimiter SHALL keep its guards: `$` SHALL NOT open after `$` or `\` or before whitespace or `$`, and SHALL NOT close after whitespace or before `$`; `\(` SHALL NOT open after a backslash or inside a link or image destination, and an empty `\(\)` SHALL stay literal; inside both forms a backslash SHALL pair with the next character, and a backslash before a line terminator or at the end of the text SHALL leave the candidate literal. When deciding whether a `\(` sits inside a destination, link syntax inside an already-claimed span SHALL NOT open a destination, and a `\(` rejected inside a destination SHALL NOT hide a later opener outside it. The scan SHALL run in time linear in the length of the inline text.

#### Scenario: Dollar signs inside paren-delimited math reach the engine

- **WHEN** a paragraph contains `\(\text{$x$}\)`
- **THEN** one math span is produced whose TeX source is `\text{$x$}`
- **AND** no nested math span is produced

#### Scenario: A code span inside math is TeX source

- **WHEN** a paragraph contains `` $a `b` c$ ``
- **THEN** one math span is produced whose TeX source is `` a `b` c ``
- **AND** no `<code>` element is produced

#### Scenario: Math does not close inside a code span

- **WHEN** a paragraph contains `` The plan costs $20/month. Set `$API_KEY` first. ``
- **THEN** no math span is produced
- **AND** `$API_KEY` renders as inline code and `$20/month` stays literal text

#### Scenario: The earliest math opener owns its span

- **WHEN** a paragraph contains `\(a$b\) and \(c$d\)`
- **THEN** two math spans are produced, with TeX sources `a$b` and `c$d`

#### Scenario: Paren delimiters inside dollar math stay TeX

- **WHEN** a paragraph contains `$\text{\(x\)}$`
- **THEN** one math span is produced whose TeX source is `\text{\(x\)}`

#### Scenario: Carried-over guards keep text literal

- **WHEN** a paragraph contains `a $ x$ b`, `a $x$$ b`, `a \$x$ b`, `a $$x$ b`, or `a \\(x\) b`
- **THEN** no math span is produced
- **AND** the authored text remains visible in the output

#### Scenario: Link syntax inside a claimed span does not open a destination

- **WHEN** a paragraph contains `` Type `](` then \(x\) here ``
- **THEN** `\(x\)` renders as an inline math span

#### Scenario: A rejected opener does not hide a later one

- **WHEN** a paragraph contains `[a](\(x) \(y\))`
- **THEN** the link's destination is `(x`
- **AND** `\(y\)` after the destination renders as an inline math span
