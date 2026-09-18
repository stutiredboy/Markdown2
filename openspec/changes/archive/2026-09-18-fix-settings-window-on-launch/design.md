## Context

Document windows in this app are AppKit-managed (`NSWindow` + `NSHostingView`, one `DocumentStore` per window) so that closing, tabs, cascading, and the unsaved-changes prompts stay under app control. That architecture is deliberate and stays. Its consequence here: the app declares exactly one SwiftUI scene — `Settings` — because there is no `WindowGroup`.

SwiftUI presents the app's only scene at launch when the executable was linked below the macOS 15 SDK, and does not when it was linked at or above it. The shipped binary is linked below: the package declares a macOS 14 platform, SwiftPM links with `-target arm64-apple-macos14.0`, and the recorded `LC_BUILD_VERSION` ends up `minos 14.0, sdk 14.0` — so the framework takes the legacy path and presents the Settings window at launch, before `applicationDidFinishLaunching` runs. Because Finder double-click, `open`, and the file-argument path all *launch the app*, the user sees the window appear every time they open a document too.

Evidence gathered in a dev build on macOS 26 (SDK 27), all reproducible:

- The window exists and is key before the app's own launch code runs: `title=Markdown2 设置`, `class=AppKitWindow`, `identifier=com_apple_SwiftUI_Settings_window`, frame 480×450 (matching `SettingsView`'s width). It is present at the start of `applicationDidFinishLaunching`, and with a file argument it sits beside the document window.
- `otool -l` on the built binary records `minos 14.0, sdk 14.0`, while its own object file records `minos 14.0, sdk 27.0`: the downgrade happens in SwiftPM's link step, not in any source.
- Re-linking the same objects by hand with an explicit `-Xlinker -platform_version macos 14.0 27.0` records `sdk 27.0` (source unchanged).
- A minimal SwiftPM-built app whose only scene is `Settings` reproduces the window; bisecting the recorded SDK version in that app: `14.4` → window presented, `15.0` and `26.0` → no window. So the gate is the link-time SDK version, at 15.0.
- Adding `platforms: [.macOS(.v15)]` to that minimal app makes SwiftPM record `minos 15.0, sdk 15.0` and the window disappears with no code change.
- `.defaultLaunchBehavior(.suppressed)` on the same minimal app removes the window *even when it is still linked as `sdk 14.0`*.
- In this app, with the modifier applied: a no-arg launch leaves 0 windows; a document launch shows only the document window; performing the app menu's ⌘, item afterwards opens the Settings window (480×450, same identifier) with the full UI.

Constraints found while trying to keep macOS 14 working (all verified by compiling):

- `SceneBuilder` offers `buildOptional` and `buildLimitedAvailability` but no `buildEither`, so `if #available(macOS 15.0, *) { … } else { … }` does not compile ("Closure containing control flow statement cannot be used with result builder 'SceneBuilder'").
- Two optional branches in one scene body do not compile either ("generic parameter 'S' could not be inferred").
- A single `if #available(macOS 15.0, *)` without `else` compiles, but on macOS 14 it produces the builder's empty scene: no Settings scene at all, i.e. no Settings window and no Settings… menu item.
- There is no public `AnyScene` to type-erase the branches, and `_EmptyScene` is underscored.
- A modifier cannot be applied to a control-flow block inside a `SceneBuilder` closure — relevant only to the availability-gated forms above, which are rejected; with the floor at 15 the body is a single expression and `.commands` attaches directly.
- A custom `@main` entry dispatching between two `App` types (a 15+ `App` carrying the modifier, a plain one for 14) **does** compile (verified on the macos14.0 target, Swift 6) — availability branching is inexpressible only *within one scene body*. Rejected anyway: on macOS 14 the plain app still presents the bug (no suppression API exists to call there), and that branch is untestable on the development machine (macOS 26).

## Goals / Non-Goals

**Goals:**

- No Settings window appears for any launch path (direct launch, launch-with-document, reopen), while the Settings window and its app-menu command keep working.
- A guard that fails loudly if the window starts being presented again — the failure mode is a window that reappears, which throws nothing and passes silently in every non-GUI suite.
- Record why the platform floor is macOS 15, so a future reader does not lower it or delete the modifier as redundant.

**Non-Goals:**

