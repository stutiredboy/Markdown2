import AppKit
import Combine
import SwiftUI

/// AppKit owns document windows, so SwiftUI commands need their own observable
/// boundary for focus changes, including a non-document window becoming key.
@MainActor
final class AttachmentCommandState: ObservableObject {
    @Published private(set) var document: DocumentStore?
    @Published private(set) var canCollect = false
    private var currentDocument: (() -> DocumentStore?)?
    private var windowObservation: AnyCancellable?
    private var busyObservation: AnyCancellable?

    func observeCurrentDocument(_ provider: @escaping () -> DocumentStore?) {
        currentDocument = provider
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification, NSWindow.willCloseNotification]
        windowObservation = Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
            // Let AppKit finish the key/main transition before resolving focus.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        let current = currentDocument?()
        guard current !== document else { return }
        busyObservation = nil
        document = current
        canCollect = current != nil && current?.isWorkingOnAttachments == false
        busyObservation = current?.$isWorkingOnAttachments.sink { [weak self] busy in
            self?.canCollect = !busy
        }
    }
}

/// A command-local dependency keeps the native menu live without requiring a
/// settings change to re-evaluate the surrounding AppCommands tree.
struct CollectLocalImagesCommand: View {
    let title: String
    @ObservedObject var state: AttachmentCommandState
    let action: () -> Void

    var body: some View {
        Button(title, action: action).disabled(!state.canCollect)
    }
}
