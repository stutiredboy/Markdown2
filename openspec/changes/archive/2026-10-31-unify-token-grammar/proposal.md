## Why

The placeholder token grammar (`\u{E000}MD2-<n>\u{E000}`) was read in three places, by two different readers. The resolver (`restore`, `source`, `attributeText`) reads it with a Unicode-scalar parser: ASCII digits only, canonical decimal, no leading zeros, overflow-safe. The bare-URL cut in `protectBareAutolinks` and the continuation guard in `visibleContinuation` read it with `NSRegularExpression` `MD2-(\d+)`. ICU's `\d` matches any Unicode decimal digit, and the cut then converted the digits with `Int()`, which accepts leading zeros.

The readers disagree only on text a document author typed with U+E000, but there they disagree in ways that matter:

- The cut read `\u{E000}MD2-00\u{E000}` as entry 0 and ended the URL there, while the resolver emits the same text literally.
- A regex match on a spelling the resolver rejects consumed its closing sentinel. When that sentinel is shared with a following real token, the cut never saw the token, so a structural token stayed inside the URL. `` `x` https://a.com/p\u{E000}MD2-١\u{E000}MD2-0\u{E000} end `` linked ``https://a.com/p\u{E000}MD2-١`x` ``: the code span's source joined the link, and the code span disappeared from the page. That breaks the rule that structural tokens end a bare URL.
- The continuation guard read such a spelling as one restored unit and skipped past its closing sentinel, so a sentinel fused into a grapheme with a combining mark was never checked. The guard's own rule says such a sentinel fails closed.

The pre-landing review of `fix-quadratic-inline-rendering` (2026-10-19) found the drift. It was deferred to `TODOS.md` ("Deferred inline review refactor (token grammar)").

## What Changes

- **One grammar, one scan.** `InlineProtector.token(at:in:)` (the former private `token(in:from:)`, now static) is the only token grammar. `InlineProtector.firstToken(in:from:limit:)` is the only token scan: a token is consumed whole, and any other sentinel is one literal scalar, exactly as the resolver reads.
- **Every reader uses them.** `resolveTokens` and `tokenIndices` pass their entry count as `limit`. The bare-URL cut and the continuation guard locate tokens with no limit, as before, so canonical spellings behave exactly as they did. `tokenPattern`, `tokenRegex` and the `Int()` conversion are removed.
- **Declare the behavior** in the placeholder-restoration requirement of `inline-render-performance`, with scenarios for the cut, the shared sentinel, and the continuation guard.
- **Add tests** that fail against the regex readers and pass with the shared scan.
- **Record three pre-existing bugs** the differential run exposed in `TODOS.md` (they reproduce on `main` without any private-use text): a trailing entity after a bare URL is double-escaped, a combining mark after `http://` or `www.` makes a bare URL a `mailto:` link, and a paragraph that starts with a combining mark gets its source-line attribute on the closing tag.

**Non-goals:**

- Index limits are unchanged. The bare-URL cut still treats a canonical out-of-range spelling as a token, and the resolver still emits it literally; the limit is resolver context, not grammar.
- The D4 boundary and the authored-token amplification TODO are unchanged.
- The three pre-existing bugs above are recorded, not fixed.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `inline-render-performance`: the placeholder token grammar is read by one scan everywhere, so text the resolver emits literally is never a token for the bare-URL cut or the continuation guard.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `InlineProtector` (grammar and scan), `protectBareAutolinks`, `visibleContinuation`.
- `Tests/MD2CoreTests/InlineRenderingPerformanceTests.swift`: three new tests in the D4 section.
- `TODOS.md`: the token-grammar item is removed; two items record the pre-existing bugs.
- Rendered output is byte-identical for documents without U+E000. No public API, dependency, preview JavaScript/CSS, PDF/print, HTML-export, or GUI-gated path changes.
