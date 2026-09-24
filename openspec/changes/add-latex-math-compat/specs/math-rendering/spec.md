# Math Rendering — Delta

## MODIFIED Requirements

### Requirement: Inline math rendering
The system SHALL detect inline TeX math delimited by single dollar signs (`$...$`) or by a backslash-parenthesis pair (`\(...\)`) within a line of Markdown and SHALL render it as typeset math in the Read-mode preview. The math content SHALL be treated literally and SHALL NOT be processed by inline Markdown rules (emphasis, links, autolinks) nor HTML-escaped in a way that alters the TeX source seen by the math engine. Backslash sequences inside a math span — including backslash-punctuation TeX commands such as `\,`, `\%`, `\{`, `\;`, `\_`, and `\$` — SHALL reach the math engine verbatim and SHALL NOT be consumed as Markdown backslash escapes; an escaped dollar sign (`\$`) inside a `$...$` span SHALL NOT terminate it. Neither delimiter pair SHALL appear in the rendered output.

#### Scenario: Inline math is typeset
- **WHEN** a paragraph contains `The mass is $E = mc^2$ today.`
- **THEN** the preview renders `E = mc^2` as typeset inline math inline with the surrounding text
- **AND** the literal characters `$`, `=`, `^` do not appear as plain text in the output

#### Scenario: Markdown is not applied inside inline math
- **WHEN** a paragraph contains `$a_*b_*c$`
- **THEN** the underscores and asterisks are passed to the math engine as TeX source
- **AND** no `<em>`/`<strong>` emphasis is produced from the math content

#### Scenario: Paren-delimited inline math is typeset
- **WHEN** a paragraph contains `The mass is \(E = mc^2\) today.`
- **THEN** the preview renders `E = mc^2` as typeset inline math inline with the surrounding text
- **AND** the literal characters `\(` and `\)` do not appear in the output

#### Scenario: Paren-delimited inline math accepts surrounding spaces
- **WHEN** a paragraph contains `\( x + y \)`
- **THEN** a math span containing `x + y` is produced

#### Scenario: Backslash TeX commands survive inside paren-delimited inline math
- **WHEN** a paragraph contains `\(0.25\,C_\text{eff}\)`
- **THEN** the math span's TeX source contains `0.25\,C_\text{eff}` with the `\,` intact
- **AND** the backslash is not consumed as a Markdown escape

#### Scenario: Unterminated paren delimiter is not math
- **WHEN** a paragraph contains `see \(x + y` with no closing `\)`
- **THEN** no math span is produced
- **AND** the authored text remains visible in the output

### Requirement: Block (display) math rendering
The system SHALL detect block/display math in any of the following forms and SHALL render it as a centered display equation in the Read-mode preview: double dollar signs (`$$...$$`), bracket delimiters (`\[...\]`), and a native environment opening with `\begin{<env>}` on a line and closing with the matching `\end{<env>}` with no `$$` or `\[` wrapper. Each form SHALL support content that spans multiple lines as well as content contained on a single line. The block SHALL NOT be treated as a paragraph or code block. Display equations containing a `\label{key}` command SHALL be assigned a sequential equation number, rendered right-aligned alongside the equation, and the label SHALL be registered for cross-reference resolution, in every recognized form. The `\label{}` command itself SHALL be removed before typesetting and SHALL NOT appear in the rendered output. Display equations without `\label{}` SHALL be unnumbered by default, unless a "number all display equations" setting is enabled. The `\tag{n}` command SHALL set a manual equation number, overriding auto-numbering, and the system SHALL NOT also apply its own sequential number to that equation.

An environment SHALL be recognized only when the opening and closing environment names match, an inner environment that closes inside the block SHALL NOT terminate the block early, and same-name nested environments SHALL be captured in full via depth counting. A candidate block whose scan encounters a fenced-code opener before its matching closer SHALL NOT be treated as math. Environments the bundled engine can typeset — `align`, `align*`, `alignat`, `alignat*`, `gather`, `gather*`, `equation`, `equation*`, and the standalone inner environments it accepts, enumerated as `aligned`, `alignedat`, `split`, `cases`, `array`, `matrix`, `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`, `Vmatrix`, `smallmatrix` — SHALL be typeset, with the environment commands retained in the TeX handed to the engine. Environments the bundled engine does not implement, such as `multline` and `eqnarray`, SHALL also be recognized as display math blocks so that the engine reports them visibly rather than their source being consumed as ordinary prose.

The bundled engine's own display numbering SHALL be suppressed for recognized environments, so that a display equation never carries two numbers: the sequential number the system assigns, or a manual `\tag{}`, and never both. An explicit `\tag{}` SHALL keep rendering.

