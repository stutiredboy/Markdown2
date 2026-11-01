## Context

`protectBareAutolinks` runs after the text is escaped, and works on the candidate: escaped text plus placeholder tokens. It cuts the candidate at the first non-literal token, so `prefix` holds only escaped text and literal tokens (entities and backslash escapes). It then reads `prefix` as authored text, `url = decodeEntities(source(in: prefix))`, and trims a tail from `url`:

1. everything from `<` on;
2. then, repeatedly, trailing `?!.,:*_~`, an excess `)`, or a trailing `&[A-Za-z0-9]+;`.

The anchor is built from what remains. The trimmed tail went back into the HTML as `escapeHTML(trailing)`.

That last step escapes **authored** text, so it is right only when the tail holds no entity. `&amp;` was an entity token in the candidate, became the spelling `&amp;` in `trailing`, and was escaped again to `&amp;amp;`. The same happens to entities in a `<` tail (`https://a.com/x<y&amp;z`).

The other two bugs are `Character`-vs-scalar mismatches in the same function. The pipeline's regexes work on UTF-16, but `hasPrefix("http://")` and `firstIndex(of: "<")` compare grapheme clusters. U+0301 after `/` or `<` forms one cluster, which equals neither.

## Goals / Non-Goals

**Goals:**
- The trimmed tail renders exactly as the same text renders outside a URL.
- The guard reads that tail the way it renders.
- A mark cannot change the scheme check or the `<` cut.
- No other output changes, and no slowdown.

**Non-Goals:**
- Changing what the trailing rule removes.
- The backslash that a `\.` at the end of a URL leaves inside the anchor.
- The source-line stamp after a leading mark (its own TODO).
- Authored placeholder tokens.

## Decisions

### Emit the tail as the candidate's own text

`cutTailHTML(in: prefix, trailing:, protector:)` finds where `trailing` begins in `prefix` and returns that suffix of the candidate. The suffix is escaped text and literal tokens, the same HTML the candidate would produce unlinked, so every construct in it keeps its meaning: an entity stays an entity, a renderer escape stays an escape, and a backslash escape stays an escape.

The walk steps back from the end over the units that `decodeEntities(source(in:))` maps to authored text:
- A token stands for its decoded source.
- One of the escapes `escapeHTML` writes (`&amp;`, `&lt;`, `&gt;`, `&quot;`) stands for one scalar.
- Any other scalar stands for itself.

Tokens come from the forward `firstToken` scan, because reading the shared-sentinel grammar backward could pair sentinels differently. Escapes can be read backward safely: in escaped text every `&` starts one of the four, and none is a prefix of another.

The result is accepted only if the walk lands on a unit boundary and the covered units decode back to exactly `trailing`. Otherwise the old `escapeHTML(trailing)` is used. That is the right answer for the case that falls inside a unit, `\&amp;`: the `&` is a backslash escape, so the author wrote the text `&amp;`.

