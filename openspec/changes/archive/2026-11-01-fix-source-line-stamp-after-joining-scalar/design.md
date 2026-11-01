## Context

Every top-level block, and each block inside a nested blockquote render, goes through `appendBlock`, which calls `taggedWithSourceLines(html, startLine:endLine:)`. The function inserts ` data-md2-source-line="N"` (plus `-end-line` for multi-line spans) before the first `>` of the block's HTML. Its contract, written in its doc comment, is that block HTML starts with the element's tag and every attribute value is escaped, so the first `>` ends that tag.

The search was `html.firstIndex(of: ">")`, which compares grapheme clusters. Under Unicode's grapheme rules, a `>` followed by an extending scalar or a spacing mark forms one cluster, and that cluster is not equal to `">"`. The search therefore went on to the next `>` that stands alone.

## Decisions

### Search UTF-8, not `Character`s

`html.utf8.firstIndex(of: UInt8(ascii: ">"))` returns the same index whenever the old search found the right tag. It differs only when the opening tag's `>` was fused. The index is also a `Character` boundary, because the fused cluster starts at the `>`, so inserting there is exact.

This is the same choice `HTMLEscaping` makes: an ASCII byte never occurs inside a multi-byte UTF-8 sequence.

*Alternative considered:* the scalar view, `unicodeScalars.firstIndex(of: ">")`. It is equivalent; UTF-8 matches the escaping code and skips scalar decoding.

### Leave the block parser alone

The probe for this fix also showed that a joining scalar after a block marker's space hides the marker (`# ` + U+0301, `- ` + U+0301, `- [ ] ` + U+0301). It also showed that a prepend character before `[` hides the bracket from the link scanner. Each of those is a parser change with its own tests and differential run, so they are recorded in `TODOS.md` rather than folded in here.

## Verification

### Differential run

`swiftc -O` probes of `main` (`55ec860`) and this change rendered the same inputs.

| Corpus | Inputs | Differ |
| --- | ---: | ---: |
| Repository and local Markdown documents, CommonMark and GFM examples | 1,827 | 0 |
| Generated, fuzz | 120,000 | 2,587 |
| Generated, structured | 120,000 | 0 |

Every difference is the stamp moving:
- **Same output otherwise:** with every `data-md2-source(-end)-line` attribute removed, the two outputs are identical, and each output has the same number of stamps.
- **Placement:** on this change every stamp sits on the tag that opens its line, and no output has an attribute on a closing tag.
- **Where `main` put them:** on `</p>` (706), `<a>` (462), `<code>` (380), `<span>` (361), `<br>` (316), `<em>` (187), `<img>` (173) and `</em>` (2).

## Risks / Trade-offs

- **The function stamps every block.** Mitigation: the differential run shows no change outside blocks that start with a joining scalar. `MetadataInvariantTests`, the conformance suite and both gutter GUI suites pass.
