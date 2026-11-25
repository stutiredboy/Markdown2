import AppKit
import Combine
import MD2Core
import SwiftUI

@MainActor
final class DocumentWindowContentState: ObservableObject {
    @Published var folderSidebar: FolderSidebarState? {
        didSet {
            sidebarObservation = folderSidebar?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
    @Published var folderRemoteImages: FolderRemoteImages? {
        didSet {
            remoteImagesObservation = folderRemoteImages?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
    /// Last reported location, also used by the app menu when replacing the preview host.
    var previewAnchor: ViewportAnchor?
    let remoteResourceSheet = RemoteResourceSheet()
    let surfaceDidFocus = PassthroughSubject<SplitPane, Never>()

    @Published var isFolderPreviewSelected = false
    @Published private(set) var editorFocusRequest: UUID?
    @Published var sidebarRevealRequest: UUID?
    private var sidebarObservation: AnyCancellable?
    private var remoteImagesObservation: AnyCancellable?

    func focusEditor() {
        folderSidebar?.cancelPendingFocus()
        editorFocusRequest = UUID()
    }
}

/// The folder's tree, expansion and filter are shared by its document tabs.
/// Only the selected tab hosts the native browser view.
@MainActor
final class FolderSidebarState: ObservableObject {
    enum Section: Hashable { case files, outline }

    @Published var section: Section = .files {
        didSet { updateBrowserHost() }
    }
    @Published var isVisible = true {
        didSet { updateBrowserHost() }
    }

    var onShowFiles: ((NSWindow) -> Void)?
    private let browserView: NSView
    private let focusBrowser: () -> Void
    private let hosts = NSMapTable<NSWindow, FolderSidebarHostView>.weakToWeakObjects()
    private weak var activeWindow: NSWindow?
    private var pendingFocus: (() -> Void)?

    init(browserView: NSView, focusBrowser: @escaping () -> Void) {
        self.browserView = browserView
        self.focusBrowser = focusBrowser
    }

    func activate(in window: NSWindow?, focusFiles: Bool = false) {
        if let window, focusFiles {
            showFiles(in: window, focus: focusBrowser)
            return
        }
        setActiveWindow(window)
        updateBrowserHost()
    }

    func showFiles(in window: NSWindow, focus: @escaping () -> Void) {
        setActiveWindow(window)
        if section == .files, isVisible, browserView.window === window, window.isKeyWindow {
            // Menu shortcuts can be followed immediately by typing. Once the
            // browser is mounted, apply focus before the next input event.
            pendingFocus = nil
            focus()
            return
        }
        onShowFiles?(window)
        if section != .files { section = .files }
        if !isVisible { isVisible = true }
        pendingFocus = focus
        updateBrowserHost()
    }

    func cancelPendingFocus() { pendingFocus = nil }

    fileprivate func register(_ host: FolderSidebarHostView, in window: NSWindow) {
        hosts.setObject(host, forKey: window)
        updateBrowserHost()
    }

    fileprivate func unregister(_ host: FolderSidebarHostView, from window: NSWindow) {
        if hosts.object(forKey: window) === host { hosts.removeObject(forKey: window) }
        updateBrowserHost()
    }

    private func setActiveWindow(_ window: NSWindow?) {
        if activeWindow !== window { pendingFocus = nil }
        activeWindow = window
    }

    private func updateBrowserHost() {
        guard isVisible, section == .files else {
            pendingFocus = nil
            browserView.removeFromSuperview()
            return
        }
        let host = activeWindow.flatMap { hosts.object(forKey: $0) }
        if browserView.superview !== host {
            browserView.removeFromSuperview()
            if let host {
                browserView.translatesAutoresizingMaskIntoConstraints = true
                browserView.autoresizingMask = [.width, .height]
                browserView.frame = host.bounds
                host.addSubview(browserView)
            }
        }
        guard let host, pendingFocus != nil else { return }
        // Let AppKit finish mounting the representable before changing its
        // responder. Setting it on this tab also works before it becomes key.
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host, let focus = self.pendingFocus,
                  self.browserView.superview === host,
                  let window = host.window, self.activeWindow === window else { return }
            self.pendingFocus = nil
            focus()
        }
    }
}

@MainActor
final class FolderSidebarHostView: NSView {
    private weak var sidebar: FolderSidebarState?
    private weak var registeredWindow: NSWindow?

    func connect(to sidebar: FolderSidebarState?) {
        guard self.sidebar !== sidebar else { return }
        if let registeredWindow { self.sidebar?.unregister(self, from: registeredWindow) }
        self.sidebar = sidebar
        if let window { sidebar?.register(self, in: window) }
        registeredWindow = window
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard registeredWindow !== window else { return }
        if let registeredWindow { sidebar?.unregister(self, from: registeredWindow) }
        registeredWindow = window
        if let window { sidebar?.register(self, in: window) }
    }
}

struct FolderSidebarHost: NSViewRepresentable {
    let sidebar: FolderSidebarState

    func makeNSView(context: Context) -> FolderSidebarHostView {
        let view = FolderSidebarHostView()
        view.connect(to: sidebar)
        return view
    }

    func updateNSView(_ view: FolderSidebarHostView, context: Context) {
        view.connect(to: sidebar)
    }

    static func dismantleNSView(_ view: FolderSidebarHostView, coordinator: ()) {
        view.connect(to: nil)
    }
}
