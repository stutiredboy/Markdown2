import AppKit
import Combine
import MD2AppSupport
import SwiftUI

@MainActor
final class MD2AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = AppSettings()
    let attachmentCommandState = AttachmentCommandState()
    let pasteCommandState = MarkdownPasteCommandState()

    /// Recent-documents list (persists across launches). Noted on every
    /// successful open and first save.
    let recentDocuments = RecentDocumentsModel(recorder: SystemRecentDocumentsRecorder())
    let favoriteFolders = FavoriteFoldersModel(recorder: UserDefaultsFavoriteFoldersRecorder())
    private var documentWindows: [DocumentWindow] = []
    private var folder: FolderSession?
    private var folderBrowser: FolderBrowserController? { folder?.browser }
    private var folderAuthorization: Task<Void, Never>?
    private var favoriteFolderAddition: Task<Void, Never>?
    private let recoveryRepository = DocumentRecoveryRepository.applicationRepository()
    private let historyRepository = DocumentHistoryRepository.applicationRepository
    private var isTerminating = false
    private var pendingRecoverySnapshots: [DocumentRecoverySnapshot] = []
    private var recoveryReadFailed = false
    private var receivedOpenRequest = false
    private let activationController = LaunchActivationController()
    /// Set when the user asks to restart for a language change. Read in
    /// `applicationWillTerminate` to arm the relaunch only once termination is
    /// actually committed (a cancelled unsaved-changes prompt clears it).
    private var pendingLanguageRelaunch = false
    /// Re-renders open documents when a setting changes. The menu commands need
    /// no help from here: `AppCommands` observes `settings` itself.
    private var settingsObservation: AnyCancellable?
    private var modeShortcutObservation: AnyCancellable?
    /// Shortcuts that have been registered as mode shortcuts during this run.
    /// Consuming stale entries here keeps an old binding from doing anything
    /// after the user customizes it.
    private var knownModeShortcuts = Set<ModeKeyboardShortcut>()

    override init() {
        super.init()
        let notifications = NotificationCenter.default
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            notifications.addObserver(self, selector: #selector(updateFavoriteFoldersMenuAccessibility),
                                      name: name, object: nil)
        }
        attachmentCommandState.observeCurrentDocument { [weak self] in self?.currentDocumentStore }
        // Read before Finder can deliver openURLs and create this session's records.
        do { pendingRecoverySnapshots = try recoveryRepository.load() }
        catch { recoveryReadFailed = true }
        if !settings.restoresWindowsOnLaunch {
            for snapshot in pendingRecoverySnapshots where !snapshot.isDirty {
                try? recoveryRepository.remove(snapshot.id)
            }
            pendingRecoverySnapshots.removeAll { !$0.isDirty }
        }
        knownModeShortcuts = Set(settings.modeShortcuts.assignments.map(\.shortcut))
        modeShortcutObservation = settings.$modeShortcuts.sink { [weak self] configuration in
            self?.knownModeShortcuts.formUnion(configuration.assignments.map(\.shortcut))
        }
        settingsObservation = settings.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            // `objectWillChange` fires before the new value commits, so re-render
            // on the next runloop tick to pick up committed settings.
            DispatchQueue.main.async {
                for documentWindow in self.documentWindows {
                    documentWindow.store.reRenderForSettingsChange()
                }
                self.folderBrowser?.updateLocalizedText()
                self.folder?.preview?.updateTabTitle()
            }
        }
    }

    @objc private func updateFavoriteFoldersMenuAccessibility(_ notification: Notification) {
        FavoriteFoldersMenu.updateNativeAccessibility(notification, settings: settings)
    }

    /// The document store backing the frontmost window. Menu commands such as
    /// Save act on whichever document the user is currently looking at.
    var currentDocumentStore: DocumentStore? {
        if let keyWindow = NSApp.keyWindow {
            return documentWindows.first(where: { $0.window == keyWindow })?.store
        }
        if let mainWindow = NSApp.mainWindow {
            if mainWindow === folder?.landingWindow { return nil }
            if let match = documentWindows.first(where: { $0.window == mainWindow }) { return match.store }
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

        if knownModeShortcuts.contains(shortcut), shortcut != settings.folderBrowserShortcut {
            return true
        }

        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        historyRepository.pruneExpired()
        let recentDirectories = Set(recentDocuments.urls.map { $0.deletingLastPathComponent() })
        Task.detached(priority: .background) {
            for directory in recentDirectories { LegacyPreviewCleaner.clean(in: directory) }
        }
        if let url = fileURLFromLaunchArguments() {
            openInNewWindow(url)
        } else if !receivedOpenRequest,
                  notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool != false {
            // Only an ordinary app launch resumes the whole session. Finder's
            // open event usually arrives first; AppKit's launch flag also
            // suppresses restoration if that event has not reached us yet.
            if settings.restoresWindowsOnLaunch {
                restoreDocumentWindows()
            } else if !pendingRecoverySnapshots.isEmpty {
                if recoveryRepository.restorationWasInterrupted {
                    restoreDocumentWindows(onlyDirty: true)
                } else {
                    let alert = NSAlert()
                    alert.messageText = settings.text(.unsavedRecoveryTitle)
                    alert.informativeText = settings.text(.unsavedRecoveryMessage)
                    alert.addButton(withTitle: settings.text(.recoverDrafts))
                    alert.addButton(withTitle: settings.text(.skipRecovery))
                    if alert.runModal() == .alertFirstButtonReturn {
                        restoreDocumentWindows(onlyDirty: true)
                    }
                }
            }
            if documentWindows.isEmpty && settings.opensBlankDocumentOnLaunch {
                newDocument()
            }
        }
        activationController.activateAfterLaunch()
        LaunchHealthReporter.write("didFinishLaunching")
    }

    /// The Dock icon's context menu: live recent documents, rebuilt by AppKit
    /// on every right-click from the same entries as File ▸ Open Recent.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let entries = recentDocuments.entries
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
        if documentWindows.isEmpty && folder?.landingWindow == nil {
            newDocument()
        } else if !flag {
            let window = folder?.landingWindow ?? documentWindows.last?.window
            window?.makeKeyAndOrderFront(nil)
        }
        activationController.activateAfterLaunch()
        LaunchHealthReporter.write("reopen")
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !urls.isEmpty { receivedOpenRequest = true }
        for url in urls {
            openInNewWindow(url)
        }
        activationController.activateAfterLaunch()
        LaunchHealthReporter.write("openURLs")
    }

    // MARK: - Document actions

    /// Opens a fresh, empty document in its own window. `store` is injected so
    /// tests can supply a save location without the modal `NSSavePanel`.
    @discardableResult
    func newDocument(store: DocumentStore? = nil) -> NSWindow {
        let window = makeDocumentWindow(store: store ?? makeDocumentStore()).window
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// The document presented in `window`, or `nil` for a window that is not a
    /// document window (e.g. Settings).
    func documentStore(for window: NSWindow) -> DocumentStore? {
        documentWindows.first(where: { $0.window == window })?.store
    }

    /// Creates a document store wired to read the live export profile and
    /// citation/equation preferences from settings, so export, print, and the
    /// preview always use the user's current configuration without each store
    /// holding its own copy.
    private func makeDocumentStore() -> DocumentStore {
        DocumentStore(
            exportProfileProvider: { [settings] in settings.exportProfile },
            renderConfigProvider: { [settings] in (settings.citationStyle, settings.numberAllEquations) },
            syntaxConfigProvider: { [settings] in (settings.inlineFeatures, settings.alertLanguage) },
            alertTextProvider: { [settings] in settings.text($0) },
            recoveryRepository: recoveryRepository,
            historyRepository: historyRepository,
            keepsLocalHistory: { [settings] in settings.keepsLocalHistory },
            confirmEncodingConversion: { [settings] encoding in
                let alert = NSAlert()
                alert.messageText = settings.text(.encodingConversionTitle)
                alert.informativeText = String(format: settings.text(.encodingConversionMessage), encoding)
                alert.addButton(withTitle: settings.text(.convertToUTF8))
                alert.addButton(withTitle: settings.text(.cancel))
                return alert.runModal() == .alertFirstButtonReturn
            }
        )
    }

    /// Closes the frontmost document or folder landing in response to ⌘W. Routing through
    /// `performClose(_:)` (rather than `close()`) drives the window through
    /// `windowShouldClose(_:)`, so the existing unsaved-changes prompt runs and
    /// no save/discard logic is duplicated. No-ops safely when no document
    /// window is focused.
    func closeCurrentDocument() {
        let target: NSWindow?
        if let keyWindow = NSApp.keyWindow {
            target = keyWindow === folder?.landingWindow
                ? keyWindow : documentWindows.first(where: { $0.window === keyWindow })?.window
        } else if let landing = folder?.landingWindow,
                  NSApp.mainWindow === landing || documentWindows.isEmpty {
            target = landing
        } else {
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

    func openFolder(quickOpen: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = settings.text(.openFolder)
        panel.directoryURL = folderBrowser?.root.url ?? currentDocumentStore?.fileURL?.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        authorizeFolder(url, quickOpen: quickOpen)
    }

    func openFavoriteFolder(_ entry: FavoriteFolderEntry) {
        authorizeFolder(entry.url, quickOpen: false, favorite: entry)
    }

    private func authorizeFolder(_ url: URL, quickOpen: Bool, favorite: FavoriteFolderEntry? = nil) {
        folderAuthorization?.cancel()
        folderAuthorization = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                if favorite != nil { return try FolderIndex.authorizeFavorite(url) }
                return try FolderIndex.authorize(url)
            }
            await self?.presentFolder(result, quickOpen: quickOpen, favorite: favorite)
        }
    }

    func quickOpenFolderFile() {
        guard let folder, let window = folder.selectedWindow else {
            openFolder(quickOpen: true)
            return
        }
        window.makeKeyAndOrderFront(nil)
        folder.sidebar.showFiles(in: window) { [weak browser = folder.browser] in
            browser?.focusQuickOpen()
        }
    }

    func focusFolderBrowser() {
        guard let folder, let window = folder.selectedWindow else { return }
        window.makeKeyAndOrderFront(nil)
        folder.sidebar.activate(in: window, focusFiles: true)
    }

    func revealInFolderBrowser() {
        guard let folder, let url = currentDocumentStore?.fileURL, folder.browser.canReveal(url),
              let window = folder.selectedWindow else {
            NSSound.beep()
            return
        }
        window.makeKeyAndOrderFront(nil)
        folder.sidebar.showFiles(in: window) { [weak browser = folder.browser] in
            browser?.reveal(url)
        }
    }

    private func presentFolder(
        _ result: Result<FolderIndex.Root, Error>, quickOpen: Bool, favorite: FavoriteFolderEntry?
    ) {
        guard !Task.isCancelled, !isTerminating else { return }
        folderAuthorization = nil
        let root: FolderIndex.Root
        switch result {
        case .success(let authorizedRoot):
            root = authorizedRoot
        case .failure(let error):
            if let favorite {
                presentUnavailableFavorite(favorite, reason: error as? FolderIndex.FavoriteFailure)
            } else {
                let alert = NSAlert()
                alert.messageText = settings.text(.openFolder)
                alert.informativeText = settings.text(.folderAuthorizationFailed)
                alert.runModal()
            }
            return
        }

        if folderBrowser?.root != root {
            let store = currentDocumentStore
            let current = documentWindows.first { $0.store === store }
            let starter = current.flatMap { $0.store.isReusableEmptyDocument && $0.canRetireCleanTab ? $0 : nil }
            let previousLanding = folder?.landingWindow
            endFolderSession()
            let browser = FolderBrowserController(
                root: root, text: settings.text, favorites: favoriteFolders,
                onToggleFavorite: { [weak self] in self?.toggleCurrentFavoriteFolder() },
                onOpen: { [weak self] opened, decoded, intent in
                    try self?.openFolderDocument(opened, decoded: decoded, intent: intent)
                }
            )
            let sidebar = FolderSidebarState(browserView: browser.view, focusBrowser: { [weak browser] in
                browser?.focusTree()
            })
            let host: FolderSession.Host
            if starter == nil, let group = current?.window.tabGroup {
                host = .tabs(group)
            } else {
                let frame = previousLanding?.frame ?? starter?.window.frame
                host = .landing(makeFolderLanding(root: root, sidebar: sidebar, frame: frame))
            }
            let session = FolderSession(browser: browser, sidebar: sidebar, host: host)
            folder = session
            favoriteFolders.currentRoot = root
            observeFolderGroup(session)
            reconcileFolderTabs()
            browser.start()
            if quickOpen { quickOpenFolderFile() }
            else { focusFolderBrowser() }
            previousLanding?.close()
            starter?.window.performClose(nil)
        } else if quickOpen {
            quickOpenFolderFile()
        } else {
            focusFolderBrowser()
        }
    }

    private func observeFolderGroup(_ session: FolderSession) {
        session.groupObservation = session.group?.observe(\.windows) { [weak self, weak session] _, _ in
            // AppKit is still mutating its selected window during the KVO callback.
            DispatchQueue.main.async {
                guard let self, let session, self.folder === session else { return }
                self.reconcileFolderTabs()
            }
        }
    }

    private func makeFolderLanding(root: FolderIndex.Root, sidebar: FolderSidebarState, frame: NSRect?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DocumentLayoutMetrics.defaultWindowWidth, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.tabbingMode = .disallowed
        window.title = root.url.lastPathComponent.isEmpty ? root.url.path : root.url.lastPathComponent
        window.setAccessibilityIdentifier("folder-landing-window")
        window.delegate = self
        window.contentView = NSHostingView(rootView: FolderLandingView(sidebar: sidebar, settings: settings))
        if let frame { window.setFrame(frame, display: false) }
        else { window.center() }
        return window
    }

    private func endFolderSession() {
        guard let folder else { return }
        self.folder = nil
        folder.preview?.setPreview(false)
        folder.sidebar.activate(in: nil)
        folder.browser.stop()
        for document in documentWindows where document.contentState.folderSidebar === folder.sidebar {
            document.contentState.folderSidebar = nil
        }
        favoriteFolders.currentRoot = nil
        favoriteFolderAddition?.cancel()
        favoriteFolderAddition = nil
    }

    private func reconcileFolderTabs() {
        guard let folder, let group = folder.group else { return }
        let groupWindows = group.windows
        if let preview = folder.preview, !groupWindows.contains(preview.window) {
            preview.setPreview(false)
            folder.preview = nil
        }
        var hasDocuments = false
        for document in documentWindows {
            let belongs = groupWindows.contains(document.window)
            hasDocuments = hasDocuments || belongs
            let sidebar = belongs ? folder.sidebar : nil
            if document.contentState.folderSidebar !== sidebar {
                document.contentState.folderSidebar = sidebar
            }
        }
        if !hasDocuments { endFolderSession() }
        else if let selected = group.selectedWindow { updateFolderSidebar(for: selected) }
    }

    private func updateFolderSidebar(for window: NSWindow) {
        guard let folder else { return }
        if window === folder.landingWindow {
            folder.sidebar.activate(in: window)
            return
        }
        guard folder.group?.windows.contains(window) == true,
              let document = documentWindows.first(where: { $0.window === window }) else { return }
        if document.contentState.folderSidebar !== folder.sidebar {
            document.contentState.folderSidebar = folder.sidebar
        }
        folder.sidebar.activate(in: window)
        folder.browser.setCurrentFile(document.store.fileURL)
        if !document.isPreview {
            folder.announcedPreview = nil
        } else if window.isKeyWindow, folder.announcedPreview !== document, NSWorkspace.shared.isVoiceOverEnabled {
            folder.announcedPreview = document
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: window.tab.toolTip, .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        }
    }

    func toggleCurrentFavoriteFolder() {
        guard let root = folderBrowser?.root else { return }
        let name = root.url.lastPathComponent.isEmpty ? root.url.path : root.url.lastPathComponent
        if favoriteFolders.contains(root) {
            favoriteFolders.remove(root)
            announceFavoriteChange(String(format: settings.text(.favoriteFolderRemoved), name))
            return
        }
        guard favoriteFolderAddition == nil else { return }
        favoriteFolderAddition = Task.detached(priority: .userInitiated) { [weak self] in
            let authorized = try? FolderIndex.authorizeFavorite(root.url)
            await self?.finishAddingFavorite(root, name: name, authorized: authorized)
        }
    }

    private func finishAddingFavorite(_ root: FolderIndex.Root, name: String, authorized: FolderIndex.Root?) {
        guard !Task.isCancelled, !isTerminating, folderBrowser?.root == root else { return }
        favoriteFolderAddition = nil
        guard authorized == root else {
            let alert = NSAlert()
            alert.messageText = settings.text(.favoriteFolderCannotAdd)
            alert.informativeText = settings.text(.folderRootUnavailable)
            let acknowledge = alert.addButton(withTitle: settings.text(.ok))
            acknowledge.setAccessibilityLabel(acknowledge.title)
            acknowledge.setAccessibilityIdentifier("favorite-folder-cannot-add-ok")
            alert.window.setAccessibilityLabel(alert.messageText)
            alert.window.setAccessibilityIdentifier("favorite-folder-cannot-add")
            alert.runModal()
            return
        }
        favoriteFolders.add(root)
        announceFavoriteChange(String(format: settings.text(.favoriteFolderAdded), name))
    }

    func removeFavoriteFolder(_ entry: FavoriteFolderEntry) {
        favoriteFolders.remove(entry)
        announceFavoriteChange(String(format: settings.text(.favoriteFolderRemoved), entry.title))
    }

    func clearFavoriteFolders() {
        favoriteFolderAddition?.cancel()
        favoriteFolderAddition = nil
        favoriteFolders.clear()
        announceFavoriteChange(settings.text(.favoriteFoldersCleared))
    }

    private func presentUnavailableFavorite(_ entry: FavoriteFolderEntry, reason: FolderIndex.FavoriteFailure?) {
        let key: L10nKey
        switch reason {
        case .missingOrMoved: key = .favoriteFolderMoved
        case .permissionDenied: key = .favoriteFolderPermissionDenied
        case .symbolicLinkOrAlias: key = .favoriteFolderLink
        case .unavailable, nil: key = .folderRootUnavailable
        }
        let alert = NSAlert()
        alert.messageText = settings.text(.favoriteFolderUnavailable)
        alert.informativeText = "\(settings.text(key))\n\n\(entry.path)"
        let keep = alert.addButton(withTitle: settings.text(.favoriteFolderKeep))
        let remove = alert.addButton(withTitle: settings.text(.favoriteFolderRemove))
        keep.setAccessibilityLabel(keep.title)
        keep.setAccessibilityIdentifier("favorite-folder-keep")
        remove.setAccessibilityLabel(remove.title)
        remove.setAccessibilityIdentifier("favorite-folder-remove")
        alert.window.setAccessibilityLabel(alert.messageText)
        alert.window.setAccessibilityIdentifier("favorite-folder-unavailable")
        if alert.runModal() == .alertSecondButtonReturn {
            removeFavoriteFolder(entry)
        }
    }

    private func announceFavoriteChange(_ message: String) {
        let element: NSResponder = NSApp.keyWindow ?? NSApp
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }

    func createCopy() {
        guard let store = currentDocumentStore else { return }
        Task { await store.copyFlow.create(from: store, text: settings.text) }
    }

    func browseLocalHistory() {
        guard let store = currentDocumentStore,
              let window = documentWindows.first(where: { $0.store === store })?.window else { return }
        DocumentHistorySheet.present(in: window, store: store, settings: settings,
            makeStore: makeDocumentStore, onOpen: { [weak self] copy in self?.newDocument(store: copy) })
    }

    /// A newly committed copy must open its on-disk bytes in a fresh Store, not
    /// restore an older recovery draft that once happened to use this filename.
    private func openCreatedCopy(_ receipt: DocumentCopyReceipt, from source: DocumentStore) {
        Task {
            guard let store = await source.copyFlow.openCreatedCopy(receipt, from: source,
                text: settings.text, makeStore: makeDocumentStore) else { return }
            let documentWindow = makeDocumentWindow(store: store)
            documentWindow.window.makeKeyAndOrderFront(nil)
            source.copyFlow.dismiss()
        }
    }

    /// Loads `url` into a window. If it is already open, that window is brought
    /// to the front; otherwise an untouched starter window is reused or a new
    /// one is created. Also the open path for Markdown links clicked in a
    /// preview, so linked documents front/dedupe like any other open.
    func openInNewWindow(_ linkURL: URL) {
        let target = DocumentLinkTarget(linkURL)
        openDocument(target) { $0.open(target.fileURL) }
    }

    private func openFolderDocument(
        _ opened: FolderIndex.OpenedFile, decoded: MarkdownFileDecoder.DecodedFile?,
        intent: FolderBrowserController.OpenIntent
    ) throws {
        guard let folder else { return }
        try opened.validate()
        let open = FolderOpen(session: folder, intent: intent, keepTreeFocus: folder.browser.hasTreeFocus)
        try openDocument(DocumentLinkTarget(opened.url), folderFile: opened, folderOpen: open) {
            try $0.openVerifiedFolderFile(opened, decoded: decoded)
        }
    }

    private func openDocument(_ target: DocumentLinkTarget, folderFile: FolderIndex.OpenedFile? = nil,
                              folderOpen: FolderOpen? = nil, load: (DocumentStore) throws -> Void) rethrows {
        let url = target.fileURL
        let resolvedURL = folderFile?.url ?? url.resolvingSymlinksInPath()
        func matches(_ store: DocumentStore) -> Bool {
            guard let openedURL = store.fileURL else { return false }
            if let folderFile {
                return openedURL.standardizedFileURL.path == resolvedURL.path
                    || (try? folderFile.fileReference.validate(at: openedURL.resolvingSymlinksInPath())) != nil
            }
            return openedURL.resolvingSymlinksInPath() == resolvedURL || store.matchesFolderFile(at: url)
        }
        // Run after every open path, including an existing window or restored
        // dirty draft. The fragment uses that window's current text, not disk.
        defer {
            if folderFile == nil || target.fragment != nil {
                documentWindows.first(where: { matches($0.store) })?.store.requestHeadingNavigation(target.fragment)
            }
        }
        for document in documentWindows {
            document.store.refreshFileLocation()
            document.store.detachUnavailableFolderDraft(replacedBy: url, verifiedReference: folderFile?.fileReference)
        }
        if let existing = documentWindows.first(where: { matches($0.store) }) {
            if let folderOpen { presentFolderDocument(existing, open: folderOpen, canPreview: false) }
            else {
                existing.setPreview(false)
                existing.window.makeKeyAndOrderFront(nil)
            }
            // Re-opening an already-open document still bumps its recency,
            // matching platform behavior. (Fresh opens are noted through the
            // window's fileURL transition.)
            noteRecentDocument(url)
            return
        }

        // Explicit opens consume only this file's recovery record. Unrelated
        // drafts stay on disk and in the pending list, including when another
        // file is opened later in this process.
        if restoreDocumentWindows(matching: url, folderFile: folderFile, folderOpen: folderOpen) { return }

        if let reusable = reusableStarter(for: folderOpen) {
            try load(reusable.store)
            if let folderOpen, reusable.store.fileURL != nil {
                presentFolderDocument(reusable, open: folderOpen, canPreview: true)
            } else {
                reusable.window.makeKeyAndOrderFront(nil)
            }
            return
        }

        if let folderOpen {
            // Load before touching the current preview. A stale entry or a
            // decoding error must leave the old tab and its view intact.
            let store = makeDocumentStore()
            try load(store)
            guard store.fileURL != nil else {
                if let selected = folderOpen.session.selectedWindow, let error = store.alert {
                    if let current = documentStore(for: selected) {
                        current.alert = error
                    } else {
                        let alert = NSAlert()
                        alert.messageText = error.message
                        alert.informativeText = error.detail
                        alert.addButton(withTitle: settings.text(.ok))
                        alert.beginSheetModal(for: selected)
                    }
                }
                return
            }
            let document = makeDocumentWindow(store: store, folderSidebar: folderOpen.session.sidebar)
            presentFolderDocument(document, open: folderOpen, canPreview: true)
        } else {
            let document = makeDocumentWindow(store: makeDocumentStore())
            do { try load(document.store) }
            catch {
                document.window.close()
                throw error
            }
            document.window.makeKeyAndOrderFront(nil)
        }
    }

    private func reusableStarter(for open: FolderOpen?) -> DocumentWindow? {
        if let open {
            return documentWindows.first {
                $0.window === open.session.selectedWindow && $0.store.isReusableEmptyDocument
            }
        }
        return documentWindows.first { $0.store.isReusableEmptyDocument }
    }

    private func presentFolderDocument(_ document: DocumentWindow, open: FolderOpen, canPreview: Bool) {
        let session = open.session
        let window = document.window
        let landing = session.landingWindow
        guard let group = session.group ?? window.tabGroup else { return }
        if let landing {
            if canPreview { window.setFrame(landing.frame, display: false) }
            session.host = .tabs(group)
            observeFolderGroup(session)
        }
        let isPreview = open.intent == .preview && (canPreview || document.isPreview)
            && !document.store.isDirty && document.store.fileURL != nil
        let previous = isPreview && session.preview?.isPreview == true ? session.preview : nil
        let replacementIndex = previous.flatMap { group.windows.firstIndex(of: $0.window) }
        if !group.windows.contains(window) {
            if let replacementIndex { group.insertWindow(window, at: replacementIndex) }
            else { group.addWindow(window) }
        }
        if document.contentState.folderSidebar !== session.sidebar {
            document.contentState.folderSidebar = session.sidebar
        }
        document.setPreview(isPreview)
        if isPreview { session.preview = document }
        else if session.preview === document { session.preview = nil }
        if isPreview && !group.isTabBarVisible { window.toggleTabBar(nil) }
        group.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        updateFolderSidebar(for: window)
        landing?.close()

        if let previous, previous !== document {
            // Pin any preview with work that a close would discard, including
            // an uncommitted composition or an in-flight attachment edit.
            let canClose = previous.isPreview && previous.canRetireCleanTab
                && group.windows.contains(previous.window)
            if canClose && previous.store.closeDocument(discardRecovery: true) {
                previous.window.close()
            } else {
                previous.setPreview(false)
            }
        }
        if open.intent == .pinAndFocusEditor {
            document.contentState.focusEditor()
        } else if open.keepTreeFocus {
            session.sidebar.activate(in: window, focusFiles: true)
        }
    }

    /// Restored records stay on disk until explicit window close. An explicit
    /// file open restores its newest matching record; additional versions stay
    /// pending for full session recovery, which preserves them as untitled drafts.
    @discardableResult
    private func restoreDocumentWindows(matching requestedURL: URL? = nil, onlyDirty: Bool = false,
                                        folderFile: FolderIndex.OpenedFile? = nil,
                                        folderOpen: FolderOpen? = nil) -> Bool {
        if let folderFile, (try? folderFile.validate()) == nil { return false }
        if requestedURL == nil, !pendingRecoverySnapshots.isEmpty,
           recoveryRepository.restorationWasInterrupted {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = settings.text(.recoveryInterruptedTitle)
            alert.informativeText = settings.text(.recoveryInterruptedMessage)
            alert.addButton(withTitle: settings.text(.skipRecovery))
            alert.addButton(withTitle: settings.text(.restoreRecovery))
            if alert.runModal() == .alertFirstButtonReturn { return false }
        }
        let snapshots: [DocumentRecoverySnapshot]
        if let requestedURL {
            let match = pendingRecoverySnapshots.last { snapshot in
                if let folderFile, let identity = snapshot.identity,
                   identity.isFolderFile, !identity.matchesFolderEntry(folderFile.fileReference) {
                    return false
                }
                let resolved = snapshot.fileURL.flatMap { snapshot.identity?.resolve(fallback: $0) }
                if snapshot.identity?.isFolderFile == true && resolved == nil { return false }
                let url = resolved ?? snapshot.fileURL
                return url?.resolvingSymlinksInPath() == requestedURL.resolvingSymlinksInPath()
            }
            snapshots = match.map { [$0] } ?? []
        } else {
            snapshots = onlyDirty ? pendingRecoverySnapshots.filter(\.isDirty) : pendingRecoverySnapshots
        }
        let requestedWindow = requestedURL == nil
            ? documentWindows.first(where: { $0.window == NSApp.keyWindow })?.window : nil
        defer { requestedWindow?.makeKeyAndOrderFront(nil) }
        var restoredCount = 0
        do {
            if requestedURL == nil, !snapshots.isEmpty { try recoveryRepository.beginRestoration() }
            var restoredURLs = Set<URL>()
            for var snapshot in snapshots {
                var url = snapshot.fileURL.flatMap { snapshot.identity?.resolve(fallback: $0) } ?? snapshot.fileURL
                if let candidate = url?.resolvingSymlinksInPath(), !restoredURLs.insert(candidate).inserted {
                    if !snapshot.isDirty {
                        try recoveryRepository.remove(snapshot.id)
                        pendingRecoverySnapshots.removeAll { $0.id == snapshot.id }
                        continue
                    }
                    // Two retained drafts can refer to one file (e.g. an earlier
                    // second app instance). Preserve both texts, with only one
                    // writer attached to the original file.
                    snapshot.fileURL = nil
                    snapshot.identity = nil
                    snapshot.fingerprint = nil
                    snapshot.isDirty = true
                    url = nil
                }
                let existing = url.flatMap { url in
                    documentWindows.first { $0.store.fileURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }
                        ?? (requestedURL != nil ? reusableStarter(for: folderOpen) : nil)
                }
                let document: DocumentWindow
                if let existing {
                    let temporaryID = existing.store.recoveryID
                    existing.store.restore(snapshot, openingFolderFile: folderFile)
                    if temporaryID != snapshot.id { try recoveryRepository.remove(temporaryID) }
                    if folderOpen == nil, let frame = snapshot.windowFrame { existing.window.setFrame(from: frame) }
                    document = existing
                } else {
                    let store = makeDocumentStore()
                    store.restore(snapshot, openingFolderFile: folderFile)
                    document = makeDocumentWindow(store: store, folderSidebar: folderOpen?.session.sidebar)
                }
                if let folderOpen { presentFolderDocument(document, open: folderOpen, canPreview: true) }
                else { document.window.makeKeyAndOrderFront(nil) }
                pendingRecoverySnapshots.removeAll { $0.id == snapshot.id }
                restoredCount += 1
            }
            if requestedURL == nil && (recoveryReadFailed || !recoveryRepository.unreadableRecords.isEmpty) {
                showRecoveryReadError()
            }
            if requestedURL == nil, !snapshots.isEmpty { try recoveryRepository.finishRestoration() }
        } catch { showRecoveryReadError() }
        return restoredCount > 0
    }

    private func showRecoveryReadError() {
        let alert = NSAlert()
        alert.messageText = String(format: settings.text(.alertRecoveryUnreadable), recoveryRepository.directory.path)
        alert.addButton(withTitle: settings.text(.ok))
        alert.runModal()
    }

    // MARK: - Recent documents

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
            recentDocuments.remove(url)
            return
        }
        openInNewWindow(url)
    }

    func clearRecentDocuments() {
        recentDocuments.clear()
    }

    /// Records `url` as a recent document.
    private func noteRecentDocument(_ url: URL) {
        recentDocuments.note(url)
    }

    // MARK: - Window management

    @discardableResult
    private func makeDocumentWindow(store: DocumentStore, folderSidebar: FolderSidebarState? = nil) -> DocumentWindow {
        let restoredFrame = folderSidebar == nil ? store.windowFrame : nil
        let contentState = DocumentWindowContentState()
        contentState.folderSidebar = folderSidebar
        let contentView = ContentView(
            document: store,
            settings: settings,
            onOpen: { [weak self] in self?.openDocument() },
            onOpenMarkdownLink: { [weak self] url in self?.openInNewWindow(url) },
            onOpenCreatedCopy: { [weak self, weak store] receipt in
                guard let store else { return }
                self?.openCreatedCopy(receipt, from: store)
            },
            contentState: contentState
        )

        let window = ModeShortcutWindow(
            contentRect: NSRect(x: 0, y: 0, width: DocumentLayoutMetrics.defaultWindowWidth, height: 680),
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
        window.autorecalculatesKeyViewLoop = true

        let previous = documentWindows.last?.window
        // A window asks its delegate for an undo manager once and keeps the
        // answer, creating a private one if the delegate has none. Installing
        // the content view already asks, so register the document first: the
        // window must keep the document's history, not a private stack.
        let documentWindow = DocumentWindow(
            window: window,
            store: store,
            settings: settings,
            contentState: contentState,
            onFileBacked: { [weak self] url in self?.noteRecentDocument(url) },
            onFileURLChanged: { [weak self, weak window] in
                guard let window, window.isKeyWindow else { return }
                self?.updateFolderSidebar(for: window)
            }
        )
        documentWindows.append(documentWindow)
        attachmentCommandState.refresh()
        window.delegate = self
        window.contentView = NSHostingView(rootView: contentView)
        // Let macOS group document windows into native tabs when the user
        // prefers tabs; they can always be torn off into separate windows.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "MD2Document"

        if let previous {
            var origin = previous.frame.origin
            origin = window.cascadeTopLeft(from: NSPoint(x: origin.x, y: origin.y + previous.frame.height))
            window.setFrameTopLeftPoint(origin)
        } else {
            window.center()
        }
        if let frame = restoredFrame { window.setFrame(from: frame) }
        store.windowFrame = window.frameDescriptor
        store.persistRecoveryNow()
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

    /// Edit ▸ Undo acts on the document's own history — the undo manager the
    /// editor's text view registers on — not on a window-private one. AppKit
    /// asks once per window and keeps the answer, which is why
    /// `makeDocumentWindow` registers the document before installing the view.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        documentStore(for: window)?.undoManager
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let store = documentStore(for: sender) else {
            return true
        }
        return confirmDiscardOrSaveIfNeeded(for: store) && store.closeDocument(discardRecovery: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        updateFolderSidebar(for: window)
    }

    func windowDidMove(_ notification: Notification) { recordWindowFrame(notification) }
    func windowDidResize(_ notification: Notification) { recordWindowFrame(notification) }

    private func recordWindowFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        documentStore(for: window)?.windowFrame = window.frameDescriptor
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Detach the file watcher deterministically; releasing the store also
        // cancels it, but the hosting view can keep references alive briefly.
        documentStore(for: window)?.closeDocument(discardRecovery: !isTerminating)
        documentWindows.removeAll { $0.window == window }
        if let folder {
            if window === folder.landingWindow {
                endFolderSession()
            } else if let group = folder.group,
                      !documentWindows.contains(where: { group.windows.contains($0.window) }) {
                endFolderSession()
            }
        }
        attachmentCommandState.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        if !settings.restoresWindowsOnLaunch {
            for documentWindow in documentWindows {
                if !confirmDiscardOrSaveIfNeeded(for: documentWindow.store) {
                    pendingLanguageRelaunch = false
                    documentWindow.window.makeKeyAndOrderFront(nil)
                    return .terminateCancel
                }
            }
            for documentWindow in documentWindows {
                do { try recoveryRepository.remove(documentWindow.store.recoveryID) }
                catch {
                    pendingLanguageRelaunch = false
                    return .terminateCancel
                }
            }
            for snapshot in pendingRecoverySnapshots where !snapshot.isDirty {
                try? recoveryRepository.remove(snapshot.id)
            }
            isTerminating = true
            for documentWindow in documentWindows {
                documentWindow.store.closeDocument(discardRecovery: false)
            }
            return finishHistoryBeforeTermination(sender)
        }
        for documentWindow in documentWindows {
            documentWindow.store.windowFrame = documentWindow.window.frameDescriptor
            if !documentWindow.store.prepareForTermination() {
                pendingLanguageRelaunch = false
                documentWindow.window.makeKeyAndOrderFront(nil)
                return .terminateCancel
            }
        }
        isTerminating = true
        for documentWindow in documentWindows {
            documentWindow.store.closeDocument(discardRecovery: false)
        }
        return finishHistoryBeforeTermination(sender)
    }

    private func finishHistoryBeforeTermination(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The source files and recovery have already been handled. Give the
        // optional history queue a short drain without making it own Quit.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            reply()
        }
        Task {
            await historyRepository.flush()
            deadline.cancel()
            reply()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Only reached once recovery data is durably written; a failed write
        // returns `.terminateCancel` and clears the flag, so arming the
        // relaunch here can never strand a second instance.
        guard pendingLanguageRelaunch else { return }
        relaunchAfterTermination()
    }

    /// Restarts the app so the standard menu bar rebuilds in the newly chosen
    /// language. Terminates through `NSApp.terminate(_:)` — not `exit()` — so
    /// recovery is flushed first; the relaunch itself is armed in
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

@MainActor
private final class FolderSession {
    enum Host {
        case landing(NSWindow)
        case tabs(NSWindowTabGroup)
    }

    let browser: FolderBrowserController
    let sidebar: FolderSidebarState
    var host: Host
    weak var preview: DocumentWindow?
    weak var announcedPreview: DocumentWindow?
    var groupObservation: NSKeyValueObservation?

    init(browser: FolderBrowserController, sidebar: FolderSidebarState, host: Host) {
        self.browser = browser
        self.sidebar = sidebar
        self.host = host
    }

    var landingWindow: NSWindow? {
        if case .landing(let window) = host { return window }
        return nil
    }

    var group: NSWindowTabGroup? {
        if case .tabs(let group) = host { return group }
        return nil
    }

    var selectedWindow: NSWindow? {
        landingWindow ?? group?.selectedWindow
    }
}

private struct FolderOpen {
    let session: FolderSession
    let intent: FolderBrowserController.OpenIntent
    let keepTreeFocus: Bool
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
    let contentState: DocumentWindowContentState
    private(set) var isPreview = false
    private let settings: AppSettings
    private var cancellable: AnyCancellable?
    private var dirtyCancellable: AnyCancellable?
    private var conflictCancellable: AnyCancellable?
    private var encodingCancellable: AnyCancellable?
    private var isPresentingEncoding = false
    private var isPresentingConflict = false
    /// The last file URL reported through `onFileBacked`, so a document
    /// becoming file-backed (open into this window, or an untitled document's
    /// first save) is reported exactly once per URL — re-saves do not re-note.
    private var lastReportedFileURL: URL?
    private var displayedTab = (title: "", previewHelp: Optional<String>.none)

    init(
        window: NSWindow,
        store: DocumentStore,
        settings: AppSettings,
        contentState: DocumentWindowContentState,
        onFileBacked: @escaping (URL) -> Void,
        onFileURLChanged: @escaping () -> Void
    ) {
        self.window = window
        self.store = store
        self.settings = settings
        self.contentState = contentState
        lastReportedFileURL = store.fileURL
        if let url = store.fileURL { onFileBacked(url) }
        updateTabTitle()
        dirtyCancellable = store.$isDirty.sink { [weak self] dirty in
            if dirty { self?.setPreview(false) }
        }
        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateTabTitle()
                if self.store.fileURL != self.lastReportedFileURL {
                    self.lastReportedFileURL = self.store.fileURL
                    if let url = self.store.fileURL { onFileBacked(url) }
                    onFileURLChanged()
                }
            }
        }
        encodingCancellable = store.$encodingConversionRequest.sink { [weak self] request in
            guard request != nil else { return }
            DispatchQueue.main.async { self?.presentEncodingPromptIfNeeded() }
        }
        conflictCancellable = store.$externalConflictRequest.sink { [weak self] request in
            guard request != nil else { return }
            DispatchQueue.main.async {
                self?.presentConflictPromptIfNeeded()
            }
        }
    }

    var canRetireCleanTab: Bool {
        !store.isDirty && store.editorSession.textView?.hasMarkedText() != true
            && !store.isWorkingOnAttachments && !store.isProducingDerivedArtifact
            && !store.backingFileMissing && window.attachedSheet == nil
    }

    func setPreview(_ preview: Bool) {
        guard preview != isPreview else { return }
        isPreview = preview
        updateTabTitle()
    }

    func updateTabTitle() {
        let title = store.displayTitle
        if window.title != title { window.title = title }
        if window.isDocumentEdited != store.isDirty { window.isDocumentEdited = store.isDirty }
        if window.representedURL != store.fileURL { window.representedURL = store.fileURL }
        let previewHelp = isPreview ? String(format: settings.text(.folderPreviewTabHelp), title) : nil
        guard displayedTab != (title, previewHelp) else { return }
        displayedTab = (title, previewHelp)
        if let previewHelp {
            let font = NSFontManager.shared.convert(.systemFont(ofSize: NSFont.smallSystemFontSize), toHaveTrait: .italicFontMask)
            window.tab.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
            window.tab.toolTip = previewHelp
        } else {
            window.tab.attributedTitle = nil
            window.tab.toolTip = title
        }
    }

    private func presentEncodingPromptIfNeeded() {
        guard !isPresentingEncoding, store.encodingConversionRequest != nil else { return }
        isPresentingEncoding = true
        let alert = NSAlert()
        alert.messageText = settings.text(.encodingConversionTitle)
        alert.informativeText = String(format: settings.text(.encodingConversionMessage), store.fileFormat.encodingLabel)
        alert.addButton(withTitle: settings.text(.convertToUTF8))
        alert.addButton(withTitle: settings.text(.cancel))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPresentingEncoding = false
            self.store.resolveEncodingConversion(convertToUTF8: response == .alertFirstButtonReturn)
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
