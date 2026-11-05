## Context

`wrapLongLabels` runs three regular expressions over the whole diagram source, one per bracket type. Nothing tells them which text is a node, so `url(http://example.com/long/path.svg)` matches as a node `url` with a long plain label. The wrap runs before Mermaid and on every diagram type.

## Decisions

### Protect spans, not lines

The source is split around the text that cannot hold a label, and only the pieces between are wrapped. Skipping lines by their start would miss two forms that render correctly today:

- A multi-line directive, where only the first line starts with `%%`.
- A statement after a `;`, as in `graph TD; A[x]; click A href "...";`.

### Follow how the bundled engine reads each form

The spans come from Mermaid's own patterns in `mermaid.min.js`, so the wrap and the engine agree on where each one ends:

| Form | Engine's rule | Span |
| --- | --- | --- |
| Front matter | Only at the very start of the source | `^---`, without the multiline flag |
| Directive | Anywhere, across lines, closed by `}%%` | `%%{` to `}%%` |
| Comment | Only on its own line, and `%%{` is not one | Line start, `%%(?!{)` |

The comment's `(?!{)` is required. Without it a comment match takes a directive's first line and leaves the rest exposed.

### A statement runs to the end of its line

The diagrams that accept `url()` in these statements read them with a rest-of-line lexer rule, so `classDef hot fill:red;,stroke:url(...);` in a state diagram is one statement. Stopping at `;` would expose the rest of it. In a flowchart, where `;` does end a statement, the only cost is that a label later on the same line stays unwrapped: a wider diagram, not a broken one.

### Match keywords followed by a space, in any case

A keyword needs a following space or tab, so a node id that starts with one, like `style-guide[...]` or `classes(...)`, is still a node. Case is ignored because the state lexer is case-insensitive (`CLASSDEF` works there). A flowchart keyword is case-sensitive, but a false match needs a word followed by a space, which is never `id[`, so nothing that would have wrapped is lost.

### Why `linkStyle` and `class` are listed

`linkStyle` exists only in flowcharts, which reject the values in question, so it protects no diagram that renders. It is listed because the spec names it, and so the fallback text stays as written. `class` is listed for the same family of statement, and because a one-line `class A { +run(...) }` is a definition, not a node.

## What this does not cover

The flowchart grammar rejects `url()` in `style`, `classDef` and `linkStyle`. Making those render would mean changing Mermaid, and the value is not valid there in the first place.

The wrap still changes other text that is not a node label, all of it found while checking this change:

- `subgraph sg[title]` with no space before the bracket. The spec says subgraph titles are left alone, and the form with a space is. Here the title wraps.
- Class members, sequence messages, and `gantt`, `pie` and `accTitle` titles with a long `word(...)`. Most of these show a literal `<br>`; a sequence message happens to read it as a line break.
- The fallback text of an invalid diagram shows the wrapped source, so long labels in it hold `<br/>` the author never wrote.

Limiting the wrap to flowcharts would address most of these, but it changes which diagrams wrap at all, so it needs its own change.

## Risks

- **A label stops wrapping.** A label after a statement on the same line, or one holding `;` and a keyword and a space, stays unwrapped. The diagram is wider and still correct.
- **A later engine bump changes a form.** The spans follow 10.9.8. The rendering tests would fail if a form moved, and CI's `gui-tests` job runs them on every PR.
