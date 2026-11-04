## Why

Audit item F10: the Edit / Side by Side / Preview control falls into the toolbar's overflow menu, and it is the first item to go. It is worse than the audit recorded, because it happens at the default window size. Measured on `main` at 7a2ba51 (macOS 27.2, Side by Side, outline hidden), a window opens 980 pt wide and the control is hidden at these widths:

| Language | Front matter | Hidden at | First visible at |
|---|---|---|---|
| zh-Hans | yes | 800, 900, 980 | 1100 |
| zh-Hans | no | 800 | 900 |
| English | yes | 800, 900, 980, 1100 | 1300 |
| English | no | 800, 900, 980 | 1100 |

So a new English window has no visible mode control, with or without front matter.

Two things cause it. `NSToolbar` overflows from its trailing end, and the picker was the last item. And the picker's `.frame(width: 280)` reserved 280 pt for three icons that need 115.5 pt.

That frame also hid a second problem. It came with `improve-preview-reader-ux`, which removed the picker's `.labelStyle(.iconOnly)` so that its text would show. A toolbar's default label style is icon-only, so the text never appeared, and the mode control has not met the spec's default-width rule at any width.

## What Changes

- **The toolbar's labels depend on the window width.** There are three densities, and the width alone chooses between them:
  - From 1160 pt, every control shows its text.
  - From 960 pt, Line Numbers and the metadata button drop to their icons. This includes the 980 pt default.
  - Below 960 pt, the mode picker drops to icon-only segments too.
- **The mode picker shows real text** at the default width and above, for the first time. The fixed 280 pt frame is gone, so the picker takes its natural width.
- **The trailing group is reordered:** metadata, mode picker, Open, Save.
  - The picker sits left of Open and Save, so it is the last of them to overflow, even if a future macOS needs more room than these widths allow.
  - The metadata button sits on the group's leading end. It comes and goes with the mode, and the group is anchored to the trailing edge, so there it cannot push the picker out from under the pointer that just switched mode.
- **Icon-only segments expose the mode's name in the app's language.** Their accessibility label used to be the SF Symbol's own description in the system language, such as `拆分为二乘一的矩形` for Side by Side. `accessibilityLabel` on a segment's label never reached the segment.
- **Tests:**
  - New `DocumentToolbarGUITests`, gated on `MD2_RUN_GUI_TESTS`: the width matrix in both languages, with and without front matter, in all three modes, plus long file names, a shown outline, the default-width labels, collapsed names and help, switching from the compact picker, and the picker staying put across a switch.
  - Headless tests in `PreviewReaderUXTests` pin the order of the densities and that the default window shows the mode text.

**Non-goals:**

- Mode switching, its shortcuts and viewport anchoring do not change. The picker keeps its binding through `requestMode`.
- No change to the window's minimum widths.
- Outline, Open and Save keep their text at every width.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `document-toolbar-discoverability`: adds that the mode control stays in the toolbar at every width and does not move when the mode changes. The existing default-width rule stands unchanged: it turned out to be achievable, and the mode control now meets it.

## Impact

- `Sources/MD2App/ContentView.swift`: the `.toolbar` block, the new `DocumentToolbarDensity` and `CollapsibleToolbarLabel`, and `DocumentLayoutMetrics.defaultWindowWidth`.
- `Sources/MD2App/MD2AppDelegate.swift`: `makeDocumentWindow` uses the named default width.
- `Tests/MD2CoreTests/DocumentToolbarGUITests.swift`, `Tests/MD2CoreTests/PreviewReaderUXTests.swift`, `CLAUDE.md`.
- The picker moves left of Open and Save, and shows text where it showed three icons.
- No change to rendered HTML or exports.
