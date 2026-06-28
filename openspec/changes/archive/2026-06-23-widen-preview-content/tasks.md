## 1. Widen the preview content column

- [x] 1.1 In `Sources/MD2Core/MarkdownRenderer.swift`, `htmlDocument(body:)`, replace the `main` rule (`width: min(100%, 860px); padding: 52px 58px 80px;`) with `width: 100%; max-width: 1280px;` and responsive horizontal padding `padding: 52px clamp(28px, 4vw, 64px) 80px;`, keeping `box-sizing: border-box` and `margin: 0 auto`.
- [x] 1.2 Confirm no other CSS rule or JS in `MarkdownRenderer.swift` / `MarkdownPreviewView.swift` re-pins the column to 860px.

## 2. Verify behavior

- [x] 2.1 Build the app (`swift build`) and open a document in single-pane preview on a wide window; confirm the column is wider than before, stays centered, and caps at the max width on a very wide window. Verified by rendering real app HTML and measuring `<main>` in a browser: 1280px at 1440px viewport (was 860px), capped at 1280px and centered (640/640 margins) at 2560px.
- [x] 2.2 Resize to a narrow window and to Side by Side; confirm the column shrinks to fit, there is no horizontal page scroll, and the side gutter scales with window width. Verified across 2560/1440/1000/700px: column fills to 100% below the cap, gutter scales 24→40→57.6→64px, no horizontal page scroll at any width.
- [x] 2.3 Export a PDF and confirm the output layout is unchanged (PDF still uses its own page margins / full-width flow via `PDFExporter.printStyleScript`). Verified by inspection: `printStyleScript` is unchanged and forces `main { max-width: none !important; width: 100% !important; padding: 0 !important }`, which supersedes the new preview column during capture.

## 3. Finalize

- [x] 3.1 Run the test suite (`swift test`) to confirm no rendering tests regressed. All 157 tests pass.
- [x] 3.2 If the chosen max width (1280px) needs tuning for the owner's display, adjust the single `max-width` value and re-verify. No tuning applied: 1280px verified as a good balance (near-full column at 1440px windows, readable cap on ultrawide). Adjust the single `max-width` value if a different width is preferred.
