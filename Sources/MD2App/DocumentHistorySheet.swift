import AppKit
import SwiftUI

/// The editor windows are AppKit-owned, so the browser is attached to the
/// exact source window and completes dismissal before the copy takes focus.
@MainActor
final class DocumentHistorySheet {
    private weak var window: NSWindow?
    private let panel = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    private let flow: DocumentHistoryFlow
    private let makeStore: () -> DocumentStore
    private var copy: DocumentStore?
    private var loading: Task<Void, Never>?
    private var restoring: Task<Void, Never>?

    static func present(in window: NSWindow, store: DocumentStore, settings: AppSettings,
                        makeStore: @escaping () -> DocumentStore, onOpen: @escaping (DocumentStore) -> Void) {
        guard window.attachedSheet == nil,
              !NSApp.windows.contains(where: { $0.sheetParent === window }) else { return }
        do {
            let flow = try DocumentHistoryFlow(store: store)
            let sheet = DocumentHistorySheet(window: window, flow: flow, makeStore: makeStore)
            sheet.show(settings: settings, onOpen: onOpen)
        } catch DocumentHistoryFlowError.composing {
            NSSound.beep()
        } catch {
            let key = (error as? DocumentHistoryFlowError)?.message ?? .historyLoadFailed
            store.alert = DocumentAlert(message: settings.text(.historyTitle), detail: settings.text(key))
        }
    }

    private init(window: NSWindow, flow: DocumentHistoryFlow, makeStore: @escaping () -> DocumentStore) {
        self.window = window
        self.flow = flow
        self.makeStore = makeStore
    }

    private func show(settings: AppSettings, onOpen: @escaping (DocumentStore) -> Void) {
        panel.title = settings.text(.historyTitle)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: DocumentHistoryView(
            flow: flow, settings: settings, onRestore: { [weak self] name in self?.restore(named: name) },
            onClose: { [weak self] in self?.close() }
        ))
        panel.setContentSize(DocumentHistoryView.preferredContentSize)
        window?.beginSheet(panel) { [self] _ in
            loading?.cancel()
            restoring?.cancel()
            flow.cancelPreview()
            if let copy { onOpen(copy) }
        }
        loading = Task { [flow] in await flow.load() }
    }

    private func restore(named name: String) {
        guard restoring == nil else { return }
        restoring = Task { [weak self, flow, makeStore] in
            let copy = await flow.restore(named: name, makeStore: makeStore)
            guard let self else { return }
            restoring = nil
            if let copy {
                self.copy = copy
                close()
            }
        }
    }

    private func close() {
        guard !flow.isRestoring else { return }
        window?.endSheet(panel)
    }
}
