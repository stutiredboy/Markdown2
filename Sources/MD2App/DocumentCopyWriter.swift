import CryptoKit
import Darwin
import Foundation

/// The exact editor contents a copy operation is allowed to write. Construct it
/// while capturing the editor state; the writer never reads a DocumentStore.
/// `operationID` must also be invalidated by the caller when conflict/file
/// identity changes, even if the text revision is unchanged. Adoption is outside
/// this type and outside the writer.
struct DocumentCopySnapshot: Sendable {
    let operationID: UUID
    let documentID: UUID
    let revision: Int
    let text: String
    let format: MarkdownFileFormat
    let sourceURL: URL
    let sourceIdentity: DocumentCopyFileIdentity
    fileprivate let directoryIdentity: DocumentCopyFileIdentity

    init(operationID: UUID = UUID(), documentID: UUID, revision: Int, text: String,
         format: MarkdownFileFormat, sourceURL: URL) throws {
        guard DocumentCopyWriter.isLocalFileURL(sourceURL), !sourceURL.hasDirectoryPath else {
            throw DocumentCopyError.invalidSource
        }
        let directory = sourceURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let normalized = directory.appendingPathComponent(sourceURL.lastPathComponent)
        let descriptor = try DocumentCopyWriter.openDirectory(directory)
        defer { Darwin.close(descriptor) }
        var parent = stat()
        guard fstat(descriptor, &parent) == 0 else { throw DocumentCopyError.io(.inspectSource, errno) }
        var source = stat()
        guard fstatat(descriptor, normalized.lastPathComponent, &source, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw DocumentCopyError.io(.inspectSource, errno)
        }
        // A final-component symlink, directory, device, or FIFO is outside this
        // first slice; in particular, never open a FIFO just to inspect a copy.
        guard source.st_mode & S_IFMT == S_IFREG else { throw DocumentCopyError.invalidSource }
        self.operationID = operationID
        self.documentID = documentID
        self.revision = revision
        self.text = text
        self.format = format
        self.sourceURL = normalized
        sourceIdentity = DocumentCopyFileIdentity(source)
        directoryIdentity = DocumentCopyFileIdentity(parent)
    }
}

struct DocumentCopyFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    fileprivate init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
    }
}

/// A committed, complete text file. This receipt does not authorize adopting it
/// as the document, nor promise that attachments have been copied. Cancellation
/// after commit returns success: the file must not be mistaken for an aborted save.
struct DocumentCopyReceipt: Equatable, Sendable {
    enum Completeness: Equatable, Sendable { case textOnly }

    let operationID: UUID
    let documentID: UUID
    let revision: Int
    let destinationURL: URL
    let writtenFormat: MarkdownFileFormat
    let byteCount: Int
    let contentHash: Data
    let completeness: Completeness = .textOnly
}

enum DocumentCopyError: Error, Equatable {
    enum Operation: Equatable { case openDirectory, inspectSource, inspectDestination, createTemporary, write, synchronize, commit }
    case invalidSource
    case invalidDestination
    case outsideSourceDirectory
    case sourceChanged
    case sameAsSource
    case destinationExists
    case unrepresentableEncoding
    case temporaryFileChanged
    case io(Operation, Int32)
}

