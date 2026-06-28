## 1. Front Matter Reader Presentation

- [x] 1.1 Add app state and localized labels for showing and hiding front matter metadata in reader surfaces.
- [x] 1.2 Update `MarkdownPreviewView` preview-only script/style state so valid leading YAML front matter is hidden from Read mode and Side by Side preview by default while remaining visible in Edit mode and shared renderer/export output.
- [x] 1.3 Add an explicit per-window reader toolbar control to show and hide front matter metadata without editing the Markdown source; reset it to hidden when the document identity changes.
- [x] 1.4 Preserve source-line metadata, outline jumps, mode-switch anchoring, and split scroll synchronization when front matter is hidden.
- [x] 1.5 Add tests for hidden default front matter, explicit metadata display, no-front-matter documents, navigation below hidden front matter, and export/shared-renderer invariance.

## 2. Image Load Diagnostics

- [x] 2.1 Add localized diagnostic text for remote image load failures and any generic fallback image-load failure state.
- [x] 2.2 Update preview broken-image JavaScript to classify failed `http` and `https` sources separately from local file, absolute path, and relative path failures.
- [x] 2.3 Ensure diagnostic source text remains inert and is inserted only as text, never markup.
- [x] 2.4 Preserve existing local-image rendering, remote-image successful rendering, PDF export, print, and self-contained HTML export behavior.
- [x] 2.5 Add tests covering missing local images, unavailable remote images, generic fallback classification, successful image rendering, and inert diagnostic text.

## 3. Toolbar Discoverability

- [x] 3.1 Add or reuse localized labels for Outline, Open, Save, Metadata, Edit, Side by Side, Read, and mode selection so toolbar text matches menu terminology.
- [x] 3.2 Update the document toolbar to show native visible action labels at the default document width while retaining compact icon-only behavior when space is constrained.
- [x] 3.3 Ensure every toolbar action and mode option exposes stable localized accessibility labels and help text in both expanded and compact presentations.
- [x] 3.4 Verify toolbar label expansion and collapse do not overlap the document surface, outline, or status bar.
- [x] 3.5 Add UI-level or view-model tests for toolbar labels, accessibility labels, localization, and mode-switch behavior preservation.

## 4. Outline Navigation Accessibility

- [x] 4.1 Refactor `OutlineSidebar` rows so each heading exposes an explicit activation action and full-title accessibility metadata.
- [x] 4.2 Add keyboard navigation for focused outline rows, including Up, Down, and Return activation.
- [x] 4.3 Track and expose selected outline state after mouse, keyboard, accessibility, and mode-switch navigation.
- [x] 4.4 Preserve the localized empty-outline state without exposing inert heading rows.
- [x] 4.5 Add tests for mouse activation, accessibility activation, keyboard activation, long headings, selected state, and empty documents.

## 5. Side by Side Layout With Outline

- [x] 5.1 Define minimum usable pane widths as 360 pt for the editor and 420 pt for the preview when split mode is active.
- [x] 5.2 Update Side by Side entry behavior so the default window/minimum size preserves usable editor and preview pane widths when the 230 pt outline is visible.
- [x] 5.3 Add constrained-width adaptation through window minimum-width enforcement/widening rather than silent outline auto-collapse.
- [x] 5.4 Preserve explicit user outline visibility; layout adaptation must not permanently change outline preference.
- [x] 5.5 Add tests for default-size split entry, constrained-width adaptation, divider minimums, resize behavior, and outline restoration.

## 6. Validation

- [x] 6.1 Run `swift test` and address any failures.
- [x] 6.2 Run targeted GUI/WebKit tests with `MD2_RUN_GUI_TESTS=1` where the environment supports them.
- [x] 6.3 Manually smoke test `/Applications/Markdown2.app` with `Examples/Sample.md` for Read, Edit, Side by Side, outline, toolbar labels, image diagnostics, and front matter visibility.
- [x] 6.4 Confirm DOCX/EPUB export remains out of scope and no new DOCX/EPUB menu items are added.
