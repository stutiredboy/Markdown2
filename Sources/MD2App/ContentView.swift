import Foundation
import MD2Core
import SwiftUI

enum FrontMatterMetadataVisibility {
    static func hasDisplayableFrontMatter(in markdown: String) -> Bool {
        !FrontMatterReader.fields(in: markdown).isEmpty
    }
}

enum DocumentLayoutMetrics {
    static let splitEditorMinWidth: CGFloat = 360
    static let splitPreviewMinWidth: CGFloat = 420
    static let outlineSidebarWidth: CGFloat = 230
    static let splitChromeReserveWidth: CGFloat = 36
    static let nonSplitMinWidth: CGFloat = 780

    static func minimumWindowWidth(mode: EditorMode, showsOutline: Bool) -> CGFloat {
        if mode == .split {
            return splitEditorMinWidth
                + splitPreviewMinWidth
                + (showsOutline ? outlineSidebarWidth : 0)
                + splitChromeReserveWidth
        }
        return nonSplitMinWidth
    }
}

enum SplitEditSyncGate {
    static let editSuppressionWindow: TimeInterval = 0.85

    static func suppressionDeadline(afterEditAt date: Date) -> Date {
        date.addingTimeInterval(editSuppressionWindow)
    }

    static func allowsPreviewDrivenEditorSync(now: Date, suppressUntil: Date) -> Bool {
        now >= suppressUntil
    }
}

enum OutlineMoveDirection {
    case up
    case down
}

/// What Esc does in a document surface: a visible find bar is always dismissed
/// first — the mode gesture never fires while one is shown — and only a
/// subsequent Esc (no bar visible) switches single-pane write mode to preview.
/// Read mode and Side by Side have no Esc mode gesture.
enum EscAction: Equatable {
    case dismissFind
    case switchToPreview
    case none
}

enum EscRouting {
    static func action(findBarVisible: Bool, mode: EditorMode) -> EscAction {
        if findBarVisible {
            return .dismissFind
        }
        return mode == .write ? .switchToPreview : .none
    }
}

enum OutlineKeyboardNavigation {
    static func selectedID(
        after move: OutlineMoveDirection,
        in headings: [Heading],
        currentID: String?
    ) -> String? {
        guard !headings.isEmpty else { return nil }
        guard let currentID,
              let currentIndex = headings.firstIndex(where: { $0.id == currentID }) else {
            return move == .up ? headings.last?.id : headings.first?.id
        }

        switch move {
        case .up:
            return headings[max(0, currentIndex - 1)].id
        case .down:
            return headings[min(headings.count - 1, currentIndex + 1)].id
        }
    }
}

