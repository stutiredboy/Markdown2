## Why

Every time the app launches — including the common "open a document from the Finder" path, which launches the app — a Settings window appears by itself, on top of the document the user asked for. The user has to close it every time, and it makes the app look misconfigured.

The cause is a SwiftUI scene rule meeting how this app is built. Document windows are AppKit-managed (`NSWindow` + `NSHostingView`), so the app's only SwiftUI scene is `Settings`. SwiftUI decides whether to present that scene at launch from the SDK version recorded in the executable's `LC_BUILD_VERSION` (`sdk 14.0`, because the package declares a macOS 14 platform and SwiftPM links the binary that way); below macOS 15 the framework takes its legacy path and presents the app's only scene at launch, and at `sdk >= 15` it does not. Verified on this machine: the window exists and is key before `applicationDidFinishLaunching` runs (`title=Markdown2 设置`, `identifier=com_apple_SwiftUI_Settings_window`), and re-linking the same objects with an explicit `-platform_version ... 27.0` removes it with no source change.

## What Changes

- **Stop the Settings scene from being presented at launch.** Apply `.defaultLaunchBehavior(.suppressed)` to the Settings scene. The app menu's Settings… (⌘,) still opens the window on demand — verified after suppression.
- **BREAKING: raise the minimum supported macOS from 14.0 to 15.0.** The suppression API exists only in macOS 15+, and SwiftUI's `SceneBuilder` cannot express an availability-conditional scene (it has no `buildEither`; `if #available` without `else` compiles, `if #available … else …` and two optional branches do not) — so "suppress on 15+, keep the plain scene on 14" is not expressible in one scene body. A custom `@main` two-`App` dispatch does compile, but was rejected: on macOS 14 the plain app keeps the bug, and that branch is untestable on the development machine. Raising the floor makes the fix unconditional and drops the branch entirely. The SwiftPM platform declaration and both app-bundle `Info.plist` producers (`DirectLaunchBootstrap`'s runtime bundle builder and `Scripts/package_app.sh` for the release DMG) must agree, or the app would still install on macOS 14 and then fail.
- **Add a GUI-gated regression guard** (per repo convention, `MD2_RUN_GUI_TESTS=1`) that launches a test-identity app bundle and asserts the window set across the launch matrix — direct launch, launch-with-document (file argument and URL delivery), re-activation of a running instance — and that the Settings command still opens the window, re-opens after closing, and that quitting with Settings open does not restore it on relaunch.
- **Document the coupling** in `CLAUDE.md`'s testing section, alongside the other GUI-gated guards, so the next person to touch launch or settings wiring knows this path fails silently (a window that reappears, not an error).
- No preference, data-format, or export changes; the stored Settings window frame is untouched.

## Capabilities

### New Capabilities
- `settings-window-presentation`: the Settings window is never presented as part of launching the app (direct launch, launch-with-document, and later activation), it opens only on explicit user request, and the app declares macOS 15 as its minimum supported system version.

### Modified Capabilities
<!-- None: no existing spec governs launch-time window presentation or the Settings window's lifecycle.
     (Note: the archived 2026-06-24 menu-i18n-startup-improvements change declared a
     `launch-window-behavior` capability that was never synced into openspec/specs/ — pre-existing
     gap, not addressed here.) -->

## Impact

- **Scene/render path** — `Sources/MD2App/MD2App.swift`: the Settings scene gains the suppression modifier inline; no scene-property split is needed once no availability branch remains.
- **Platform floor** — `Package.swift` (`platforms:`), `Sources/MD2App/DirectLaunchBootstrap.swift` (`LSMinimumSystemVersion` in the generated plist the app actually runs under in dev), `Scripts/package_app.sh` (the plist inside the released `.app`/DMG).
- **Tests** — new GUI-gated suite under `Tests/MD2CoreTests/` (the repo's first multi-process GUI test; the command-direction cases need Accessibility trust) plus non-GUI unit tests for the generated plist floor and the launch-probe format. Wired to the existing `MD2_HEALTH_FILE` launch probe, extended with per-window detail and fresh snapshots at each observed lifecycle stage. Skipped by `swift test` and CI, like the other GUI guards (see `TODOS.md`: the headless GUI CI lane is still unimplemented).
- **Docs** — `CLAUDE.md` testing section: new guard suite and the macOS 15 floor.
- **Not addressed (out of scope)** — the binary still records `LC_BUILD_VERSION sdk 14.0` (SwiftPM records the deployment target rather than the SDK), so every other "linked on or after macOS 15" framework behavior stays in legacy mode. Changing that would flip AppKit/WebKit/Foundation compatibility behaviors app-wide and is deliberately not part of this change.
