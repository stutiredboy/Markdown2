## MODIFIED Requirements

### Requirement: Nested list rendering by indentation
The system SHALL determine each list item's nesting level from its leading-whitespace indentation relative to the content column of the nearest preceding list item. A list item indented to or beyond the preceding item's content column SHALL render as a child list nested inside that preceding item's `<li>`. Returning to a shallower indentation SHALL close the deeper child list(s) and continue the appropriate ancestor list. The content column is the parent marker indentation plus marker width: two columns for an unordered marker such as `- `, three columns for an ordered marker such as `1. `, and four columns for an ordered marker such as `10. `. A tab and four spaces SHALL satisfy nesting under any one-, two-, or three-column marker. Nested ordered, unordered, mixed-kind, and task lists SHALL remain visibly indented from their parent item in the rendered preview.

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
- **AND** the nested `<ul>` is visually indented relative to the `空调` item

#### Scenario: Returning to a shallower level closes nested lists
- **WHEN** a child item is followed by an item at the parent's indentation level
- **THEN** the nested child list is closed
- **AND** the following item is rendered as a sibling of the parent item

#### Scenario: Multiple nesting levels
- **WHEN** the source contains an item, a child indented one level, and a grandchild indented two levels
- **THEN** the grandchild renders inside a list nested within the child's `<li>`, which is itself nested within the top-level item's `<li>`

#### Scenario: Two-space unordered child nests under its parent
- **WHEN** a `- parent` line is immediately followed by a `  - child` line indented with two spaces
- **THEN** the `child` item renders inside a nested `<ul>` under `parent`
- **AND** the child item is visibly indented in the preview

#### Scenario: Monthly report nested bullet items remain indented
- **WHEN** the source contains:
  ```
  - **重要事项**：
    - 第一项说明内容，含一些细节。
  - **补充说明**：
    - 第二项说明内容，含 **加粗** 文字。
  ```
- **THEN** the preview renders exactly two top-level list items
- **AND** each top-level item contains a nested `<ul>` with its detail item
- **AND** the detail bullets are visually indented relative to their bold parent bullets

#### Scenario: Monthly report image blocks do not break nested child lists
- **WHEN** nested child bullet items are separated by one or more standalone image lines that are not indented
- **THEN** the standalone image lines render as content of the preceding child item
- **AND** the following child bullet remains in the same nested child list instead of starting an unindented top-level list

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

#### Scenario: Bullets aligned to a two-digit ordered marker nest under that item
- **WHEN** the source contains:
  ```
  10. first
      - detail a
  11. second
  ```
- **THEN** the preview renders a single `<ol>` whose first item contains a nested `<ul>` with `detail a`
- **AND** the `second` item remains a sibling ordered item

### Requirement: Task list and mixed-kind nesting preservation
The system SHALL preserve task-list rendering and mixed ordered/unordered nesting. A list item written as `- [ ]` or `- [x]` SHALL render with an enabled (clickable) checkbox reflecting the checked state, including when nested. Each task checkbox SHALL carry a `data-md2-task-line` attribute holding the 1-based source line of its list item, absolute with respect to the whole document (including items rendered inside blockquotes). A nested child list MAY be of a different kind (ordered vs. unordered) than its parent. Task-list marker styling SHALL NOT collapse child-list indentation.

#### Scenario: Nested task list items keep checkboxes
- **WHEN** a parent item has a nested child item written as `  - [x] done`
- **THEN** the nested child renders inside a child list with a checked, enabled checkbox
- **AND** the nested task list is visually indented from the parent item

#### Scenario: Checkbox carries its source line
- **WHEN** the third line of the document is `- [ ] Ship`
- **THEN** its rendered checkbox input carries `data-md2-task-line="3"`

#### Scenario: Task item inside a blockquote carries an absolute line
- **WHEN** a `> - [ ] quoted` task line is the fifth line of the document
- **THEN** its rendered checkbox input carries `data-md2-task-line="5"`

#### Scenario: Ordered list nested under unordered item
- **WHEN** a `- parent` item is followed by `  1. step one` and `  2. step two`
- **THEN** the `parent` item contains a nested `<ol>` with two items
- **AND** the nested ordered list is visually indented from the parent item
