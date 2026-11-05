## 1. Fix

- [x] 1.1 Move the three label replacements in `wrapLongLabels` into `wrapNodeLabels`.
- [x] 1.2 Split the source around front matter, `%%{...}%%` directives, `%%` comments, and `style`, `linkStyle`, `classDef`, `class` and `click` statements, and wrap only the text between.

## 2. Tests

- [x] 2.1 Check against the bundled engine which forms Mermaid accepts, so the rendering tests use diagrams that can render.
- [x] 2.2 `testWrapLeavesLongURLInStyleUntouched` and `testWrapLeavesLongURLInClassDefUntouched`: rendered where the grammar accepts `url()`, compared as text for flowcharts.
- [x] 2.3 `testWrapLeavesLongURLInInitDirectiveUntouched`, `testWrapLeavesLongURLInMultilineInitDirectiveUntouched` and `testWrapLeavesLongURLInFrontMatterUntouched`: the value reaches the SVG.
- [x] 2.4 `testWrapLeavesLinkInClickUntouched` and `testWrapLeavesStatementAfterSemicolonUntouched`: the value reaches the SVG.
- [x] 2.5 `testWrapLeavesEveryDirectiveFormUntouched`: the forms that draw nothing or do not parse, compared as text.
- [x] 2.6 `testWrapStillWrapsLabelsBesideDirectives`: labels around every span still wrap.
- [x] 2.7 Confirm each test fails without the fix, and that removing or loosening each part of the fix fails a test.

## 3. Verification

- [x] 3.1 Run `openspec validate skip-styling-text-in-label-wrap --strict`.
- [x] 3.2 Run `swift test`.
- [x] 3.3 Run `MD2_RUN_GUI_TESTS=1 swift test --filter MermaidOffscreenRenderingTests --filter PDFExportEndToEndVerification`.
- [x] 3.4 Run `MD2_RUN_GUI_TESTS=1 swift test --filter MermaidLabelSecurityGUITests`.