struct ContentView: View {
    @ObservedObject var document: DocumentStore
    @ObservedObject var settings: AppSettings
    @State private var mode: EditorMode
    @State private var showsOutline: Bool
    @State private var showsFrontMatterMetadata = false
    /// Latest top-visible source line reported by the editor — the cached
    /// fallback when a live capture is unavailable at switch time.
    @State private var editorAnchorLine = 1
    /// Latest debounced viewport anchor reported by the preview — the cached
    /// fallback when the live capture does not answer in time.
    @State private var previewAnchor: ViewportAnchor?
    /// On-demand readers for the *live* outgoing surface, so a switch right
    /// after a scroll uses the current viewport rather than a stale callback.
    @State private var editorViewport = EditorViewportReader()
    @State private var previewViewport = PreviewViewportReader()
    /// True while a Read→Write switch waits for the preview's async anchor
    /// capture, so repeated requests cannot race each other.
    @State private var isCapturingPreviewAnchor = false
    /// Edit-mode find/replace bar state (write mode).
    @State private var editorFindVisible = false
    @State private var editorFindShowsReplace = false
    @State private var editorFindQuery = ""
    @State private var editorFindReplacement = ""
    @State private var editorFindFocusToken = UUID()
    @State private var editorFindNavigation: FindCommand?
    @State private var editorReplaceCommand: FindReplaceCommand?
    @State private var editorSurfaceFocusToken = UUID()
    @State private var editorMatchTotal = 0
    @State private var editorMatchIndex = 0
    /// Preview-mode find bar state (read mode).
    @State private var previewFindVisible = false
    @State private var previewFindQuery = ""
    @State private var previewFindFocusToken = UUID()
    @State private var previewFindNavigation: FindCommand?
    @State private var previewSurfaceFocusToken = UUID()
    @State private var previewMatchTotal = 0
    @State private var previewMatchIndex = 0
    /// Side by Side: the pane that most recently had user interaction, so a
    /// menu-driven Find routes to the surface the user is actually working in.
    @State private var focusedPane: SplitPane = .editor
    /// Side by Side scroll-sync driver: the pane currently driving the other.
    /// While set, the follower's settle-time anchor reports are ignored so the
    /// two panes cannot oscillate against each other.
    @State private var splitSyncSource: SplitPane?
    /// Re-armed every time a pane drives the sync; the matching delayed reset is
    /// the only one that clears `splitSyncSource`.
    @State private var splitSyncToken = UUID()
    /// Re-armed while the user is editing in Side by Side. Render/layout anchor
    /// reports from the preview during this window are consequences of editing,
    /// not preview scroll gestures, so they must never move the editor.
    @State private var suppressPreviewDrivenEditorSyncUntil = Date.distantPast
    private let onOpen: () -> Void
    /// Opens a local Markdown file the user clicked in the preview, routed up
    /// to the app delegate's open-in-window path.
    private let onOpenMarkdownLink: (URL) -> Void
    private var findDialogEntranceAnimation: Animation { .easeOut(duration: 0.20) }
    private var findDialogExitAnimation: Animation { .easeIn(duration: 0.15) }
    private var findDialogTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    init(
        document: DocumentStore,
        settings: AppSettings,
        onOpen: @escaping () -> Void,
        onOpenMarkdownLink: @escaping (URL) -> Void = { _ in }
    ) {
        self.document = document
        self.settings = settings
        self.onOpen = onOpen
        self.onOpenMarkdownLink = onOpenMarkdownLink
        _mode = State(initialValue: settings.presentationMode(isFileBacked: document.fileURL != nil))
        _showsOutline = State(initialValue: settings.showsOutlineByDefault)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsOutline {
                    OutlineSidebar(
                        headings: document.rendered.outline,
                        selectedHeadingID: document.jumpHeadingID,
                        settings: settings,
                        width: DocumentLayoutMetrics.outlineSidebarWidth,
                        onSelect: document.jump(to:)
                    )
                    Divider()
                }

                editorSurface
            }