- Replacing the AppKit document-window architecture with `WindowGroup`/`DocumentGroup` scene(s).
- Changing how SwiftPM records the SDK version, or otherwise opting the whole app into or out of other frameworks' linked-on-or-after behaviors beyond what the macOS 15 floor implies.
- Any per-OS-version branching of the scene (see Decisions) or any redesign of the Settings UI.
- Making the new guard run in CI (the headless GUI lane is still listed in `TODOS.md`).

## Decisions

**1. Opt the scene out of launch presentation with `.defaultLaunchBehavior(.suppressed)`, rather than fixing the link.**

The alternative — making the binary record the true SDK version (`-Xlinker -platform_version macos 14.0 <sdk>`) — was verified to remove the window. It was rejected as the primary fix because that single field flips *every* "linked on or after macOS 15" behavior in every framework the app loads (AppKit, WebKit, Foundation, SwiftUI), a blast radius that cannot be reviewed or tested from here, in exchange for a symptom we can address directly. The attribution is also inverted for this project: the project wants the *scene* to stop being presented, not the app to pretend it is newer than its declared floor.

Alternatives considered and rejected for the same reason:

- Dismissing the auto-presented window at launch from AppKit — works, but depends on the private identifier `com_apple_SwiftUI_Settings_window` and degrades silently if Apple renames it.
- Declaring a decoy second scene so `Settings` is no longer the only scene — no scene type on macOS 14 presents nothing at launch (`WindowGroup`/`Window` open a window, `MenuBarExtra` adds a menu bar item), and a modifier cannot be applied conditionally.

**2. Apply the modifier unconditionally and raise the platform floor to macOS 15, instead of availability-gating the scene.**

Availability-gating is not expressible (see Context): with `SceneBuilder`'s missing `buildEither`, the only compiling forms either lose the Settings scene entirely on macOS 14 or keep the bug there. Losing the Settings window and its menu command on macOS 14 is a functional regression, so the choice was between keeping the bug on 14, an AppKit workaround for 14, or raising the floor. The floor was chosen deliberately as a product decision: the fix becomes unconditional, the code carries no version branch, and macOS 15 is honest about what the app now needs.

This has a second effect worth stating plainly: SwiftPM records the deployment target as the SDK version, so raising the floor to 15 makes the binary record `sdk 15.0` and the app *also* becomes "linked on or after macOS 15" for every other framework gate. That is unavoidable for an app that claims 15+ — and it is why the modifier is best described as the explicit, toolchain-independent statement of intent, while the linkage change is what an unmodified floor would already produce. Both are kept on purpose: the modifier is what survives someone lowering the floor again.

**3. Keep the Settings scene; do not hand-roll an AppKit settings window.**

The scene is what supplies the app menu's Settings… item and the standard ⌘, wiring, and it was verified to keep working after suppression. A hand-rolled window would have to recreate that menu wiring, and a SwiftUI `App` body must declare at least one scene anyway, so removing the scene would just move the problem.

**4. Apply the modifier inline; no scene-property split.**

An earlier draft split the scene into a `settingsScene` property so `.commands { … }` could attach around an availability branch. That branch is rejected (Decision 2), and with the floor at 15 `body` is a single expression: `Settings { … }.defaultLaunchBehavior(.suppressed).commands { … }` compiles inline (verified). Keeping the split would preserve indirection whose stated reason no longer exists.

**5. Guard the behavior, not the modifier.**

A new GUI-gated suite (`MD2_RUN_GUI_TESTS=1`, per repo convention) launches the *built app bundle* and asserts the visible window set across the launch matrix: nothing at a direct launch, only the document at a launch-with-document (both file-argument and URL delivery — `application(_:open:)` is a different path from `fileURLFromLaunchArguments`), no Settings window on re-activating a running instance, the Settings window appears on the menu command and re-opens after being closed, and a relaunch after quitting with Settings open does not restore the window. It must assert both directions — a suppression that also broke the command would otherwise pass a one-sided check. Properties that matter for the test's design:

