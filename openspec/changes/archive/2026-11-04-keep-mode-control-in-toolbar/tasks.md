## 1. Toolbar

- [x] 1.1 Add `DocumentToolbarDensity` and `DocumentLayoutMetrics.defaultWindowWidth`, and have `makeDocumentWindow` use the named width.
- [x] 1.2 Add `CollapsibleToolbarLabel` and apply it to Line Numbers, the metadata button and the mode picker. Feed the density from `onGeometryChange`.
- [x] 1.3 Remove the picker's fixed frame, and reorder the primary group to metadata, mode picker, Open, Save.
- [x] 1.4 Add `modeSegment`, so an icon segment carries the mode's localized name.

## 2. Tests

- [x] 2.1 `DocumentToolbarGUITests`: the mode control stays visible across the width sweep in both languages, with and without front matter, in all three modes, and the toolbar's height does not change.
- [x] 2.2 The same with a long file name and with the outline shown.
- [x] 2.3 The default width shows Outline, Open, Save and the mode control's text.
- [x] 2.4 Collapsed controls keep their localized names and help.
- [x] 2.5 The compact picker switches modes and follows the store, and switching mode does not move the picker.
- [x] 2.6 Headless `PreviewReaderUXTests`: the densities collapse in order, and the default window shows the mode text.
- [x] 2.7 Confirm the GUI tests fail on the old toolbar, and that the position and accessibility tests each fail on a mutation.

## 3. Verification

- [x] 3.1 Run `openspec validate keep-mode-control-in-toolbar --strict`.
- [x] 3.2 Run the non-GUI CI steps and the whole GUI lane locally, with the skip check.
- [x] 3.3 Look at the toolbar in real composited windows, in both languages and in dark mode.
