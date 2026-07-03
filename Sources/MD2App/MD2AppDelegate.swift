import AppKit
import Combine
import MD2AppSupport
import SwiftUI

@MainActor
final class MD2AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let settings = AppSettings()

    /// Recent-documents list (persists across launches; also noted with the
    /// system so the system-level recents work where code signing allows).
    /// Noted on every successful open and first save.
    private let recentDocuments: RecentDocumentsRecording = SystemRecentDocumentsRecorder()
    private var documentWindows: [DocumentWindow] = []
    private let activationController = LaunchActivationController()
    /// Set when the user asks to restart for a language change. Read in
    /// `applicationWillTerminate` to arm the relaunch only once termination is
    /// actually committed (a cancelled unsaved-changes prompt clears it).
    private var pendingLanguageRelaunch = false
    /// Republishes `settings` changes as our own, so SwiftUI — which observes
    /// this delegate via `@NSApplicationDelegateAdaptor` — re-evaluates the
    /// `.commands` menu when the language changes. This keeps the app's own menu
    /// items (New, Open, Save, Print, …) localized immediately; only the standard
    /// AppKit menu bar still needs a restart.
    private var settingsObservation: AnyCancellable?
    private var modeShortcutObservation: AnyCancellable?
    /// Shortcuts that have been registered as mode shortcuts during this run.
    /// SwiftUI command menus can keep a previous key equivalent alive after a
    /// Settings edit; consuming stale entries here prevents old bindings from
    /// firing after the user customizes them.
    private var knownModeShortcuts = Set<ModeKeyboardShortcut>()

    override init() {
        super.init()
        knownModeShortcuts = Set(settings.modeShortcuts.assignments.map(\.shortcut))
        modeShortcutObservation = settings.$modeShortcuts.sink { [weak self] configuration in
            self?.knownModeShortcuts.formUnion(configuration.assignments.map(\.shortcut))
        }
        settingsObservation = settings.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            // `objectWillChange` fires before the new value commits, so re-render
            // on the next runloop tick to pick up committed settings. The second
            // delegate publish also lets SwiftUI rebuild command shortcuts after
            // users change mode bindings in Settings.
            DispatchQueue.main.async {
                self.objectWillChange.send()
                for documentWindow in self.documentWindows {
                    documentWindow.store.reRenderForSettingsChange()
                }
            }
        }
    }

    /// The document store backing the frontmost window. Menu commands such as
    /// Save act on whichever document the user is currently looking at.
    var currentDocumentStore: DocumentStore? {
        if let keyWindow = NSApp.keyWindow {
            return documentWindows.first(where: { $0.window == keyWindow })?.store
        }
        if let mainWindow = NSApp.mainWindow,
           let match = documentWindows.first(where: { $0.window == mainWindow }) {
            return match.store
        }
        return documentWindows.last?.store
    }

    private func handleModeShortcutEvent(_ event: NSEvent, for store: DocumentStore) -> Bool {
        guard let shortcut = ModeKeyboardShortcut(event: event) else {
            return false
        }

        if let assignment = settings.modeShortcuts.assignments.first(where: { $0.shortcut == shortcut }) {
            store.requestMode(assignment.mode)
            return true
        }

        if knownModeShortcuts.contains(shortcut) {
            return true
        }

        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = fileURLFromLaunchArguments() {
            openInNewWindow(url)
        } else if documentWindows.isEmpty && settings.opensBlankDocumentOnLaunch {
            // Direct launch with no file: open a blank document only when the
            // user opted in. The `documentWindows.isEmpty` check still matters —
            // `application(_:open:)` may have already opened a file window when
            // launched via Finder, in which case we never want a blank one.
            newDocument()
        }
        activationController.activateAfterLaunch()
        LaunchHealthReporter.write("didFinishLaunching")
    }

    /// The Dock icon's context menu: live recent documents, rebuilt by AppKit
    /// on every right-click. This surface is fully app-owned, so it stays
    /// current within the session — unlike the File menu, whose SwiftUI
    /// command tree is frozen while the Settings scene is closed.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let entries = recentDocumentEntries
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(openDockRecentDocument(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.url
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openDockRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openRecentDocument(url)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if documentWindows.isEmpty {
            newDocument()
        } else {
            documentWindows.last?.window.makeKeyAndOrderFront(nil)
        }
        activationController.activateAfterLaunch()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openInNewWindow(url)
        }
        activationController.activateAfterLaunch()
    }

    // MARK: - Document actions

    /// Opens a fresh, empty document in its own window.
    func newDocument() {
        makeDocumentWindow(store: makeDocumentStore()).window.makeKeyAndOrderFront(nil)
    }

    /// Creates a document store wired to read the live export profile and
    /// citation/equation preferences from settings, so export, print, and the
    /// preview always use the user's current configuration without each store
    /// holding its own copy.
    private func makeDocumentStore() -> DocumentStore {
        DocumentStore(
            exportProfileProvider: { [settings] in settings.exportProfile },
            renderConfigProvider: { [settings] in (settings.citationStyle, settings.numberAllEquations) },
            alertTextProvider: { [settings] in settings.text($0) }
        )
    }

    /// Closes the frontmost document window in response to ⌘W. Routing through
    /// `performClose(_:)` (rather than `close()`) drives the window through
    /// `windowShouldClose(_:)`, so the existing unsaved-changes prompt runs and
    /// no save/discard logic is duplicated. No-ops safely when no document
    /// window is focused.
    func closeCurrentDocument() {
        let target: NSWindow?
        if let keyWindow = NSApp.keyWindow {
            // Only act when the focused window is one of our document windows;
            // when something else is key (e.g. Settings) leave documents alone.
            target = documentWindows.first(where: { $0.window == keyWindow })?.window
        } else {
            // No key window at all — fall back to the most recent document window.
            target = documentWindows.first?.window
        }
        target?.performClose(nil)
    }

    /// Presents an open panel and loads every selected file, each in its own window.
    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentStore.markdownTypes

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            openInNewWindow(url)
        }
    }

    /// Loads `url` into a window. If it is already open, that window is brought
    /// to the front; otherwise an untouched starter window is reused or a new
    /// one is created. Also the open path for Markdown links clicked in a
    /// preview, so linked documents front/dedupe like any other open.
    func openInNewWindow(_ url: URL) {
        if let existing = documentWindows.first(where: { $0.store.fileURL == url }) {
            existing.window.makeKeyAndOrderFront(nil)
            // Re-opening an already-open document still bumps its recency,
            // matching platform behavior. (Fresh opens are noted through the
            // window's fileURL transition.)
            noteRecentDocument(url)
            return
        }

        if let reusable = documentWindows.first(where: { $0.store.isReusableEmptyDocument }) {
            reusable.store.open(url)
            reusable.window.makeKeyAndOrderFront(nil)
            return
        }

        let documentWindow = makeDocumentWindow(store: makeDocumentStore())
        documentWindow.store.open(url)
        documentWindow.window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Recent documents

    /// The Open Recent menu model (deduplicated, disambiguated, most recent
    /// first). The `.commands` tree re-reads this whenever the delegate
    /// republishes.
    var recentDocumentEntries: [RecentDocumentEntry] {
        RecentDocumentsList.menuEntries(for: recentDocuments.recentDocumentURLs)
    }

    /// Opens a document chosen from the Open Recent menu. A file that no
    /// longer exists shows the localized open-failure notice and is pruned
    /// from the list, leaving the remaining entries intact.
    func openRecentDocument(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(format: settings.text(.alertCouldNotOpen), url.lastPathComponent)
            alert.informativeText = settings.text(.recentDocumentMissingDetail)
            alert.addButton(withTitle: settings.text(.ok))
            alert.runModal()
            RecentDocumentsList.removeEntry(url, from: recentDocuments)
            return
        }
        openInNewWindow(url)
    }

    func clearRecentDocuments() {
        recentDocuments.clear()
    }

    /// Records `url` as a recent document. The submenu pulls the live list on
    /// every open, so recording needs no UI notification.
    private func noteRecentDocument(_ url: URL) {
        recentDocuments.note(url)
    }

    // MARK: - Window management

    @discardableResult
    private func makeDocumentWindow(store: DocumentStore) -> DocumentWindow {
        let contentView = ContentView(
            document: store,
            settings: settings,
            onOpen: { [weak self] in self?.openDocument() },
            onOpenMarkdownLink: { [weak self] url in self?.openInNewWindow(url) }
        )

        let window = ModeShortcutWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.modeShortcutHandler = { [weak self, weak store] event in
            guard let self, let store else { return false }
            return self.handleModeShortcutEvent(event, for: store)
        }
        window.title = store.displayTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: contentView)
        // Let macOS group document windows into native tabs when the user
        // prefers tabs; they can always be torn off into separate windows.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "MD2Document"

        if let previous = documentWindows.last?.window {
            var origin = previous.frame.origin
            origin = window.cascadeTopLeft(from: NSPoint(x: origin.x, y: origin.y + previous.frame.height))
            window.setFrameTopLeftPoint(origin)
        } else {
            window.center()
        }

        let documentWindow = DocumentWindow(
            window: window,
            store: store,
            settings: settings,
            onFileBacked: { [weak self] url in self?.noteRecentDocument(url) }
        )
        documentWindows.append(documentWindow)
        return documentWindow
    }

    private func fileURLFromLaunchArguments() -> URL? {
        let arguments = CommandLine.arguments.dropFirst()
        guard let path = arguments.first(where: { !$0.hasPrefix("-") }) else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let store = documentWindows.first(where: { $0.window == sender })?.store else {
            return true
        }
        return confirmDiscardOrSaveIfNeeded(for: store)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Detach the file watcher deterministically; releasing the store also
        // cancels it, but the hosting view can keep references alive briefly.
        documentWindows.first(where: { $0.window == window })?.store.stopWatchingFile()
        documentWindows.removeAll { $0.window == window }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for documentWindow in documentWindows where documentWindow.store.isDirty {
            documentWindow.window.makeKeyAndOrderFront(nil)
            if !confirmDiscardOrSaveIfNeeded(for: documentWindow.store) {
                // User cancelled: abort any pending language relaunch so a later
                // normal quit does not unexpectedly relaunch the app.
                pendingLanguageRelaunch = false
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Only reached once termination is committed (a cancelled unsaved-changes
        // prompt returns `.terminateCancel` and clears the flag), so arming the
        // relaunch here can never strand a second instance.
        guard pendingLanguageRelaunch else { return }
        relaunchAfterTermination()
    }

    /// Restarts the app so the standard menu bar rebuilds in the newly chosen
    /// language. Terminates through `NSApp.terminate(_:)` — not `exit()` — so the
    /// unsaved-changes prompt runs first; the relaunch itself is armed in
    /// `applicationWillTerminate`.
    func requestLanguageRelaunch() {
        pendingLanguageRelaunch = true
        NSApp.terminate(nil)
    }

    /// Spawns a detached shell that waits for this process to exit, then reopens
    /// the app bundle. Launching before terminating would not start a new
    /// process: `NSWorkspace` reactivates this still-running instance instead.
    private func relaunchAfterTermination() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
            "md2-language-relaunch",
            "\(pid)",
            bundlePath
        ]
        try? process.run()
    }

    private func confirmDiscardOrSaveIfNeeded(for store: DocumentStore) -> Bool {
        guard store.isDirty else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = settings.text(.unsavedChangesTitle)
        alert.informativeText = settings.text(.unsavedChangesMessage)
        alert.alertStyle = .warning
        alert.addButton(withTitle: settings.text(.save))
        alert.addButton(withTitle: settings.text(.cancel))
        alert.addButton(withTitle: settings.text(.dontSave))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return store.save()
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }
}

