## 1. Shortcut Configuration Model

- [x] 1.1 Add a typed mode shortcut model that represents key equivalent, modifiers, display label, and target `EditorMode`.
- [x] 1.2 Define default mode shortcuts as Edit `Command-1`, Preview `Command-2`, and Side by Side `Command-3`.
- [x] 1.3 Add validation helpers that reject duplicates, malformed shortcuts, existing Markdown2 command shortcuts, and macOS reserved/high-risk shortcuts.
- [x] 1.4 Persist the mode shortcut configuration in `AppSettings` with a new `UserDefaults` key and fallback to defaults when the stored value is missing or invalid.

## 2. Mode Command Routing

- [x] 2.1 Add a `ModeCommand` publisher to `DocumentStore`, following the existing `FindCommand` command-routing pattern.
- [x] 2.2 Observe `DocumentStore.modeCommand` in `ContentView` and route it through `requestMode(_:)` so shortcut-triggered switches preserve viewport anchoring.
- [x] 2.3 Add app menu commands for Edit, Preview, and Side by Side using the configured shortcuts from `AppSettings`.
- [x] 2.4 Ensure command-triggered mode switching is a no-op when no frontmost document is available and does not affect existing Esc or Cmd+double-click behavior.

## 3. Settings UI

- [x] 3.1 Add localized Settings labels for the mode shortcut section, the three mode shortcut rows, reset action, and validation errors.
- [x] 3.2 Add a compact shortcut recorder/control in `SettingsView` that captures a shortcut only while the control is active.
- [x] 3.3 Apply validation before saving a changed shortcut and keep the previous valid assignment when validation fails.
- [x] 3.4 Add a reset-to-defaults action for the three mode shortcuts.

## 4. Verification

- [x] 4.1 Add unit tests for default shortcut values, persistence round-trip, invalid stored data fallback, duplicate rejection, app-command rejection, and macOS-reserved shortcut rejection.
- [x] 4.2 Add tests or focused manual QA for `ModeCommand` routing from Edit to Preview, Preview to Edit, Edit to Side by Side, and Preview to Side by Side.
- [x] 4.3 Run the Swift test suite.
- [x] 4.4 Manually verify in the macOS app that `Command-1`, `Command-2`, and `Command-3` switch modes, custom shortcuts take effect, invalid shortcuts are rejected, and Esc/Cmd+double-click still behave as before.
