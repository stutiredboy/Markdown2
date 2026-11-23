import Darwin
import Foundation

/// Persisted only while an update of a shared inode might be incomplete.
struct DocumentLinkedSaveIntent: Codable, Sendable {
    let fileKey: String?
    let targetHash: Data
}

/// Pins the shared inode for verification and writing. Other Markdown2
/// instances cooperate through flock. The descriptor and read validation also
/// catch path replacement and changes made before a noncooperating writer.
final class DocumentLinkedSaveFile {
    struct Contents {
        let data: Data
        fileprivate let version: Version
    }

    fileprivate struct Version: Equatable {
        let size: off_t
        let changedSecond: Int
        let changedNanosecond: Int
        let modifiedSecond: Int
        let modifiedNanosecond: Int

        init(_ info: stat) {
            size = info.st_size
            changedSecond = info.st_ctimespec.tv_sec
            changedNanosecond = info.st_ctimespec.tv_nsec
            modifiedSecond = info.st_mtimespec.tv_sec
            modifiedNanosecond = info.st_mtimespec.tv_nsec
        }
    }

    let handle: FileHandle
    let historyID: DocumentHistoryFileID?
    private let url: URL
    private let identity: DocumentCopyFileIdentity

    init(at url: URL, writable: Bool) throws {
        self.url = url
        // Foundation may present /private/var as /var even after resolving
        // symlinks. Open the kernel path so O_NOFOLLOW_ANY can guard it.
        guard let path = realpath(url.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(path) }
        let mode = writable ? O_RDWR : O_RDONLY
        let descriptor = Darwin.open(path, mode | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw DocumentCopyOpenError.changed
        }
        let lock = writable ? LOCK_EX : LOCK_SH
        guard flock(descriptor, lock | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        identity = DocumentCopyFileIdentity(info)
        let target = URL(fileURLWithPath: String(cString: path))
        historyID = DocumentHistoryFileID(url: target).flatMap { $0.matches(info) ? $0 : nil }
        _ = try validate()
    }

    @discardableResult
    func validate(matching contents: Contents? = nil, requiresHardLinks: Bool = false) throws -> stat {
        var entry = stat()
        var opened = stat()
        guard stat(url.path, &entry) == 0, fstat(handle.fileDescriptor, &opened) == 0,
              entry.st_mode & S_IFMT == S_IFREG, DocumentCopyFileIdentity(entry) == identity,
              DocumentCopyFileIdentity(opened) == identity, opened.st_nlink > 0,
              !requiresHardLinks || opened.st_nlink > 1,
              contents == nil || contents?.version == Version(opened) else {
            throw DocumentCopyOpenError.changed
        }
        return opened
    }

    func read() throws -> Contents {
        let info = try validate()
        try handle.seek(toOffset: 0)
        let data = try handle.readToEnd() ?? Data()
        let contents = Contents(data: data, version: Version(info))
        guard data.count == info.st_size else { throw DocumentCopyOpenError.changed }
        try validate(matching: contents)
        return contents
    }

    /// The offset is nil for a new save or rollback. A confirmed recovery
    /// appends to a verified prefix, so another interruption can be retried.
    static func write(_ data: Data, to handle: FileHandle, resumingAt offset: Int?) throws {
        if let offset {
            // An uncooperative process can still write through another
            // descriptor. O_APPEND avoids overwriting bytes it just added.
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_APPEND) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard try handle.seekToEnd() == UInt64(offset) else { throw DocumentCopyOpenError.changed }
        } else {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
