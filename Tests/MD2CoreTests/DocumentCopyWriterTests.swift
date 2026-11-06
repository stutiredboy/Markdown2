import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MD2App

private final class CopyTestState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func access<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&value) }
    }
}

private struct CopyFixture: Sendable {
    let directory: URL
    let source: URL
    let destination: URL
    let original = Data([0xef, 0xbb, 0xbf]) + Data("Disk version\r\n".utf8)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-copy-test-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("source.md")
        destination = directory.appendingPathComponent("copy.md")
        try original.write(to: source)
    }

    func snapshot(text: String = "Editor version\n", format: MarkdownFileFormat = .init()) throws -> DocumentCopySnapshot {
        try DocumentCopySnapshot(documentID: UUID(), revision: 7, text: text, format: format, sourceURL: source)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func names() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) }
    func assertFailedCleanly() throws {
        #expect(try Data(contentsOf: source) == original)
        #expect(try names() == ["source.md"])
    }
}

struct DocumentCopyWriterTests {
    @Test func writesImmutableEditorSnapshotAndReturnsVerifiableReceipt() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        var text = "Editor version\n"
        var format = MarkdownFileFormat(encoding: .utf8, hasBOM: true, lineEnding: .crlf)
        let snapshot = try fixture.snapshot(text: text, format: format)
        text = "Later edit"
        format = .init()
        let expected = Data([0xef, 0xbb, 0xbf]) + Data("Editor version\r\n".utf8)
        let receipt = try DocumentCopyWriter().writeNew(snapshot, to: fixture.destination)
        #expect(try Data(contentsOf: fixture.destination) == expected)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(try fixture.snapshot().sourceIdentity == snapshot.sourceIdentity)
        #expect(receipt.operationID == snapshot.operationID)
        #expect(receipt.documentID == snapshot.documentID)
        #expect(receipt.revision == 7)
        #expect(receipt.destinationURL == fixture.destination)
        #expect(receipt.writtenFormat == snapshot.format)
        #expect(receipt.byteCount == expected.count)
        #expect(receipt.contentHash == Data(SHA256.hash(data: expected)))
        #expect(receipt.completeness == .textOnly)
        #expect(try fixture.names() == ["source.md", "copy.md"])
        #expect(text == "Later edit" && format == MarkdownFileFormat())
    }

    @Test func preservesEncodingBOMAndNewlinesWithGoldenBytes() throws {
        let cases: [(MarkdownFileFormat, String, [UInt8])] = [
            (.init(), "A\n", [0x41, 0x0a]),
            (.init(encoding: .utf8, hasBOM: true, lineEnding: .mixed), "A\r\nB\rC\n", [0xef,0xbb,0xbf,0x41,0x0d,0x0a,0x42,0x0d,0x43,0x0a]),
            (.init(encoding: .utf16LE, hasBOM: true, lineEnding: .crlf), "A\n", [0xff,0xfe,0x41,0,0x0d,0,0x0a,0]),
            (.init(encoding: .utf16BE, hasBOM: false, lineEnding: .cr), "A\n", [0,0x41,0,0x0d]),
            (.init(encoding: .utf32LE, hasBOM: true), "A\n", [0xff,0xfe,0,0,0x41,0,0,0,0x0a,0,0,0]),
            (.init(encoding: .utf32BE, hasBOM: true), "A\n", [0,0,0xfe,0xff,0,0,0,0x41,0,0,0,0x0a]),
            (.init(encoding: .gbk, lineEnding: .crlf), "中\n", [0xd6,0xd0,0x0d,0x0a]),
            (.init(encoding: .gb18030, lineEnding: .crlf), "中\n", [0xd6,0xd0,0x0d,0x0a])
        ]
        for (format, text, bytes) in cases {
            let fixture = try CopyFixture()
            defer { fixture.remove() }
            let receipt = try DocumentCopyWriter().writeNew(fixture.snapshot(text: text, format: format), to: fixture.destination)
            #expect(try Data(contentsOf: fixture.destination) == Data(bytes), "\(format.encodingLabel)")
            #expect(receipt.writtenFormat == format)
            #expect(try Data(contentsOf: fixture.source) == fixture.original)
        }
    }

    @Test func emptyTextCommitsAnEmptyFile() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let receipt = try DocumentCopyWriter().writeNew(fixture.snapshot(text: ""), to: fixture.destination)
        #expect(receipt.byteCount == 0)
        #expect(try Data(contentsOf: fixture.destination).isEmpty)
    }

    @Test func refusesUnrepresentableTextWithoutChangingEncoding() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.snapshot(text: "🧪", format: .init(encoding: .gbk))
        #expect(throws: DocumentCopyError.unrepresentableEncoding) {
            try DocumentCopyWriter().writeNew(snapshot, to: fixture.destination)
        }
        try fixture.assertFailedCleanly()
    }

    @Test func refusesExistingFileAndLeavesItsBytesUntouched() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let existing = Data("Existing destination".utf8)
        try existing.write(to: fixture.destination)
        #expect(throws: DocumentCopyError.destinationExists) {
            try DocumentCopyWriter().writeNew(fixture.snapshot(), to: fixture.destination)
        }
        #expect(try Data(contentsOf: fixture.destination) == existing)
        #expect(try fixture.names() == ["source.md", "copy.md"])
    }

    @Test func refusesSameSourceHardLinkAndSymbolicAlias() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let hardLink = fixture.directory.appendingPathComponent("hard.md")
        let symbolicLink = fixture.directory.appendingPathComponent("symbolic.md")
        try FileManager.default.linkItem(at: fixture.source, to: hardLink)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: fixture.source)
        let snapshot = try fixture.snapshot()
        for url in [fixture.source, hardLink, symbolicLink] {
            #expect(throws: DocumentCopyError.sameAsSource) { try DocumentCopyWriter().writeNew(snapshot, to: url) }
        }
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(try fixture.names() == ["source.md", "hard.md", "symbolic.md"])
    }

    @Test func refusesDanglingSymlinkAndDirectoryDestinations() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(atPath: fixture.destination.path, withDestinationPath: "missing.md")
        #expect(throws: DocumentCopyError.destinationExists) {
            try DocumentCopyWriter().writeNew(fixture.snapshot(), to: fixture.destination)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path) == "missing.md")
        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try DocumentCopyWriter().writeNew(fixture.snapshot(), to: fixture.destination)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test func refusesCrossDirectoryAndNonFileDestinations() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let other = fixture.directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let snapshot = try fixture.snapshot()
        #expect(throws: DocumentCopyError.outsideSourceDirectory) {
            try DocumentCopyWriter().writeNew(snapshot, to: other.appendingPathComponent("copy.md"))
        }
        #expect(throws: DocumentCopyError.invalidDestination) {
            try DocumentCopyWriter().writeNew(snapshot, to: URL(string: "https://example.com/copy.md")!)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    @Test func refusesSymlinkSource() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: fixture.source)
        #expect(throws: DocumentCopyError.invalidSource) {
            try DocumentCopySnapshot(documentID: UUID(), revision: 0, text: "copy", format: .init(), sourceURL: fixture.destination)
        }
    }

    @Test func sourceReplacementAfterSnapshotIsRejected() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.snapshot()
        let held = fixture.directory.appendingPathComponent("held.md")
        try FileManager.default.moveItem(at: fixture.source, to: held)
        try Data("Replacement".utf8).write(to: fixture.source)
        #expect(throws: DocumentCopyError.sourceChanged) {
            try DocumentCopyWriter().writeNew(snapshot, to: fixture.destination)
        }
        #expect(try Data(contentsOf: held) == fixture.original)
        #expect(try Data(contentsOf: fixture.source) == Data("Replacement".utf8))
        #expect(try fixture.names() == ["source.md", "held.md"])
    }

    @Test func inPlaceExternalEditIsNeverOverwritten() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.snapshot()
        // Writing without .atomic preserves the source inode.
        let changed = Data("External edit after capture".utf8)
        try changed.write(to: fixture.source)
        _ = try DocumentCopyWriter().writeNew(snapshot, to: fixture.destination)
        #expect(try Data(contentsOf: fixture.source) == changed)
        #expect(try Data(contentsOf: fixture.destination) == Data(snapshot.text.utf8))
    }

    @Test func shortWritesAndInterruptedSyscallsAreRetried() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let writes = CopyTestState(0)
        let syncs = CopyTestState(0)
        var writer = DocumentCopyWriter()
        writer.io.write = { fd, buffer, count in
            let attempt = writes.access { $0 += 1; return $0 }
            if attempt == 1 { errno = EINTR; return -1 }
            return Darwin.write(fd, buffer, min(count, 3))
        }
        writer.io.synchronize = { fd in
            let attempt = syncs.access { $0 += 1; return $0 }
            if attempt == 1 { errno = EINTR; return -1 }
            return Darwin.fsync(fd)
        }
        let snapshot = try fixture.snapshot()
        _ = try writer.writeNew(snapshot, to: fixture.destination)
        #expect(try Data(contentsOf: fixture.destination) == Data(snapshot.text.utf8))
        #expect(writes.access { $0 } > 2)
        #expect(syncs.access { $0 } == 2)
    }

    @Test(arguments: [EIO, ENOSPC]) func failedPartialWriteRemovesTemporaryAndNeverPublishes(error: Int32) throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let writes = CopyTestState(0)
        var writer = DocumentCopyWriter()
        writer.io.write = { fd, buffer, count in
            let attempt = writes.access { $0 += 1; return $0 }
            if attempt == 1 { return Darwin.write(fd, buffer, min(count, 3)) }
            errno = error
            return -1
        }
        #expect(throws: DocumentCopyError.io(.write, error)) {
            try writer.writeNew(fixture.snapshot(), to: fixture.destination)
        }
        try fixture.assertFailedCleanly()
    }

    @Test func zeroLengthWriteFailsWithoutSpinning() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        var writer = DocumentCopyWriter()
        writer.io.write = { _, _, _ in 0 }
        #expect(throws: DocumentCopyError.io(.write, EIO)) {
            try writer.writeNew(fixture.snapshot(), to: fixture.destination)
        }
        try fixture.assertFailedCleanly()
    }

    @Test func failedSyncDoesNotPublish() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        var writer = DocumentCopyWriter()
        writer.io.synchronize = { _ in errno = EIO; return -1 }
        #expect(throws: DocumentCopyError.io(.synchronize, EIO)) {
            try writer.writeNew(fixture.snapshot(), to: fixture.destination)
        }
        try fixture.assertFailedCleanly()
    }

    @Test func collisionAtCommitCannotOverwriteCompetitor() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let competingBytes = Data("A different writer won".utf8)
        var writer = DocumentCopyWriter()
        writer.io.commit = { directory, temporary, target in
            // Introduce the race after validation, then invoke the real syscall.
            let fd = openat(directory, target, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            #expect(fd >= 0)
            if fd >= 0 {
                competingBytes.withUnsafeBytes { buffer in
                    #expect(Darwin.write(fd, buffer.baseAddress!, buffer.count) == buffer.count)
                }
                Darwin.close(fd)
            }
            return renameatx_np(directory, temporary, directory, target, UInt32(RENAME_EXCL))
        }
        #expect(throws: DocumentCopyError.destinationExists) {
            try writer.writeNew(fixture.snapshot(), to: fixture.destination)
        }
        #expect(try Data(contentsOf: fixture.destination) == competingBytes)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(try fixture.names() == ["source.md", "copy.md"])
    }

    @Test func unsupportedAtomicCommitFailsClosed() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        var writer = DocumentCopyWriter()
        writer.io.commit = { _, _, _ in errno = ENOTSUP; return -1 }
        #expect(throws: DocumentCopyError.io(.commit, ENOTSUP)) {
            try writer.writeNew(fixture.snapshot(), to: fixture.destination)
        }
        try fixture.assertFailedCleanly()
    }

    @Test func cancellationBeforeWorkAndAfterPartialWriteLeavesNoTarget() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        var before = DocumentCopyWriter()
        before.checkCancellation = { throw CancellationError() }
        #expect(throws: CancellationError.self) { try before.writeNew(fixture.snapshot(), to: fixture.destination) }
        try fixture.assertFailedCleanly()

        let cancelled = CopyTestState(false)
        var during = DocumentCopyWriter()
        during.checkCancellation = { if cancelled.access({ $0 }) { throw CancellationError() } }
        during.io.write = { fd, buffer, count in
            let result = Darwin.write(fd, buffer, min(count, 3))
            cancelled.access { $0 = true }
            return result
        }
        #expect(throws: CancellationError.self) { try during.writeNew(fixture.snapshot(), to: fixture.destination) }
        try fixture.assertFailedCleanly()
    }

    @Test func completeFileAppearsAtCommitAndLateCancellationReturnsReceipt() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let text = String(repeating: "Complete content\n", count: 20_000)
        let expected = Data(text.utf8)
        let cancelled = CopyTestState(false)
        var writer = DocumentCopyWriter()
        writer.checkCancellation = { if cancelled.access({ $0 }) { throw CancellationError() } }
        writer.io.commit = { directory, temporary, target in
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            #expect((try? Data(contentsOf: fixture.directory.appendingPathComponent(temporary))) == expected)
            let result = renameatx_np(directory, temporary, directory, target, UInt32(RENAME_EXCL))
            cancelled.access { $0 = true }
            return result
        }
        let receipt = try writer.writeNew(fixture.snapshot(text: text), to: fixture.destination)
        #expect(try Data(contentsOf: fixture.destination) == expected)
        #expect(receipt.contentHash == Data(SHA256.hash(data: expected)))
        #expect(try fixture.names() == ["source.md", "copy.md"])
    }

    @Test func sourceReplacementDuringWriteAbortsBeforePublication() throws {
        let fixture = try CopyFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.snapshot()
        let held = fixture.directory.appendingPathComponent("held.md")
        var writer = DocumentCopyWriter()
        writer.io.synchronize = { fd in
            do {
                try FileManager.default.moveItem(at: fixture.source, to: held)
                try Data("Latest external version".utf8).write(to: fixture.source)
            } catch { Issue.record(error) }
            return Darwin.fsync(fd)
        }
        #expect(throws: DocumentCopyError.sourceChanged) { try writer.writeNew(snapshot, to: fixture.destination) }
        #expect(try Data(contentsOf: held) == fixture.original)
        #expect(try Data(contentsOf: fixture.source) == Data("Latest external version".utf8))
        #expect(try fixture.names() == ["source.md", "held.md"])
    }

    @Test func renamedParentAbortsAndCleansTemporaryThroughDirectoryDescriptor() throws {
        let fixture = try CopyFixture()
        let moved = fixture.directory.appendingPathExtension("moved")
        defer { fixture.remove(); try? FileManager.default.removeItem(at: moved) }
        let snapshot = try fixture.snapshot()
        var writer = DocumentCopyWriter()
        writer.io.synchronize = { fd in
            do { try FileManager.default.moveItem(at: fixture.directory, to: moved) }
            catch { Issue.record(error) }
            return Darwin.fsync(fd)
        }
        #expect(throws: DocumentCopyError.sourceChanged) { try writer.writeNew(snapshot, to: fixture.destination) }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: moved.path)) == ["source.md"])
        #expect(try Data(contentsOf: moved.appendingPathComponent("source.md")) == fixture.original)
    }
}
