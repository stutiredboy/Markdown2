## MODIFIED Requirements

### Requirement: Nested list rendering by indentation
The system SHALL determine each list item's nesting level from its leading-whitespace indentation, and SHALL render items indented more deeply than the preceding item as a child list nested inside that preceding item's `<li>`. Returning to a shallower indentation SHALL close the deeper child list(s) and continue the appropriate ancestor list. A list item SHALL open a deeper nesting level when its indentation is at least three columns greater than the indentation at which the enclosing level began; an indentation increase of two columns or fewer SHALL remain at the current level. A tab, four spaces, and the content column of an ordered marker such as `1. ` (three columns) or `10. ` (four columns) all satisfy the three-column step and therefore nest.

#### Scenario: Single level of nesting
- **WHEN** the source contains:
  ```
  - 空调
      - 内外机
      - 安装（铜、电缆）
      - 人工
  - 电缆
  - 配电箱
  ```
- **THEN** the preview renders a top-level `<ul>` with three items `空调`, `电缆`, `配电箱`
- **AND** the `空调` item contains a nested `<ul>` with three items `内外机`, `安装（铜、电缆）`, `人工`
- **AND** `电缆` and `配电箱` are siblings of `空调`, not children of it

#### Scenario: Returning to a shallower level closes nested lists
- **WHEN** a child item is followed by an item at the parent's indentation level
- **THEN** the nested child list is closed
- **AND** the following item is rendered as a sibling of the parent item

#### Scenario: Multiple nesting levels
- **WHEN** the source contains an item, a child indented one level, and a grandchild indented two levels
- **THEN** the grandchild renders inside a list nested within the child's `<li>`, which is itself nested within the top-level item's `<li>`

#### Scenario: Two-space indentation stays at the current level
- **WHEN** a `- parent` line is immediately followed by a `  - sibling` line indented with two spaces
- **THEN** both items render as siblings of one `<ul>`
- **AND** the `parent` item does not contain a nested list

#### Scenario: Bullets aligned to an ordered marker nest under that item
- **WHEN** the source contains:
  ```
  1. first
     - detail a
     - detail b
  2. second
  ```
- **THEN** the preview renders a single `<ol>` whose first `<li>` is `first` and whose second `<li>` is `second`
- **AND** the `first` item contains a nested `<ul>` with two items `detail a` and `detail b`
- **AND** the `second` item is rendered as the second item of the ordered list, not as a new list

## ADDED Requirements

### Requirement: Loose-list continuity across blank lines
The system SHALL treat a blank line between list items as a separator within one list rather than a list terminator, provided the list resumes: when a blank line is followed (after any number of consecutive blank lines) by another list item, the items before and after the blank line SHALL belong to the same list and an ordered list's numbering SHALL continue without resetting. A blank line followed by a non-list line SHALL still end the list. Items grouped across a blank line SHALL render with the same tight `<li>` content as items with no intervening blank line (no `<p>` wrapping is introduced).

#### Scenario: Blank line between ordered items keeps continuous numbering
- **WHEN** the source contains:
  ```
  1. first

  2. second

  3. third
  ```
- **THEN** the preview renders a single `<ol>` containing three `<li>` items in order `first`, `second`, `third`
- **AND** the rendered markers are `1.`, `2.`, `3.` (the count does not reset to `1` for every item)

#### Scenario: Blank line before a non-list line ends the list
- **WHEN** an ordered list item is followed by a blank line and then a paragraph line that is not a list item
- **THEN** the list ends at the item before the blank line
- **AND** the following text renders as a separate paragraph

#### Scenario: Mixed ordered list with blank-line separation and nested bullets
- **WHEN** the source contains:
  ```
  1. **first point**
     - supporting detail
     - another detail

  2. **second point**
     - supporting detail
  ```
- **THEN** the preview renders a single `<ol>` whose items are numbered `1.` and `2.`
- **AND** each ordered item contains a nested `<ul>` with its bullet details
- **AND** no ordered item's marker resets to `1.`
