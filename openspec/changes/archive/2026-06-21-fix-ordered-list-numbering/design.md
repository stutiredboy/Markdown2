## Context

`MarkdownRenderer.listBlock` (Sources/MD2Core/MarkdownRenderer.swift:423) builds a list in three steps:

1. **Collect**: a `while` loop walks `lines` and appends every line that `parseListItem` accepts into an `items` array, stopping at the first line that is not a list item.
2. **Level**: `nestingLevels(for:)` (line 446) maps each item to a nesting level with `indent / 4` — a tab or four spaces is one level.
3. **Build**: `buildList` (line 455) recursively emits `<ul>`/`<ol>`, treating items at the same level as siblings, deeper items as nested child lists, and breaking the current list when the kind (`ordered`/`unordered`) changes at the same level.

The earlier `fix-nested-list-rendering` change introduced this and explicitly listed "loose vs. tight lists, blank-line grouping rules" and "configurable / non-4-space indentation" as **Non-Goals**. The reported document lands squarely in that gap. For section `## 6. 管理启示`:

```
1. **关键单位成本三角…**
   - 自制正常班…
   - 因此企业需要…

2. **人工成本上行…**
   - 当本地用工成本…
```

- The blank line between item 1's group and item 2 is not a list item, so the collect loop **stops** after item 1's group. Item 2 then starts a brand-new `listBlock`, so its `<ol>` restarts at `1`. Every numbered item repeats this — all render `1.`.
- Even without the blank lines, the bullets are indented 3 columns (aligned to the `1. ` marker's content column). `3 / 4 == 0`, so they are read as **level-0 siblings of a different kind**, which makes `buildList` break the `<ol>` at the kind change — again restarting numbering.

Both behaviors must change for the numbers to run `1.`–`6.` with nested `<ul>` children.

## Goals / Non-Goals

**Goals:**
- A blank line between list items continues the same list (continuous ordered numbering) when the list resumes after the blank line.
- Bullets indented to an ordered marker's content column (e.g. 3 spaces under `1. `) nest as children of that item.
- Every existing list behavior is preserved: flat/tight lists, the 4-space and 1-tab nesting step, the "2-space stays a sibling" rule, task-list checkboxes, the indented-code boundary, and blockquote-nested lists with absolute source lines.

**Non-Goals:**
- Loose-list paragraph spacing — `<li>` content stays tight (no `<p>` wrapping). Only list **continuity** changes, not the inner HTML shape.
- Multi-paragraph or lazy-continuation item bodies, fenced code / blockquotes as item children.
- Configurable indentation width.
- Full CommonMark list start-number handling (`<ol start="N">`); numbering remains the natural `1..N` of a single continuous `<ol>`.

## Decisions

### Decision A — Blank lines do not terminate a list (loose-list continuity)

Change the collect loop in `listBlock` so a blank line is absorbed only when the list genuinely continues: when a line fails `parseListItem` because it is blank, look ahead past consecutive blank lines; if the next non-blank line **is** a list item, skip the blank line(s) and keep collecting; otherwise stop. A blank line followed by a non-list line (paragraph, heading, fence, dedented prose) still ends the list, exactly as today.

Rendering stays tight: items collected across a blank line still emit `<li>content</li>` with no `<p>` wrapper. Only the grouping changes, so an `<ol>` spans the blank lines and its `<li>` count — hence its numbering — is continuous.

**Index-mapping correction (required):** the collect loop currently assumes item *i* sits at line `startIndex + i`, and `listBlock` returns `startIndex + built.next` as the next unconsumed line. Absorbing blank lines breaks that 1:1 mapping. The collect loop MUST record each item's raw `lines` index, and `listBlock` MUST resolve `built.next` (an `items` index) back to the real line index (the recorded index of the first unconsumed item, or the loop's stop index when all items were consumed). Without this, the top-level walk would resume at the wrong line.

*Alternative considered:* mark looseness and wrap item content in `<p>` like CommonMark. Rejected — it changes the HTML shape of every loose list (regressing current tight output and spacing) for no benefit to the reported symptom.

### Decision B — Nest at a 3-column step instead of a fixed 4

Replace the absolute `indent / 4` computation in `nestingLevels(for:)` with a relative one driven by a stack of the indentations at which each open level began: an item opens a **deeper** level when its indentation is at least **3 columns** greater than the enclosing level's indentation, and dropping below a level's indentation closes that level. `buildList` is unchanged — it keeps consuming the per-item `levels` array.

Why 3 is the threshold:
- It is the smallest step that still treats a 2-space indent as a sibling — preserving the deliberate `twoSpaceIndentedListItemStaysAtCurrentFourSpaceLevel` behavior.
- An ordered marker's content column is ≥3 (`1. ` = 3, `10. ` = 4), so marker-aligned bullets nest.
- A 4-space indent and a 1-tab indent (4 columns) still exceed the step, so unordered nesting and the existing multi-level/tab/ordered-under-unordered tests are unaffected.

Worked check against the section-6 shape: `1.`(indent 0, level 0, ordered) → `   - sub`(indent 3 ≥ 0+3, level 1, unordered, nested) → `2.`(indent 0 < 3, closes level 1, back to level 0, ordered, **same kind** → continues the `<ol>` as item 2). Result: one `<ol>` numbered 1..6, each with a nested `<ul>`.

*Alternative considered:* nest at the parent marker's exact content column (CommonMark). Rejected — `- ` has a 2-column content column, so a 2-space child would nest, contradicting the existing "2-space is a sibling" decision and its test.

## Risks / Trade-offs

- **Two adjacent ordered lists separated only by a blank line now merge into one continuous count.** → This matches CommonMark loose-list behavior; an intentional break still requires an intervening non-list block, as in CommonMark. Acceptable.
- **A 3-space-indented bullet under a `- ` parent now nests where it previously stayed a sibling.** → Only 2-column-or-less indentation is contractually a sibling; 3 columns is past the `- ` marker and reasonably reads as nested. No existing test covers 3-space-under-`-`, and it is not a documented behavior.
- **Index-mapping regression risk** when absorbing blank lines. → Mitigated by recording raw line indices per item (Decision A) and covered by tests that assert correct rendering of blocks following a loose list, plus existing source-line-metadata tests.
- **Tight rendering of loose lists** means no extra vertical spacing between blank-line-separated items. → Explicit Non-Goal; visual spacing is governed by preview CSS, not list grouping, and is out of scope.

## Open Questions

- None blocking. Start-number preservation (`<ol start>`) and true loose-list `<p>` spacing are possible later enhancements, intentionally excluded here.
