import CryptoKit
import Foundation

/// The last content this app read from or wrote to a document's backing file:
/// its modification date plus a SHA-256 of the bytes. The hash — not the date —
/// decides whether an event is a real external change, so the app's own atomic
/// saves and metadata-only touches never masquerade as one.
struct DocumentFileFingerprint: Equatable, Sendable {
    var modificationDate: Date?
    var contentHash: Data

    static func hash(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func of(data: Data, at url: URL) -> DocumentFileFingerprint {
        DocumentFileFingerprint(
            modificationDate: modificationDate(at: url),
            contentHash: hash(of: data)
        )
    }

    /// The file's on-disk fingerprint right now, or `nil` when it is missing
    /// or unreadable (deleted, moved, mid-replacement).
    static func current(at url: URL) -> DocumentFileFingerprint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return of(data: data, at: url)
    }

    static func modificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

enum FingerprintComparison: Equatable, Sendable {
    /// Same bytes (the date may have changed — a touch, or our own save's
    /// rename event).
    case unchanged
    /// Different bytes: a genuine external modification or replacement.
    case contentChanged
    /// The file is gone (deleted or moved away).
    case missing
}

extension DocumentFileFingerprint {
    static func comparison(
        lastKnown: DocumentFileFingerprint,
        current: DocumentFileFingerprint?
    ) -> FingerprintComparison {
        guard let current else { return .missing }
        return current.contentHash == lastKnown.contentHash ? .unchanged : .contentChanged
    }
}

/// What the store does about an observed change to the backing file.
enum ExternalChangeAction: Equatable, Sendable {
    case ignore
    case reloadPreservingViewport
    case presentConflict
    case markDeletedDirty
}

enum ExternalChangeDecision {
    /// Pure mapping from (what happened on disk, unsaved edits?) to the store
    /// action: a clean document follows the disk, a dirty one is asked, and a
    /// vanished file leaves memory as the only truthful copy — marked dirty so
    /// close/quit protection applies.
    static func action(for comparison: FingerprintComparison, isDirty: Bool) -> ExternalChangeAction {
        switch comparison {
        case .unchanged:
            return .ignore
        case .contentChanged:
            return isDirty ? .presentConflict : .reloadPreservingViewport
        case .missing:
            return .markDeletedDirty
        }
    }
}

/// Watches one file path and signals "something happened here — evaluate".
/// Distinguishing modified/replaced/deleted is the fingerprint's job, not the
/// watcher's. Injectable so store behavior is testable without file-system
/// event timing.
@MainActor
protocol DocumentFileWatching: AnyObject {
    var onEvent: (() -> Void)? { get set }
    func watch(url: URL)
    func stop()
}

/// Dispatch-source file watcher on an `O_EVTONLY` descriptor.
///
/// Atomic-save editors replace the file (write temp + rename over), which
/// delivers `.rename`/`.delete` on the *old* inode and leaves the descriptor
/// stale — so on those flags the watcher re-arms on the path, retrying briefly
/// while the swap settles, then polling slowly while the file stays missing so
/// an external restore (e.g. `git checkout`) is picked up again. Events are
/// debounced, and a momentarily-absent path is given a beat to settle before
/// the event fires, so a replacement is evaluated as a modification rather
/// than a deletion.
@MainActor
final class DispatchSourceFileWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?

    private var url: URL?
    private var source: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var rearmWork: DispatchWorkItem?

    private static let debounceInterval: TimeInterval = 0.2
    private static let settleRetryInterval: TimeInterval = 0.1
    private static let settleMaxRetries = 5
    /// Quick retries cover an in-flight atomic replacement…
    private static let rearmQuickRetries = 8
    /// …after which a missing file is polled slowly until it comes back.
    private static let missingPollInterval: TimeInterval = 2.0

    func watch(url: URL) {
        self.url = url
        cancelRearm()
        if !arm() {
            scheduleRearm(attempt: 0)
        }
    }

    func stop() {
        url = nil
        debounceWork?.cancel()
        debounceWork = nil
        cancelRearm()
        source?.cancel()
        source = nil
    }

    deinit {
        // The cancel handler closes the descriptor; cancel is thread-safe.
        source?.cancel()
    }

    @discardableResult
    private func arm() -> Bool {
        source?.cancel()
        source = nil
        guard let url else { return false }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            // Source data resets when the handler returns; read it here.
            let flags = source?.data ?? []
            Task { @MainActor in self?.handleSourceEvent(flags) }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
        return true
    }

    private func handleSourceEvent(_ flags: DispatchSource.FileSystemEvent) {
        guard url != nil else { return }
        if flags.contains(.rename) || flags.contains(.delete) {
            // The descriptor tracks the old inode now; watch the path again.
            scheduleRearm(attempt: 0)
        }
        scheduleDebouncedEvent()
    }

    private func scheduleRearm(attempt: Int) {
        cancelRearm()
        guard url != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.attemptRearm(attempt: attempt) }
        }
        rearmWork = work
        let delay = attempt < Self.rearmQuickRetries ? Self.settleRetryInterval : Self.missingPollInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func attemptRearm(attempt: Int) {
        guard url != nil else { return }
        if arm() {
            // Watching a fresh inode: the file was replaced or restored, so
            // let the owner evaluate what is there now.
            scheduleDebouncedEvent()
        } else {
            scheduleRearm(attempt: attempt + 1)
        }
    }

    private func cancelRearm() {
        rearmWork?.cancel()
        rearmWork = nil
    }

    private func scheduleDebouncedEvent() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.fireEventIfSettled(retriesLeft: Self.settleMaxRetries) }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func fireEventIfSettled(retriesLeft: Int) {
        guard let url else { return }
        // Mid-replacement the path is briefly absent; give it a beat so a swap
        // is evaluated as a modification, not a deletion.
        if !FileManager.default.fileExists(atPath: url.path), retriesLeft > 0 {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.fireEventIfSettled(retriesLeft: retriesLeft - 1) }
            }
            debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleRetryInterval, execute: work)
            return
        }
        onEvent?()
    }
}
