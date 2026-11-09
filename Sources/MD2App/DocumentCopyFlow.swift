import AppKit
import Foundation
import SwiftUI

/// Captured on the main actor after the filename is confirmed. Filesystem
/// inspection and encoding are left to the worker, never the typing path.
struct DocumentCopySource: Sendable {
    let documentID: UUID
    let revision: Int
    let text: String
    let format: MarkdownFileFormat
    let url: URL
    let identity: DocumentFileIdentity?
}

enum DocumentCopyFlowError: Error {
    case untitled, unavailable, composing, changed, invalidName
}

@MainActor
final class DocumentCopyFlow: ObservableObject {
    typealias Writer = @Sendable (DocumentCopySource, URL) async throws -> DocumentCopyReceipt

    @Published private(set) var isRunning = false
    @Published private(set) var isOpening = false
    @Published private(set) var receipt: DocumentCopyReceipt?
    @Published private(set) var message: String?
    @Published private(set) var detail: String?
    private var worker: Task<DocumentCopyReceipt, Error>?

    /// The source's save, undo, recovery and watcher state is never adopted or
    /// reset. A receipt remains a success even when cancellation follows commit.
    @discardableResult
    func create(
        from store: DocumentStore,
        text: @escaping @MainActor (L10nKey) -> String,
        chooseName: (@MainActor (URL) -> String?)? = nil,
        write: @escaping Writer = DocumentCopyFlow.write
    ) async -> DocumentCopyReceipt? {
        guard !isRunning, !isOpening else { return nil }
        isRunning = true
        defer { isRunning = false; worker = nil }
        var sourceFormat = store.fileFormat.encodingLabel
        do {
            let initial = try store.captureCopySource()
            let name: String?
            if let chooseName { name = chooseName(initial.url) }
            else { name = Self.chooseName(for: initial.url, text: text) }
            guard let name else { return nil }
            let source = try store.captureCopySource()
            sourceFormat = source.format.encodingLabel
            guard source.documentID == initial.documentID, source.url == initial.url else {
                throw DocumentCopyFlowError.changed
            }
            let destination = try Self.destination(named: name, beside: source.url)
            try Task.checkCancellation()
            let task = Task { try await write(source, destination) }
            worker = task
            let completed = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            receipt = completed
            message = String(format: text(.copyCreated), completed.destinationURL.lastPathComponent)
            detail = text(.copyCreatedDetail)
            return completed
        } catch is CancellationError {
            return nil
        } catch {
            receipt = nil
            message = text(.copyFailed)
            detail = Self.errorDescription(error, sourceFormat: sourceFormat, text: text)
            return nil
        }
    }

    func cancel() { worker?.cancel() }

    func dismiss() {
        receipt = nil
        message = nil
        detail = nil
    }

    /// Refuse a focus change while the original editor owns provisional input.
    /// Keeping the receipt makes the Open Copy action available after composition.
    func mayOpen(from store: DocumentStore, text: (L10nKey) -> String) -> Bool {
        guard receipt != nil else { return false }
        if store.editorSession.textView?.hasMarkedText() == true {
            detail = text(.copyFinishComposition)
            return false
        }
        return true
    }

    func openCreatedCopy(
        _ receipt: DocumentCopyReceipt, from source: DocumentStore,
        text: (L10nKey) -> String, makeStore: () -> DocumentStore,
        reader: DocumentCopyReader = .init()
    ) async -> DocumentStore? {
        guard !isOpening, self.receipt == receipt, mayOpen(from: source, text: text) else { return nil }
        isOpening = true
        defer { isOpening = false }
        do {
            return try await Self.openFreshStore(receipt, reader: reader, beforeAdoption: {
                guard self.receipt == receipt else { throw CancellationError() }
                guard self.mayOpen(from: source, text: text) else { throw DocumentCopyFlowError.composing }
            }, makeStore: makeStore)
        } catch is CancellationError {
            return nil
        } catch DocumentCopyFlowError.composing {
            detail = text(.copyFinishComposition)
            return nil
        } catch {
            // Creation did succeed. Keep that receipt/message and distinguish
            // this later open failure; the app must not show a starter window.
            detail = text(.copyOpenFailed)
            return nil
        }
    }

