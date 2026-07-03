## Purpose

Define how soft and hard line breaks in Markdown source render in the preview.

## Requirements

### Requirement: Soft line breaks are preserved as visible line breaks

The renderer SHALL convert a soft line break (a newline between two non-blank
lines within the same block) into an HTML `<br>` element, so each authored line
appears on its own line. This rule SHALL apply uniformly to regular paragraphs
and to paragraphs nested inside blockquotes.

#### Scenario: Multi-line paragraph

- **WHEN** a paragraph contains three consecutive non-blank lines `a`, `b`, `c`
- **THEN** the rendered HTML places `<br>` between `a` and `b` and between `b` and `c`
- **AND** the three lines are not joined by a space onto one line

#### Scenario: Multi-line blockquote

- **WHEN** the source is a blockquote with three lines:

  ```
  > asdfasdf
  > asdfasdf
  > asdfasdf
  ```

- **THEN** the rendered blockquote shows three separate lines, separated by `<br>`
- **AND** it does NOT render as the single line `asdfasdf asdfasdf asdfasdf`

### Requirement: Hard line breaks remain supported

The renderer SHALL continue to treat an explicit hard break — a line ending with
two or more trailing spaces or with a trailing backslash (`\`) — as a `<br>`, and
the trailing break markers SHALL NOT appear in the rendered text.

#### Scenario: Trailing-spaces hard break

- **WHEN** a line ends with two trailing spaces followed by another line
- **THEN** the rendered output contains a single `<br>` between the two lines
- **AND** the trailing spaces are not visible in the output

#### Scenario: Backslash hard break

- **WHEN** a line ends with a trailing backslash followed by another line
- **THEN** the rendered output contains a `<br>` between the two lines
- **AND** the trailing backslash is removed from the rendered text

### Requirement: Blank lines still separate blocks

A blank line SHALL still terminate the current block, so consecutive paragraphs
remain distinct `<p>` blocks rather than one paragraph joined by `<br>`.

#### Scenario: Two paragraphs separated by a blank line

- **WHEN** two lines of text are separated by a blank line
- **THEN** the renderer emits two separate `<p>` blocks
- **AND** there is no `<br>` bridging the two paragraphs
