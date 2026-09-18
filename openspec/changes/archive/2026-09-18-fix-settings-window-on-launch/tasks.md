## 1. Raise the platform floor to macOS 15

- [x] 1.1 `Package.swift`: change `platforms: [.macOS(.v14)]` to `.macOS(.v15)`
- [x] 1.2 `Sources/MD2App/DirectLaunchBootstrap.swift`: change `LSMinimumSystemVersion` in the generated `Info.plist` from `14.0` to `15.0`
- [x] 1.3 `Scripts/package_app.sh`: change `LSMinimumSystemVersion` in the release `Info.plist` heredoc from `14.0` to `15.0`
- [x] 1.4 Verify the raised floor landed everywhere: `swift build` succeeds, then `otool -l .build/debug/Markdown2 | grep -A4 LC_BUILD_VERSION` records `minos 15.0` (and therefore `sdk 15.0`), and grep the repo for any remaining `LSMinimumSystemVersion`/`macos14`/`.v14` declaration (`grep -rn "14.0\|macos14\|v14" Package.swift Scripts/ Sources/MD2App/DirectLaunchBootstrap.swift`)
- [x] 1.5 Add a non-GUI unit test in `Tests/MD2CoreTests/RuntimeAppBundleBuilderTests.swift` asserting the generated plist declares `LSMinimumSystemVersion` `15.0` (and the default `CFBundleIdentifier` is unchanged) — a CI-enforced regression guard for the dev-bundle half of the floor

## 2. Suppress the Settings scene's launch presentation