#### Scenario: Multi-line display block is typeset
- **WHEN** the source contains a block opening with a line `$$`, then `\int_0^1 x^2 \, dx`, then a closing line `$$`
- **THEN** the preview renders the integral as a centered display equation
- **AND** the `$$` delimiters are not shown as literal text

#### Scenario: Single-line display block is typeset
- **WHEN** the source contains a line `$$a^2 + b^2 = c^2$$`
- **THEN** the preview renders it as a centered display equation

#### Scenario: Bracket-delimited display block is typeset
- **WHEN** the source contains a line `\[`, then `C^{availability}_t=\frac{A_t}{H_t}\times 100`, then a closing line `\]`
- **THEN** the preview renders it as a centered display equation
- **AND** the `\[` and `\]` delimiters are not shown as literal text

#### Scenario: Native align environment is typeset without a dollar wrapper
- **WHEN** the source contains `\begin{align}` on its own line, then `a &= b \\`, then `c &= d`, then `\end{align}`
- **THEN** the preview renders the block as a centered display equation
- **AND** the literal text `\begin{align}` does not appear in the output

#### Scenario: Single-line native equation environment is typeset
- **WHEN** the source contains a line `\begin{equation}E = mc^2\end{equation}`
- **THEN** the preview renders it as a centered display equation

#### Scenario: Starred environment is unnumbered
- **WHEN** the source contains `\begin{equation*}E = mc^2\end{equation*}` with no `\label{}`
- **THEN** the preview renders the equation without a number

#### Scenario: Environment carries at most one number
- **WHEN** the source contains a labeled `align` environment
- **THEN** the rendered equation carries exactly one number — the sequential number assigned to its label
- **AND** the engine does not additionally number the environment's rows

#### Scenario: Unlabeled environment stays unnumbered by default
- **WHEN** the source contains `\begin{align}` with no `\label{}` and the number-all setting is off
- **THEN** the preview renders the equation without any number

#### Scenario: Manual tag still renders in a recognized environment
- **WHEN** the source contains `\begin{align}` whose content carries `\tag{3.1}`
- **THEN** the preview renders the manual number `(3.1)`
- **AND** no additional sequential number is applied to the same equation

#### Scenario: Nested inner environment does not close the outer block
- **WHEN** the source contains `\begin{align}`, then `x &= \begin{cases} 1 & a \\ 2 & b \end{cases}`, then `\end{align}`
- **THEN** a single display equation is produced containing the full nested source
- **AND** the block is not terminated at the inner `\end{cases}`

#### Scenario: Nested same-name environments do not truncate the block
- **WHEN** the source contains `\begin{matrix}`, then `\begin{matrix} a \end{matrix}`, then `\end{matrix}` on separate lines
- **THEN** a single display equation is produced containing the full nested source
- **AND** no orphaned `\end{matrix}` remains as literal text

#### Scenario: A closer that appears only inside a fenced code block does not open a math block
- **WHEN** the source contains a line starting with `\begin{align}`, prose lines, then a fenced code block whose content includes a line ending with `\end{align}`
- **THEN** no display equation is produced and all lines remain visible as authored
- **AND** the fenced code block still renders as code

#### Scenario: Environment with a label is numbered and registered
- **WHEN** the source contains `\begin{equation}E = mc^2 \label{eq:energy}\end{equation}`
- **THEN** the preview renders the equation centered with a right-aligned number
- **AND** the label `eq:energy` is registered for `\ref{}` resolution
- **AND** the literal text `\label{eq:energy}` does not appear in the output

#### Scenario: Labeled display equation is numbered
- **WHEN** the source contains `$$E = mc^2 \label{eq:energy}$$`
- **THEN** the preview renders the equation centered with a right-aligned number `(1)`
- **AND** the label `eq:energy` is registered for `\ref{}` resolution

#### Scenario: Label command is not shown in the typeset equation
- **WHEN** the source contains `$$E = mc^2 \label{eq:energy}$$`
- **THEN** the typeset equation shows `E = mc^2` alongside its number
- **AND** the literal text `\label{eq:energy}` does not appear in the output

#### Scenario: Unlabeled display equation is unnumbered by default
- **WHEN** the source contains `$$E = mc^2$$` without `\label{}`
- **THEN** the preview renders the equation without a number

#### Scenario: Manual tag overrides auto-numbering
- **WHEN** the source contains `$$a = b \tag{3.1}$$`
- **THEN** the preview renders the equation with the manual number `(3.1)` right-aligned
- **AND** no additional sequential number is applied to the same equation

#### Scenario: Environment the engine does not implement is reported visibly
- **WHEN** the source contains `\begin{eqnarray}` on its own line, a row, then `\end{eqnarray}`
- **THEN** the block is treated as display math and the engine's failure is shown in place
- **AND** the surrounding document still renders normally

