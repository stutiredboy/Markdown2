import CryptoKit
import Darwin
import Foundation

enum DocumentCopyOpenError: Error {
    case changed, unavailable, invalidData
}

/// A read-only pin keeps the committed inode alive, so even inode reuse cannot
/// turn a receipt into authority to open another file. All reads use pread;
/// sharing a receipt never shares a mutable file offset or a writable handle.
final class DocumentCopyFileReference: @unchecked Sendable, Equatable {
    let identity: DocumentCopyFileIdentity
    private let descriptor: Int32

    private init(descriptor: Int32, identity: DocumentCopyFileIdentity) {
        self.descriptor = descriptor
        self.identity = identity
    }

    deinit { Darwin.close(descriptor) }

    static func == (lhs: DocumentCopyFileReference, rhs: DocumentCopyFileReference) -> Bool {
        lhs.identity == rhs.identity
    }

    static func open(at url: URL, matching expected: DocumentCopyFileIdentity? = nil) throws -> DocumentCopyFileReference {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        return try adopting(descriptor, matching: expected)
    }

    static func open(at directory: Int32, name: String, matching expected: DocumentCopyFileIdentity) throws -> DocumentCopyFileReference {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        return try adopting(descriptor, matching: expected)
    }

    private static func adopting(_ descriptor: Int32, matching expected: DocumentCopyFileIdentity?) throws -> DocumentCopyFileReference {
        guard descriptor >= 0 else { throw DocumentCopyOpenError.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              expected == nil || DocumentCopyFileIdentity(info) == expected else {
            Darwin.close(descriptor)
            throw DocumentCopyOpenError.changed
        }
        return DocumentCopyFileReference(descriptor: descriptor, identity: DocumentCopyFileIdentity(info))
    }

    /// Refuse redirection, aliases and disappeared files. This is a gate, not a
    /// claim of filesystem CAS against arbitrary concurrent renames.
    func validate(at url: URL) throws {
        var entry = stat()
        var opened = stat()
        guard lstat(url.path, &entry) == 0, fstat(descriptor, &opened) == 0 else {
            throw DocumentCopyOpenError.unavailable
        }
        guard entry.st_mode & S_IFMT == S_IFREG, opened.st_mode & S_IFMT == S_IFREG,
              entry.st_nlink == 1, opened.st_nlink == 1,
              DocumentCopyFileIdentity(entry) == identity, DocumentCopyFileIdentity(opened) == identity else {
            throw DocumentCopyOpenError.changed
        }
    }

    /// Move handling uses the pinned object; it never falls back to a reused
    /// pathname when the object has been unlinked or acquired another link.
    func currentURL() -> URL? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return nil }
        let url = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        guard !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes"),
              (try? validate(at: url)) != nil else { return nil }
        return url
    }

    func read(at url: URL, expectedCount: Int? = nil) throws -> Data {
        try validate(at: url)
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_size >= 0,
              before.st_size <= Int.max else { throw DocumentCopyOpenError.unavailable }
        let count = Int(before.st_size)
        guard expectedCount == nil || expectedCount == count else { throw DocumentCopyOpenError.changed }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try Task.checkCancellation()
                let amount = pread(descriptor, buffer.baseAddress!.advanced(by: offset), min(count - offset, 64 * 1024), off_t(offset))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw DocumentCopyOpenError.changed }
                offset += amount
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw DocumentCopyOpenError.changed }
        try validate(at: url)
        return data
    }
}

struct DocumentCopyOpenData: Sendable {
    let receipt: DocumentCopyReceipt
    let data: Data
}

struct DocumentCopyReader: Sendable {
    /// Race seams run against real descriptors and files, not mocked identities.
    var afterInitialValidation: @Sendable () throws -> Void = {}
    var afterRead: @Sendable () throws -> Void = {}

    func read(_ receipt: DocumentCopyReceipt) throws -> DocumentCopyOpenData {
        try Self.validateDirectory(receipt)
        try receipt.fileReference.validate(at: receipt.destinationURL)
        try afterInitialValidation()
        let data = try receipt.fileReference.read(at: receipt.destinationURL, expectedCount: receipt.byteCount)
        guard Data(SHA256.hash(data: data)) == receipt.contentHash else { throw DocumentCopyOpenError.changed }
        try afterRead()
        try Self.validateDirectory(receipt)
        try receipt.fileReference.validate(at: receipt.destinationURL)
        return DocumentCopyOpenData(receipt: receipt, data: data)
    }

    static func validateDirectory(_ receipt: DocumentCopyReceipt) throws {
        var info = stat()
        guard stat(receipt.destinationURL.deletingLastPathComponent().path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              DocumentCopyFileIdentity(info) == receipt.directoryIdentity else { throw DocumentCopyOpenError.changed }
    }
}

/// Narrow save seams exercise real staged files and the atomic replacement
/// boundary. They are used only by independently opened copy Stores.
@MainActor
struct DocumentCopySaveIO {
    var writeTemporary: (Data, URL) throws -> Void = { try $0.write(to: $1) }
    var replace: (URL, URL) throws -> Void = {
        _ = try FileManager.default.replaceItemAt($0, withItemAt: $1, backupItemName: nil, options: [])
    }
}
