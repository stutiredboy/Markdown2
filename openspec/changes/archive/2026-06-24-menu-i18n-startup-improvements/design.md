## Context

`MD2App` is a native macOS SwiftUI app. The custom menu commands in `MD2App.swift` already localize through `AppSettings.text(_:)` (resolving `L10nKey` against `AppLanguage`). Three of the four changes are small, well-isolated edits; the menu-bar localization and the Print command carry the real design weight:

- **Menu-bar localization**: The standard menus (File/Edit/View/Window/Help) and system items (About, Hide, Quit, Cut/Copy/Paste, Minimize, Zoom…) are built by AppKit from the *process's active localization*, which is derived from `AppleLanguages` / system locale at launch — independent of the app's `MD2.Language` setting. So a user who picks Simplified Chinese still sees English standard menus.
- **Print**: `PDFExporter` already renders the document's HTML offscreen and paginates it to a print-ready PDF. Its header documents that driving `NSPrintOperation` directly off the offscreen `WKWebView` produced structurally invalid, multi-gigabyte output. That proven-bad path must be avoided.

Constraints: macOS 14+, Swift 6, no new third-party dependencies, owner-only git authorship (per `CLAUDE.md`). An app-bundle relaunch helper already exists in `DirectLaunchBootstrap`.

### Architecture notes