            Divider()
            StatusBar(stats: document.rendered.stats, url: document.fileURL, settings: settings)
        }
        .frame(minWidth: minimumWindowWidth, minHeight: 540)
        .navigationTitle(document.displayTitle)
        .onChange(of: document.documentIdentity) { _, _ in
            applyDefaultPresentation()
            showsFrontMatterMetadata = false
            dismissEditorFind()
            dismissPreviewFind()
        }
        .onChange(of: mode) { _, _ in
            dismissEditorFind()
            dismissPreviewFind()
        }
        .onChange(of: document.findCommand) { _, command in
            handleFindCommand(command)
        }
        .onChange(of: document.modeCommand) { _, command in
            handleModeCommand(command)
        }
        .onChange(of: document.pendingExternalReload) { _, token in
            guard token != nil else { return }
            captureAnchorForExternalReload()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    showsOutline.toggle()
                } label: {
                    Label(
                        showsOutline ? settings.text(.hideOutline) : settings.text(.showOutline),
                        systemImage: "sidebar.left"
                    )
                }
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(showsOutline ? settings.text(.hideOutline) : settings.text(.showOutline))
                .help(showsOutline ? settings.text(.hideOutline) : settings.text(.showOutline))
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    onOpen()
                } label: {
                    Label(settings.text(.open), systemImage: "folder")
                }
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(settings.text(.open))
                .help(settings.text(.open))

                Button {
                    document.save()
                } label: {
                    Label(settings.text(.save), systemImage: "square.and.arrow.down")
                }
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(settings.text(.save))
                .help(settings.text(.save))

                if mode != .write, hasDisplayableFrontMatter {
                    Button {
                        showsFrontMatterMetadata.toggle()
                    } label: {
                        Label(
                            showsFrontMatterMetadata ? settings.text(.hideMetadata) : settings.text(.showMetadata),
                            systemImage: "info.circle"
                        )
                    }
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel(
                        showsFrontMatterMetadata ? settings.text(.hideMetadata) : settings.text(.showMetadata)
                    )
                    .help(showsFrontMatterMetadata ? settings.text(.hideMetadata) : settings.text(.showMetadata))
                }

                Picker(
                    settings.text(.mode),
                    selection: Binding(get: { mode }, set: { requestMode($0) })
                ) {
                    Label(settings.text(.write), systemImage: "pencil")
                        .accessibilityLabel(settings.text(.write))
                        .help(settings.text(.write))
                        .tag(EditorMode.write)
                    Label(settings.text(.sideBySide), systemImage: "rectangle.split.2x1")
                        .accessibilityLabel(settings.text(.sideBySide))
                        .help(settings.text(.sideBySide))
                        .tag(EditorMode.split)
                    Label(settings.text(.read), systemImage: "doc.richtext")
                        .accessibilityLabel(settings.text(.read))
                        .help(settings.text(.read))
                        .tag(EditorMode.read)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .accessibilityLabel(settings.text(.mode))
                .help(settings.text(.writeReadOrSplit))
            }
        }
        .alert(item: $document.alert) { alert in
            Alert(
                title: Text(alert.message),
                message: Text(alert.detail),
                dismissButton: .default(Text(settings.text(.ok)))
            )
        }
    }

    private func applyDefaultPresentation() {
        mode = settings.presentationMode(isFileBacked: document.fileURL != nil)
        showsOutline = settings.showsOutlineByDefault
    }

    private var hasDisplayableFrontMatter: Bool {
        FrontMatterMetadataVisibility.hasDisplayableFrontMatter(in: document.text)
    }

    private var showsFrontMatterInPreview: Bool {
        hasDisplayableFrontMatter && showsFrontMatterMetadata
    }

    private var minimumWindowWidth: CGFloat {
        DocumentLayoutMetrics.minimumWindowWidth(mode: mode, showsOutline: showsOutline)
    }

    private func handleModeCommand(_ command: ModeCommand?) {
        guard let command else { return }
        requestMode(command.mode)
    }

    /// The document's backing file changed externally and the store wants to
    /// reload in place: capture the live viewport anchor of the surface the
    /// user is looking at (same machinery as a mode switch) and hand it back,
    /// so the refreshed content lands where the user was reading.
    private func captureAnchorForExternalReload() {
        switch mode {
        case .write, .split:
            document.completeExternalReload(anchor: editorAnchorForPreview())
        case .read:
            previewViewport.currentAnchor { fresh in
                document.completeExternalReload(anchor: previewAnchorForEditor(fresh: fresh))
            }
        }
    }

    /// Esc pressed in the editor text: a visible find bar closes (keeping the
    /// document in its mode, focus back in the editor); only a subsequent Esc
    /// performs the single-pane write→preview gesture. Split never switches.
    private func handleEditorEscape() {
        switch EscRouting.action(findBarVisible: editorFindVisible, mode: mode) {
        case .dismissFind:
            dismissEditorFind(refocusEditor: true)
        case .switchToPreview:
            requestMode(.read)
        case .none:
            break
        }
    }

    /// Esc pressed in the preview page: closes a visible preview find bar and
    /// reports whether the key was consumed (an unconsumed Esc stays available
    /// to the system, e.g. exiting full screen).
    private func handlePreviewEscape() -> Bool {
        guard EscRouting.action(findBarVisible: previewFindVisible, mode: mode) == .dismissFind else {
            return false
        }
        dismissPreviewFind(refocusPreview: true)
        return true
    }

    /// Dispatches a find action from the menu to the active surface.
    private func handleFindCommand(_ command: FindCommand?) {
        guard let command else { return }
        defer { document.findCommand = nil }

        switch mode {
        case .write:
            handleEditorFindAction(command.action)
        case .read:
            handlePreviewFindAction(command.action)
        case .split:
            // Route a menu-driven Find to the pane the user last worked in.
            if focusedPane == .preview {
                handlePreviewFindAction(command.action)
            } else {
                handleEditorFindAction(command.action)
            }
        }
    }

    private func handleEditorFindAction(_ action: FindCommand.Action) {
        switch action {
        case .show:
            showEditorFind(showsReplace: false)
        case .showReplace:
            showEditorFind(showsReplace: true)
        case .next, .previous:
            if editorFindVisible {
                editorFindNavigation = FindCommand(action)
            } else {
                showEditorFind(showsReplace: editorFindShowsReplace)
            }
        }
    }

    private func showEditorFind(showsReplace: Bool) {
        withAnimation(findDialogEntranceAnimation) {
            editorFindVisible = true
            editorFindShowsReplace = showsReplace
        }
        editorFindFocusToken = UUID()
    }

    private func dismissEditorFind(refocusEditor: Bool = false) {
        if editorFindVisible {
            withAnimation(findDialogExitAnimation) {
                editorFindVisible = false
            }
        }
        editorFindQuery = ""
        editorFindNavigation = nil
        editorReplaceCommand = nil
        editorMatchTotal = 0
        editorMatchIndex = 0
        if refocusEditor {
            editorSurfaceFocusToken = UUID()
        }
    }

    private func handlePreviewFindAction(_ action: FindCommand.Action) {
        switch action {
        case .show, .showReplace:
            // Replace is unavailable in preview; both just open the find bar.
            showPreviewFind()
        case .next, .previous:
            if previewFindVisible {
                previewFindNavigation = FindCommand(action)
            }
        }
    }

    private func showPreviewFind() {
        withAnimation(findDialogEntranceAnimation) {
            previewFindVisible = true
        }
        previewFindFocusToken = UUID()
    }

    private func dismissPreviewFind(refocusPreview: Bool = false) {
        if previewFindVisible {
            withAnimation(findDialogExitAnimation) {
                previewFindVisible = false
            }
        }
        previewFindQuery = ""
        previewFindNavigation = nil
        previewMatchTotal = 0
        previewMatchIndex = 0
        if refocusPreview {
            previewSurfaceFocusToken = UUID()
        }
    }

    /// Localized "i of n" match status, "No results", or empty when idle.
    private var previewStatusText: String {
        matchStatusText(query: previewFindQuery, total: previewMatchTotal, index: previewMatchIndex)
    }

    private var editorStatusText: String {
        matchStatusText(query: editorFindQuery, total: editorMatchTotal, index: editorMatchIndex)
    }

    private func matchStatusText(query: String, total: Int, index: Int) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return settings.text(.noResults) }
        return String(format: settings.text(.matchStatus), index, total)
    }

    /// Switches mode, first resolving the outgoing view's viewport anchor to a
    /// target on the incoming view. The anchor is captured fresh from the live
    /// outgoing surface at request time (the cached scroll callback is only the
    /// fallback), and is set on `document` *before* `mode` flips, so the
    /// freshly-created destination view already knows where to land when it
    /// loads — critical for the preview, whose page load can be slow when
    /// heavy diagram/math engines are inlined.
    private func requestMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        // The destination surface reads `rendered` (outline, body) as it mounts;
        // make sure any debounced edit render has landed so it opens current.
        document.flushPendingRender()

        switch mode {
        case .write, .split:
            // The editor pane's anchor is readable synchronously; in Side by
            // Side both panes are aligned, so the editor is the reliable source.
            deliver(anchor: editorAnchorForPreview(), to: newMode)
        case .read:
            // Read → *: ask the live page first; its capture answers fast or
            // times out to the cached debounced anchor.
            guard !isCapturingPreviewAnchor else { return }
            isCapturingPreviewAnchor = true
            previewViewport.currentAnchor { fresh in
                isCapturingPreviewAnchor = false
                guard mode == .read else { return }
                deliver(anchor: previewAnchorForEditor(fresh: fresh), to: newMode)
            }
        }
    }

    /// Publishes the anchor for the incoming view and flips the mode. The
    /// single-target jump bindings are cleared so a leftover outline/find jump
    /// can never override the fresher viewport anchor. Each direction has its
    /// own anchor binding: the outgoing surface's final `updateNSView` pass
    /// must not be able to consume the incoming surface's target.
    private func deliver(anchor: ViewportAnchor, to newMode: EditorMode) {
        document.jumpLine = nil
        document.jumpHeadingID = nil
        document.jumpFraction = nil
        switch newMode {
        case .read:
            document.editorJumpAnchor = nil
            document.previewJumpAnchor = anchor
        case .write:
            document.previewJumpAnchor = nil
            document.editorJumpAnchor = anchor
        case .split:
            // Land both freshly mounted panes on the same content so Side by
            // Side opens aligned to where the user was.
            document.editorJumpAnchor = anchor
            document.previewJumpAnchor = anchor
        }
        // A mode change starts a clean sync slate.
        splitSyncSource = nil
        mode = newMode
        if newMode == .split {
            realignPreviewToEditorAfterEntry()
        }
    }

    /// Entering Side by Side rebuilds the preview web view; its reload can land
    /// the page at the top before the handed-off `previewJumpAnchor` settles
    /// (notably Preview→Split, where the binding is consumed by the outgoing web
    /// view and never reaches the rebuilt one). Once both panes are up, re-drive
    /// the preview from the editor — the reliable source of truth, already landed
    /// on the target line — through `previewJumpAnchor` so it re-pins via the
    /// mode-switch settle loop and survives async math/diagram reflow. Retried so
    /// the realignment lands whether the preview finishes loading early or late.
    private func realignPreviewToEditorAfterEntry() {
        for delay in [0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard mode == .split, splitSyncSource == nil else { return }
                document.previewJumpAnchor = editorAnchorForPreview()
            }
        }
    }

    /// The editor's live viewport anchor (falling back to the last reported
    /// line), completed with the heading/fraction fallbacks the preview needs
    /// when block metadata cannot resolve.
    private func editorAnchorForPreview() -> ViewportAnchor {
        var anchor = editorViewport.currentAnchor() ?? ViewportAnchor(
            sourceLine: editorAnchorLine,
            scrollFraction: fraction(forLine: editorAnchorLine, totalLines: totalLineCount)
        )
        if let line = anchor.sourceLine {
            anchor.fallbackHeadingID = document.rendered.outline.heading(atOrAbove: line)?.id
        }
        return anchor
    }

    /// The preview anchor to apply to the editor: the fresh capture when it
    /// answered, else the cached debounced anchor. A heading-only anchor is
    /// resolved to its source line here, where the outline is known.
    private func previewAnchorForEditor(fresh: ViewportAnchor?) -> ViewportAnchor {
        var anchor = fresh ?? previewAnchor ?? ViewportAnchor()
        if anchor.sourceLine == nil,
           let headingID = anchor.fallbackHeadingID,
           let heading = document.rendered.outline.heading(forID: headingID) {
            anchor.sourceLine = heading.line
            anchor.sourceEndLine = nil
            anchor.intraBlockProgress = 0
        }
        return anchor
    }

    private var totalLineCount: Int {
        document.text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    @ViewBuilder
    private var editorSurface: some View {
        switch mode {
        case .write:
            editorPane(inSplit: false)
        case .read:
            previewPane(inSplit: false)
        case .split:
            // Editor on the left, live preview on the right, with a draggable
            // divider (HSplitView). Each pane is clamped to a usable minimum.
            HSplitView {
                editorPane(inSplit: true)
                    .frame(minWidth: DocumentLayoutMetrics.splitEditorMinWidth)
                previewPane(inSplit: true)
                    .frame(minWidth: DocumentLayoutMetrics.splitPreviewMinWidth)
            }
        }
    }

    /// The editor surface (with its find bar). In Side by Side it also drives
    /// the preview on scroll and claims focus on interaction; the mode-toggle
    /// shortcut (Esc) is disabled so it cannot accidentally leave split.
    @ViewBuilder
    private func editorPane(inSplit: Bool) -> some View {
        ZStack(alignment: .top) {
            MarkdownEditorView(
                text: $document.text,
                jumpLine: $document.jumpLine,
                jumpFraction: $document.jumpFraction,
                jumpAnchor: $document.editorJumpAnchor,
                viewportReader: editorViewport,
                onAnchorLineChange: { line, drivesPreviewSync in
                    editorAnchorLine = line
                    // A genuine user scroll or the mode-switch settle aligns the
                    // preview; an edit-induced caret-reveal scroll must not (the
                    // edit-follow keeps the caret visible instead).
                    if inSplit, drivesPreviewSync { syncEditorToPreview(line: line) }
                },
                onTextEdit: { caretLine in
                    if inSplit { markEditorEditInSplit(caretLine: caretLine) }
                },
                onEnterPreview: { handleEditorEscape() },
                findQuery: $editorFindQuery,
                findNavigation: $editorFindNavigation,
                findReplacement: $editorFindReplacement,
                replaceCommand: $editorReplaceCommand,
                focusToken: editorSurfaceFocusToken,
                focusOnProgrammaticScroll: !inSplit,
                onFindShortcut: { action in
                    if inSplit { focusedPane = .editor }
                    handleEditorFindAction(action)
                },
                onFindResult: { total, index in
                    editorMatchTotal = total
                    editorMatchIndex = index
                },
                onInsertImageAttachments: { sources in
                    document.insertImageAttachments(sources, folder: settings.attachmentFolder)
                }
            )

            if editorFindVisible {
                EditorFindBar(
                    query: $editorFindQuery,
                    replacement: $editorFindReplacement,
                    showsReplace: editorFindShowsReplace,
                    focusToken: editorFindFocusToken,
                    statusText: editorStatusText,
                    settings: settings,
                    onNext: { editorFindNavigation = FindCommand(.next) },
                    onPrevious: { editorFindNavigation = FindCommand(.previous) },
                    onReplace: { editorReplaceCommand = FindReplaceCommand(.current) },
                    onReplaceAll: { editorReplaceCommand = FindReplaceCommand(.all) },
                    onClose: { dismissEditorFind(refocusEditor: true) }
                )
                .transition(findDialogTransition)
                .zIndex(1)
            }
        }
    }

    /// The preview surface (with its find bar). In Side by Side it re-renders in
    /// place as the document changes (`liveUpdate`), drives the editor on scroll,
    /// and claims focus on interaction; the mode-toggle gesture (Cmd+double
    /// click) is disabled so it cannot accidentally leave split.
    @ViewBuilder
    private func previewPane(inSplit: Bool) -> some View {
        ZStack(alignment: .top) {
            MarkdownPreviewView(
                html: document.rendered.html,
                bodyHTML: document.rendered.body,
                baseURL: document.baseURL,
                liveUpdate: inSplit,
                showsFrontMatter: showsFrontMatterInPreview,
                jumpHeadingID: $document.jumpHeadingID,
                jumpFraction: $document.jumpFraction,
                jumpAnchor: $document.previewJumpAnchor,
                viewportReader: previewViewport,
                onAnchorChange: { anchor, isUserInitiated in
                    previewAnchor = anchor
                    if inSplit, isUserInitiated { syncPreviewToEditor(anchor: anchor) }
                },
                onEnterEdit: { if !inSplit { requestMode(.write) } },
                onEscape: { handlePreviewEscape() },
                onToggleTask: { line, checked in
                    if inSplit { focusedPane = .preview }
                    // Capture the live viewport first so the re-render the
                    // toggle triggers can land back where the user was.
                    previewViewport.currentAnchor { fresh in
                        guard document.toggleTask(atLine: line, to: checked) else { return }
                        document.previewJumpAnchor = fresh ?? previewAnchor
                    }
                },
                onOpenMarkdownLink: onOpenMarkdownLink,
                findQuery: $previewFindQuery,
                findNavigation: $previewFindNavigation,
                focusToken: previewSurfaceFocusToken,
                onFindShortcut: { action in
                    if inSplit { focusedPane = .preview }
                    handlePreviewFindAction(action)
                },
                onFindResult: { total, index in
                    previewMatchTotal = total
                    previewMatchIndex = index
                },
                localImageMissingLabel: settings.text(.imageNotFound),
                remoteImageUnavailableLabel: settings.text(.remoteImageUnavailable),
                genericImageLoadFailedLabel: settings.text(.imageLoadFailed)
            )

            if previewFindVisible {
                PreviewFindBar(
                    query: $previewFindQuery,
                    focusToken: previewFindFocusToken,
                    statusText: previewStatusText,
                    settings: settings,
                    onNext: { previewFindNavigation = FindCommand(.next) },
                    onPrevious: { previewFindNavigation = FindCommand(.previous) },
                    onClose: { dismissPreviewFind(refocusPreview: true) }
                )
                .transition(findDialogTransition)
                .zIndex(1)
            }
        }
    }

    // MARK: Side by Side scroll synchronization

    /// Editor scrolled: drive the preview to the matching source position with a
    /// lightweight, continuous follow (no mode-switch pinning), so the preview
    /// tracks the drag smoothly instead of snapping between block tops. Ignored
    /// while the editor is itself following the preview, so the two cannot
    /// oscillate. The editor reports a fractional top line so sub-line scrolling
    /// is reflected continuously.
    private func syncEditorToPreview(line: Int) {
        guard mode == .split, splitSyncSource != .preview else { return }
        markSyncSource(.editor)
        focusedPane = .editor
        let fractionalLine = editorViewport.currentTopFractionalLine() ?? Double(line)
        previewViewport.scrollToFollowLine(fractionalLine)
    }

    /// Preview scrolled: drive the editor to the matching source position with a
    /// lightweight, continuous follow. Ignored while the preview is itself
    /// following the editor.
    private func syncPreviewToEditor(anchor: ViewportAnchor) {
        guard mode == .split,
              splitSyncSource != .editor,
              SplitEditSyncGate.allowsPreviewDrivenEditorSync(
                now: Date(),
                suppressUntil: suppressPreviewDrivenEditorSyncUntil
              ) else { return }
        markSyncSource(.preview)
        focusedPane = .preview
        editorViewport.scrollToFollowLine(fractionalSourceLine(from: anchor))
    }

    /// Text edits are the editor's strongest ownership signal. While the render
    /// pipeline catches up, preview anchor reports are layout fallout, not user
    /// intent, so keep the editor as the sync driver for a short grace window.
    /// The preview is told to keep the caret's source line in view: each coalesced
    /// live re-render applies the follow right after it swaps the content (so the
    /// DOM is current and no `keepPinned` loop competes), and only moves the
    /// preview when that line is off-screen. Edit-induced editor scrolls do not
    /// drive the preview (only genuine user scrolls do — see `onAnchorLineChange`),
    /// and the editor pane is never driven, so this cannot bounce the editor.
    private func markEditorEditInSplit(caretLine: Int) {
        guard mode == .split else { return }
        focusedPane = .editor
        suppressPreviewDrivenEditorSyncUntil = SplitEditSyncGate.suppressionDeadline(afterEditAt: Date())
        markSyncSource(.editor, cooldown: SplitEditSyncGate.editSuppressionWindow)
        previewViewport.setPendingEditFollow(caretLine)
    }

    /// Converts a preview viewport anchor into a fractional source line for the
    /// editor to follow: the block's start line advanced by intra-block progress
    /// across its span, with heading and proportional fallbacks resolved here
    /// where the outline is known.
    private func fractionalSourceLine(from anchor: ViewportAnchor) -> Double {
        if let line = anchor.sourceLine {
            let end = anchor.sourceEndLine ?? line
            let span = Double(max(0, end - line))
            return Double(line) + clampedUnitProgress(anchor.intraBlockProgress) * span
        }
        if let headingID = anchor.fallbackHeadingID,
           let heading = document.rendered.outline.heading(forID: headingID) {
            return Double(heading.line)
        }
        return clampedUnitProgress(anchor.scrollFraction) * Double(max(1, totalLineCount))
    }

    /// Marks `pane` as the current sync driver and arms a short cooldown. The
    /// follower's programmatic scroll suppresses its own anchor reporting, and
    /// this guard ignores the single settle-time report that still arrives, so a
    /// drive in one direction cannot bounce back as a drive in the other.
    private func markSyncSource(_ pane: SplitPane, cooldown: TimeInterval = 0.25) {
        splitSyncSource = pane
        let token = UUID()
        splitSyncToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldown) {
            if splitSyncToken == token {
                splitSyncSource = nil
            }
        }
    }
}