    static func openFreshStore(
        _ receipt: DocumentCopyReceipt, reader: DocumentCopyReader = .init(),
        beforeAdoption: () throws -> Void = {}, makeStore: () -> DocumentStore
    ) async throws -> DocumentStore {
        let task = Task.detached(priority: .userInitiated) { try reader.read(receipt) }
        let opened = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        try beforeAdoption()
        let store = makeStore()
        try store.openVerifiedCopy(opened)
        return store
    }

    static func destination(named name: String, beside source: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0"),
              !name.contains("\n"), !name.contains("\r") else {
            throw DocumentCopyFlowError.invalidName
        }
        let suffix = (name as NSString).pathExtension.lowercased()
        guard suffix == "md" || suffix == "markdown" else { throw DocumentCopyFlowError.invalidName }
        return source.deletingLastPathComponent().appendingPathComponent(name)
    }

    nonisolated static func write(_ source: DocumentCopySource, to destination: URL) async throws -> DocumentCopyReceipt {
        let task = Task.detached(priority: .userInitiated) {
            // A Finder move may precede its watcher event. Refuse the stale
            // location, especially when another file has reused the old path;
            // do not mutate the source Store merely to resolve a copy request.
            if let identity = source.identity, identity.resolve(fallback: source.url) != source.url {
                throw DocumentCopyError.sourceChanged
            }
            let snapshot = try DocumentCopySnapshot(documentID: source.documentID, revision: source.revision,
                text: source.text, format: source.format, sourceURL: source.url)
            return try DocumentCopyWriter().writeNew(snapshot, to: destination)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func chooseName(for source: URL, text: (L10nKey) -> String) -> String? {
        let prompt = NSAlert()
        prompt.messageText = text(.createCopy)
        prompt.informativeText = String(format: text(.copyPromptDetail), source.deletingLastPathComponent().path)
        let suffix = source.pathExtension.lowercased() == "markdown" ? "markdown" : "md"
        let field = NSTextField(string: source.deletingPathExtension().lastPathComponent + text(.copyNameSuffix) + "." + suffix)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.setAccessibilityLabel(text(.copyFilename))
        prompt.accessoryView = field
        prompt.addButton(withTitle: text(.createCopyAction))
        prompt.addButton(withTitle: text(.cancel))
        prompt.window.initialFirstResponder = field
        guard prompt.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func errorDescription(_ error: Error, sourceFormat: String, text: (L10nKey) -> String) -> String {
        switch error {
        case DocumentCopyFlowError.untitled: return text(.copySaveFirst)
        case DocumentCopyFlowError.composing: return text(.copyFinishComposition)
        case DocumentCopyFlowError.changed: return text(.copySourceChanged)
        case DocumentCopyFlowError.invalidName: return text(.copyInvalidName)
        case DocumentCopyFlowError.unavailable, DocumentCopyError.invalidSource: return text(.copySourceUnavailable)
        case DocumentCopyError.sameAsSource, DocumentCopyError.destinationExists: return text(.copyNameExists)
        case DocumentCopyError.unrepresentableEncoding: return String(format: text(.copyEncodingUnavailable), sourceFormat)
        case DocumentCopyError.sourceChanged: return text(.copySourceChanged)
        case DocumentCopyError.io(.inspectSource, _): return text(.copySourceUnavailable)
        case DocumentCopyError.io(_, let code): return String(cString: strerror(code))
        default: return error.localizedDescription
        }
    }
}

/// A completion never presents a modal alert over newly started marked text.
struct DocumentCopyNotice: View {
    @ObservedObject var flow: DocumentCopyFlow
    @ObservedObject var settings: AppSettings
    let onOpen: (DocumentCopyReceipt) -> Void

    var body: some View {
        if let message = flow.message {
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.callout.weight(.semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = flow.detail {
                    Text(detail).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let receipt = flow.receipt {
                        Button(settings.text(.openCopy)) { onOpen(receipt) }
                            .accessibilityIdentifier("openCreatedCopy")
                            .disabled(flow.isOpening)
                    }
                    Button(settings.text(.dismissCopyNotice)) { flow.dismiss() }
                        .accessibilityIdentifier("dismissCopyNotice")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.bar)
            Divider()
        }
    }
}
