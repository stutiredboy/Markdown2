## 1. Renderer

- [x] 1.1 Copy each literal run in `InlineProtector.resolveTokens` as `String(text[run])` instead of appending through `unicodeScalars`, and document why the direct `Substring` append is rejected.

## 2. Tests

- [x] 2.1 Add `prependedMarkBeforeSentinelIsKept` for a literal run that ends inside a grapheme cluster; confirm a `Character`-granular sentinel search fails it.

## 3. Verification

- [x] 3.1 Run `openspec validate speed-up-token-restore --strict`.
- [x] 3.2 Run the full non-GUI suite with `swift test`.
- [x] 3.3 Compare `swiftc -O` probes with and without this change: byte-identical output on every repository document, CommonMark/GFM example and differential-corpus input, and the timing table in `design.md`.
- [x] 3.4 Confirm no GUI-gated path is involved: the change touches `MD2Core` rendering only, so `MD2_RUN_GUI_TESTS=1` is not required.
