import AppKit
import Combine

/// Owns the folder tree and Quick Open state while the sidebar moves between tabs.
@MainActor
final class FolderBrowserController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    enum OpenIntent: Int {
        case preview
        case pin
        case pinAndFocusEditor
    }

    typealias OpenDocument = (FolderIndex.OpenedFile, MarkdownFileDecoder.DecodedFile?, OpenIntent) throws -> Void

    let root: FolderIndex.Root
    let view = NSView()
    private let text: (L10nKey) -> String
    private let favorites: FavoriteFoldersModel
    private let onToggleFavorite: () -> Void
    private let scan: @Sendable (FolderIndex.Root) throws -> FolderIndex.Snapshot
    private let onOpen: OpenDocument

    private let search = NSSearchField()
    private let outline = FolderBrowserOutline()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let favoriteButton = NSButton()
    private let refreshButton = NSButton()
    private let cancelButton = NSButton()
    private let openButton = NSButton()
    private let progress = NSProgressIndicator()

    private var scanTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var activeOpen: OpenRequest?
    private var queuedOpens: [OpenRequest] = []
    private var favoritesObservation: AnyCancellable?
    private var watcher: FolderIndexWatcher?
    private var isStarted = false
    private var needsRefresh = false
    private var pendingRefresh: Task<Void, Never>?
    private var snapshot: FolderIndex.Snapshot?
    private var indexIssue: L10nKey?
    private var openIssue: L10nKey?
    private var query = ""
    private var tree: [Item] = []
    private var searchIndex: [SearchMatch] = []
    private var indexedPaths: Set<String> = []
    private var visibleItems: [Item] = []
    private var expandedFolders: Set<String> = []
    private var selectedTreeID: String?
    private var currentFileURL: URL?
    private var currentFilePath: String?

    init(
        root: FolderIndex.Root,
        text: @escaping (L10nKey) -> String,
        favorites: FavoriteFoldersModel,
        onToggleFavorite: @escaping () -> Void,
        scan: @escaping @Sendable (FolderIndex.Root) throws -> FolderIndex.Snapshot = { try FolderIndex.scan($0) },
        onOpen: @escaping OpenDocument
    ) {
        self.root = root
        self.text = text
        self.favorites = favorites
        self.onToggleFavorite = onToggleFavorite
        self.scan = scan
        self.onOpen = onOpen
        super.init()
        configureContents()
        updateLocalizedText()
        favoritesObservation = favorites.$entries.dropFirst().sink { [weak self] entries in
            guard let self else { return }
            updateFavoriteButton(isFavorite: entries.contains { $0.url == root.url })
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Subscribe before scanning so changes during the initial traversal
        // invalidate its result as well.
        watcher = FolderIndexWatcher(root: root) { [weak self] in
            self?.invalidateIndex()
        }
        beginScan()
    }

    func stop() {
        isStarted = false
        watcher = nil
        pendingRefresh?.cancel()
        scanTask?.cancel()
        openTask?.cancel()
        pendingRefresh = nil
        scanTask = nil
        openTask = nil
        activeOpen = nil
        queuedOpens.removeAll()
        needsRefresh = false
    }

    var hasTreeFocus: Bool { view.window?.firstResponder === outline }

    var hasQuickOpenFocus: Bool {
        guard let responder = view.window?.firstResponder else { return false }
        return responder === search || responder === search.currentEditor()
    }

    func focusTree() {
        view.window?.makeFirstResponder(outline)
    }

    func focusQuickOpen() {
        search.selectText(nil)
    }

    func setCurrentFile(_ url: URL?) {
        guard url != currentFileURL else { return }
        currentFileURL = url
        let path = url.map(browserPath(of:))
        guard path != currentFilePath else { return }
        currentFilePath = path
        outline.enumerateAvailableRowViews { [self] _, row in
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FolderBrowserCell else {
                return
            }
            cell.setCurrentFile(isCurrentFile(outline.item(atRow: row) as? Item))
        }
    }

    func canReveal(_ url: URL) -> Bool { indexedPaths.contains(browserPath(of: url)) }

    func reveal(_ url: URL) {
        let filePath = browserPath(of: url)
        guard indexedPaths.contains(filePath) else { return }
        focusTree()
        search.stringValue = ""
        readQuery()
        guard let path = treePath(to: filePath, in: tree), let file = path.last else { return }
        for folder in path.dropLast() { outline.expandItem(folder) }
        selectRow(outline.row(forItem: file))
    }

    private func browserPath(of url: URL) -> String {
        let path = url.path
        let rootPath = root.url.path
        let prefix = rootPath == "/" ? rootPath : rootPath + "/"
        if path.hasPrefix(prefix) { return path }
        // A document opened through File > Open can retain an ancestor alias
        // such as /var. The index uses the kernel's canonical path.
        return FolderIndex.canonicalPath(of: url) ?? path
    }

    private func treePath(to path: String, in items: [Item]) -> [Item]? {
        for item in items {
            if item.file?.url.path == path { return [item] }
            if let children = item.children, let suffix = treePath(to: path, in: children) { return [item] + suffix }
        }
        return nil
    }

    private func configureContents() {
        let path = NSTextField(labelWithString: root.url.path)
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.cell?.truncatesLastVisibleLine = true
        path.toolTip = root.url.path
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setAccessibilityIdentifier("folder-root-path")

        favoriteButton.setButtonType(.pushOnPushOff)
        favoriteButton.bezelStyle = .rounded
        favoriteButton.imagePosition = .imageOnly
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        favoriteButton.setAccessibilityIdentifier("folder-favorite-toggle")
        favoriteButton.setContentHuggingPriority(.required, for: .horizontal)
        favoriteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        favoriteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        let pathRow = NSStackView(views: [path, favoriteButton])
        pathRow.distribution = .fill
        pathRow.alignment = .centerY
        pathRow.spacing = 8

        search.delegate = self
        search.target = self
        search.action = #selector(searchAction)
        search.sendsSearchStringImmediately = true
        search.maximumRecents = 0
        search.setAccessibilityIdentifier("folder-quick-open")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder-name"))
        column.resizingMask = [.autoresizingMask]
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 24
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.onClick = { [weak self] item, count in self?.clickedItem(item, count: count) }
        outline.onReturn = { [weak self] in self?.openSelection(intent: .pinAndFocusEditor) }
        outline.onSpace = { [weak self] in self?.openSelection(intent: .preview) }
        outline.setAccessibilityIdentifier("folder-file-list")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("folder-status")
        status.setContentCompressionResistancePriority(.required, for: .vertical)

        configure(refreshButton, symbol: "arrow.clockwise", identifier: "folder-refresh", action: #selector(refresh))
        configure(cancelButton, symbol: "xmark", identifier: "folder-cancel-scan", action: #selector(cancelScan))
        configure(openButton, identifier: "folder-open-selection", action: #selector(openSelectedFile))

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityElement(false)
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let spacer = NSView()
        let actions = NSStackView(views: [refreshButton, cancelButton, progress, spacer, openButton])
        actions.alignment = .centerY
        actions.spacing = 8
        actions.detachesHiddenViews = true

        let body = NSStackView(views: [pathRow, search, scroll, status, actions])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            pathRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            search.widthAnchor.constraint(equalTo: body.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            status.widthAnchor.constraint(equalTo: body.widthAnchor),
            actions.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])
    }

    private func configure(_ button: NSButton, symbol: String? = nil, identifier: String, action: Selector) {
        button.bezelStyle = .rounded
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
        }
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    func updateLocalizedText() {
        search.placeholderString = text(.folderFilterPlaceholder)
        search.setAccessibilityLabel(text(.folderQuickOpenField))
        outline.setAccessibilityLabel(text(.folderFileList))
        openButton.title = text(.folderOpenSelection)
        for (button, key) in [(refreshButton, L10nKey.folderRefresh), (cancelButton, .folderCancelScan),
                              (openButton, .folderOpenSelection)] {
            let label = text(key)
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        updateFavoriteButton(isFavorite: favorites.contains(root))
        updateState()
    }

    private func updateFavoriteButton(isFavorite: Bool) {
        let label = text(isFavorite ? .favoriteFolderRemoveCurrent : .favoriteFolderAddCurrent)
        favoriteButton.image = NSImage(systemSymbolName: isFavorite ? "star.fill" : "star", accessibilityDescription: nil)
        favoriteButton.toolTip = label
        favoriteButton.setAccessibilityLabel(label)
        favoriteButton.state = isFavorite ? .on : .off
    }

    @objc private func toggleFavorite() {
        // The model remains authoritative while a new favorite is being revalidated.
        favoriteButton.state = favorites.contains(root) ? .on : .off
        onToggleFavorite()
    }

    @objc private func refresh() {
        openIssue = nil
        beginScan()
    }

    private func invalidateIndex() {
        guard isStarted else { return }
        needsRefresh = true
        schedulePendingRefresh()
    }

    private func schedulePendingRefresh() {
        guard needsRefresh, scanTask == nil, pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            // Coalesce event batches, especially during directory copies or saves.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            pendingRefresh = nil
            beginScan(priority: .utility)
        }
    }

    private func beginScan(priority: TaskPriority = .userInitiated) {
        guard isStarted, scanTask == nil else { return }
        pendingRefresh?.cancel()
        pendingRefresh = nil
        needsRefresh = false
        indexIssue = nil
        let root = self.root
        let scan = self.scan
        scanTask = Task { [weak self] in
            do {
                let snapshot = try await Self.runInBackground(priority: priority) { try scan(root) }
                guard let self, !Task.isCancelled else { return }
                scanTask = nil
                replaceSnapshot(snapshot)
                updateState(announce: true)
                schedulePendingRefresh()
            } catch {
                guard let self, !Task.isCancelled else { return }
                scanTask = nil
                indexIssue = .folderRootUnavailable
                replaceSnapshot(nil)
                updateState(announce: true)
                schedulePendingRefresh()
            }
        }
        updateState()
    }

    @objc private func cancelScan() {
        guard let scanTask else { return }
        scanTask.cancel()
        self.scanTask = nil
        needsRefresh = false
        indexIssue = snapshot == nil ? .folderScanCancelled : .folderRefreshCancelled
        updateState(announce: true)
    }

    private nonisolated static func runInBackground<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func replaceSnapshot(_ snapshot: FolderIndex.Snapshot?) {
        rememberTreeState()
        let selection = selectedItem?.id
        self.snapshot = snapshot
        tree = snapshot?.nodes.map(Item.init(node:)) ?? []
        searchIndex = snapshot?.files.map(SearchMatch.init(file:)) ?? []
        indexedPaths = Set(snapshot?.files.map { $0.url.path } ?? [])
        reloadRows(selecting: selection)
    }

    func controlTextDidChange(_ notification: Notification) {
        readQuery()
    }

    @objc private func searchAction() {
        // NSSearchField's clear button also sends its action.
        readQuery()
    }

    private func readQuery() {
        if let editor = search.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        let next = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != query else { return }
        rememberTreeState()
        query = next
        if openIssue == .folderFileUnavailable || openIssue == .folderFileTooLarge { openIssue = nil }
        reloadRows(selecting: nil)
        updateState()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard control === search, !textView.hasMarkedText() else { return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            readQuery()
            openSelection(intent: .pinAndFocusEditor)
        case #selector(NSResponder.cancelOperation(_:)):
            guard !search.stringValue.isEmpty else { return false }
            search.stringValue = ""
            readQuery()
        default:
            return false
        }
        return true
    }

    private func moveSelection(by offset: Int) {
        let count = outline.numberOfRows
        guard count > 0 else { return }
        let selected = outline.selectedRow
        let row = selected < 0 ? (offset > 0 ? 0 : count - 1) : min(max(selected + offset, 0), count - 1)
        selectRow(row)
        if query.isEmpty { focusTree() }
    }

    private func selectRow(_ row: Int) {
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    private func rememberTreeState() {
        guard query.isEmpty else { return }
        selectedTreeID = selectedItem?.id
        expandedFolders = Set((0..<outline.numberOfRows).compactMap { row in
            guard let item = outline.item(atRow: row) as? Item, outline.isItemExpanded(item) else {
                return nil
            }
            return item.id
        })
    }

    private func reloadRows(selecting selection: String?) {
        if query.isEmpty {
            visibleItems = tree
        } else {
            let foldedQuery = Self.fold(query)
            let words = foldedQuery.split(whereSeparator: \.isWhitespace)
            var exactMatches: [Item] = []
            var nameMatches: [Item] = []
            var pathMatches: [Item] = []
            for candidate in searchIndex {
                if candidate.foldedName == foldedQuery {
                    exactMatches.append(candidate.item)
                } else if words.allSatisfy({ candidate.foldedName.contains($0) }) {
                    nameMatches.append(candidate.item)
                } else if words.allSatisfy({ candidate.foldedPath.contains($0) }) {
                    pathMatches.append(candidate.item)
                }
            }
            visibleItems = exactMatches + nameMatches + pathMatches
        }
        outline.rowHeight = query.isEmpty ? 24 : 39
        outline.reloadData()
        if query.isEmpty { restoreExpandedFolders(in: visibleItems) }

        let selectionID = query.isEmpty ? selectedTreeID : selection
        let visibleRows = 0..<outline.numberOfRows
        if let selectionID,
           let row = visibleRows.first(where: { (outline.item(atRow: $0) as? Item)?.id == selectionID }) {
            selectRow(row)
        } else if !query.isEmpty, !visibleRows.isEmpty {
            selectRow(0)
        } else {
            outline.deselectAll(nil)
        }
    }

    private func restoreExpandedFolders(in items: [Item]) {
        for item in items where expandedFolders.contains(item.id) {
            guard let children = item.children else { continue }
            outline.expandItem(item)
            restoreExpandedFolders(in: children)
        }
    }

    private var selectedItem: Item? {
        let row = outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? Item : nil
    }

    private func clickedItem(_ item: Any, count: Int) {
        guard let item = item as? Item else { return }
        activate(item, intent: count == 1 ? .preview : .pin)
    }

    @objc private func openSelectedFile() {
        openSelection(intent: .pinAndFocusEditor)
    }

    private func openSelection(intent: OpenIntent) {
        guard let item = selectedItem else { return }
        activate(item, intent: intent)
    }

    private struct OpenRequest {
        let file: FolderIndex.File
        var intent: OpenIntent

        mutating func promote(to intent: OpenIntent) {
            if intent.rawValue > self.intent.rawValue { self.intent = intent }
        }
    }

    private func activate(_ item: Item, intent: OpenIntent) {
        guard isStarted else { return }
        guard let file = item.file else {
            guard intent != .preview else { return }
            if outline.isItemExpanded(item) { outline.collapseItem(item) }
            else { outline.expandItem(item) }
            return
        }
        // A new request supersedes an uncommitted preview. Keep explicit pin
        // requests queued and upgrade a preview already reading the same file.
        queuedOpens.removeAll { $0.intent == .preview }
        if activeOpen?.file == file {
            activeOpen?.promote(to: intent)
            return
        }
        if let index = queuedOpens.firstIndex(where: { $0.file == file }) {
            queuedOpens[index].promote(to: intent)
            return
        }
        queuedOpens.append(OpenRequest(file: file, intent: intent))
        if activeOpen?.intent == .preview {
            openTask?.cancel()
            openTask = nil
            activeOpen = nil
        }
        beginNextOpen()
    }

    private func beginNextOpen() {
        guard openTask == nil, !queuedOpens.isEmpty else { return }
        let request = queuedOpens.removeFirst()
        activeOpen = request
        openIssue = nil
        let file = request.file
        let root = self.root
        openTask = Task { [weak self] in
            let result: Result<(FolderIndex.OpenedFile, MarkdownFileDecoder.DecodedFile?), Error>
            do {
                result = .success(try await Self.runInBackground {
                    let opened = try FolderIndex.open(file, in: root)
                    try Task.checkCancellation()
                    return (opened, MarkdownFileDecoder.decode(opened.data))
                })
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            finishOpen(result)
        }
        updateState()
    }

    private func finishOpen(_ result: Result<(FolderIndex.OpenedFile, MarkdownFileDecoder.DecodedFile?), Error>) {
        guard let request = activeOpen else { return }
        openTask = nil
        activeOpen = nil
        do {
            let (opened, decoded) = try result.get()
            try onOpen(opened, decoded, request.intent)
            updateState()
        } catch {
            switch error as? FolderIndex.Failure {
            case .rootUnavailable:
                scanTask?.cancel()
                scanTask = nil
                indexIssue = .folderRootUnavailable
                replaceSnapshot(nil)
                schedulePendingRefresh()
            case .fileTooLarge:
                openIssue = .folderFileTooLarge
            default:
                openIssue = .folderFileUnavailable
            }
            updateState(announce: true)
        }
        beginNextOpen()
    }

    private func updateState(announce: Bool = false) {
        let scanning = scanTask != nil
        let opening = openTask != nil
        let message: String
        if let openIssue {
            message = text(openIssue)
        } else if opening {
            message = text(.folderOpening)
        } else if let indexIssue {
            message = text(indexIssue)
        } else if scanning {
            message = text(.folderScanning)
        } else if let snapshot {
            var lines = [countMessage(snapshot)]
            if snapshot.isLimited { lines.append(text(.folderScanLimited)) }
            if snapshot.hasUnreadableItems { lines.append(text(.folderScanUnreadable)) }
            message = lines.joined(separator: "\n")
        } else {
            message = ""
        }
        status.stringValue = message
        refreshButton.isEnabled = !scanning
        if !scanning, view.window?.firstResponder === cancelButton { focusQuickOpen() }
        cancelButton.isHidden = !scanning
        if scanning || opening { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        updateOpenButton()

        if announce, let window = view.window, window.isKeyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        }
    }

    private func countMessage(_ snapshot: FolderIndex.Snapshot) -> String {
        let isSearching = !query.isEmpty
        let count = isSearching ? visibleItems.count : snapshot.files.count
        switch (count, isSearching) {
        case (0, false): return text(.folderNoFiles)
        case (0, true): return text(.noResults)
        case (1, false): return text(.folderOneFile)
        case (1, true): return text(.folderOneMatch)
        default:
            return String(format: text(isSearching ? .folderMatchCount : .folderFileCount), count.formatted())
        }
    }

    private func updateOpenButton() {
        openButton.isEnabled = selectedItem?.file != nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateOpenButton()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !children(of: item).isEmpty
    }

    private func children(of item: Any?) -> [Item] {
        item == nil ? visibleItems : (item as? Item)?.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("folder-item-cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? FolderBrowserCell
            ?? FolderBrowserCell()
        cell.identifier = identifier
        cell.show(name: item.name, file: item.file, showPath: !query.isEmpty)
        cell.setCurrentFile(isCurrentFile(item))
        return cell
    }

    private func isCurrentFile(_ item: Item?) -> Bool {
        guard let currentFilePath else { return false }
        return item?.file?.url.path == currentFilePath
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private final class Item: NSObject {
        let id: String
        let name: String
        let children: [Item]?
        let file: FolderIndex.File?

        init(node: FolderIndex.Node) {
            id = node.id
            name = node.name
            children = node.children?.map(Item.init(node:))
            file = node.file
        }

        init(file: FolderIndex.File) {
            id = file.id
            name = file.name
            children = nil
            self.file = file
        }
    }

    private struct SearchMatch {
        let item: Item
        let foldedName: String
        let foldedPath: String

        @MainActor init(file: FolderIndex.File) {
            item = Item(file: file)
            foldedName = FolderBrowserController.fold(file.name)
            foldedPath = FolderBrowserController.fold(file.relativePath)
        }
    }
}

private final class FolderBrowserOutline: NSOutlineView {
    var onClick: ((Any, Int) -> Void)?
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?

    private static let commandModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let clickedItem = row >= 0 ? item(atRow: row) as? NSObject : nil
        super.mouseDown(with: event)
        guard event.modifierFlags.intersection(Self.commandModifiers).isEmpty,
              let clickedItem, selectedRow >= 0,
              (item(atRow: selectedRow) as? NSObject) === clickedItem else { return }
        onClick?(clickedItem, event.clickCount)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(Self.commandModifiers).isEmpty {
            switch event.charactersIgnoringModifiers {
            case "\r", "\u{3}":
                if !event.isARepeat { onReturn?() }
                return
            case " ":
                if !event.isARepeat { onSpace?() }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

private final class FolderBrowserCell: NSTableCellView {
    private static let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    private static let fileIcon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Assign the primary field so AppKit supplies the usual row label,
        // selection styling and VoiceOver behavior for a table cell.
        textField = nameLabel
        imageView = icon

        let labels = NSStackView(views: [nameLabel, pathLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        labels.detachesHiddenViews = true
        labels.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
            pathLabel.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(name: String, file: FolderIndex.File?, showPath: Bool) {
        nameLabel.stringValue = name
        let relativePath = showPath ? file?.relativePath : nil
        let parentPath = relativePath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        nameLabel.setAccessibilityLabel(relativePath ?? name)
        pathLabel.stringValue = parentPath
        pathLabel.isHidden = parentPath.isEmpty
        pathLabel.setAccessibilityElement(false)
        toolTip = file?.relativePath ?? name
        icon.image = file == nil ? Self.folderIcon : Self.fileIcon
    }

    func setCurrentFile(_ isCurrent: Bool) {
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: isCurrent ? .semibold : .regular)
        icon.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor
        nameLabel.setAccessibilityIdentifier(isCurrent ? "folder-current-file" : nil)
    }
}
