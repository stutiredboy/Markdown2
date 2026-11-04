## Context

The app's document windows are AppKit windows, and its only SwiftUI scene is Settings. The menu bar comes from `.commands` on that scene. Every title in that tree was read as `appDelegate.settings.text(...)`, and `MD2AppDelegate` republished `settings.objectWillChange` as its own, on the understanding that `@NSApplicationDelegateAdaptor` would then re-evaluate `.commands`.

`keep-open-recent-live` found that a view with its own dependency updates inside the tree, and recorded that what does not re-run is the App body while Settings is closed. This change measures the rest of that claim.

## Decisions

### Measure first: the App body runs once

All on `main`, with a real change through the Settings picker, and "Later" pressed by title in the restart prompt:

| Measurement | Result |
|---|---|
| Titles on macOS 27.2 | All 33 stay English, closed, open, and after Settings closes |
| Titles on CI's `macos-15` runner | The same 33 stay English |
| A log in `App.body` and in the `.commands` closure, macOS 27.2 | Each logged once, at launch, and never again, with Settings open during the change |
| Mode menu after Reset Shortcuts, macOS 27.2 | Still shows the old keys |

So the earlier wording was too narrow. Whether Settings is open makes no difference: the App body is not re-evaluated by settings changes at all, and `objectWillChange` on the app delegate does not reach it.

### Move the tree into a `Commands` type that observes the settings

`AppCommands` holds `@ObservedObject var settings: AppSettings`. A `Commands` type with a dynamic property of its own re-evaluates when that property changes, even though the App body that created it does not. One observer covers every title and shortcut, and the commands' content moves unchanged, apart from reading `settings` directly.

Every published setting now re-evaluates the tree, including a zoom step or a typography edit. That is about forty buttons, on a user action, and the titles it compares do not change. Splitting the observation to avoid it would add code to save nothing a user can see.

*Alternatives considered:*

- **A view per command group, each observing the settings.** This is the shape `RecentDocumentsMenu` uses, and it would update the items, but a `CommandMenu` takes its title as a value, so nothing inside a menu can reach the Format, Paragraph and Mode titles.
- **Set titles on the `NSMenuItem`s from AppKit.** SwiftUI reconciles its menus from the tree, so this would fight the framework, and `keep-open-recent-live` measured that it drops what the tree does not contain.
- **Correct the comments and leave the behavior.** Not needed once a live fix measured clean.

### Remove the republishing

With `AppCommands` in place, nothing reads the delegate's `objectWillChange`, and the measurement shows it never did anything for the menus. Keeping it would keep the misleading mechanism alive, so the two `send()` calls and the `ObservableObject` conformance go. The sink stays because it re-renders open documents on the next tick.

### Guard with a real language change

Writing `MD2.Language` from outside would not exercise the running app, so `MenuLanguageGUITests` drives the Settings picker through Accessibility. Expected titles come from the `L10n` table, so the suite does not repeat the translations. It compares each command's shortcut rather than the whole menu bar's shape, because standard items come and go: the Window menu lists Settings while it is open.

Waiting reads the closed menu, because a read makes AppKit update the menu and needs no focus. Only a case's last step opens one.

## Risks / Trade-offs

- **`Commands` observation is framework behavior, not a documented promise.** The suite runs on macOS 15 in CI and on the current system locally, so a change in either shows up as a failing test.
- **The restart prompt says the menu bar updates after a restart.** That is still true of what remains, so its copy stays.