- It must not touch the developer's real app state (`dev.codex.md2.debug` preferences, recent documents, the autosaved Settings frame). So it builds a test-identity bundle through `RuntimeAppBundleBuilder` (extended with an optional `bundleIdentifier` parameter, default unchanged) and deletes that domain afterwards, rather than launching the real bundle id or plist-editing a copy inside the test.
- It reuses the existing `MD2_HEALTH_FILE` launch probe (`LaunchHealthReporter`) for the in-process window inventory instead of inventing a second reporting channel; the probe is extended to name the windows it saw and to write fresh snapshots at each observed lifecycle stage (`didFinishLaunching`, reopen, open-URLs) so post-launch assertions read evidence from the moment being tested, not a stale launch-time list.
- Every absence assertion is preceded by a positive control: the probe's stage line and per-window inventory must be present (and in document cases, the document window must be identified) before "no Settings window" may pass. A missing, unread, or format-drifted inventory fails the guard instead of passing it vacuously.
- Cases that perform the app menu's Settings command or observe windows across processes require Accessibility trust for the calling test process. The suite probes `AXIsProcessTrusted` first and, when untrusted, skips with a loud, actionable message (grant path and reason) — visible degradation, not silent one-sidedness. Settings-window visibility after the command is observed through the AX windows attribute under the same trust.
- Health-file reads poll with a timeout, and teardown terminates the launched app instance; the direct-launch and Settings-command cases share one app instance (assert absent → invoke → assert present → close → re-invoke → assert present).

## Risks / Trade-offs

- **[Dropping macOS 14 is user-visible and BREAKING]** → The floor must be raised in all three places that decide whether the app runs — `Package.swift`, `DirectLaunchBootstrap`'s generated runtime plist, and `Scripts/package_app.sh`'s release plist. If any is missed, the app installs on macOS 14 and then fails (a missing SwiftUI symbol) instead of being refused by the installer. Tasks cover all three plus a check of the built plist.
- **[The linkage change flips other frameworks' macOS 15 behaviors app-wide]** → Accepted as the cost of the floor (see Decision 2). It is gated at 15, not at the newest SDK, so the flip set is the smallest one that supports the stated floor. Smoke-test the surfaces that depend on window/menu behavior (launch, mode switching, find bar, export/print) as part of this change rather than assuming they are unaffected.
- **[The suppression could be deleted later as "redundant" now that the linkage also suppresses it]** → Keep it, with a comment stating why both layers exist, and let the guard fail if the behavior returns.
- **[A one-sided guard passes while Settings is unreachable]** → The guard asserts the Settings window opens on request as well as its absence at launch.
- **[The guard never runs in CI]** → Same limitation as every other GUI-gated suite (documented in `CLAUDE.md`; the CI lane is tracked in `TODOS.md`). The guard is therefore also documented in `CLAUDE.md`'s testing section so that a change to the launch or settings wiring triggers a local run, and the manual verification recipe (`MD2_HEALTH_FILE`) is recorded with it.
- **[The window inventory could be asserted incorrectly under tabbing/activation]** → The assertion is on the presence of a window whose identifier is `com_apple_SwiftUI_Settings_window` or whose title is the localized Settings title, not on raw window counts (the app already has a hidden `TUINSWindow` in its list during launch, which a count-based assertion would trip over).
- **[All GUI evidence comes from macOS 26; macOS 15 behavior is unverified]** → The suppression API is documented macOS 15+, but its behavior on 15 itself cannot be observed from the development machine. This epistemics is recorded explicitly, and behavioral verification on 15 is bound to the headless GUI CI lane (`TODOS.md`), which lands on `macos-15` runners — the same image `release.yml` builds on.
- **[The guard is the repo's first multi-process GUI test and needs Accessibility trust]** → Menu performance and cross-process window observation require the calling process to hold Accessibility trust; without it the command-direction cases would fail misleadingly or degrade to one-sided. Handled by the explicit `AXIsProcessTrusted` probe and loud skip (Decision 5), with the grant path documented in `CLAUDE.md`.

## Migration Plan

No data or preference migration: the change removes a window presentation, adds none, and touches no persisted key (the Settings window's autosaved frame is left as-is). Users on macOS 14 stop being able to install or launch the app; the release notes for the version carrying this change must say so. Rollback is deleting the modifier and lowering the three platform declarations — independent, no state to unwind.

## Open Questions

- Does the release build's ICU/SDK version on the `macos-15` CI runner change anything about the guard's expectations? The guard is skipped in CI today, so this only matters when the headless lane from `TODOS.md` is built.
- Should the macOS 15 floor be accompanied by the still-unsynced `launch-window-behavior` capability (declared by the archived 2026-06-24 change, absent from `openspec/specs/`)? Out of scope here; flagged so the gap is not lost.
