# markdown-block-markers Specification

## Purpose
Define how the renderer recognizes Markdown's ASCII block markers and link-reference syntax: by Unicode code point, as CommonMark specifies, so a joining scalar that fuses with a marker into one grapheme cluster neither hides the marker nor is dropped with it.
## Requirements
### Requirement: Block markers are recognized by code point
The renderer SHALL recognize Markdown's ASCII block markers by Unicode code point, as CommonMark specifies, and not by grapheme cluster. The markers are:
- ATX heading hashes and the space after them
- bullet markers (`-`, `*`, `+`) with their space, and ordered-list markers
- task markers (`[ ]`, `[x]`, `[X]`)
- the blockquote `>`
- code fences (backticks and tildes)
- the indentation of indented code
- the display-math openers `$$` and `\[`

A joining scalar right after a marker (a combining mark, a zero-width joiner, a variation selector, or a spacing mark) SHALL NOT hide the marker, even though it fuses with the marker's last character into one grapheme. Dropping a marker SHALL keep the joining scalar that follows it as the first scalar of the content.

Leading indentation SHALL be measured as spaces and tabs counted by scalar, both for list nesting and continuation in the renderer and for the editor's list commands, which share the same measure.

#### Scenario: A heading whose text starts with a combining mark
- **WHEN** the source contains `# `, then U+0301, then `word`
- **THEN** it renders as a level-1 heading whose text starts with U+0301

#### Scenario: A bullet item whose text starts with a joining scalar
- **WHEN** the source contains `- `, `* ` or `+ `, then U+0301, U+200D, U+FE0F or U+093F, then `word`
- **THEN** it renders as a list item whose text starts with that scalar

#### Scenario: A task item whose text starts with a combining mark
- **WHEN** the source contains `- [ ] ` or `- [X] `, then U+0301, then `word`
- **THEN** it renders as a task item with a checkbox

#### Scenario: Blockquote, fence, indented code and display math
- **WHEN** a combining mark directly follows `>`, a code fence, four spaces of indentation, `$$` or `\[`
- **THEN** the line renders as a blockquote, a fenced code block with that info string, an indented code block, or a display-math block
- **AND** the combining mark is the first scalar of the content

#### Scenario: Nested and continued list content
- **WHEN** a nested list item or a list continuation line starts with a combining mark after its indentation
- **THEN** it renders inside its parent item, as it would with a letter in that place

### Requirement: Link-reference syntax is read by code point
Link reference definitions SHALL be parsed by Unicode code point, so a joining scalar after a definition's `[` or after a title's opening quote SHALL NOT hide it. Reference links SHALL pair their brackets by code point, so a joining scalar after `[`, or a prepended mark (such as U+0600) before it, SHALL NOT keep a shortcut, collapsed or full reference link from resolving.

#### Scenario: A label that starts with a combining mark
- **WHEN** the source defines `[`, U+0301, `r]: /u` and uses the same label as a shortcut reference
- **THEN** the shortcut renders as a link to `/u` whose text starts with U+0301

#### Scenario: A full reference whose key starts with a combining mark
- **WHEN** the source contains `[t][`, U+0301, `r]` and defines that key
- **THEN** `t` renders as a link to the key's destination

#### Scenario: A definition title that starts with a combining mark
- **WHEN** a definition's title starts with U+0301 after its opening quote
- **THEN** the reference link carries that title

#### Scenario: A prepended mark before a reference link
- **WHEN** the source contains U+0600 directly before `[r]` and defines `r`
- **THEN** `r` renders as a link, with U+0600 before it

