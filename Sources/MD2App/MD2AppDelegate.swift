import AppKit
import Combine
import MD2AppSupport
import SwiftUI

@MainActor
final class MD2AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = AppSettings()
    let windowCommandState = WindowCommandState()
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
    private var documentSubmenuObservation: AnyCancellable?
    private var modeShortcutObservation: AnyCancellable?
    /// Shortcuts that have been registered as mode shortcuts during this run.
    /// Consuming stale entries here keeps an old binding from doing anything
    /// after the user customizes it.
    private var knownModeShortcuts = Set<ModeKeyboardShortcut>()

    override init() {
        super.init()
        let notifications = NotificationCenter.default
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            notifications.addObserver(self, selector: #selector(nativeMenuItemDidChange),
                                      name: name, object: nil)
        }
        windowCommandState.observe { [weak self] in
            self?.currentWindowCommandContext ?? .init()
        }
        documentSubmenuObservation = windowCommandState.$context
            .map { $0.document != nil }
            .removeDuplicates()
            // Read the committed state in case changing a native item posts another notification.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshDocumentSubmenus() }
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
                self.refreshDocumentSubmenus()
            }
        }
    }

    @objc private func nativeMenuItemDidChange(_ notification: Notification) {
        FavoriteFoldersMenu.updateNativeAccessibility(notification, settings: settings)
        guard let mainMenu = NSApp.mainMenu,
              let menu = notification.object as? NSMenu, menu.supermenu === mainMenu,
              let index = notification.userInfo?["NSMenuItemIndex"] as? Int,
              let item = menu.item(at: index) else { return }
        updateDocumentSubmenu(item)
    }

    private func refreshDocumentSubmenus() {
        for item in NSApp.mainMenu?.items ?? [] {
            item.submenu?.items.forEach(updateDocumentSubmenu)
        }
    }

    /// SwiftUI leaves the generated NSMenuItem enabled when `.disabled` applies
    /// to a Menu. Synchronize the two headers without replacing their submenus.
    private func updateDocumentSubmenu(_ item: NSMenuItem) {
        let enabled = windowCommandState.context.document != nil
        guard item.hasSubmenu, item.isEnabled != enabled,
              item.title == settings.text(.exportTo) || item.title == settings.text(.tableOperations)
        else { return }
        item.isEnabled = enabled
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

    private var currentWindowCommandContext: WindowCommandState.Context {
        WindowCommandState.Context(
            document: currentDocumentStore,
            canClose: currentClosableWindow != nil,
            canFocusFolderBrowser: folder?.selectedWindow != nil,
            canRevealInFolderBrowser: revealableDocumentURL != nil
        )
    }

    func contentState(for store: DocumentStore) -> DocumentWindowContentState? {
        documentWindows.first(where: { $0.store === store })?.contentState
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
        refreshDocumentSubmenus()
        historyRepository.pruneExpired()
        let recentDirectories = Set(recentDocuments.urls.map { $0.deletingLastPathComponent() })
        Task.detached(priority: .background) {
            for directory in recentDirectories { LegacyPreviewCleaner.clean(in: directory) }
        }
        let launchURLs = fileURLsFromLaunchArguments()
        if !launchURLs.isEmpty {
            for url in launchURLs { openInNewWindow(url) }
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

    /// Opens a fresh, empty document. `store` is injected so
    /// tests can supply a save location without the modal `NSSavePanel`.
    @discardableResult
    func newDocument(store: DocumentStore? = nil) -> NSWindow {
        let document = makeDocumentWindow(store: store ?? makeDocumentStore())
        presentIndependentDocument(document)
        return document.window
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
    /// no save/discard logic is duplicated.
    func closeCurrentDocument() {
        currentClosableWindow?.performClose(nil)
    }

    private var currentClosableWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow {
            return keyWindow === folder?.landingWindow
                ? keyWindow : documentWindows.first(where: { $0.window === keyWindow })?.window
        }
        if let landing = folder?.landingWindow,
           NSApp.mainWindow === landing || documentWindows.isEmpty {
            return landing
        }
        guard let store = currentDocumentStore else { return nil }
        return documentWindows.first(where: { $0.store === store })?.window
    }

    /// Presents an open panel and loads every selected file.
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

    private var revealableDocumentURL: URL? {
        guard let folder, folder.selectedWindow != nil, let url = currentDocumentStore?.fileURL,
              folder.browser.canReveal(url) else { return nil }
        return url
    }

    func revealInFolderBrowser() {
        guard let folder, let window = folder.selectedWindow, let url = revealableDocumentURL else {
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
            let currentGroup = current?.window.tabGroup
            let canReuseGroup = currentGroup.map { $0 === folder?.group || $0.windows.count == 1 } ?? false
            let starter = canReuseGroup
                ? current.flatMap { $0.store.isReusableEmptyDocument && $0.canRetireCleanTab ? $0 : nil } : nil
            let previousLanding = folder?.landingWindow
            endFolderSession()
            let isFavorite = favoriteFolders.contains(root)
            let remoteImages = FolderRemoteImages(
                rootPath: root.url.path,
                isAllowed: favoriteFolders.allowsRemoteImages(in: root),
                isFavorite: isFavorite && root.favoriteRemoteImageGrantID != nil,
                canRememberPermission: root.favoriteRemoteImageGrantID != nil
            )
            let browser = FolderBrowserController(
                root: root, text: settings.text, favorites: favoriteFolders,
                onToggleFavorite: { [weak self] in self?.toggleCurrentFavoriteFolder() },
                remoteImages: remoteImages,
                onIndexInvalidated: { [weak self] in self?.refreshFolderRemoteImages() },
                onIndexChanged: { [weak self] in self?.windowCommandState.refresh() },
                isTemporaryPreview: { [weak self] file in
                    guard let preview = self?.folder?.preview, preview.isPreview else { return false }
                    return preview.store.matchesFolderFile(file)
                },
                onOpen: { [weak self] opened, decoded, intent in
                    try self?.openFolderDocument(opened, decoded: decoded, intent: intent)
                }
            )
            let sidebar = FolderSidebarState(browserView: browser.view, focusBrowser: { [weak browser] in
                browser?.focusTree()
            })
            sidebar.onShowFiles = { [weak self] window in
                self?.documentWindows.first { $0.window === window }?.contentState.sidebarRevealRequest = UUID()
            }
            let host: FolderSession.Host
            if starter == nil, canReuseGroup, let group = currentGroup {
                host = .tabs(group)
            } else {
                let frame = previousLanding?.frame ?? starter?.window.frame
                host = .landing(makeFolderLanding(root: root, sidebar: sidebar, frame: frame))
            }
            let session = FolderSession(
                browser: browser, sidebar: sidebar, host: host, remoteImages: remoteImages, isFavorite: isFavorite
            )
            remoteImages.onPermissionChange = { [weak self, weak session] allowed in
                guard let self, let session, self.folder === session else { return }
                self.setFolderRemoteImages(allowed, in: session)
            }
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
        session.selectionObservation = session.group?.observe(\.selectedWindow) { [weak self, weak session] _, _ in
            DispatchQueue.main.async {
                guard let self, let session, self.folder === session else { return }
                self.updateFolderPreviewSelection(in: session)
                self.windowCommandState.refresh()
            }
        }
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
        folder.remoteImages.isAllowed = false
        for document in documentWindows {
            if document.contentState.folderSidebar === folder.sidebar {
                document.contentState.folderSidebar = nil
                document.contentState.isFolderPreviewSelected = false
            }
            if document.contentState.folderRemoteImages === folder.remoteImages {
                applyFolderRemoteImages(to: document, in: nil, member: nil)
            }
        }
        favoriteFolders.currentRoot = nil
        favoriteFolderAddition?.cancel()
        favoriteFolderAddition = nil
        windowCommandState.refresh()
    }

    private func reconcileFolderTabs() {
        defer { windowCommandState.refresh() }
        guard let folder, var group = folder.group else { return }
        // Merge All Windows can move the folder's entire group into the
        // frontmost independent group. Follow the surviving folder documents.
        if group.windows.isEmpty,
           let moved = documentWindows.first(where: { $0.contentState.folderSidebar === folder.sidebar }),
           let destination = moved.window.tabGroup {
            group = destination
            folder.host = .tabs(destination)
            observeFolderGroup(folder)
        }
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
                if !belongs { document.contentState.isFolderPreviewSelected = false }
            }
        }
        if !hasDocuments {
            endFolderSession()
        } else {
            updateFolderPreviewSelection(in: folder)
            refreshFolderRemoteImages()
            if let selected = group.selectedWindow { updateFolderSidebar(for: selected) }
        }
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
        updateFolderPreviewSelection(in: folder)
        refreshFolderRemoteImages(for: document)
        if !document.isPreview {
            folder.announcedPreview = nil
        } else if window.isKeyWindow, folder.announcedPreview !== document, NSWorkspace.shared.isVoiceOverEnabled {
            folder.announcedPreview = document
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: window.tab.toolTip ?? document.store.displayTitle,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        }
    }

    private func setFolderRemoteImages(_ allowed: Bool, in session: FolderSession) {
        let root = session.browser.root
        guard !allowed || FolderIndex.isCurrent(root) else {
            refreshFolderRemoteImages()
            return
        }
        favoriteFolders.setRemoteImagesAllowed(allowed, in: root)
        if session.remoteImages.isAllowed != allowed { session.remoteImages.isAllowed = allowed }
        refreshFolderRemoteImages()
    }

    private func folderFavoriteStatusChanged() {
        guard let session = folder else { return }
        let root = session.browser.root
        let isFavorite = favoriteFolders.contains(root)
        guard session.isFavorite != isFavorite else { return }
        session.isFavorite = isFavorite
        session.remoteImages.isFavorite = isFavorite && root.favoriteRemoteImageGrantID != nil
        setFolderRemoteImages(isFavorite && session.remoteImages.isAllowed, in: session)
    }

    private func updateFolderPreviewSelection(in session: FolderSession) {
        session.browser.updateOpenButton()
        guard let group = session.group else { return }
        let selected = group.selectedWindow
        for document in documentWindows where document.contentState.folderSidebar === session.sidebar {
            let showing = document.window === selected && document.window.isVisible && !document.window.isMiniaturized
            if document.contentState.isFolderPreviewSelected != showing {
                document.contentState.isFolderPreviewSelected = showing
            }
        }
    }

    private func refreshFolderRemoteImages() {
        if let folder, folder.remoteImages.isAllowed, !FolderIndex.isCurrent(folder.browser.root) {
            folder.remoteImages.isAllowed = false
        }
        for document in documentWindows {
            refreshFolderRemoteImages(for: document)
        }
    }

    private func refreshFolderRemoteImages(for document: DocumentWindow) {
        let member = folder.flatMap { folderRemoteImageMember(document, in: $0) }
        applyFolderRemoteImages(to: document, in: folder, member: member)
    }

    private func folderRemoteImageMember(_ document: DocumentWindow, in session: FolderSession) -> Data? {
        guard session.group?.windows.contains(document.window) == true,
              let backing = document.store.remoteImageBacking,
              let url = FolderIndex.verifyRemoteImageMember(at: backing.url, in: session.browser.root,
                                                           reference: backing.reference) else { return nil }
        // Use the verified relative file location as the session exception key.
        // Comparing bytes keeps distinct filenames apart on byte-sensitive volumes.
        return Data(url.path.utf8)
    }

    private func applyFolderRemoteImages(to document: DocumentWindow, in session: FolderSession?,
                                         member: Data?) {
        let permission = member == nil ? nil : session?.remoteImages
        if document.contentState.folderRemoteImages !== permission {
            document.contentState.folderRemoteImages = permission
        }
        let blocked = member.map { member in
            session?.blockedRemoteImagePaths.contains(member) == true
        } ?? false
        document.store.setFolderRemoteImages(allowed: permission?.isAllowed == true, blockedForFile: blocked)
    }

    private func setFolderRemoteImageOverride(_ choice: RemoteImageOverride, for document: DocumentWindow) {
        guard let folder, let member = folderRemoteImageMember(document, in: folder) else {
            applyFolderRemoteImages(to: document, in: nil, member: nil)
            return
        }
        if choice == .block { folder.blockedRemoteImagePaths.insert(member) }
        else { folder.blockedRemoteImagePaths.remove(member) }
        applyFolderRemoteImages(to: document, in: folder, member: member)
    }

    func toggleCurrentFavoriteFolder() {
        guard let root = folderBrowser?.root else { return }
        let name = root.url.lastPathComponent.isEmpty ? root.url.path : root.url.lastPathComponent
        if favoriteFolders.contains(root) {
            favoriteFolders.remove(root)
            folderFavoriteStatusChanged()
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
        folderFavoriteStatusChanged()
        announceFavoriteChange(String(format: settings.text(.favoriteFolderAdded), name))
    }

    func removeFavoriteFolder(_ entry: FavoriteFolderEntry) {
        favoriteFolders.remove(entry)
        folderFavoriteStatusChanged()
        announceFavoriteChange(String(format: settings.text(.favoriteFolderRemoved), entry.title))
    }

    func clearFavoriteFolders() {
        favoriteFolderAddition?.cancel()
        favoriteFolderAddition = nil
        favoriteFolders.clear()
        folderFavoriteStatusChanged()
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
            presentIndependentDocument(makeDocumentWindow(store: store))
            source.copyFlow.dismiss()
        }
    }

    /// Loads `url` into a window. If it is already open, that window is brought
    /// to the front; otherwise an untouched starter window is reused or a new
    /// one is created. Also the open path for Markdown links clicked in a
    /// preview, so linked documents front/dedupe like any other open.
    func openInNewWindow(_ linkURL: URL) {
        let target = DocumentLinkTarget(linkURL)
        openDocument(target) { store, _ in store.open(target.fileURL) }
    }

    private func openFolderDocument(
        _ opened: FolderIndex.OpenedFile, decoded: MarkdownFileDecoder.DecodedFile?,
        intent: FolderBrowserController.OpenIntent
    ) throws {
        guard !isTerminating, let folder else { return }
        try opened.validate()
        let open = FolderOpen(session: folder, intent: intent, keepTreeFocus: folder.browser.hasTreeFocus,
                              canReplacePreview: decoded != nil)
        try openDocument(DocumentLinkTarget(opened.url), folderFile: opened, folderOpen: open) { store, replacing in
            try store.openVerifiedFolderFile(opened, decoded: decoded, replacingCleanPreview: replacing)
        }
    }

    private func openDocument(_ target: DocumentLinkTarget, folderFile: FolderIndex.OpenedFile? = nil,
                              folderOpen: FolderOpen? = nil, load: (DocumentStore, Bool) throws -> Void) rethrows {
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

        if let folderOpen, folderOpen.intent == .preview, folderOpen.canReplacePreview,
           let preview = folderOpen.session.preview, preview.isPreview, preview.canRetireCleanTab,
           folderOpen.session.group?.windows.contains(preview.window) == true {
            // Swap the verified contents in place, so a single preview does
            // not briefly acquire a second tab as the user skims the tree.
            try load(preview.store, true)
            if matches(preview.store) {
                folderOpen.session.announcedPreview = nil
                presentFolderDocument(preview, open: folderOpen, canPreview: true)
            }
            return
        }

        if let reusable = reusableStarter(for: folderOpen) {
            try load(reusable.store, false)
            if let folderOpen, reusable.store.fileURL != nil {
                presentFolderDocument(reusable, open: folderOpen, canPreview: true)
            } else {
                presentIndependentDocument(reusable)
            }
            return
        }

        if let folderOpen {
            // Load before touching the current preview. A stale entry or a
            // decoding error must leave the old tab and its view intact.
            let store = makeDocumentStore()
            try load(store, false)
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
            do { try load(document.store, false) }
            catch {
                document.window.close()
                throw error
            }
            if document.store.fileURL != nil {
                presentIndependentDocument(document)
            } else {
                document.present()
            }
        }
    }

    private func reusableStarter(for open: FolderOpen?) -> DocumentWindow? {
        if let open {
            return documentWindows.first {
                $0.window === open.session.selectedWindow && $0.store.isReusableEmptyDocument
            }
        }
        let group = independentTabGroup()
        return documentWindows.first {
            $0.window.tabGroup !== folder?.group && $0.store.isReusableEmptyDocument && $0.canRetireCleanTab
                && (group == nil || $0.window.tabGroup === group)
        }
    }

    private func presentFolderDocument(_ document: DocumentWindow, open: FolderOpen, canPreview: Bool) {
        let session = open.session
        let window = document.window
        let landing = session.landingWindow
        guard let group = session.group ?? window.tabGroup else { return }
        if let landing, canPreview { window.setFrame(landing.frame, display: false) }
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
        group.selectedWindow = window
        document.present()
        if let landing {
            session.host = .tabs(group)
            observeFolderGroup(session)
            landing.close()
        }
        updateFolderSidebar(for: window)

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
        if session.sidebar.isVisible, session.sidebar.section == .files {
            // The user opened this document from Files. Carry the visible tree
            // into the selected tab, including the first one after a landing.
            document.contentState.sidebarRevealRequest = UUID()
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
            // A different hard-linked name can address the same interrupted
            // save. Prove the identity before choosing its recovery record.
            let linkedFileKey = folderFile == nil && pendingRecoverySnapshots.contains { $0.linkedSave?.fileKey != nil }
                ? DocumentHistoryFileID(url: requestedURL.resolvingSymlinksInPath())?.storageKey : nil
            let linkedMatch = linkedFileKey.flatMap { key in
                pendingRecoverySnapshots.last { $0.isDirty && $0.linkedSave?.fileKey == key }
            }
            let match = linkedMatch ?? pendingRecoverySnapshots.last { snapshot in
                if let folderFile, let identity = snapshot.identity,
                   identity.isFolderFile, !identity.matchesFolderEntry(folderFile.fileReference) {
                    return false
                }
                let resolved = snapshot.fileURL.flatMap { snapshot.identity?.resolve(fallback: $0) }
                if snapshot.identity?.isFolderFile == true && resolved == nil { return false }
                let url = resolved ?? snapshot.fileURL
                return url?.resolvingSymlinksInPath() == requestedURL.resolvingSymlinksInPath()
            }
            snapshots = match.map { snapshot in
                guard let linkedFileKey, snapshot.linkedSave?.fileKey == linkedFileKey else { return [snapshot] }
                var rebound = snapshot
                rebound.fileURL = requestedURL
                rebound.identity = DocumentFileIdentity(url: requestedURL)
                return [rebound]
            } ?? []
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
            let needsLinkedDeduplication = snapshots.count > 1 && snapshots.contains { $0.linkedSave?.fileKey != nil }
            let destinations = snapshots.map { snapshot in
                let url = snapshot.fileURL.flatMap { snapshot.identity?.resolve(fallback: $0) } ?? snapshot.fileURL
                let key = needsLinkedDeduplication ? url.flatMap {
                    DocumentHistoryFileID(url: $0.resolvingSymlinksInPath())?.storageKey
                } : nil
                return (snapshot, url, key)
            }
            let linkedDrafts = destinations.reduce(into: [String: UUID]()) { drafts, destination in
                let (snapshot, _, key) = destination
                if let key, snapshot.isDirty, snapshot.linkedSave?.fileKey == key { drafts[key] = snapshot.id }
            }
            for (var snapshot, var url, key) in destinations {
                let sharesLinkedDraft = key.flatMap { linkedDrafts[$0] }.map { $0 != snapshot.id } ?? false
                let reusesURL = !sharesLinkedDraft
                    && (url.map { !restoredURLs.insert($0.resolvingSymlinksInPath()).inserted } ?? false)
                if sharesLinkedDraft || reusesURL {
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
                    snapshot.linkedSave = nil
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
                    document = existing
                } else {
                    let store = makeDocumentStore()
                    store.restore(snapshot, openingFolderFile: folderFile)
                    document = makeDocumentWindow(store: store, folderSidebar: folderOpen?.session.sidebar)
                }
                if let folderOpen { presentFolderDocument(document, open: folderOpen, canPreview: true) }
                else { presentIndependentDocument(document, restoredFrame: snapshot.windowFrame) }
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

    private func independentTabGroup(excluding window: NSWindow? = nil) -> NSWindowTabGroup? {
        guard settings.preferTabsForDocuments else { return nil }
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            + NSApp.orderedWindows + documentWindows.reversed().map(\.window)
        return candidates.lazy.compactMap { candidate -> NSWindowTabGroup? in
            guard candidate !== window, candidate is ModeShortcutWindow,
                  candidate.isVisible || candidate.isMiniaturized,
                  let group = candidate.tabGroup, group !== self.folder?.group else { return nil }
            return group
        }.first
    }

    private func presentIndependentDocument(_ document: DocumentWindow, restoredFrame: String? = nil) {
        let window = document.window
        if !window.hasPresentedDocument, let group = independentTabGroup(excluding: window) {
            group.addWindow(window)
            group.selectedWindow = window
        } else if window.tabGroup?.windows.count == 1, let restoredFrame {
            window.setFrame(from: restoredFrame)
        }
        document.present()
    }

    @discardableResult
    private func makeDocumentWindow(store: DocumentStore, folderSidebar: FolderSidebarState? = nil) -> DocumentWindow {
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
        window.onSurfaceFocus = { [weak contentState] pane in contentState?.surfaceDidFocus.send(pane) }
        contentState.window = window
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
                guard let self else { return }
                if let window, window.isKeyWindow {
                    self.updateFolderSidebar(for: window)
                }
                self.windowCommandState.refresh()
            }
        )
        documentWindow.onPreviewChanged = { [weak self] in self?.folder?.browser.updateOpenButton() }
        documentWindows.append(documentWindow)
        store.onRemoteImageBackingChanged = { [weak self, weak documentWindow] in
            guard let self, let documentWindow,
                  self.folder != nil || documentWindow.contentState.folderRemoteImages != nil else { return }
            self.refreshFolderRemoteImages(for: documentWindow)
        }
        store.onRemoteImageOverrideChanged = { [weak self, weak documentWindow] choice in
            guard let self, let documentWindow, self.folder != nil else { return }
            self.setFolderRemoteImageOverride(choice, for: documentWindow)
        }
        windowCommandState.refresh()
        window.delegate = self
        window.contentView = NSHostingView(rootView: contentView)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "MD2Document"

        if let previous {
            var origin = previous.frame.origin
            origin = window.cascadeTopLeft(from: NSPoint(x: origin.x, y: origin.y + previous.frame.height))
            window.setFrameTopLeftPoint(origin)
        } else {
            window.center()
        }
        return documentWindow
    }

    private func fileURLsFromLaunchArguments() -> [URL] {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let normalized = DirectLaunchBootstrap.normalizedRelaunchArguments(arguments)
        return DirectLaunchBootstrap.documentArgumentIndices(arguments).compactMap { index in
            let url = URL(fileURLWithPath: normalized[index])
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue ? url : nil
        }
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
        (window as? ModeShortcutWindow)?.refreshTabPresentation()
        updateFolderSidebar(for: window)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if let folder { updateFolderPreviewSelection(in: folder) }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if let folder { updateFolderPreviewSelection(in: folder) }
    }

    func windowDidMove(_ notification: Notification) { recordWindowFrame(notification) }
    func windowDidResize(_ notification: Notification) { recordWindowFrame(notification) }

    private func recordWindowFrame(_ notification: Notification) {
        guard let window = notification.object as? ModeShortcutWindow, window.hasPresentedDocument else { return }
        let group = window.tabGroup
        guard group?.selectedWindow == nil || group?.selectedWindow === window else { return }
        let frame = window.frameDescriptor
        for document in documentWindows where document.window === window || group?.windows.contains(document.window) == true {
            document.store.windowFrame = frame
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Detach the file watcher deterministically; releasing the store also
        // cancels it, but the hosting view can keep references alive briefly.
        documentStore(for: window)?.closeDocument(discardRecovery: !isTerminating)
        (window as? ModeShortcutWindow)?.stopObservingTabPresentation()
        documentWindows.removeAll { $0.window == window }
        if let folder {
            if window === folder.landingWindow {
                endFolderSession()
            } else {
                // The native group and its selected window settle after the
                // close notification.
                DispatchQueue.main.async { self.reconcileFolderTabs() }
            }
        }
        windowCommandState.refresh()
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
            let window = documentWindow.window
            documentWindow.store.windowFrame = (window.tabGroup?.selectedWindow ?? window).frameDescriptor
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
    let remoteImages: FolderRemoteImages
    var isFavorite: Bool
    var blockedRemoteImagePaths = Set<Data>()
    var host: Host
    weak var preview: DocumentWindow?
    weak var announcedPreview: DocumentWindow?
    var groupObservation: NSKeyValueObservation?
    var selectionObservation: NSKeyValueObservation?

    init(browser: FolderBrowserController, sidebar: FolderSidebarState, host: Host,
         remoteImages: FolderRemoteImages, isFavorite: Bool) {
        self.browser = browser
        self.sidebar = sidebar
        self.host = host
        self.remoteImages = remoteImages
        self.isFavorite = isFavorite
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
    let canReplacePreview: Bool
}

final class ModeShortcutWindow: NSWindow {
    var onSurfaceFocus: ((SplitPane) -> Void)?
    var modeShortcutHandler: ((NSEvent) -> Bool)?
    private(set) var hasPresentedDocument = false
    private var groupObservation: NSKeyValueObservation?
    private var tabObservations: [NSKeyValueObservation] = []
    private weak var observedGroup: NSWindowTabGroup?
    private var lastTabCount = 1

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let previous = firstResponder
        let accepted = super.makeFirstResponder(responder)
        if accepted, let current = firstResponder, previous !== current, let pane = SplitPane.containing(current) {
            // AppKit can change the responder while SwiftUI mounts a surface.
            // Publish after layout, and only if this exact responder still owns focus.
            DispatchQueue.main.async { [weak self, weak current] in
                guard let self, let current, self.firstResponder === current else { return }
                self.onSurfaceFocus?(pane)
            }
        }
        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if modeShortcutHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func presentDocument() {
        if hasPresentedDocument {
            makeKeyAndOrderFront(nil)
            return
        }
        hasPresentedDocument = true
        // AppKit consults the system preference on the first order-front.
        // Keep the group chosen by the app and then restore native commands.
        let previous = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        makeKeyAndOrderFront(nil)
        NSWindow.allowsAutomaticWindowTabbing = previous
        if let group = tabGroup, group.windows.count == 1, group.isTabBarVisible {
            super.toggleTabBar(nil)
        }
        groupObservation = observe(\.tabGroup) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshTabPresentation() }
        }
        refreshTabPresentation()
    }

    override func toggleTabBar(_ sender: Any?) {
        super.toggleTabBar(sender)
        DispatchQueue.main.async { [weak self] in self?.refreshTabPresentation() }
    }

    func refreshTabPresentation() {
        guard groupObservation != nil else { return }
        let group = tabGroup
        if observedGroup !== group {
            observedGroup = group
            tabObservations = []
            if let group {
                tabObservations = [
                    group.observe(\.windows) { [weak self] _, _ in
                        DispatchQueue.main.async { self?.refreshTabPresentation() }
                    },
                    group.observe(\.selectedWindow) { [weak self] _, _ in
                        DispatchQueue.main.async { self?.refreshTabPresentation() }
                    },
                    group.observe(\.isTabBarVisible) { [weak self] _, _ in
                        DispatchQueue.main.async { self?.refreshTabPresentation() }
                    }
                ]
            }
        }
        // Default visibility follows changes between one and several tabs.
        // Within the same membership count, honor the native toggle action.
        if let group, let selected = group.selectedWindow {
            let tabCount = group.windows.count
            let hadMultipleTabs = lastTabCount >= 2
            let hasMultipleTabs = tabCount >= 2
            lastTabCount = tabCount
            if selected === self, hadMultipleTabs != hasMultipleTabs, group.isTabBarVisible != hasMultipleTabs {
                super.toggleTabBar(nil)
            }
        }
        let visibility: NSWindow.TitleVisibility = group?.isTabBarVisible == true ? .hidden : .visible
        if titleVisibility != visibility { titleVisibility = visibility }
    }

    func stopObservingTabPresentation() {
        groupObservation = nil
        tabObservations = []
    }
}

/// Pairs an `NSWindow` with the document it presents, keeps the window's
/// title in sync with the document (filename and unsaved-changes marker), and
/// presents the external-change conflict prompt the store requests.
@MainActor
final class DocumentWindow {
    let window: ModeShortcutWindow
    let store: DocumentStore
    let contentState: DocumentWindowContentState
    private(set) var isPreview = false
    var onPreviewChanged: (() -> Void)?
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
        window: ModeShortcutWindow,
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
            && !store.backingFileMissing && !store.hasExternalConflict && window.attachedSheet == nil
            && !store.copyFlow.isRunning && !store.copyFlow.isOpening && store.copyFlow.message == nil
    }

    func present() {
        updateTabTitle()
        window.presentDocument()
        store.windowFrame = window.frameDescriptor
        store.persistRecoveryNow()
    }

    func setPreview(_ preview: Bool) {
        guard preview != isPreview else { return }
        isPreview = preview
        updateTabTitle()
        onPreviewChanged?()
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

    private func presentConflictPromptIfNeeded() {
        guard !isPresentingConflict, store.hasExternalConflict, store.externalConflictRequest != nil else { return }
        isPresentingConflict = true
        window.makeKeyAndOrderFront(nil)

        guard store.offersLinkedSaveRepair else {
            ExternalConflictSheet.present(in: window, store: store, settings: settings) { [weak self] in
                self?.isPresentingConflict = false
                self?.presentConflictPromptIfNeeded()
            }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = settings.text(.linkedSaveInterruptedTitle)
        alert.informativeText = settings.text(.linkedSaveInterruptedMessage)
        let later = alert.addButton(withTitle: settings.text(.linkedSaveLater))
        later.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: settings.text(.finishLinkedSave)).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPresentingConflict = false
            self.store.resolveLinkedSaveRepair(finish: response == .alertSecondButtonReturn)
        }
    }
}
