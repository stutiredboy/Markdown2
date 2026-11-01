## 1. Renderer

- [x] 1.1 Emit text cut from a bare URL's tail as the candidate's own text (`cutTailHTML`): step back over tokens, renderer escapes and scalars; fall back to the escaped spelling when the cut falls inside a unit or the units do not decode back to the tail; escape undefined entity names.
- [x] 1.2 Compare the `http://`, `https://` and `www.` prefixes and the `<` cut on Unicode scalars.
- [x] 1.3 Read the cut text decoded in the continuation guard, and fail closed when the named-entity table is missing.
- [x] 1.4 Keep `HTMLSafety.decodeEntities`'s pattern in a static.

## 2. Tests

- [x] 2.1 Add `textCutFromBareURLTailRendersAsOutsideOne`, `trailingEntityEndsAuthorityAsItsCharacterDoes`, `combiningMarkAfterSchemeIsNotAnEmail` and `fusedAngleBracketStillEndsBareURL`, plus two `&period;` rows in `spoofContinuationsStayLiteral`. Update the `&copy;` row of `bareLinks`. Confirm the new cases fail against `main`, except the rows that pin unchanged behavior (`&hl;`, `\&amp;`, a mark in the path).
- [x] 2.2 Mutation checks: a guard that reads the tail by its spelling, and a tail that keeps undefined entity names, each fail a test.

## 3. Verification

- [x] 3.1 Run `openspec validate fix-bare-url-tail-and-scheme --strict`.
- [x] 3.2 Run the full non-GUI suite with `swift test`, in the same three steps as CI.
- [x] 3.3 Compare `swiftc -O` probes with and without this change: byte-identical on every repository and local Markdown document and every CommonMark/GFM example; every differing generated input classified in `design.md`.
- [x] 3.4 Compare release-build timings with `Scripts/benchmark_inline.sh` and a probe of URLs with tails (tables in `design.md`).
- [x] 3.5 Confirm no GUI-gated path is involved: the change touches `MD2Core` rendering only (CI's `gui-tests` job runs the GUI suites anyway).

## 4. Docs

- [x] 4.1 Declare the tail rendering in the `gfm-autolinks` matrix entry, regenerate `Docs/CompatibilityMatrix.md`, and update `Docs/MarkdownSupport.md`.
- [x] 4.2 Remove the bare-URL item from `TODOS.md`, and note the duplicated-anchor shape in the authored-token item.
