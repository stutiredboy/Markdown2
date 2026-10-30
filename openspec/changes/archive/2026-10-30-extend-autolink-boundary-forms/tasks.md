## 1. Renderer

- [x] 1.1 Add the assigned characters of U+FE10–U+FE19, U+FE30–U+FE4F and U+FE50–U+FE6B (excluding U+FE53 and U+FE67) and the invisible format characters U+00AD, U+2060, U+FEFF, U+061C, U+200E–U+200F and U+2066–U+2069 to `bareURLBoundaryCharacters`; document the excluded joiners and bidi embedding/override controls.
- [x] 1.2 Extend `bareURLStructuralLookalikes` with `︖﹒﹖﹟﹣﹫︳︴﹍﹎﹏` and document the compatibility-form rule.
- [x] 1.3 Add `compatibilityFormRange`/`compatibilityFormFolds` and fold vertical and small forms first in `normalizeContinuation`.

## 2. Tests

- [x] 2.1 Extend `bareURLBoundarySamples` to every new character, so the terminator, left-boundary and sync tests cover all 156.
- [x] 2.2 Extend `structuralLookalikesStayURLContent` and `structuralLookalikesStayInSync` to the eighteen lookalikes; add `structuralLookalikesAreTheStructuralCompatibilityForms`.
- [x] 2.3 Extend `adjacentNonNormativeCodePointsStayURLContent` with the compatibility-block neighbours, the unassigned gaps, and the excluded format characters.
- [x] 2.4 Add `compatibilityFormsAndFormatCharactersBoundReportedBareLinks` for the reported prose, BOM and bidi-wrapped cases.
- [x] 2.5 Add fold rows to `spoofContinuationsStayLiteral`, `labelExtensionStaysLiteral`, `emailSpoofContinuationsStayLiteral` and `emailProseContinuationsStillLink`; confirm each fold row fails with the fold disabled.

## 3. Compatibility artifacts

- [x] 3.1 Update the `gfm-autolinks` entry in `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`; keep the tier `Supported`.
- [x] 3.2 Regenerate `Docs/CompatibilityMatrix.md` with `MD2_REGENERATE_DOCS=1 swift test --filter CrossArtifactConsistencyTests`.
- [x] 3.3 Update the autolinks bullet in `Docs/MarkdownSupport.md`.
- [x] 3.4 Extend the token guards in `CompatibilityMatrixTests` and `CrossArtifactConsistencyTests`.
- [x] 3.5 Remove the resolved "CJK compatibility punctuation and invisible format characters in bare-URL boundaries" item from `TODOS.md`.

## 4. Verification

- [x] 4.1 Run `openspec validate extend-autolink-boundary-forms --strict`.
- [x] 4.2 Run the full non-GUI suite with `swift test`.
- [x] 4.3 Compare `swiftc -O` probes of `HEAD` and this change on real documents and boundary-dense workloads; record the numbers in `design.md`.
- [x] 4.4 Confirm no GUI-gated path is involved: the change touches `MD2Core` rendering only, so `MD2_RUN_GUI_TESTS=1` is not required.
