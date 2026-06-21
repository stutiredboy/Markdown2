## Why

When ordered list items are separated by blank lines and carry marker-aligned nested bullets — a common, valid CommonMark structure — the Read-mode preview renumbers every item as `1.`. A real document (section `## 6. 管理启示`) written as:

```
1. **关键单位成本三角的稳定性决定策略稳定性**
   - 自制正常班…
   - 因此企业需要…

2. **人工成本上行 → 推动"轻资产化"**
   - 当本地用工成本…
```

renders six separate `<ol>` blocks each starting at `1`, instead of one `<ol>` numbered `1.`–`6.` with nested `<ul>` children. Two renderer behaviors combine to cause this, both explicitly deferred as Non-Goals by the earlier `fix-nested-list-rendering` change:

1. A blank line between list items terminates `listBlock`'s collection loop, so each numbered item becomes its own list (restarting the count).
2. Nesting requires ≥4 columns of indentation, but bullets under `1. ` are indented to the marker's content column (3 columns), so they are read as same-level siblings of a different kind — which also breaks the ordered list at the kind change.

## What Changes

- Treat a blank line inside a list as a separator between items of the **same** list (loose list) rather than as a list terminator, as long as a subsequent line continues the list at a compatible indentation. The ordered count continues across the blank line.
- Recognize bullets indented to an ordered marker's content column (e.g. 3 spaces under `1. `) as nested children of that item, so mixed ordered/unordered lists keep their hierarchy and the parent `<ol>` is not split.
- Preserve all existing list behavior: flat lists, tight lists, the 4-space/tab nesting step for unordered-under-unordered lists, task-list checkboxes, indented-code boundaries, and blockquote-nested lists.

## Capabilities

### New Capabilities
<!-- None -->

### Modified Capabilities
- `list-rendering`: Add requirements for (a) blank-line-separated (loose) list continuity so ordered numbering does not reset, and (b) nesting bullets aligned to an ordered marker's content column.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `listBlock` (collection loop across blank lines), `nestingLevels`/`buildList` (marker-width-aware nesting), and possibly `parseListItem` (to expose marker width).
- `Tests/MD2CoreTests/MarkdownRendererTests.swift`: new coverage for loose ordered lists and marker-aligned nesting; review of existing nesting tests to confirm they still hold.
- No changes to public APIs or dependencies.
