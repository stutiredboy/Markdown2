import AppKit
import Combine

/// Browses one explicitly chosen folder. The index contains names and paths;
/// files are opened through the app's document window pipeline.
@MainActor
final class FolderBrowserWindowController: NSWindowController, NSWindowDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    typealias OpenDocument = (FolderIndex.OpenedFile, MarkdownFileDecoder.DecodedFile?) throws -> Void

    let root: FolderIndex.Root
    private let text: (L10nKey) -> String
    private let favorites: FavoriteFoldersModel
    private let onToggleFavorite: () -> Void
    private let onOpen: OpenDocument
    private let onClose: () -> Void

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
    private var favoritesObservation: AnyCancellable?
    private var shouldRefreshOnActivation = false
    private var snapshot: FolderIndex.Snapshot?
    private var issue: L10nKey?
    private var query = ""
    private var tree: [Item] = []
    private var searchIndex: [SearchMatch] = []
    private var visibleItems: [Item] = []
    private var expandedFolders: Set<String> = []
    private var selectedTreeID: String?

    init(
        root: FolderIndex.Root,
        text: @escaping (L10nKey) -> String,
        favorites: FavoriteFoldersModel,
        onToggleFavorite: @escaping () -> Void,
        onOpen: @escaping OpenDocument,
        onClose: @escaping () -> Void
    ) {
        self.root = root
        self.text = text
        self.favorites = favorites
        self.onToggleFavorite = onToggleFavorite
        self.onOpen = onOpen
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 570, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.setAccessibilityIdentifier("folder-browser-window")
        window.contentMinSize = NSSize(width: 390, height: 290)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        configureContents(in: window)
        updateLocalizedText()
        favoritesObservation = favorites.$entries.dropFirst().sink { [weak self] entries in
            guard let self else { return }
            updateFavoriteButton(isFavorite: entries.contains { $0.url == root.url })
        }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(quickOpen: Bool = false) {
        guard let window else { return }
        if !window.isVisible && scanTask == nil { refresh() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if quickOpen { search.selectText(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        scanTask?.cancel()
        openTask?.cancel()
        scanTask = nil
        openTask = nil
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        shouldRefreshOnActivation = true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard shouldRefreshOnActivation else { return }
        shouldRefreshOnActivation = false
        if scanTask == nil && openTask == nil { refresh() }
    }

    private func configureContents(in window: NSWindow) {
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
        outline.usesAlternatingRowBackgroundColors = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openClickedRow)
        outline.onReturn = { [weak self] in self?.openSelection() }
        outline.setAccessibilityIdentifier("folder-file-list")

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("folder-status")
        status.setContentCompressionResistancePriority(.required, for: .vertical)

        configure(refreshButton, identifier: "folder-refresh", action: #selector(refresh))
        configure(cancelButton, identifier: "folder-cancel-scan", action: #selector(cancelScan))
        configure(openButton, identifier: "folder-open-selection", action: #selector(openSelection))

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

        let content = NSView()
        content.addSubview(body)
        window.contentView = content
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            pathRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            search.widthAnchor.constraint(equalTo: body.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            status.widthAnchor.constraint(equalTo: body.widthAnchor),
            actions.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])

        window.initialFirstResponder = search
        window.autorecalculatesKeyViewLoop = true
    }

    private func configure(_ button: NSButton, identifier: String, action: Selector) {
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    func updateLocalizedText() {
        let name = root.url.lastPathComponent.isEmpty ? root.url.path : root.url.lastPathComponent
        window?.title = String(format: text(.folderWindowTitle), name)
        search.placeholderString = text(.folderFilterPlaceholder)
        search.setAccessibilityLabel(text(.folderQuickOpenField))
        outline.setAccessibilityLabel(text(.folderFileList))
        refreshButton.title = text(.folderRefresh)
        cancelButton.title = text(.folderCancelScan)
        openButton.title = text(.folderOpenSelection)
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
        guard scanTask == nil, openTask == nil else { return }
        issue = nil
        let root = self.root
        scanTask = Task { [weak self] in
            do {
                let snapshot = try await Self.runInBackground { try FolderIndex.scan(root) }
                guard let self, !Task.isCancelled else { return }
                scanTask = nil
                replaceSnapshot(snapshot)
                updateState(announce: true)
            } catch {
                guard let self, !Task.isCancelled else { return }
                scanTask = nil
                issue = .folderRootUnavailable
                replaceSnapshot(nil)
                updateState(announce: true)
            }
        }
        updateState()
    }

    @objc private func cancelScan() {
        guard let scanTask else { return }
        scanTask.cancel()
        self.scanTask = nil
        issue = snapshot == nil ? .folderScanCancelled : .folderRefreshCancelled
        updateState(announce: true)
    }

    private nonisolated static func runInBackground<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
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
        if issue == .folderFileUnavailable || issue == .folderFileTooLarge { issue = nil }
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
            openSelection()
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
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        if query.isEmpty { window?.makeFirstResponder(outline) }
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
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else if !query.isEmpty, !visibleRows.isEmpty {
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            outline.scrollRowToVisible(0)
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

    @objc private func openClickedRow() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) as? Item else { return }
        activate(item)
    }

    @objc private func openSelection() {
        guard let item = selectedItem else { return }
        activate(item)
    }

    private func activate(_ item: Item) {
        guard let file = item.file else {
            if outline.isItemExpanded(item) { outline.collapseItem(item) }
            else { outline.expandItem(item) }
            return
        }
        guard openTask == nil else { return }
        // A previously listed item can open while a refresh is in progress.
        // Its path and identity are validated independently of the snapshot.
        scanTask?.cancel()
        scanTask = nil
        issue = nil
        let root = self.root
        openTask = Task { [weak self] in
            do {
                let (opened, decoded) = try await Self.runInBackground {
                    let opened = try FolderIndex.open(file, in: root)
                    try Task.checkCancellation()
                    return (opened, MarkdownFileDecoder.decode(opened.data))
                }
                guard let self, !Task.isCancelled else { return }
                openTask = nil
                updateState()
                try onOpen(opened, decoded)
            } catch {
                guard let self, !Task.isCancelled else { return }
                openTask = nil
                switch error as? FolderIndex.Failure {
                case .rootUnavailable:
                    issue = .folderRootUnavailable
                    replaceSnapshot(nil)
                case .fileTooLarge:
                    issue = .folderFileTooLarge
                default:
                    issue = .folderFileUnavailable
                }
                updateState(announce: true)
            }
        }
        updateState()
    }

    private func updateState(announce: Bool = false) {
        let scanning = scanTask != nil
        let opening = openTask != nil
        let message: String
        if let issue {
            message = text(issue)
        } else if opening {
            message = text(.folderOpening)
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
        refreshButton.isEnabled = !scanning && !opening
        if !scanning, window?.firstResponder === cancelButton { window?.makeFirstResponder(search) }
        cancelButton.isHidden = !scanning
        if scanning || opening { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        updateOpenButton()

        if announce, let window, window.isKeyWindow {
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
        openButton.isEnabled = openTask == nil && selectedItem?.file != nil
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
        return cell
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
            foldedName = FolderBrowserWindowController.fold(file.name)
            foldedPath = FolderBrowserWindowController.fold(file.relativePath)
        }
    }
}

private final class FolderBrowserOutline: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}" {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
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
}
