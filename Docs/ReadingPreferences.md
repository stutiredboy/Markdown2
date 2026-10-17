# Reading preferences and statistics

## Counting

`MarkdownRenderer` derives document statistics from its rendered body through
`RenderedPlainText`, before the page shell and scripts are added. Each Han
character counts as one unit, including supplementary-plane Han characters;
Foundation word boundaries handle the remaining text. Punctuation and emoji
do not add words. Reading time remains rounded up at 240 units per minute.

Link labels and visible code count. Link targets, image paths/alt attributes,
front matter, generated TOC copies, footnote navigation, and diagram/math source
payloads do not. Footnote bodies and bibliography prose do count. A URL written
as visible text still counts as visible text. HTML entities are decoded once;
the HTML5 named-reference table comes from Python's standard `html.entities.html5`.
Characters refer to extracted text; lines refer to source lines, not wrapping.

The status bar shows selection / document units for a nonempty selection.
Editor selections are rendered as Markdown fragments using the active inline
syntax settings. Preview selections use a cloned DOM range and the same plain
text extractor, excluding UI such as broken-image messages and line numbers.
Counting is debounced, runs off the main actor, and discards stale results.
Clearing the selection or switching modes returns to document statistics.

## Outline

The active heading is the last heading at or above the visible source line.
The editor's viewport callback and the preview's block anchor drive it; in
Side by Side the pane driving scroll synchronization owns the active section.
Jump requests are transient, while the current section survives their consumption.

## Typography

Settings → Typography provides system, serif, and monospaced font families,
separate choices for editing and reading, and a 12–32pt base font size.
Zoom ranges from 50% to 200% in 10-point increments: `Cmd++` or `Cmd+=` zooms
in, `Cmd+-` zooms out, and `Option+Cmd+0` resets zoom while retaining the base font size.
Those shortcuts are reserved against custom mode shortcuts.

Reading widths are narrow (640px), comfortable (800px, default), wide (1100px),
and full width. These are outer maximum widths, including responsive padding.
Preferences persist under `MD2.Typography` and update open document windows.
Editor styling preserves native text, selection, IME composition, and undo.
Preview styling is injected only into the live view; PDF, print, and HTML exports
retain their own layout. Custom CSS themes are outside this change.

## Verification

```sh
swift test
MD2_RUN_GUI_TESTS=1 swift test --filter ReadingImprovementsGUITests --filter MarkdownEditingGUITests --filter UndoHistoryGUITests
```
