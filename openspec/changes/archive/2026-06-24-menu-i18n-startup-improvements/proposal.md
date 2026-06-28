## Why

Four menu and startup rough edges hurt the everyday experience: the File menu carries a **Save As…** item that duplicates what the Finder does better, the standard menu bar (File/Edit/View/Window/Help and system items) ignores the in-app language setting and stays in the system locale, launching the app always spawns an empty throwaway document, and there is no way to **Print** a document even though a full rendered-output pipeline already exists.

## What Changes

- **Remove the File ▸ Save As… menu item.** Saving an unsaved document still prompts for a destination via the normal Save flow; only the redundant standalone menu command (and its ⇧⌘S shortcut) goes away. Relocating an existing file is left to the Finder.
- **Make the standard menu bar follow the app language setting.** When Settings is set to Simplified Chinese (or English), the standard AppKit menus and items localize to that language instead of the system locale, matching the already-localized custom command items.
- **Stop opening a blank document on launch by default; make it a setting.** A new "Open a blank document on launch" preference (default **off**) controls whether direct launch creates a starter window. Opening files (file argument, Open panel, Finder) and Dock-icon reopen are unaffected.
- **Add a File ▸ Print command (⌘P).** Prints the current document's rendered content through the system print dialog, reusing the existing paginated-render pipeline.

## Capabilities

### New Capabilities
- `app-menu-localization`: The application's full menu bar — standard AppKit menus/items and the app menu — is presented in the configured app language rather than the system locale.
- `launch-window-behavior`: Whether direct launch opens a blank starter document is user-configurable, defaulting to not opening one.
- `document-print`: A Print command in the File menu that sends the current document's rendered output to the system print dialog.
- `file-save-commands`: The File menu exposes a single Save command and no separate Save As menu item, while still prompting for a location when first saving an untitled document.

### Modified Capabilities
<!-- None: no existing spec governs the File-menu command set, menu-bar localization, or launch window behavior. -->

## Impact

- **Menus** — `Sources/MD2App/MD2App.swift`: remove the Save As button/shortcut, add a Print command in the standard print placement.
- **Localization** — `Sources/MD2App/AppSettings.swift`: add the `.print` localization key and an app-language override (`AppleLanguages`) applied at startup; `Sources/MD2App/SettingsView.swift` + a relaunch helper: prompt to restart when the language changes so the standard menu bar re-localizes. The relaunch must go through `NSApp.terminate` (not raw `exit()`) so `applicationShouldTerminate` can prompt for unsaved changes. If the runtime app bundle lacks `CFBundleLocalizations`, it may need to be added to the generated `Info.plist` in `DirectLaunchBootstrap` so that `AppleLanguages` localizes standard AppKit menus.
- **Launch** — `Sources/MD2App/MD2AppDelegate.swift` + `AppSettings.swift`: new `opensBlankDocumentOnLaunch` preference gating the launch-time `newDocument()` call (preserving the `documentWindows.isEmpty` check for files opened before `applicationDidFinishLaunching`); `SettingsView.swift` exposes it.
- **Print** — `Sources/MD2App/DocumentStore.swift` + a new `DocumentPrinter` reusing the offscreen rendered-PDF pipeline (`PDFExporter`/`PDFPaginator`) to produce a temp PDF, then printing via `PDFKit.PDFDocument.printOperation(for:scalingMode:autoRotate:)`. Print and Export share the same concurrency guard (mutually exclusive). Temp PDF goes to the system temp directory (untitled documents have no directory) and is cleaned up explicitly.
- **Tests** — `Tests/MD2CoreTests`: cover language-override resolution (stored language, not effectiveLanguage), launch-gating logic, Print/Export mutual exclusion, and Save As removal.
- **No data/format changes**; preferences are additive `UserDefaults` keys.
