import AppKit
import Combine
import SwiftUI

/// Publishes the AppKit window context to the SwiftUI command views.
@MainActor
final class WindowCommandState: ObservableObject {
    struct Context: Equatable {
        var document: DocumentStore?
        var canClose = false
        var canFocusFolderBrowser = false
        var canRevealInFolderBrowser = false

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.document === rhs.document && lhs.canClose == rhs.canClose
                && lhs.canFocusFolderBrowser == rhs.canFocusFolderBrowser
                && lhs.canRevealInFolderBrowser == rhs.canRevealInFolderBrowser
        }
    }

    @Published private(set) var context = Context()
    @Published private(set) var canCollect = false
    private var currentContext: (() -> Context)?
    private var windowObservation: AnyCancellable?
    private var busyObservation: AnyCancellable?

    func observe(_ provider: @escaping () -> Context) {
        currentContext = provider
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification, NSWindow.willCloseNotification]
        windowObservation = Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
            // Let AppKit finish the key/main transition before resolving focus.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        guard let current = currentContext?(), current != context else { return }
        let documentChanged = current.document !== context.document
        context = current
        guard documentChanged else { return }
        busyObservation = nil
        canCollect = current.document?.isWorkingOnAttachments == false
        busyObservation = current.document?.$isWorkingOnAttachments.dropFirst().sink { [weak self] busy in
            self?.canCollect = !busy
        }
    }
}

/// A command-local dependency keeps the native menu live without requiring a
/// settings change to re-evaluate the surrounding AppCommands tree.
struct CollectLocalImagesCommand: View {
    let title: String
    @ObservedObject var state: WindowCommandState
    let action: () -> Void

    var body: some View {
        Button(title, action: action).disabled(!state.canCollect)
    }
}