private final class ModeShortcutWindow: NSWindow {
    var modeShortcutHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if modeShortcutHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Pairs an `NSWindow` with the document it presents, keeps the window's
/// title in sync with the document (filename and unsaved-changes marker), and
/// presents the external-change conflict prompt the store requests.
@MainActor
private final class DocumentWindow {
    let window: NSWindow
    let store: DocumentStore
    private let settings: AppSettings
    private var cancellable: AnyCancellable?
    private var conflictCancellable: AnyCancellable?
    private var isPresentingConflict = false
    /// The last file URL reported through `onFileBacked`, so a document
    /// becoming file-backed (open into this window, or an untitled document's
    /// first save) is reported exactly once per URL — re-saves do not re-note.
    private var lastReportedFileURL: URL?

    init(
        window: NSWindow,
        store: DocumentStore,
        settings: AppSettings,
        onFileBacked: @escaping (URL) -> Void = { _ in }
    ) {
        self.window = window
        self.store = store
        self.settings = settings
        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window.title = self.store.displayTitle
                self.window.isDocumentEdited = self.store.isDirty
                self.window.representedURL = self.store.fileURL
                if let url = self.store.fileURL, url != self.lastReportedFileURL {
                    self.lastReportedFileURL = url
                    onFileBacked(url)
                }
            }
        }
        conflictCancellable = store.$externalConflictRequest.sink { [weak self] request in
            guard request != nil else { return }
            DispatchQueue.main.async {
                self?.presentConflictPromptIfNeeded()
            }
        }
    }

    /// Sheet on the affected window: keep the in-memory version (default; the
    /// next save overwrites the disk) or reload from disk (discarding edits).
    /// One sheet at a time — re-raised requests while it is up are answered by
    /// the same pending choice.
    private func presentConflictPromptIfNeeded() {
        guard !isPresentingConflict, store.hasExternalConflict else { return }
        isPresentingConflict = true

        let alert = NSAlert()
        alert.messageText = settings.text(.externalChangeConflictTitle)
        alert.informativeText = settings.text(.externalChangeConflictMessage)
        alert.alertStyle = .warning
        alert.addButton(withTitle: settings.text(.keepMyVersion))
        alert.addButton(withTitle: settings.text(.reloadFromDisk))

        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPresentingConflict = false
            self.store.resolveExternalConflict(
                reloadingFromDisk: response == .alertSecondButtonReturn
            )
        }
    }
}