*Alternative considered:* re-protect each trimmed entity spelling as it is moved into `trailing` (the TODO's literal suggestion). Rejected for three reasons:
- It treats `\&amp;` as an entity, so `&amp;` would show `&` where the author escaped it.
- It needs a second re-tokenizer for the `<` tail.
- It fixes one instance of the class rather than the class.

### An undefined entity name stays text

The entity pass protects any `&name;` spelling, including names HTML does not define. Mid-text, the renderer emits those raw, and a browser shows them as typed. GFM example 626 expects the trimmed `&hl;` as `&amp;hl;`, and the baseline records it as a reference match only because of the double-escape. `isUndefinedNamedReference` (a named spelling that `decodeAllEntities` leaves unchanged) therefore escapes such a token when it is emitted in the tail. A browser shows the same text either way, and the GFM example keeps matching.

When the named-entity table fails to load, every name reads as undefined, so the tail falls back to escaped text, the old output.

### The guard reads the decoded tail

The guard already prepends `trailing` to the visible continuation (punctuation removed from the URL is still visible). It now prepends `decodeAllEntities(trailing)`, which matches how the tail renders:
- `&period;` is a dot, so `` https://evil.com&period;`trusted` `` stays literal.
- `&nbsp;` is whitespace, so it ends the authority as a typed no-break space does.

If the table is missing and the tail holds a named spelling, the guard fails closed, as `visibleContinuation` already does.

At the authority-ending position, a backslash escape cannot reach the tail: whatever it leaves fails domain validation first. So reading the authored tail decoded matches the rendered tail there. Inside a `<` tail, decoding a backslash-escaped entity over-reads it, which can only make the guard stricter.

### Compare scalars for the scheme and `<`

`isURL`, the `www.` destination prefix and the `<` cut use `unicodeScalars`:
- A candidate the URL alternative matched always stays a URL.
- A `<` always ends it.
- `http://` + U+0301 + `x.com` now reaches domain validation, which rejects it because a host label cannot start with a mark. That is the right outcome; the old one was a `mailto:` link.

### Compile `decodeEntities`'s pattern once

`HTMLSafety.decodeEntities` built its `NSRegularExpression` on every call. Bare-URL linking calls it three times per candidate, and the tail check adds one call per URL with a tail. A first version of `cutTailHTML` that walked forward and decoded every token cost 5–22% on 2,000-URL documents with tails. The backward walk, plus the pattern hoisted to a static, makes the change faster than `main` everywhere it is measurable.

## Verification

### Differential run

`swiftc -O` probes of `main` (`c25f26a`) and this change rendered the same inputs.

| Corpus | Inputs | Differ |
| --- | ---: | ---: |
| Repository and local Markdown documents, CommonMark and GFM examples | 1,827 | 0 |
| Generated, fuzz | 120,000 | 76 |
| Generated, structured | 120,000 | 5,520 |

Every difference is one of these:

| Class | Count | What changed |
| --- | ---: | --- |
| Tail entity rendered as an entity | 5,536 | Anchors identical; only `&amp;NAME;` → `&NAME;` after an anchor. |
| Scheme + mark is no longer `mailto:` | 48 | The `mailto:http…`/`mailto:www.…` anchor is gone. In 10 inputs the now-literal text also renders its backslash escapes, which the wrong anchor had shown as source. |
| Guard reads a decoded `&nbsp;` | 7 | The URL now links, followed by a visible no-break space. The same text with a typed U+00A0 links on `main`. |
| Guard reads a decoded tail with a further dot | 5 | `https://a.com&amp;.&amp;.` stays literal. The guard now sees `&.&.`, and the same text typed literally is literal on `main`. |

One `&nbsp;` input also contains an authored placeholder token that duplicates the anchor before `x.trusted.com`. `main` produces the same duplicate when U+00A0 is typed in place of `&nbsp;`. That is the authored-token class, so it is recorded in the authored-token TODO and is not changed here.

### Timing

`Scripts/benchmark_inline.sh` (Apple M4, macOS 26.7, 5 samples), 2,000-fragment fastest time:

| Workload | `main` (ms) | This change (ms) |
| --- | ---: | ---: |
| `bareURLs` | 64.73 | 34.68 |
| `bareURLsWithEntities` | 81.12 | 48.23 |
| `referenceLinks` | 110.15 | 67.69 |
| `referenceLinksWithProtectedKeys` | 126.23 | 81.67 |
| `markdownLinks` | 54.18 | 43.41 |
| `bareURLs`, one per line | 78.66 | 47.76 |

The other workloads are within noise, and every workload still grows about 2× per doubling.

A probe of 2,000 URLs, each followed by `.`, `&amp;.` or `<x&amp;y`, which the benchmark does not cover, renders in 40–59 ms per document, against 68–85 ms on `main`.

## Risks / Trade-offs

- **Output changes for one more class of cut text.** Mitigation: the differential run classifies every difference, and the real-document corpora are byte-identical.
- **The tail walk adds work per URL with a tail.** Mitigation: it reads only the tail's units, and the hoisted pattern more than pays for it (timing above).
- **A missing entity table now affects tail rendering.** Mitigation: the fallback is the old escaped output, and the guard fails closed.
