## Why

Today a document is shown either in Edit or in Preview, and the user must toggle
back and forth to see how their Markdown renders. Users have asked for a
**Side by Side** mode where they can write on the left and watch the rendered
output update on the right at the same time, removing the constant mode-toggling
from the writing loop.

## What Changes

- Add a third presentation mode, **"Side by Side"** (内部标识 `split`；zh-Hans
  「双栏」), that shows the editor and a live preview in one window: editor on the
  left, rendered preview on the right.
- The preview pane re-renders as the user types, reusing the existing
  `DocumentStore` render pipeline (no manual mode toggle needed).
- The two panes stay vertically aligned: scrolling one pane scrolls the other to
  the corresponding source position, reusing the existing `ViewportAnchor` /
  viewport-reader machinery but applied **continuously and bidirectionally**
  instead of once per mode switch.
- Add Side by Side as a third option in the toolbar mode picker and in **both**
  Settings mode pickers (Mode for New Documents, Mode When Opening a File).
- Add the new user-facing strings to the i18n table (English + Simplified
  Chinese) so nothing ships untranslated.

## Capabilities

### New Capabilities
- `split-view-editing`: the simultaneous edit-and-preview surface — a left editor
  pane and right live-preview pane in one window, live re-render on edit,
  bidirectional synchronized scrolling that keeps the panes aligned, and the
  per-pane find/outline/task behaviors carried over from the single-pane modes.

### Modified Capabilities
- `document-presentation-mode`: the set of selectable modes grows from
  {Edit, Preview} to {Edit, Side by Side, Preview}. Both the new-document and
  opened-file mode preferences SHALL be able to hold and persist the Side by Side
  value, and Settings SHALL expose it, localized in English and Simplified
  Chinese.

## Impact

- **Code**: `EditorMode` (new `split` case); `ContentView` (render both surfaces
  in a split layout, drive bidirectional scroll sync, route find to the focused
  pane, expand the toolbar picker to three segments); `SettingsView` (three-way
  pickers); `AppSettings` (persist/restore the third value — already string-based,
  so largely transparent); `AppSettings.L10nKey`/`L10n` (new localized strings).
- **Reused machinery**: `ViewportAnchor`, `EditorViewportReader`,
  `PreviewViewportReader`, and the editor/preview source-line anchor reporting —
  now consumed live rather than at switch time.
- **No data/format changes**: documents on disk are unaffected; this is purely a
  presentation/UX addition. Existing saved mode preferences remain valid.
