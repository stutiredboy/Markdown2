# Math Rendering — Delta

## MODIFIED Requirements

### Requirement: Inline math rendering
The system SHALL detect inline TeX math delimited by single dollar signs (`$...$`) within a line of Markdown and SHALL render it as typeset math in the Read-mode preview. The math content SHALL be treated literally and SHALL NOT be processed by inline Markdown rules (emphasis, links, autolinks, backslash escapes) nor HTML-escaped in a way that alters the TeX source seen by the math engine. Backslash sequences inside the math content — including backslash-punctuation TeX commands such as `\,`, `\%`, `\{`, `\;`, `\_`, and `\$` — SHALL reach the math engine verbatim, and an escaped dollar sign (`\$`) inside the content SHALL NOT terminate the math span. Internal protection placeholders SHALL never appear in the rendered output.

#### Scenario: Inline math is typeset
- **WHEN** a paragraph contains `The mass is $E = mc^2$ today.`
- **THEN** the preview renders `E = mc^2` as typeset inline math inline with the surrounding text
- **AND** the literal characters `$`, `=`, `^` do not appear as plain text in the output

#### Scenario: Markdown is not applied inside inline math
- **WHEN** a paragraph contains `$a_*b_*c$`
- **THEN** the underscores and asterisks are passed to the math engine as TeX source
- **AND** no `<em>`/`<strong>` emphasis is produced from the math content

#### Scenario: Backslash TeX commands survive inside inline math
- **WHEN** a paragraph contains `$h = I \cdot C_\text{eff} = 0.25\,C_\text{eff}$`
- **THEN** the math span's TeX source contains `0.25\,C_\text{eff}` with the `\,` intact
- **AND** no placeholder text such as `MD2-0` appears anywhere in the rendered output

#### Scenario: Escaped percent survives inside inline math
- **WHEN** a paragraph contains `$z_{98\%}=2.05$`
- **THEN** the math span's TeX source contains `z_{98\%}=2.05` with the `\%` intact

#### Scenario: Escaped dollar inside inline math does not close the span
- **WHEN** a paragraph contains `$\text{Inv\$} = AIL \cdot C_\text{eff}$`
- **THEN** a single math span is produced whose TeX source contains `\text{Inv\$}` with the `\$` intact
- **AND** the span extends to the final unescaped `$`

### Requirement: Avoid false-positive math detection
The system SHALL NOT treat ordinary dollar-sign usage as math. An escaped `\$` outside a math span SHALL render as a literal dollar sign and SHALL NOT open or close a math span; a dollar sign immediately followed by whitespace at the open, a dollar sign immediately preceded by whitespace at the close, and an unmatched lone `$` on a line SHALL all remain literal text.

#### Scenario: Currency text is not math
- **WHEN** a paragraph contains `It costs $5 today and $10 tomorrow.`
- **THEN** the text renders unchanged with literal dollar signs
- **AND** no math typesetting occurs

#### Scenario: Escaped dollar sign is literal
- **WHEN** a paragraph contains `Price: \$x`
- **THEN** a literal `$x` is rendered as text
- **AND** no math span is created

#### Scenario: Escaped dollars do not pair into a math span
- **WHEN** a paragraph contains `循环库存 \$18 125 与安全库存 \$10 633`
- **THEN** both amounts render as literal text with dollar signs
- **AND** no math span is created between the two escaped dollars

#### Scenario: Escaped dollar coexists with real math on one line
- **WHEN** a paragraph contains `成本为 \$5，公式为 $x+1$`
- **THEN** `$5` renders as literal text
- **AND** `x+1` is rendered as a single inline math span
