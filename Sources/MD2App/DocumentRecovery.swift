import Foundation
import Darwin

/// A bookmark follows identity across Finder renames/moves. Resolve it even
/// when the old path exists: someone may have created another file there.
struct DocumentFileIdentity: Codable, Sendable {
    var bookmark: Data?
    // Foundation may resolve a bookmark by path when that name has been reused.
    // Keep a live inode reference too. Do not serialize descriptors across runs.
    private var handle: FileHandle? = nil
    private enum CodingKeys: String, CodingKey { case bookmark }

    init(url: URL) {
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let descriptor = open(url.path, O_EVTONLY)
        if descriptor >= 0 { handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) }
    }

    func resolve(fallback: URL) -> URL? {
        if let liveURL = liveURL() { return usableURL(liveURL, fallback: fallback) }
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark,
                                      options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: resolved.path) {
                return usableURL(resolved, fallback: fallback)
            }
        }
        // Atomic replacement intentionally changes the inode at the same path.
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func usableURL(_ resolved: URL, fallback: URL) -> URL? {
        // Moving to Trash is deletion, not a new save destination.
        guard !resolved.pathComponents.contains(".Trash"),
              !resolved.pathComponents.contains(".Trashes") else { return nil }
        return resolved.resolvingSymlinksInPath() == fallback.resolvingSymlinksInPath() ? fallback : resolved
    }

    private func liveURL() -> URL? {
        guard let handle else { return nil }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_nlink > 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(handle.fileDescriptor, F_GETPATH, &path) == 0 else { return nil }
        let url = URL(fileURLWithPath: String(cString: path))
        var current = stat()
        guard stat(url.path, &current) == 0, current.st_ino == info.st_ino, current.st_dev == info.st_dev else { return nil }
        return url
    }
}

struct DocumentRecoverySnapshot: Codable, Sendable {
    var version = 1
    var id: UUID
    var text: String
    var fileURL: URL?
    var identity: DocumentFileIdentity?
    var format: MarkdownFileFormat
    var fingerprint: DocumentFileFingerprint?
    var isDirty: Bool
    var windowFrame: String?
    var updatedAt = Date()
}

/// One atomic record per open window. A bad record is retained for manual
/// recovery and does not prevent the other windows from being restored.
@MainActor
final class DocumentRecoveryRepository {
    let directory: URL
    private(set) var unreadableRecords: [URL] = []

    init(directory: URL) { self.directory = directory }

    static func applicationRepository() -> DocumentRecoveryRepository {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Test app bundles get their own namespace, never the developer's data.
        let identifier = Bundle.main.bundleIdentifier ?? "com.markdown2.app"
        return DocumentRecoveryRepository(directory: base.appendingPathComponent(identifier)
            .appendingPathComponent("Document Recovery", isDirectory: true))
    }

    func write(_ snapshot: DocumentRecoverySnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: recordURL(snapshot.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL(snapshot.id).path)
    }

    func remove(_ id: UUID) throws {
        let url = recordURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func load() throws -> [DocumentRecoverySnapshot] {
        unreadableRecords = []
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var records: [DocumentRecoverySnapshot] = []
        for url in urls where url.pathExtension == "json" {
            do {
                let snapshot = try JSONDecoder().decode(DocumentRecoverySnapshot.self, from: Data(contentsOf: url))
                guard snapshot.version == 1, url.lastPathComponent == "\(snapshot.id.uuidString).json" else {
                    unreadableRecords.append(url)
                    continue
                }
                records.append(snapshot)
            } catch { unreadableRecords.append(url) }
        }
        return records.sorted { $0.updatedAt < $1.updatedAt }
    }

    private func recordURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}