### Requirement: Avoid false-positive math detection
The system SHALL NOT treat ordinary dollar-sign usage as math. An escaped `\$`, a dollar sign immediately followed by whitespace at the open, a dollar sign immediately preceded by whitespace at the close, and an unmatched lone `$` on a line SHALL all remain literal text. Likewise, a `\(` with no matching `\)`, a `\begin{<env>}` whose matching `\end{<env>}` never appears, and an opening and closing whose environment names differ SHALL NOT open a math span or a display math block. A `\(` occurring inside an inline link or image destination SHALL NOT open a math span, because inside a destination's `(…)` it is a literal-parenthesis escape rather than a math delimiter.

#### Scenario: Currency text is not math
- **WHEN** a paragraph contains `It costs $5 today and $10 tomorrow.`
- **THEN** the text renders unchanged with literal dollar signs
- **AND** no math typesetting occurs

#### Scenario: Escaped dollar sign is literal
- **WHEN** a paragraph contains `Price: \$x`
- **THEN** a literal `$x` is rendered as text
- **AND** no math span is created

#### Scenario: Escaped parens in a link destination are not math
- **WHEN** a paragraph contains `[link](\(foo\))`
- **THEN** the output contains a link whose destination is the literal `(foo)`
- **AND** no math span is produced

#### Scenario: Escaped parens in a nested link destination are not math
- **WHEN** a paragraph contains `[link](foo\(and\(bar\))`
- **THEN** the output contains a link whose destination retains the authored parens
- **AND** no math span is produced

#### Scenario: Math after a link on the same line still renders
- **WHEN** a paragraph contains `[a](b) then \(x + y\) end`
- **THEN** the link renders as a link
- **AND** `\(x + y\)` renders as an inline math span

#### Scenario: Unterminated environment is not a math block
- **WHEN** a paragraph mentions `\begin{align}` with no `\end{align}` anywhere in the document
- **THEN** no display equation is produced
- **AND** the authored text remains visible in the output

#### Scenario: Mismatched environment names are not a math block
- **WHEN** the source contains `\begin{align}` and later `\end{gather}`
- **THEN** no display equation is produced from that pair
- **AND** the authored text remains visible in the output

### Requirement: Code content is never treated as math
The system SHALL give inline code and code blocks precedence over math detection. Math-delimited content — delimited by `$`, `\(`, `$$`, `\[`, or a native `\begin{<env>}` environment — inside inline code (`` `...` ``) or fenced/indented code blocks SHALL remain literal source text.

#### Scenario: Dollar math inside inline code stays literal
- **WHEN** a paragraph contains `` use `$x$` here ``
- **THEN** the output shows the literal text `$x$` styled as code
- **AND** no math typesetting occurs

#### Scenario: Dollar math inside a fenced code block stays literal
- **WHEN** a fenced code block contains the line `$$x^2$$`
- **THEN** the code block shows the literal `$$x^2$$`
- **AND** no display equation is rendered

#### Scenario: Environment inside a fenced code block stays literal
- **WHEN** a fenced code block contains `\begin{align}` on one line and `\end{align}` on another
- **THEN** the code block shows that source literally
- **AND** no display equation is rendered

#### Scenario: Paren-delimited math inside inline code stays literal
- **WHEN** a paragraph contains `` use `\(x\)` here ``
- **THEN** the output shows the literal text `\(x\)` styled as code
- **AND** no math span is produced

### Requirement: Offline rendering with graceful error handling
The system SHALL typeset math without any runtime network access, using assets bundled with the application. When a TeX expression contains commands the engine cannot render, the system SHALL display the offending source visibly rather than failing to render the rest of the document. This guarantee SHALL cover unsupported environments as well as unsupported commands: an environment the engine does not implement SHALL produce a visible, non-blank indicator carrying its source, and SHALL NOT blank the preview, drop the surrounding document, or crash.

#### Scenario: Math renders without network
- **WHEN** the preview is shown for a document containing math while the machine is offline
- **THEN** the math is fully typeset using bundled assets

#### Scenario: Invalid TeX does not break the page
- **WHEN** a document contains an unsupported or malformed TeX expression such as `$\unknowncmd{}$`
- **THEN** the rest of the document still renders normally
- **AND** the problematic expression is shown (e.g. highlighted as an error) instead of crashing or blanking the preview

#### Scenario: Unsupported environment does not break the page
- **WHEN** a document contains an environment the bundled engine does not implement
- **THEN** the rest of the document still renders normally
- **AND** the offending environment's source is shown in place instead of crashing or blanking the preview
