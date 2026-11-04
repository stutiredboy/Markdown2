## 1. Measure the July constraint

- [x] 1.1 In a throwaway app with the same structure, compare entries passed from the App body with a command view's own `@ObservedObject` and `@Observable` dependencies, with Settings closed.
- [x] 1.2 Check that an `NSMenuItem` injected into the File menu or the nested submenu is still dropped on open.

## 2. Live list

- [x] 2.1 Add `RecentDocumentsModel`, which publishes `entries` and takes every list change.
- [x] 2.2 Have `RecentDocumentsMenu` observe the model, and remove the launch-snapshot comment from `MD2App.swift`.
- [x] 2.3 Have the delegate own the model, and `applicationDockMenu(_:)` read `entries`.
- [x] 2.4 Let `newDocument(store:)` take an optional store, for tests.

## 3. Tests

- [x] 3.1 Headless `RecentDocumentsModelTests`.
- [x] 3.2 `RecentDocumentsMenuGUITests`: open, name collision, reopen, first save, Clear Menu, opening after Clear Menu, pruning, rows acting on their own documents, and a language change.
- [x] 3.3 Put entries back in the App body and confirm the multi-process cases fail on the menu's list.

## 4. Verification

- [x] 4.1 Confirm the live list on screen and against the real Dock menu.
- [x] 4.2 Run `MD2_RUN_GUI_TESTS=1 swift test --filter RecentDocumentsMenuGUITests` three times with the screen unlocked.
- [x] 4.3 Run `MD2_RUN_GUI_TESTS=1 swift test --filter SettingsWindowPresentationGUITests --filter UndoHistoryGUITests`.
- [x] 4.4 Run plain `swift test`, which includes `MenuStartupImprovementsTests`, `RecentDocumentsTests` and `L10nCompletenessTests`.
- [x] 4.5 Run `openspec validate keep-open-recent-live --strict`.
