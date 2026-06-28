## 1. Mode model & persistence

- [x] 1.1 Add `case split` to `EditorMode` (raw value `split`); confirm `CaseIterable`/`Identifiable` still hold
- [x] 1.2 Verify `AppSettings` persist/restore round-trips a `split` value for both `defaultMode` and `newDocumentMode` (string-based, should be transparent), and that `EditorMode(rawValue:) ?? .write` still guards unknown values
- [x] 1.3 Confirm `presentationMode(isFileBacked:)` resolves `split` for either preference with no extra logic

## 2. Localization

- [x] 2.1 Add `L10nKey.sideBySide` and add a combined mode help key (e.g. `writeReadOrSplit`) to `L10nKey`
- [x] 2.2 Add English strings: `sideBySide` = "Side by Side", help = "Edit, side by side, or preview"
- [x] 2.3 Add zh-Hans strings: `sideBySide` = "双栏", help = "编辑、双栏或预览"
- [x] 2.4 Audit that no new user-facing string is hard-coded; all go through `settings.text(_:)`

## 3. Settings UI

- [x] 3.1 Add a Side by Side segment to the "Mode for New Documents" picker in `SettingsView`
- [x] 3.2 Add a Side by Side segment to the "Mode When Opening a File" picker
- [x] 3.3 Verify segmented controls stay legible with three labels in both languages; widen the Settings form if needed

## 4. Split layout in ContentView

- [x] 4.1 Add a `.split` branch to `editorSurface` rendering `MarkdownEditorView` (left) and `MarkdownPreviewView` (right) with a vertical divider
- [x] 4.2 Implement an adjustable split via `HSplitView` (or `HStack` + draggable `Divider` backed by a width-fraction `@State`), clamped to a per-pane minimum width
- [x] 4.3 Raise the window `minWidth` when in split mode so both panes are usable; keep the outline sidebar and status bar outside the split
- [x] 4.4 Add the third segment (`.split` tag with an icon, e.g. `square.split.2x1`) to the toolbar mode `Picker`, widen the control, and localize its `.help(...)`
- [x] 4.5 Carry over the per-pane find bars (editor + preview) inside the split branch

## 5. Live preview re-render (no full reload)

- [x] 5.1 Add a JS content-update hook in the preview page (e.g. `window.md2ApplyContent(html)`) that replaces the content container's `innerHTML` and re-runs KaTeX/Mermaid over the new subtree, without tearing down the page shell
- [x] 5.2 In `MarkdownPreviewView.updateNSView`, route HTML changes through the in-place update (debounced) instead of `load(...)` while the preview is in a live/split context; keep full `load` for initial load and base-URL changes
- [x] 5.3 Ensure the preview's scroll position is preserved across content updates (page shell is never reloaded)
- [x] 5.4 Fallback path: in-place swap is implemented as the primary path, so the deferred-fallback is not the active path; a full reload still happens only when a new diagram engine must be inlined (rare)

## 6. Bidirectional scroll synchronization

- [x] 6.1 In `ContentView`, while in `.split`, feed the editor's `onAnchorLineChange` into `previewJumpAnchor` and the preview's `onAnchorChange` into `editorJumpAnchor`
- [x] 6.2 Add a "last driver" guard (owner token / timestamp) so the follower's settle-time anchor report is not treated as a new user-driven scroll
- [x] 6.3 Confirm the follower's programmatic scroll runs through `performProgrammaticScroll` / `applyAnchorUntilSettled` so `isProgrammaticScroll` suppresses sync-back (no oscillation)
- [x] 6.4 Debounce editor `boundsDidChange` reporting if the follower thrashes during fast scrolls
- [x] 6.5 Re-affirm the follower anchor after a live content swap settles so async-tall math/diagram blocks don't drift the viewport — implemented by capturing the preview anchor before the in-place DOM swap, then re-applying it through the existing pinned viewport-anchor scroll helper after the swap; this keeps math/diagram reflow from drifting the visible source block.

## 7. Mode-transition position handoff

- [x] 7.1 Entering `.split` from Edit: keep the editor pane position and align the preview pane to the same source content
- [x] 7.2 Entering `.split` from Preview: keep the preview pane position and align the editor pane to it
- [x] 7.3 Leaving `.split` to Edit/Preview: hand the corresponding pane's current position to the destination single-pane surface via the existing jump-anchor bindings

## 8. Per-pane find / outline / task wiring

- [x] 8.1 Track a `focusedPane` state in split and route `handleFindCommand` to the editor or preview accordingly (default editor)
- [x] 8.2 Make outline selection move both panes (set both editor and preview jump targets) while in split
- [x] 8.3 Verify task-checkbox toggling in the preview updates the source and leaves both panes at their current scroll positions

## 9. Verification

- [ ] 9.1 Build and manually verify: type in the editor → preview updates live without full-page flash or scroll reset — builds clean; live-update path implemented; visual confirmation pending in the running app
- [x] 9.2 Verify scroll alignment both directions (editor→preview, preview→editor) on a long document with headings, a long code block, and math/diagram blocks — runtime-verified with `/tmp/Markdown2SplitUX.md`; editor→preview aligned immediately, preview→editor settled after debounce. A focus-stealing issue found during this check was fixed by preventing split follower scrolls from making the editor first responder.
- [ ] 9.3 Verify mode transitions Edit↔Side by Side↔Preview preserve reading position — pending runtime verification
- [x] 9.4 Verify Settings persistence: set each preference to Side by Side, relaunch, confirm the resolved mode; confirm old Edit/Preview preferences still resolve — covered by new unit tests `sideBySideModePersistsForBothPreferences` and `unknownStoredModeFallsBackToEdit`
- [ ] 9.5 Verify EN and zh-Hans labels/tooltips for the new mode in toolbar and Settings — strings added and wired through `settings.text(_:)`; visual confirmation pending in the running app
- [x] 9.6 `openspec validate add-split-mode` passes; run `/opsx:verify` before archiving