- [x] 2.1 `Sources/MD2App/MD2App.swift`: chain `.defaultLaunchBehavior(.suppressed)` inline on the existing single-expression body — `Settings { … }.defaultLaunchBehavior(.suppressed).commands { … }` (no availability branch remains, so no scene-property split is needed; compile-verified)
- [x] 2.2 Add a comment at the modifier recording why it is there and why both it and the macOS 15 floor are deliberate (SwiftUI presents an app's only scene at launch when the binary is linked below the macOS 15 SDK; the modifier states the intent independently of the linkage and survives a future floor change)
- [x] 2.3 Confirm the app still builds and the Settings scene still exists: the app menu shows Settings… (⌘,) and invoking it opens the window (manual check, recipe in 4.3)

## 3. Extend the launch probe so a guard can identify windows at each observed stage

- [x] 3.1 `Sources/MD2App/LaunchHealthReporter.swift`: keep the existing `stage: windows=N visible=M` line and append one line per window with its title, identifier, class, and visibility, so a guard can assert on *which* windows exist instead of on a count (the app's window list already contains a hidden non-document window during launch)
- [x] 3.2 Add fresh probe writes at the observed lifecycle stages: `Sources/MD2App/MD2AppDelegate.swift` `applicationShouldHandleReopen` (stage `reopen`) and `application(_:open:)` (stage `openURLs`) — post-launch guard cases must read a snapshot from the moment being tested, not a stale launch-time list
- [x] 3.3 Introduce a minimal window-snapshot seam (default = live `NSApplication.shared.windows`) so the line format is unit-testable without real windows
- [x] 3.4 Non-GUI unit tests for the probe: the per-window line format (all four fields) and the no-op contract when `MD2_HEALTH_FILE` is unset (the reporter must stay a no-op in normal runs)

## 4. Verify manually before adding the guard

- [x] 4.1 Direct launch: `pkill -x Markdown2; MD2_HEALTH_FILE=/tmp/md2-health.txt ./.build/debug/Markdown2`, wait, then confirm the file records 0 windows at `didFinishLaunching` (no `com_apple_SwiftUI_Settings_window`)
- [x] 4.2 Launch with a document: `MD2_HEALTH_FILE=/tmp/md2-health.txt ./.build/debug/Markdown2 Examples/Sample.md` and confirm exactly the document window is visible
- [x] 4.3 Settings on demand: with the app running, open the app menu's Settings… (⌘,) and confirm the Settings window opens with the full UI (this is the direction a one-sided fix would break)
- [x] 4.4 Re-launch after closing Settings and confirm the window does not reappear on its own

## 5. Add the GUI-gated regression guard (the repo's first multi-process GUI suite)

- [x] 5.1 New `Tests/MD2CoreTests/SettingsWindowPresentationGUITests.swift`, gated by `MD2_RUN_GUI_TESTS` so `swift test` and CI skip it
- [x] 5.2 Build a test-identity bundle via `RuntimeAppBundleBuilder` extended with an optional `bundleIdentifier` parameter (default `dev.codex.md2.debug`, existing callers unchanged); point `MD2_HEALTH_FILE` at a temp file, launch via `NSWorkspace`, poll the health file with a timeout (never a single read), terminate the launched instance in teardown, and delete the test-only preferences domain (the guard must never touch the developer's real state or recents)
- [x] 5.3 Positive control before any absence assertion: the health file must contain the stage line and per-window inventory (in document cases, the document window must be identified) — a missing, unread, or unparseable inventory fails the guard instead of passing it vacuously
- [x] 5.4 Assert the direct launch presents no window whose identifier is `com_apple_SwiftUI_Settings_window` (assert on identifier primarily; the title is localized)
- [x] 5.5 Assert a launch-with-document via file argument presents the document window and no Settings window
- [x] 5.6 Assert URL delivery presents no Settings window: `open <file>` into the running instance (`openURLs` stage) and `open -a <bundle> <file>` cold launch — Finder's path (`application(_:open:)`) is distinct from the argv path
- [x] 5.7 Assert re-activation presents no Settings window: `open -a <bundle>` (no `-n`) on the running instance, wait for the `reopen` stage snapshot, assert no Settings window
- [x] 5.8 Settings command works (both directions in one instance): probe `AXIsProcessTrusted` first — trusted: perform the app menu item with key equivalent `,`, assert the Settings window appears (via the AX windows attribute), close it, re-invoke, assert it re-opens; untrusted: `XCTSkip` with a loud, actionable message (grant path and why) — visible degradation, never a silent one-sided pass
- [x] 5.9 Assert a relaunch after quitting with Settings open does not restore the window: same test identity, terminate gracefully while the Settings window is open, relaunch, assert no Settings window (restoration must not bypass suppression; also spot-check the autosaved frame is honored)
- [x] 5.10 Confirm the suite fails for the right reason: temporarily remove the `.defaultLaunchBehavior(.suppressed)` modifier and lower the floor to `.v14`, observe the guard fail, then restore (do not land the temporary change)

## 6. Run the existing suites

- [x] 6.1 `swift test` (non-GUI) is green
- [x] 6.2 Run the GUI-gated suites that exist, in separate invocations — `MD2_RUN_GUI_TESTS=1 swift test --filter FindFindDeleteGUITests`, then `--filter EditorLineNumberGutterGUITests`, then `--filter LineNumberGutterGUITests` — because combining them in one process segfaults (recorded in `TODOS.md`); run the new guard suite as its own invocation too
- [x] 6.3 Smoke-test the surfaces that depend on window/menu behavior, since raising the floor also changes the app's linked-on-or-after behaviors: launch (all paths), mode switching, the find bar, and export/print (per `CLAUDE.md`, a change that reaches `PDFExporter.swift`/`DocumentPrinter.swift` requires the GUI suite; this change does not edit them, but the floor change rebuilds the whole app, so confirm the offscreen path still behaves)

## 7. Documentation

- [x] 7.1 `CLAUDE.md` testing section: document the new GUI-gated suite (what it guards, the command to run it, that it must run locally before landing changes to the launch or Settings-window wiring, and the Accessibility-trust requirement for the command-direction cases with the grant path), and record the macOS 15 platform floor with its reason
- [x] 7.2 `README.md` / `README.zh-CN.md`: state the macOS 15 requirement if they mention system requirements at all (they currently do not appear to)
- [ ] 7.3 Release notes for the version carrying this change must state the raised minimum macOS version (breaking for macOS 14 users)

## 8. Validate the change

- [x] 8.1 `openspec validate fix-settings-window-on-launch` passes (strict mode too: `openspec validate --strict fix-settings-window-on-launch`)
- [x] 8.2 Re-read the spec against the implementation with the real coverage matrix — guard-automated: direct launch presents nothing visible (5.4), file-argument launch (5.5), URL delivery (5.6), re-activation (5.7), command opens + re-opens at its saved frame + leaves the document window alone (5.8), quit-with-Settings-open relaunch (5.9); manually verified: the built release artifact (`Scripts/package_app.sh` → `dist/Markdown2.app`) declares `LSMinimumSystemVersion` 15.0 and links as `minos/sdk 15.0`, and the dev bundle's plist is unit-guarded (1.4, 1.5); CI-bound limitation recorded in the design's risks and `TODOS.md`: "Settings is reachable on macOS 15" is evidenced on macOS 26 only, never on 15 itself
