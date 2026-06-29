## Why

Markdown2 currently supports Esc to leave Edit mode and Cmd+double-click to enter Edit mode from Preview, but direct keyboard access to Edit, Preview, and Side by Side is inconsistent and not user-configurable. Users need predictable default shortcuts that avoid macOS reserved shortcuts and a settings surface where those defaults can be changed later.

## What Changes

- Add three default mode-switch shortcuts:
  - Edit: `Command-1`
  - Preview: `Command-2`
  - Side by Side: `Command-3`
- Persist the three shortcuts in app configuration so users can customize them later.
- Add mode-switch commands that use the configured shortcuts and switch the frontmost document directly to the requested mode.
- Keep existing Esc and Cmd+double-click behaviors working unless a future user shortcut explicitly replaces them.
- Validate configured shortcuts against duplicate assignments and reserved/common macOS shortcuts before accepting or applying them.

## Capabilities

### New Capabilities

### Modified Capabilities

- `document-presentation-mode`: Add configurable keyboard shortcuts for switching directly to Edit, Preview, and Side by Side modes.
- `split-view-editing`: Add a configured direct shortcut for entering Side by Side mode.

## Impact

- Affected code: `AppSettings`, `SettingsView`, app command/menu wiring, `DocumentStore`/frontmost document command routing, and mode-switch handling in `ContentView`.
- Affected behavior: mode switching can be invoked from menu commands and user-configurable shortcuts while preserving existing viewport anchoring.
- Dependencies: no new third-party dependency expected.
