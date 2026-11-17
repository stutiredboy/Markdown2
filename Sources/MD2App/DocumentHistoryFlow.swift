import Combine
import Foundation

struct DocumentHistorySource: Sendable {
    let documentID: UUID
    let lineage: UUID
    let url: URL
    let fileID: DocumentHistoryFileID
    let repository: DocumentHistoryRepository
}

enum DocumentHistoryFlowError: Error {
    case disabled, untitled, composing, sourceUnavailable, sourceChanged, invalidRevision

    var message: L10nKey {
        switch self {
        case .disabled: .historyDisabled
        case .untitled: .historySaveFirst
        case .composing: .copyFinishComposition
        case .sourceUnavailable: .copySourceUnavailable
        case .sourceChanged: .historySourceChanged
        case .invalidRevision: .historyRevisionUnavailable
        }
    }
}

@MainActor
final class DocumentHistoryFlow: ObservableObject {
    @Published private(set) var revisions: [DocumentHistoryRevision] = []
    @Published private(set) var selection: DocumentHistoryRevision?
    @Published private(set) var excerpt: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isRestoring = false
    @Published private(set) var message: L10nKey?
    @Published private(set) var detail: String?
    @Published private(set) var unavailableCount = 0

    private let original: DocumentHistorySource
    private weak var store: DocumentStore?
    private var previewTask: Task<Void, Never>?
    let sourceURL: URL

    init(store: DocumentStore) throws {
        let source = try store.captureHistorySource()
        self.store = store
        original = source
        sourceURL = source.url
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let source = try currentSource()
            let stillAtLocation = await Task.detached(priority: .userInitiated) {
                DocumentHistoryFileID(url: source.url) == source.fileID
            }.value
            try Task.checkCancellation()
            let current = try currentSource()
            guard stillAtLocation || current.fileID != source.fileID else {
                throw DocumentHistoryFlowError.sourceChanged
            }
            let listing = try await current.repository.revisions(for: current.fileID)
            try Task.checkCancellation()
            _ = try currentSource()
            revisions = listing.revisions
            unavailableCount = listing.unavailableCount
        } catch is CancellationError {
            return
        } catch {
            message = (error as? DocumentHistoryFlowError)?.message ?? .historyLoadFailed
        }
    }

    func select(_ revision: DocumentHistoryRevision) {
        guard !isRestoring else { return }
        previewTask?.cancel()
        selection = revision
        excerpt = nil
        message = nil
        detail = nil
        isLoading = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { isLoading = false } }
            do {
                let contents = try await read(revision)
                let value = try await Task.detached(priority: .userInitiated) {
                    guard let decoded = MarkdownFileDecoder.decode(contents.data, preserving: contents.format) else {
                        throw DocumentHistoryFlowError.invalidRevision
                    }
                    let bytes = decoded.text.utf8
                    let prefix = bytes.prefix(8_192)
                    let excerpt = String(decoding: prefix, as: UTF8.self)
                    return prefix.endIndex == bytes.endIndex ? excerpt : excerpt + "\n…"
                }.value
                try Task.checkCancellation()
                _ = try currentSource()
                excerpt = value
            } catch {
                guard !Task.isCancelled else { return }
                message = (error as? DocumentHistoryFlowError)?.message ?? .historyRevisionUnavailable
            }
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
    }

    /// Resolves the selected revision again at commit, even after a successful
    /// preview. Retention, file replacement or removal may have happened since.
    func restore(named name: String, makeStore: () -> DocumentStore) async -> DocumentStore? {
        guard !isRestoring, let selection, excerpt != nil else { return nil }
        isRestoring = true
        message = nil
        detail = nil
        defer { isRestoring = false }
        var committed: DocumentCopyReceipt?
        do {
            let destination = try DocumentCopyFlow.destination(named: name, beside: sourceURL)
            let contents = try await read(selection)
            try Task.checkCancellation()
            let source = try currentSource()
            let task = Task.detached(priority: .userInitiated) {
                guard let decoded = MarkdownFileDecoder.decode(contents.data, preserving: contents.format) else {
                    throw DocumentHistoryFlowError.invalidRevision
                }
                let snapshot = try DocumentCopySnapshot(documentID: source.documentID, revision: 0,
                    text: decoded.text, format: contents.format, sourceURL: source.url, historyFileID: source.fileID)
                return try DocumentCopyWriter().writeNew(snapshot, to: destination, verifiedHistoricalBytes: contents.data)
            }
            let receipt = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            committed = receipt
            return try await DocumentCopyFlow.openFreshStore(receipt, preservingFormat: true, beforeAdoption: {
                _ = try self.currentSource()
            }, makeStore: makeStore)
        } catch {
            if let committed {
                message = .historyCopyOpenFailed
                detail = committed.destinationURL.lastPathComponent
            } else if error is CancellationError {
                return nil
            } else if let error = error as? DocumentHistoryFlowError {
                message = error.message
            } else {
                switch error {
                case DocumentHistoryError.missingRevision, DocumentHistoryError.corruptRevision:
                    message = .historyRevisionUnavailable
                case DocumentCopyFlowError.invalidName:
                    message = .copyInvalidName
                case DocumentCopyError.destinationExists, DocumentCopyError.sameAsSource:
                    message = .copyNameExists
                case DocumentCopyError.sourceChanged, DocumentCopyError.invalidSource, DocumentCopyError.io(.inspectSource, _):
                    message = .historySourceChanged
                case DocumentCopyError.io(_, let code):
                    message = .historyCopyFailed
                    detail = String(cString: strerror(code))
                default:
                    message = .historyCopyFailed
                }
            }
            if message == .historyRevisionUnavailable { excerpt = nil }
            return nil
        }
    }

    private func currentSource() throws -> DocumentHistorySource {
        guard let source = try store?.captureHistorySource(), source.documentID == original.documentID,
              source.lineage == original.lineage, source.url == original.url else {
            throw DocumentHistoryFlowError.sourceChanged
        }
        return source
    }

    private func read(_ revision: DocumentHistoryRevision) async throws -> DocumentHistoryContents {
        try Task.checkCancellation()
        let source = try currentSource()
        do {
            return try await source.repository.read(revision, for: source.fileID)
        } catch {
            try Task.checkCancellation()
            // A successful save may replace the backing inode while the list
            // is open. Retry its new key only within the same logical lineage.
            let latest = try currentSource()
            guard latest.fileID != source.fileID else { throw error }
            return try await latest.repository.read(revision, for: latest.fileID)
        }
    }
}
