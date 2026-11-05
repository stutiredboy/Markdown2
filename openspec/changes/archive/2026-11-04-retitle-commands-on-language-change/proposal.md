## Why

Changing the app language in Settings leaves every menu command in the old language until a relaunch, although comments on `settingsObservation` and `presentLanguageRestartPrompt` say the commands update at once. A real change through the picker shows it: `MD2.Language` becomes `zhHans`, and all 33 app-owned titles stay English, with the menu closed or open, and after Settings closes. `main` behaves the same on macOS 27.2 and on CI's `macos-15` runner, so this is not a regression in a new system.

The cause is wider than the titles. The App body and its `.commands` closure each run once, at launch, and no settings change runs them again. Publishing from the app delegate has no effect on them. So the Mode menu's shortcuts are frozen in the same way: after Reset Shortcuts, the menu still shows the old keys.

## What Changes

- **The command tree observes the settings itself.** The tree moves from `.commands` into `AppCommands`, a `Commands` type with `@ObservedObject var settings`. Titles re-title at once, including the Format, Paragraph and Mode menus' own titles. The commands' content is otherwise unchanged.
- **The Mode menu shows the configured shortcuts at once**, through the same observation.
- **The delegate stops publishing.** `objectWillChange.send()` never reached the commands, so the two calls and the `ObservableObject` conformance go. The settings observation stays for what it really does: re-rendering open documents.
- **Comments and guidance say what the app does.** `CLAUDE.md`, the Open Recent suite and the comments that said the freeze applied only while Settings is closed now say that the App body runs once.
- **Tests:**
  - The new `MenuLanguageGUITests`: a real language change through the Settings picker, in both directions and across closing Settings, checks every app-owned title and shortcut; the commands still act afterwards; and the Mode menu follows Reset Shortcuts.
  - `RecentDocumentsMenuGUITests`' language case now requires the translated titles. It only had to stay in step with the other commands while nothing re-titled.

**Non-goals:**

- Standard AppKit items (the File and Edit menus' own titles, Undo, Copy, Minimize, …) still change only on a relaunch. They are built from the process localization at launch, and the restart prompt stays for them.
- The restart prompt's copy does not change.
- `knownModeShortcuts` stays. The menu no longer keeps an old key equivalent, so it may now be removable, but showing that takes real key events.

## Capabilities

### New Capabilities

- `menu-command-localization`: the app's own menu commands follow a language change, and the Mode menu follows the configured shortcuts, without a relaunch.

### Modified Capabilities

None.

## Impact

- `Sources/MD2App/MD2App.swift`: `AppCommands`, holding the command tree.
- `Sources/MD2App/MD2AppDelegate.swift`: no `ObservableObject`, no republishing, corrected comments.
- `Sources/MD2App/SettingsView.swift`: corrected comment.
- `Tests/MD2CoreTests/`: the new `MenuLanguageGUITests`, and `RecentDocumentsMenuGUITests`.
- `CLAUDE.md`: a guard entry, and the corrected Open Recent entry.
- No change to documents, stored settings or exports.