/// The two surfaces of Side by Side mode.
private enum SplitPane {
    case editor
    case preview
}

private struct OutlineSidebar: View {
    let headings: [Heading]
    let selectedHeadingID: String?
    let settings: AppSettings
    let width: CGFloat
    let onSelect: (Heading) -> Void
    @State private var keyboardSelectedHeadingID: String?

    private var activeHeadingID: String? {
        keyboardSelectedHeadingID ?? selectedHeadingID
    }

    /// Selection drives navigation: changing the selected row (mouse, keyboard,
    /// or VoiceOver) scrolls to the heading. Programmatic selection updates from
    /// the document viewport go through `onChange(of: selectedHeadingID)` instead
    /// of this setter, so following the scroll position never re-triggers a jump.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { activeHeadingID },
            set: { newID in
                keyboardSelectedHeadingID = newID
                guard let newID,
                      let heading = headings.first(where: { $0.id == newID }) else {
                    return
                }
                onSelect(heading)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(settings.text(.outline))
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if headings.isEmpty {
                Text(settings.text(.noHeadings))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(14)
                    .accessibilityLabel(settings.text(.noHeadings))
                Spacer()
            } else {
                // A plain (non-Button) List row is the only structure that
                // reliably surfaces the heading title as the row's native
                // accessibility label and its selection as AXSelected; wrapping
                // the row in a Button or attaching an accessibility action makes
                // AppKit drop the label. Navigation is therefore driven by the
                // selection binding, so a mouse click, VoiceOver activation, and
                // Return all scroll to the heading without coordinate clicking.
                List(selection: selectionBinding) {
                    ForEach(headings) { heading in
                        HStack(spacing: 0) {
                            Color.clear
                                .frame(width: CGFloat(max(0, heading.level - 1)) * 12)
                            Text(heading.title)
                                .lineLimit(1)
                                .font(heading.level == 1 ? .callout.weight(.semibold) : .callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(activeHeadingID == heading.id ? .primary : .secondary)
                        .contentShape(Rectangle())
                        .tag(heading.id)
                        .accessibilityHint(settings.text(.navigateToHeading))
                    }
                }
                .listStyle(.sidebar)
                .focusable()
                // Arrow keys move the selection without jumping; Return activates.
                .onMoveCommand(perform: moveSelection)
                .onSubmit(activateSelectedHeading)
            }
        }
        .frame(width: width)
        .background(.regularMaterial)
        .onChange(of: selectedHeadingID) { _, newValue in
            keyboardSelectedHeadingID = newValue
        }
    }

    private func activate(_ heading: Heading) {
        keyboardSelectedHeadingID = heading.id
        onSelect(heading)
    }

    private func activateSelectedHeading() {
        guard let id = activeHeadingID,
              let heading = headings.first(where: { $0.id == id }) else {
            return
        }
        activate(heading)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !headings.isEmpty else { return }
        let move: OutlineMoveDirection
        switch direction {
        case .up:
            move = .up
        case .down:
            move = .down
        default:
            return
        }
        keyboardSelectedHeadingID = OutlineKeyboardNavigation.selectedID(
            after: move,
            in: headings,
            currentID: activeHeadingID
        )
    }
}

private struct StatusBar: View {
    let stats: DocumentStats
    let url: URL?
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 14) {
            Text("\(stats.words) \(settings.text(.words))")
            Text("\(stats.characters) \(settings.text(.chars))")
            Text("\(stats.lines) \(settings.text(.lines))")
            Text("\(stats.readingMinutes) \(settings.text(.minRead))")

            Spacer()

            if let url {
                Text(url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.bar)
    }
}
