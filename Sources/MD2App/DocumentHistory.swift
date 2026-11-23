import Darwin
import Foundation
import os

/// A physical file on a volume with persistent identity. A path can be reused,
/// and an inode can be recycled, so neither is sufficient by itself.
struct DocumentHistoryFileID: Equatable, Sendable {
    let storageKey: String
    private let device: dev_t
    private let inode: ino_t
    private let birthSecond: Int
    private let birthNanosecond: Int

    init?(url: URL) {
        guard url.isFileURL else { return nil }
        let path = url.path
        var information = stat()
        guard lstat(path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_birthtimespec.tv_sec > 0,
              let volume = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]),
              let volumeUUID = volume.volumeUUIDString.flatMap(UUID.init(uuidString:)) else { return nil }
        device = information.st_dev
        inode = information.st_ino
        birthSecond = information.st_birthtimespec.tv_sec
        birthNanosecond = information.st_birthtimespec.tv_nsec
        let key = "\(volumeUUID.uuidString)/\(inode)/\(birthSecond)/\(birthNanosecond)"
        storageKey = DocumentFileFingerprint.hash(of: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        var current = stat()
        guard lstat(path, &current) == 0, matches(current) else { return nil }
    }

    func matches(_ information: stat) -> Bool {
        information.st_mode & S_IFMT == S_IFREG && information.st_dev == device && information.st_ino == inode
            && information.st_birthtimespec.tv_sec == birthSecond
            && information.st_birthtimespec.tv_nsec == birthNanosecond
    }
}

enum DocumentHistoryReason: String, Codable, Sendable {
    case opened, saved, externalReload
}

struct DocumentHistoryRevision: Identifiable, Equatable, Sendable {
    let id: UUID
    let reason: DocumentHistoryReason
    let format: MarkdownFileFormat
    let byteCount: Int
    fileprivate let timestamp: UInt64
    var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1_000_000) }
}

struct DocumentHistoryListing: Sendable {
    let revisions: [DocumentHistoryRevision]
    let unavailableCount: Int
}

struct DocumentHistoryContents: Sendable {
    let data: Data
    let format: MarkdownFileFormat
}

enum DocumentHistoryError: Error, Equatable {
    case missingRevision, corruptRevision
}

/// History runs on its own serial queue. Document saves can enqueue immutable
/// disk bytes and complete without waiting for history, pruning, or hashing.
final class DocumentHistoryRepository: Sendable {
    struct Limits: Sendable {
        var maximumAge: TimeInterval = 30 * 24 * 60 * 60
        var revisionsPerDocument = 20
        var maximumRevisions = 500
        var maximumStorageBytes = 128 * 1024 * 1024
        var maximumRevisionBytes = 8 * 1024 * 1024
    }

