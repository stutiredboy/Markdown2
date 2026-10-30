## Why

Every inline pass ends with `InlineProtector.restore(in:)`, and mid-pipeline restores and source lookups go through the same resolver, `resolveTokens`. It copied the literal text between placeholder tokens with `result.unicodeScalars.append(contentsOf:)`, which re-encodes one scalar at a time. On token-dense text that copy is about 20× slower than a bulk one. Profiling `scan-inline-delimiter-ownership` put it at roughly 14% of the dense 2,000-line workload; that change deferred it here.

The obvious fix is to append the `Substring` slice directly, and it is a trap: it made the dense workload about 7% slower overall instead of faster. A `Substring` append inherits the flags of its whole base string, and the text being resolved always holds the non-ASCII sentinel `U+E000`. Restored HTML that is pure ASCII therefore loses the standard library's ASCII flag, and every later `NSRange` conversion and regular-expression pass over it takes the UTF-16 slow path. The resolver's own time fell, but the rest of the render paid more than it saved.

## What Changes

- **Copy each literal run as `String(text[run])`.** Slicing keeps the scalar-aligned bounds exact, even mid-grapheme, and the copy rescans its bytes, so restored output that is all ASCII keeps the ASCII flag. The dense workload gets about 11% faster, and real documents are unchanged within noise.
- **Pin the mid-cluster run end.** `prependedMarkBeforeSentinelIsKept` covers a literal run that ends inside a grapheme cluster: a prepended concatenation mark (`U+0600`) joins the token's opening sentinel. The existing test covers only a run that starts mid-cluster, after a closing sentinel.
- **State both constraints** in the placeholder-restoration requirement of `inline-render-performance`: runs are copied in bulk with exact scalar bounds, and the copy does not take all-ASCII output off the ASCII fast path.

**Non-goals:**

- Token search stays a Unicode-scalar scan. A UTF-8 byte search for the sentinel's lead byte saved about 0.15 ms per 100 KB, not enough to justify checking the rest of each candidate scalar.
- The token grammar (the deferred `firstToken(in:)` refactor in `TODOS.md`), the D4 boundary, and the authored-token amplification TODO are unchanged.
- The other `unicodeScalars.append` call sites append one scalar at a time to short slugs and are not on a hot path.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `inline-render-performance`: placeholder restoration copies literal runs in bulk with exact scalar bounds, and keeps all-ASCII output on the ASCII fast path.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `InlineProtector.resolveTokens` only.
- `Tests/MD2CoreTests/InlineRenderingPerformanceTests.swift`: one new test.
- Rendered output is byte-identical. No public API, dependency, preview JavaScript/CSS, PDF/print, HTML-export, or GUI-gated path changes.