- `MD2Application` is a **struct** conforming to `App` (decorated with `@main`), not an `NSApplication` subclass. Its `init()` is the only early hook point before the SwiftUI scene body (which contains `.commands`) is evaluated — there is no `NSApplicationDelegate.willFinishLaunching` accessible through the `App` protocol. This makes `init()` the sole place to set `AppleLanguages` before AppKit builds the main menu.
- The app uses **purely programmatic localization**: all custom strings live in `L10n.english` / `L10n.zhHans` dictionaries in `AppSettings.swift`. There are **no `.strings` files, no `.xcstrings` catalog, and no `.lproj` directories** anywhere in the project. The runtime app bundle (built by `RuntimeAppBundleBuilder`) has `CFBundleDevelopmentRegion = "en"` but no `CFBundleLocalizations` key and no localized resources.
- The stale-file sweep in `MarkdownPreviewView.sweepStalePreviewFiles` only handles files matching `.md2-preview-*.html` (both prefix and `.html` suffix). It does **not** sweep `.pdf` files.
- `DirectLaunchBootstrap.relaunchFromAppBundleIfNeeded()` launches a new process via `NSWorkspace.shared.openApplication`, then the original process calls `exit(EXIT_SUCCESS)`. Because `UserDefaults.standard` is persistent (stored in the app's defaults domain, not process-local), an `AppleLanguages` override written before the relaunch is visible to the relaunched process.

## Goals / Non-Goals

**Goals:**
- Remove the redundant Save As… menu item while keeping first-save-prompts working.
- Make the entire menu bar honor the app language setting.
- Make blank-document-on-launch opt-in (default off) without breaking file-open or reopen flows.
- Add a working File ▸ Print (⌘P) that prints rendered content, reusing the existing render pipeline.

**Non-Goals:**
- No new translation languages beyond the existing English / Simplified Chinese.
- No custom print layout UI or page-setup controls beyond the system print dialog.
- No live, restart-free relocalization of the *standard* AppKit menu bar (macOS rebuilds it at launch; a restart is the supported path).
- No change to PDF export, autosave, or document format.

## Decisions

### 1. Save As removal (issue #1)
Remove the Save As `Button` and its ⇧⌘S shortcut from the `.saveItem` `CommandGroup` in `MD2App.swift`. Keep `DocumentStore.save()`'s existing behavior: for an untitled document it calls `saveAs()` which presents a save panel. The existing `saveAs()` method is `@discardableResult func saveAs() -> Bool` and is called internally by `save()` (line 101 of `DocumentStore.swift`); make it `private` (e.g. `presentSaveLocationAndWrite()`) so it is no longer part of the menu-facing surface but still backs first-time saves. The `@discardableResult` and `Bool` return type must be preserved because `save()` propagates the result.
- *Alternative considered*: keep Save As but hide it. Rejected — the user explicitly wants it gone; the Finder covers relocation.

### 2. Menu-bar localization via `AppleLanguages` override + restart (issue #2)
Apply the app's language choice to the process by writing the `AppleLanguages` user-default at the *earliest* startup point, before AppKit builds the menu:
- Add an `AppSettings` resolver mapping the **stored** `language` value (not `effectiveLanguage`) to `AppleLanguages` codes: `.english → ["en"]`, `.zhHans → ["zh-Hans"]`. For `.system`, **remove** the `AppleLanguages` override key so the process falls back to the system locale. (Using the raw stored `language`, not `effectiveLanguage`, is critical: `effectiveLanguage` resolves `.system` to a concrete language, which would prevent the system-locale fallback.)
- In `MD2Application.init()` (which runs before the menu is constructed), if the stored `MD2.Language` is not `.system`, set `UserDefaults.standard.set([code], forKey: "AppleLanguages")`; if `.system`, call `UserDefaults.standard.removeObject(forKey: "AppleLanguages")`. Do this *before* `DirectLaunchBootstrap.relaunchFromAppBundleIfNeeded()` so a relaunched bundle process inherits the override from the persistent defaults domain.
- Because AppKit reads the localization once at launch, a language change made while running cannot retroactively relocalize the already-built standard menu bar. On change in `SettingsView`, present a localized alert ("Language updates after restarting") offering **Restart Now** / **Later**. The custom command items continue to update live via `@Published language`.

#### Relaunch ordering: terminate first, relaunch on confirmed termination
Two constraints shape the relaunch helper, and together they rule out the naive "launch the new instance, then terminate" approach:

1. **Unsaved work must not be lost.** The helper must not call `exit()` — that bypasses `applicationShouldTerminate`, which prompts for unsaved changes on every dirty window. It must go through `NSApp.terminate(nil)`.
2. **A cancelled save prompt must abort the relaunch, with no double instance.** `NSWorkspace.openApplication` on a bundle that is *already running* (the in-place `.app`) reactivates the existing instance instead of spawning a new process — the existing `openBundle` launches a fresh process only because the bootstrap's caller is a bare executable not registered under the app's bundle id. Forcing a second process up front (`createsNewApplicationInstance = true`) would spawn the new instance *before* the unsaved-changes prompt, so cancelling would strand two running instances.

Correct flow:
- **Restart Now** sets a `pendingLanguageRelaunch` flag on the delegate and calls `NSApp.terminate(nil)`. It does **not** launch anything yet.
- `applicationShouldTerminate` runs its existing unsaved-changes loop. If the user cancels, it returns `.terminateCancel`; no new instance was ever launched, so the relaunch is simply aborted.
- Only when termination is committed does `applicationWillTerminate` fire. There, if `pendingLanguageRelaunch` is set, spawn a **detached** relauncher — a `Process` that waits for the current PID to exit, then `open`s the app bundle (e.g. `/bin/sh -c 'while kill -0 <pid> 2>/dev/null; do sleep 0.2; done; open "<bundle>"'`). Because termination is now guaranteed, the wait-for-exit helper cannot linger, and `open` (without `-n`) launches exactly one fresh instance after the old one is gone.

The `AppleLanguages` override is already persisted before terminate, so the relaunched instance builds its menu bar in the new language. (The relaunched `.app` does not re-run the dev bootstrap, which is gated on `pathExtension != "app"`.) For the separate *fallback auto-relaunch* path in Risks, a `MARKDOWN2_LANGUAGE_RELAYOUT_DONE` env flag guards against a relaunch loop.

#### Bundle-localization concern
The runtime app bundle (built by `RuntimeAppBundleBuilder`) contains no `.lproj` directories and no `CFBundleLocalizations` key — only `CFBundleDevelopmentRegion = "en"`. Standard AppKit menu items are localized by the **AppKit framework's own** `.lproj` resources, selected by the process's active localization (which `AppleLanguages` controls), so the override should work without app-bundle `.lproj` resources. However, if testing reveals that the absence of `CFBundleLocalizations` / `.lproj` in the app bundle constrains AppKit to `en` only, add a `CFBundleLocalizations` array (`["en", "zh-Hans"]`) to the runtime `Info.plist` generated by `RuntimeAppBundleBuilder`. This is a low-risk additive change to the generated plist.

- *Alternatives considered*:
  - *Force-load AppKit's localized bundle at runtime and rebuild the menu* — fragile, unsupported, doesn't cover system items reliably. Rejected.
  - *Auto-relaunch immediately on every change without asking* — jarring and can lose unsaved work; the confirm-and-restart flow is safer. Rejected.

### 3. Opt-in blank document on launch (issue #3)
Add `AppSettings.opensBlankDocumentOnLaunch: Bool` (UserDefaults key `MD2.OpensBlankDocumentOnLaunch`, default `false`). In `MD2AppDelegate.applicationDidFinishLaunching`, gate the fallback `newDocument()` on the setting:
```
if let url = fileURLFromLaunchArguments() { openInNewWindow(url) }
else if documentWindows.isEmpty && settings.opensBlankDocumentOnLaunch { newDocument() }
```
The `documentWindows.isEmpty` check must be preserved: `application(_:open:)` may have already opened windows (e.g. when launched by double-clicking a file in Finder) before `applicationDidFinishLaunching` fires, and in that case no blank document should be created regardless of the setting.

`applicationShouldHandleReopen` is left unchanged so a Dock-icon reactivation with no windows always yields a document. This is deliberate macOS convention: Dock-click is an explicit user action signaling "I want a window," whereas direct launch is passive. The setting controls only the launch path, not the reopen path. Expose a Settings toggle with new `L10nKey.openBlankOnLaunch` strings.
- *Alternative considered*: default the setting to `true` (preserve old behavior). Rejected — the user wants launch to open nothing by default.

### 4. Print via the proven PDF pipeline (issue #4)
Add File ▸ Print using SwiftUI's standard `CommandGroup(replacing: .printItem)` so it lands in the native print placement with ⌘P, titled via new `L10nKey.print`. The button calls `appDelegate.currentDocumentStore?.print()` — the optional chaining makes it a safe no-op when no document is focused, consistent with the existing Save/Export commands.

`DocumentStore.print()` mirrors `exportPDF()`: flush the pending render, then hand `rendered.html` + `outline` + `baseURL` to a printer. To avoid the known-bad offscreen-`WKWebView` + `NSPrintOperation` path, **reuse `PDFExporter` to render a temporary PDF**, then print that PDF:
- Introduce a `DocumentPrinting` protocol (parallel to `PDFExporting`) and a `DocumentPrinter` that (a) renders to a temp PDF via the existing `PDFExporter` pipeline, (b) loads it with `PDFKit.PDFDocument`, and (c) calls `PDFDocument.printOperation(for:scalingMode:autoRotate:)` to obtain a standard `NSPrintOperation`, then runs it. **No custom paginated `NSView` is needed** — `PDFDocument.printOperation(for:)` is the standard PDFKit API that handles pagination natively and presents the system print dialog with printer selection, copies, page range, etc.
- The temp PDF is written to `FileManager.default.temporaryDirectory` (not the document directory, because untitled documents have no `baseURL` directory). It is deleted in the print operation's completion handler (success or failure). **The existing `sweepStalePreviewFiles` does not cover PDFs** (it only matches `.md2-preview-*.html`), so `DocumentPrinter` must clean up its own temp file explicitly.
- Printing is a derived action: it MUST NOT touch `fileURL`, `isDirty`, or autosave (same contract as export). A second Print request while one is in flight is ignored. **Print and PDF Export share the same `pdfExporter` guard** in `DocumentStore` — they are mutually exclusive, since both create an offscreen `WKWebView` through the same pipeline. A Print while an Export is in flight (or vice versa) is a no-op.
- Failures surface through the existing `DocumentAlert` path.
- *Alternatives considered*:
  - *`WKWebView.printOperation(with:)` on a fresh offscreen web view* — the codebase already documents this produces invalid output offscreen; high risk. Rejected.
  - *Print the live preview web view* — unavailable in Edit-only mode and scroll-position dependent. Rejected.
  - *Custom `NSView` that draws each `PDFPage`* — unnecessarily complex; `PDFDocument.printOperation(for:scalingMode:autoRotate:)` achieves the same result with a single API call. Rejected.

## Risks / Trade-offs

- **[`AppleLanguages` override set in `init()` is not early enough to relocalize the current process's menu]** → The design treats restart as the supported path for in-session changes and applies the override before relaunch, so a fresh launch always starts in the right language. If even first-launch menus lag, fall back to a one-time relaunch when the active localization doesn't match the stored preference (guarded against loops via the `MARKDOWN2_LANGUAGE_RELAYOUT_DONE` env flag, mirroring the existing `MARKDOWN2_DISABLE_APP_BUNDLE_BOOTSTRAP` guard).
- **[No `.lproj` resources in the app bundle]** → Standard AppKit menus are localized from the AppKit framework's own resources, so `AppleLanguages` should work without app-bundle `.lproj`. If it doesn't, add `CFBundleLocalizations` to the runtime `Info.plist` (low-risk additive change). Flagged for verification in tasks.
- **[Restart-to-apply UX]** → Mitigated by a clear localized alert and a "Restart Now" button. The restart goes through `NSApp.terminate(nil)` so `applicationShouldTerminate` prompts for unsaved changes — no work is lost silently. Custom items update immediately so most user-facing labels change without restart.
- **[Print pipeline reuse adds an indirection (PDF then print)]** → Accepted: it reuses the only rendering path known to produce valid paginated output and keeps print/export visually consistent. Temp PDF is written to the system temp directory and explicitly deleted by `DocumentPrinter` (not the preview's stale-file sweep, which only handles `.html`).
- **[Print and Export share the `pdfExporter` guard — mutually exclusive]** → Accepted: both create an offscreen `WKWebView` through the same pipeline; concurrent execution would be wasteful and could confuse the guard. The user can Print after Export completes (or vice versa).
- **[No window on launch may surprise users used to a blank doc]** → It is opt-in via Settings, and reopen/New/Open all still work; default matches the user's explicit request.
- **[Removing Save As changes muscle memory / ⇧⌘S]** → Save still prompts for a location on first save, so no workflow is lost; only relocation moves to the Finder.

## Migration Plan

Additive only — three new `UserDefaults` keys (`MD2.OpensBlankDocumentOnLaunch`, plus the system `AppleLanguages` override) and no document-format change. Existing preferences are untouched. Rollback is reverting the change; stored keys are harmless if unread. No data migration.

## Open Questions

- **Will `AppleLanguages` override localize standard menus without app-bundle `.lproj` resources?** Standard AppKit menus use the framework's own localizations, so this should work, but it must be verified on macOS 14+. If it doesn't, add `CFBundleLocalizations` to the runtime `Info.plist` (see Decision 2, "Bundle-localization concern").
- If first-launch standard menus do not pick up the override without a relaunch on the target OS, enable the guarded one-time auto-relaunch described in Risks.