    static let applicationRepository: DocumentHistoryRepository = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "com.markdown2.app"
        return DocumentHistoryRepository(directory: base.appendingPathComponent(identifier)
            .appendingPathComponent("Document History", isDirectory: true))
    }()

    private let directory: URL
    private let limits: Limits
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.markdown2.document-history", qos: .utility)
    private let pendingBytes = OSAllocatedUnfairLock(initialState: 0)
    private static let maximumPendingBytes = 128 * 1024 * 1024

    init(directory: URL, limits: Limits = .init(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        self.now = now
    }

    func canRecord(byteCount: Int) -> Bool {
        byteCount <= limits.maximumRevisionBytes && byteCount <= limits.maximumStorageBytes
    }

    func record(_ data: Data, format: MarkdownFileFormat, reason: DocumentHistoryReason,
                for id: DocumentHistoryFileID, replacing previousID: DocumentHistoryFileID? = nil) {
        // Do not retain a large buffer while the queue is busy. A large save
        // can still transfer that document's existing history to its new inode.
        let previousID = previousID.flatMap { $0.storageKey == id.storageKey ? nil : $0 }
        let payload: Data? = pendingBytes.withLock { pending in
            guard canRecord(byteCount: data.count),
                  data.count <= Self.maximumPendingBytes - pending else { return nil }
            pending += data.count
            return data
        }
        guard let payload else {
            if let previousID { reassociate(from: previousID, to: id) }
            return
        }
        let date = now()
        queue.async {
            defer { self.pendingBytes.withLock { $0 -= payload.count } }
            try? self.withRepository {
                let target = self.documentDirectory(id)
                if let previousID {
                    try self.transfer(from: self.documentDirectory(previousID), to: target)
                }
                try self.store(payload, format: format, reason: reason, date: date, in: target)
                try self.prune()
            }
        }
    }

    func reassociate(from previousID: DocumentHistoryFileID, to id: DocumentHistoryFileID) {
        guard previousID.storageKey != id.storageKey else { return }
        queue.async {
            guard (try? self.isDirectory(self.directory)) == true else { return }
            try? self.withRepository {
                try self.transfer(from: self.documentDirectory(previousID), to: self.documentDirectory(id))
                try self.prune()
            }
        }
    }

    func revisions(for id: DocumentHistoryFileID) async throws -> DocumentHistoryListing {
        try await perform {
            try self.withRepository {
                // Capacity cleanup elsewhere in the repository is best effort.
                // A filesystem failure there must not hide this file's history.
                try? self.prune()
                let cutoff = self.oldestTimestamp()
                let entries = try self.entries(in: self.documentDirectory(id)).filter { ($0.timestamp ?? cutoff) >= cutoff }
                let revisions = entries.sorted { $0.name > $1.name }.compactMap { entry in
                    try? self.readHeader(entry).revision
                }
                return DocumentHistoryListing(revisions: revisions, unavailableCount: entries.count - revisions.count)
            }
        }
    }

    func read(_ revision: DocumentHistoryRevision, for id: DocumentHistoryFileID) async throws -> DocumentHistoryContents {
        try await perform {
            try self.withRepository {
                guard revision.timestamp >= self.oldestTimestamp() else { throw DocumentHistoryError.missingRevision }
                let name = Entry.name(timestamp: revision.timestamp, id: revision.id)
                let entry = Entry(url: self.documentDirectory(id).appendingPathComponent(name))
                let result = try self.readHeader(entry, includePayload: true)
                guard result.revision == revision, let data = result.data else { throw DocumentHistoryError.corruptRevision }
                return DocumentHistoryContents(data: data, format: revision.format)
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func pruneExpired() {
        queue.async {
            guard (try? self.isDirectory(self.directory)) == true else { return }
            try? self.withRepository { try self.prune() }
        }
    }

    func removeAll() async throws {
        try await perform {
            try self.withRepository {
                // Keep the root's lock inode so another process cannot lock a
                // replacement while an operation still holds this descriptor.
                for folder in try self.documentDirectories() {
                    try FileManager.default.removeItem(at: folder)
                }
            }
        }
    }

    private func perform<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }

    private func withRepository<Value>(_ body: () throws -> Value) throws -> Value {
        let exists = try isDirectory(directory)
        if !exists {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Self.posixError() }
        defer { Darwin.close(root) }
        guard fchmod(root, 0o700) == 0 else { throw Self.posixError() }
        if !exists {
            var rootURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? rootURL.setResourceValues(values)
        }

        let lock = openat(root, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Self.posixError() }
        defer { Darwin.close(lock) }
        var information = stat()
        guard fstat(lock, &information) == 0 else { throw Self.posixError() }
        guard information.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        // Another instance can be suspended with the lock held. Bound the
        // wait so history cannot indefinitely hold up an app quit.
        let deadline = DispatchTime.now() + .milliseconds(250)
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw Self.posixError() }
            guard DispatchTime.now() < deadline else { throw POSIXError(.EWOULDBLOCK) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try body()
    }

    private func documentDirectory(_ identity: DocumentHistoryFileID) -> URL {
        directory.appendingPathComponent(identity.storageKey, isDirectory: true)
    }

    private func documentDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { url in
            let name = url.lastPathComponent.utf8
            // Recognize only document folders owned by this repository.
            return name.count == 64 && name.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        var information = stat()
        if lstat(url.path, &information) == 0 {
            guard information.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
            return true
        }
        guard errno == ENOENT else { throw Self.posixError() }
        return false
    }

    private func transfer(from previous: URL, to target: URL) throws {
        guard try isDirectory(previous) else { return }
        let manager = FileManager.default
        if try !isDirectory(target) {
            try manager.moveItem(at: previous, to: target)
        } else {
            // A second app process may have opened the just-committed inode
            // before our background write. Preserve both sets of revisions.
            for entry in try entries(in: previous) {
                let destination = target.appendingPathComponent(entry.name)
                try manager.moveItem(at: entry.url, to: destination)
            }
            try manager.removeItem(at: previous)
        }
    }

    private struct Header: Codable {
        let version: Int
        let reason: DocumentHistoryReason
        let format: MarkdownFileFormat
        let byteCount: Int
        let contentHash: Data
    }

    private struct Entry {
        let url: URL
        var name: String { url.lastPathComponent }
        var timestamp: UInt64? { name.split(separator: "-", maxSplits: 1).first.flatMap { UInt64($0, radix: 16) } }
        var id: UUID? {
            guard name.count == 62 else { return nil }
            return UUID(uuidString: String(name.dropFirst(17).dropLast(9)))
        }

        static func name(timestamp: UInt64, id: UUID) -> String {
            String(format: "%016llx", timestamp) + "-\(id.uuidString).revision"
        }
    }

    private static let hashSize = 32
    private static let maximumHeaderSize = 1_024
    private static let stagingName = ".pending"

    private func entries(in folder: URL) throws -> [Entry] {
        guard try isDirectory(folder) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "revision" }.map(Entry.init(url:))
    }

    private func readHeader(_ entry: Entry, includePayload: Bool = false)
        throws -> (revision: DocumentHistoryRevision, hash: Data, data: Data?) {
        guard let timestamp = entry.timestamp, let id = entry.id,
              entry.name == Entry.name(timestamp: timestamp, id: id) else { throw DocumentHistoryError.corruptRevision }
        // Verify the folder even on direct selection. A user may have cleared
        // or moved history since the list was obtained.
        guard try isDirectory(entry.url.deletingLastPathComponent()) else { throw DocumentHistoryError.missingRevision }
        let descriptor = Darwin.open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw DocumentHistoryError.missingRevision }
            if errno == ELOOP { throw DocumentHistoryError.corruptRevision }
            throw Self.posixError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw Self.posixError() }
        guard information.st_mode & S_IFMT == S_IFREG,
              let prefix = try handle.read(upToCount: 2), prefix.count == 2 else { throw DocumentHistoryError.corruptRevision }
        let size = Int(prefix[0]) << 8 | Int(prefix[1])
        guard (1...Self.maximumHeaderSize).contains(size),
              let storedHeader = try handle.read(upToCount: size), storedHeader.count == size,
              let digest = try handle.read(upToCount: Self.hashSize),
              digest == DocumentFileFingerprint.hash(of: Data(entry.name.utf8) + storedHeader),
              let header = try? JSONDecoder().decode(Header.self, from: storedHeader), header.version == 1,
              header.byteCount >= 0, header.byteCount <= limits.maximumRevisionBytes,
              information.st_size == 2 + size + Self.hashSize + header.byteCount else { throw DocumentHistoryError.corruptRevision }
        let revision = DocumentHistoryRevision(id: id, reason: header.reason, format: header.format,
                                               byteCount: header.byteCount, timestamp: timestamp)
        guard includePayload else { return (revision, header.contentHash, nil) }
        let data = header.byteCount == 0 ? Data() : try handle.read(upToCount: header.byteCount) ?? Data()
        guard data.count == header.byteCount, DocumentFileFingerprint.hash(of: data) == header.contentHash else {
            throw DocumentHistoryError.corruptRevision
        }
        return (revision, header.contentHash, data)
    }

    private func store(_ data: Data, format: MarkdownFileFormat, reason: DocumentHistoryReason,
                       date: Date, in folder: URL) throws {
        let hash = DocumentFileFingerprint.hash(of: data)
        let timestamp = Self.timestamp(date)
        let cutoff = oldestTimestamp()
        let latest = try entries(in: folder).filter { ($0.timestamp ?? 0) >= cutoff }.max { $0.name < $1.name }
        let existing = latest.flatMap { try? readHeader($0) }
        if let latest, let existing, existing.hash == hash, existing.revision.format == format,
           (try? readHeader(latest, includePayload: true)) != nil { return }

        // Ordering remains deterministic even for captures in the same clock
        // tick or if the worker finishes after another process recorded a save.
        let prior = existing?.revision.timestamp ?? 0
        let name = Entry.name(timestamp: max(timestamp, prior == .max ? timestamp : prior + 1), id: UUID())
        let header = Header(version: 1, reason: reason, format: format, byteCount: data.count, contentHash: hash)
        let encoded = try JSONEncoder().encode(header)
        guard encoded.count <= Self.maximumHeaderSize else { throw DocumentHistoryError.corruptRevision }
        let total = 2 + encoded.count + Self.hashSize + data.count
        guard total <= limits.maximumStorageBytes else { return }
        var prefix = Data([UInt8(encoded.count >> 8), UInt8(encoded.count & 255)])
        prefix.append(encoded)
        prefix.append(DocumentFileFingerprint.hash(of: Data(name.utf8) + encoded))
        if try !isDirectory(folder) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let pending = folder.appendingPathComponent(Self.stagingName).path
        if unlink(pending) != 0 && errno != ENOENT { throw Self.posixError() }
        let file = Darwin.open(pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.posixError() }
        defer { unlink(pending) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        try handle.write(contentsOf: prefix)
        try handle.write(contentsOf: data)
        try handle.close()
        let destination = folder.appendingPathComponent(name).path
        guard renamex_np(pending, destination, UInt32(RENAME_EXCL)) == 0 else { throw Self.posixError() }
    }

    private func prune() throws {
        let cutoff = oldestTimestamp()
        let manager = FileManager.default
        let folders = try documentDirectories()
        var candidates: [Entry] = []
        for folder in folders {
            // A damaged folder should not suppress revisions of other files.
            guard let entries = try? entries(in: folder) else { continue }
            // Remove uncommitted data left by an interrupted process.
            unlink(folder.appendingPathComponent(Self.stagingName).path)
            for (index, entry) in entries.sorted(by: { $0.name > $1.name }).enumerated() {
                if index >= limits.revisionsPerDocument || (entry.timestamp ?? cutoff) < cutoff {
                    try manager.removeItem(at: entry.url)
                } else {
                    candidates.append(entry)
                }
            }
        }

        var storageBytes = 0
        for (index, entry) in candidates.sorted(by: { $0.name > $1.name }).enumerated() {
            let size = try entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if index >= limits.maximumRevisions || size > limits.maximumStorageBytes - storageBytes {
                try manager.removeItem(at: entry.url)
            } else {
                storageBytes += size
            }
        }
        // Only empty folders are removed. rmdir never follows a symlink.
        for folder in folders { rmdir(folder.path) }
    }

    private func oldestTimestamp() -> UInt64 { Self.timestamp(now().addingTimeInterval(-limits.maximumAge)) }

    private static func timestamp(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 * 1_000_000))
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
