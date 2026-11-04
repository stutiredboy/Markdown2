## Context

The app's document windows are AppKit windows, and its only SwiftUI scene is Settings. `MD2AppDelegate` is observed through `@NSApplicationDelegateAdaptor`. The menu bar comes from `.commands` on that scene.

`RecentDocumentsMenu` took its entries as a `let` from the App body. The July 2026 design (`openspec/changes/archive/2026-07-03-add-recent-documents-menu/design.md`) tried to refresh it and failed, and concluded that the command tree is frozen while Settings is closed and that only moving the whole menu bar to AppKit would lift the limit.

## Decisions

### Observe the list in the command view, not in the App body

Measured in a throwaway app with the same structure (Settings as the only scene, AppKit window, macOS 15 floor), on macOS 27.2:

| Shape | After the model changes with Settings closed |
|---|---|
| Entries as a `let` from the App body (the old shape) | Body never re-evaluated, menu stale |
| `@ObservedObject` on the view that holds the `Menu` | Body re-evaluated, menu current |
| `@Observable` read in that view's body | Body re-evaluated, menu current |
| `@ObservedObject` on a child view inside the `Menu` | Body re-evaluated, menu current |

So the July finding is narrower than it read. What does not re-run is the App body, and with it everything it passes down. A view inside the command tree that has a dependency of its own still updates, with Settings closed, no window open and the app inactive. The July attempts all drove the menu from the App body or from the delegate, so they all hit the frozen part. This was not a change in macOS or the SDK that made a new route possible, as far as we can tell: nothing here needs the macOS 15 floor.

`RecentDocumentsMenu` now holds `@ObservedObject var recents: RecentDocumentsModel`. It keeps taking its titles from the App body, like every other command.

*Alternatives considered:*
- **Inject an `NSMenuItem`.** Measured again, and it is still dead. The nested submenu has its own delegate (`SharedMenuDelegate`, not `AppKitMainMenuItem`), which looked like a way in, but an item added to it is dropped on open just as one added to the File menu is. Only items in SwiftUI's tree survive the reconcile.
- **Move the menu bar to AppKit.** Not needed, and it would replace every command.

### One published list for both menus

`RecentDocumentsModel` wraps the recorder and publishes `entries`. Every change goes through it (`note`, `remove`, `clear`), and both File ▸ Open Recent and `applicationDockMenu(_:)` read `entries`, so the two menus cannot disagree on order or titles. `ObservableObject` matches the rest of the app. The recorder and `RecentDocumentsList` are unchanged.

### `newDocument(store:)` takes an optional store

`DocumentStore.saveLocationPicker` is injected through `init`, and the delegate's `makeDocumentStore()` does not pass it. The default parameter lets a test put a store with a known save location behind a real `DocumentWindow`. Production callers are unchanged.

### How the GUI suite gathers its evidence

`RecentDocumentsMenuGUITests` drives the real app in a bundle with its own identifier. Getting this to be reliable taught the following, each measured:

- **Read the menu after a reconcile.** `NSMenu.items` is not current until `menuNeedsUpdate:` has run, which happens on open and on an Accessibility read. An in-process dump without that shows stale items even when the menu is fine.
- **Wait on the closed menu, and open it once at the end.** The closed read needs no focus. Opening a menu on every poll failed when someone was using the machine (`the File menu did not close`, 6 failures in two runs). With polling on the closed menu, the same conditions passed 24 of 24. Each case still ends by opening the menu, because the reconcile on open is what dropped the July items.
- **`kAXCancelAction` closes a menu but can lose the next press,** so it is only used as a case's last step.
- **Report the store with a stale list.** A stale menu (store moved on) and a lost press (store unchanged) otherwise look the same.
- **A locked screen does not stop Accessibility.** Menus still answer, but no menu is drawn and windows report the role `AXApplication`, so the window-based cases fail and passes prove nothing about pixels.

The first save is covered in two hops: in-process, a real save through a real `DocumentWindow` reaches `RecentDocumentsModel`, and the multi-process cases show the model reaching the menu. The save panel itself is not driven: it is OS UI that a shared desktop can take focus from.

## Verification

All on macOS 27.2 with the screen unlocked, checked before and after each run. An earlier pass ran under a locked screen and was discarded.

- **On screen:** a screenshot of the real app shows a file opened after launch at the top of File ▸ Open Recent, above the launch entry.
- **The guard catches the bug:** with entries passed from the App body again, all 8 multi-process cases fail, on the menu's list, for example `["Seeded.md"]` against `[]` while the store holds `[]`. `testFirstSaveReachesTheListTheMenuReads` still passes then, as it should: it stops at the model.
- **With the fix:** `RecentDocumentsMenuGUITests` passes 9 of 9, three runs in a row.
- **The Dock menu:** read through Accessibility on a live instance. Its app section was `Gamma.md, Alpha.md, Beta.md`, the same as the File menu, with `Gamma.md` opened in that session.
- **Nothing else moved:** `SettingsWindowPresentationGUITests` and `UndoHistoryGUITests` pass 25 of 25, and plain `swift test` passes, including `MenuStartupImprovementsTests`, `RecentDocumentsTests` and `L10nCompletenessTests`.

Not covered here: macOS 15 could not be run locally, so CI's `gui-tests` lane is the check for the platform floor. No test drives the real save panel.

## Risks / Trade-offs

- [SwiftUI could stop updating a command view's own dependency in a future release] → the suite fails loudly on it, and CI runs it on macOS 15 as well as on developers' machines.
- [A second running instance writes the list and this one does not notice] → unchanged in effect. The Dock menu used to reread the defaults on each open, and now reads the same published list as the File menu, so the two menus still agree with each other. Recents written by another instance appear on the next launch or the next change here.

## Non-goals and a finding left open

Live language switching of menu titles does not work on macOS 27.2, and this change does not address it. With Settings open and the language changed for real (`MD2.Language` is `zhHans`), every command in the File menu keeps its old title until a relaunch, whether the menu is read closed or open, and Open Recent behaves the same with the old shape. That contradicts the comments in `MD2AppDelegate` and `SettingsView`. It is outside F11, so the new test pins what this change owns: Open Recent stays in step with the other commands, and the list stays live after a language change.
