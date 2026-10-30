## 1. Renderer

- [x] 1.1 Add `VerbatimSpan` and `VerbatimSpanScanner`: one left-to-right scalar scan in which the earliest opener with a valid closer owns its span, with the code-span pairing table, the carried-over `$` and `\(` guards, atomic code spans inside math content, and the `\(` failure frontier.
- [x] 1.2 Replace `protectCodeSpans`, `protectInlineMath` and `protectInlineParenMath` with `protectVerbatimSpans` and `protectedFragment`, keeping each span's fragment and authored source unchanged; update the pipeline comment.
- [x] 1.3 Add `LinkDestinationTracker` (the scalar nearest-opener rule) and rebuild `LinkDestinationIndex` on it; feed the scan's output prefix to the tracker, with each claimed span as one opaque unit, and skip tracking when the text has no `](`.
- [x] 1.4 Keep the fast paths as byte walks and assemble output from `Substring` slices.

## 2. Tests

- [x] 2.1 Replace `dollarMathNestedInParenDelimitedMathDoesNotBreakTheDocument` with `dollarSignsInsideParenDelimitedMathReachTheEngine`.
- [x] 2.2 Add `codeSpanInsideMathIsTeXSource`, `mathDoesNotCloseInsideACodeSpan` and `earliestOpenerOwnsBetweenMathForms`.
- [x] 2.3 Add `carriedOverGuardsKeepTextLiteral` for the five previously untested guards.
- [x] 2.4 Add `linkSyntaxInsideAClaimedSpanDoesNotHideLaterParenMath`, `rejectedParenOpenerInsideDestinationDoesNotSwallowLaterMath` and `combiningMarkAfterClosingParenStillClosesTheDestination`.
- [x] 2.5 Add the `verbatimSpans`, `unpairedDollars` and `unterminatedParenMath` scaling workloads; update the two tests whose comments named the removed pass.
- [x] 2.6 Confirm the new tests fail against `HEAD`'s renderer, and that removing code-span atomicity, the failure frontier, opaque claimed spans, or any carried-over guard fails at least one test.

## 3. Compatibility artifacts

- [x] 3.1 Update the `tex-math` boundary and the `inlines` declared behavior in `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`.
- [x] 3.2 Regenerate `Docs/CompatibilityMatrix.md` with `MD2_REGENERATE_DOCS=1 swift test --filter CrossArtifactConsistencyTests`.
- [x] 3.3 Add the reading-order rule to the math bullet in `Docs/MarkdownSupport.md`.
- [x] 3.4 Remove the resolved "Left-to-right delimiter ownership scan" item from `TODOS.md` and narrow "Deferred inline review refactors" to the token-grammar half.

## 4. Verification

- [x] 4.1 Run `openspec validate scan-inline-delimiter-ownership --strict`.
- [x] 4.2 Run the full non-GUI suite with `swift test`.
- [x] 4.3 Compare `swiftc -O` probes of `HEAD` and this change: byte-identical output on every repository document and CommonMark/GFM example, every fuzz difference in a declared class, and the timing table in `design.md`.
- [x] 4.4 Fuzz the rebuilt `LinkDestinationIndex` against the previous implementation.
- [x] 4.5 Confirm no GUI-gated path is involved: the change touches `MD2Core` rendering only, so `MD2_RUN_GUI_TESTS=1` is not required.
