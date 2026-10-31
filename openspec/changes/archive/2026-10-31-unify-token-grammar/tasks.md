## 1. Renderer

- [x] 1.1 Make the scalar token parser the one grammar (`InlineProtector.token(at:in:)`) and add the one scan (`InlineProtector.firstToken(in:from:limit:)`); route `resolveTokens` and `tokenIndices` through it with their entry-count limit.
- [x] 1.2 Switch the bare-URL cut in `protectBareAutolinks` to the scan (no limit; literal tokens are consumed whole) and remove the `Int()` conversion.
- [x] 1.3 Switch the continuation guard in `visibleContinuation` to the grammar, and remove `tokenPattern` and `tokenRegex`.

## 2. Tests

- [x] 2.1 Add `leadingZeroSpellingDoesNotCutBareURL`, `structuralTokenAfterSharedSentinelEndsBareURL` (non-ASCII, fullwidth, overflowing and leading-zero spellings) and `continuationReadsMalformedSpellingAsText`; confirm each fails against the regex readers.
- [x] 2.2 Mutation checks: a grammar that accepts leading zeros, a scan that consumes malformed spellings, a cut that ignores `isLiteral`, and a continuation guard that accepts leading zeros each fail at least one test.

## 3. Verification

- [x] 3.1 Run `openspec validate unify-token-grammar --strict`.
- [x] 3.2 Run the full non-GUI suite with `swift test`, in the same three steps as CI.
- [x] 3.3 Compare `swiftc -O` probes with and without this change: byte-identical output on every repository and local Markdown document and every CommonMark/GFM example; every differing generated input classified in `design.md`.
- [x] 3.4 Compare release-build timings on real documents and token-dense workloads (table in `design.md`).
- [x] 3.5 Confirm no GUI-gated path is involved: the change touches `MD2Core` rendering only, so `MD2_RUN_GUI_TESTS=1` is not required (CI's `gui-tests` job runs it anyway).

## 4. Docs

- [x] 4.1 Remove the token-grammar item from `TODOS.md` and record the three pre-existing bugs the differential run exposed.