/// Synchronous file I/O, intended for a worker task. First slice: a new regular
/// file beside a captured existing source. It does not touch source bytes,
/// DocumentStore, dirty state, watchers, undo, or recovery records.
///
/// The target is absent until renameatx_np(RENAME_EXCL) publishes the fully
/// written temporary file. Unsupported atomic-exclusion filesystems fail; there
/// is deliberately no ordinary-rename fallback. fsync precedes commit, but this
/// is not a promise of persistence through power loss or a filesystem failure.
struct DocumentCopyWriter: Sendable {
    /// Narrow syscall seams for exercising short writes and failures against
    /// actual temporary files, rather than mocking an entire filesystem.
    struct IO: Sendable {
        var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
        var synchronize: @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }
        var commit: @Sendable (Int32, String, String) -> Int32 = {
            Darwin.renameatx_np($0, $1, $0, $2, UInt32(RENAME_EXCL))
        }
    }

    var io = IO()
    var checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }

    func writeNew(_ snapshot: DocumentCopySnapshot, to destination: URL) throws -> DocumentCopyReceipt {
        try checkCancellation()
        guard Self.isLocalFileURL(destination), !destination.hasDirectoryPath,
              !destination.lastPathComponent.isEmpty,
              destination.lastPathComponent != ".", destination.lastPathComponent != ".." else {
            throw DocumentCopyError.invalidDestination
        }
        let directory = snapshot.sourceURL.deletingLastPathComponent()
        let targetDirectory = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        guard targetDirectory == directory else { throw DocumentCopyError.outsideSourceDirectory }
        let targetName = destination.lastPathComponent
        let output = directory.appendingPathComponent(targetName)
        let descriptor = try Self.openDirectory(directory)
        defer { Darwin.close(descriptor) }
        try Self.validateSource(snapshot, directory: descriptor)
        try Self.requireNewDestination(targetName, directory: descriptor, source: snapshot.sourceIdentity)
        guard let data = snapshot.format.encode(snapshot.text) else {
            throw DocumentCopyError.unrepresentableEncoding
        }
        let receipt = DocumentCopyReceipt(
            operationID: snapshot.operationID, documentID: snapshot.documentID, revision: snapshot.revision,
            destinationURL: output, writtenFormat: snapshot.format, byteCount: data.count,
            contentHash: Data(SHA256.hash(data: data)))
        try checkCancellation()

        let temporaryName = ".md2-copy-\(UUID().uuidString).tmp"
        let temporary = openat(descriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporary >= 0 else { throw DocumentCopyError.io(.createTemporary, errno) }
        defer { Darwin.close(temporary) }
        var information = stat()
        guard fstat(temporary, &information) == 0 else {
            let error = errno
            unlinkat(descriptor, temporaryName, 0)
            throw DocumentCopyError.io(.createTemporary, error)
        }
        let temporaryIdentity = DocumentCopyFileIdentity(information)
        var committed = false
        defer {
            // Only unlink our still-identical private entry, never a replacement
            // created by another actor at the same name.
            if !committed, Self.identity(of: temporaryName, directory: descriptor) == temporaryIdentity {
                unlinkat(descriptor, temporaryName, 0)
            }
        }

        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                try checkCancellation()
                let amount = min(buffer.count - written, 64 * 1024)
                let count = io.write(temporary, buffer.baseAddress!.advanced(by: written), amount)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw DocumentCopyError.io(.write, errno)
                }
                guard count > 0, count <= amount else { throw DocumentCopyError.io(.write, EIO) }
                written += count
            }
        }
        try checkCancellation()
        while io.synchronize(temporary) != 0 {
            if errno == EINTR { try checkCancellation(); continue }
            throw DocumentCopyError.io(.synchronize, errno)
        }
        try checkCancellation()
        try Self.validateSource(snapshot, directory: descriptor)
        guard Self.identity(of: temporaryName, directory: descriptor) == temporaryIdentity else {
            throw DocumentCopyError.temporaryFileChanged
        }
        // The atomic operation, not the earlier existence check, closes the
        // collision race. No throws/cancellation checks after a successful commit.
        guard io.commit(descriptor, temporaryName, targetName) == 0 else {
            if errno == EEXIST { throw DocumentCopyError.destinationExists }
            throw DocumentCopyError.io(.commit, errno)
        }
        committed = true
        return receipt
    }

    fileprivate static func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.query == nil && url.fragment == nil && !url.path.utf8.contains(0)
    }

    fileprivate static func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DocumentCopyError.io(.openDirectory, errno) }
        return descriptor
    }

    private static func validateSource(_ snapshot: DocumentCopySnapshot, directory: Int32) throws {
        var parent = stat()
        guard fstat(directory, &parent) == 0 else { throw DocumentCopyError.io(.inspectSource, errno) }
        guard DocumentCopyFileIdentity(parent) == snapshot.directoryIdentity,
              identity(of: snapshot.sourceURL.lastPathComponent, directory: directory) == snapshot.sourceIdentity else {
            throw DocumentCopyError.sourceChanged
        }
        // A parent moved/replaced while the descriptor was open is not the
        // promised same-directory destination. Refuse before publication.
        var currentParent = stat()
        guard stat(snapshot.sourceURL.deletingLastPathComponent().path, &currentParent) == 0,
              DocumentCopyFileIdentity(currentParent) == snapshot.directoryIdentity else {
            throw DocumentCopyError.sourceChanged
        }
    }

    private static func identity(of name: String, directory: Int32) -> DocumentCopyFileIdentity? {
        var information = stat()
        guard fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return DocumentCopyFileIdentity(information)
    }

    private static func requireNewDestination(_ name: String, directory: Int32,
                                              source: DocumentCopyFileIdentity) throws {
        var existing = stat()
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            var resolved = stat()
            if fstatat(directory, name, &resolved, 0) == 0, DocumentCopyFileIdentity(resolved) == source {
                throw DocumentCopyError.sameAsSource
            }
            throw DocumentCopyError.destinationExists
        }
        guard errno == ENOENT else { throw DocumentCopyError.io(.inspectDestination, errno) }
    }
}
