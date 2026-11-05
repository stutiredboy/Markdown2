## 1. Measure

- [x] 1.1 Confirm the stale titles on `main` with a real language change on macOS 27.2.
- [x] 1.2 Confirm the same on CI's `macos-15` runner.
- [x] 1.3 Log `App.body` and the `.commands` closure on `main` to see whether a settings change runs them.

## 2. Commands

- [x] 2.1 Move the command tree into `AppCommands`, a `Commands` type observing `AppSettings`.
- [x] 2.2 Remove the delegate's republishing and its `ObservableObject` conformance, and keep the document re-render.
- [x] 2.3 Correct the comments on `settingsObservation`, `presentLanguageRestartPrompt`, `knownModeShortcuts` and `RecentDocumentsMenu`.

## 3. Tests

- [x] 3.1 Add `MenuLanguageGUITests`: every title and shortcut across a real change, closing Settings, changing back, commands acting afterwards, and the Mode menu following Reset Shortcuts.
- [x] 3.2 Require translated titles in `RecentDocumentsMenuGUITests`' language case.
- [x] 3.3 Confirm `MenuLanguageGUITests` fails without the fix.

## 4. Documentation

- [x] 4.1 Add the guard to `CLAUDE.md` and correct the Open Recent entry.

## 5. Verification

- [x] 5.1 Run `openspec validate retitle-commands-on-language-change --strict`.
- [x] 5.2 Run `swift test`.
- [x] 5.3 Run `MD2_RUN_GUI_TESTS=1 swift test --filter MenuLanguageGUITests --filter RecentDocumentsMenuGUITests`.
- [x] 5.4 Run `MD2_RUN_GUI_TESTS=1 swift test --filter SettingsWindowPresentationGUITests`.
- [x] 5.5 Run the whole GUI lane locally (`MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing`).
