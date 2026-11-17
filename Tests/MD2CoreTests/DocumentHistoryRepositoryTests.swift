import Foundation
import Testing
import os
@testable import MD2App

private struct HistoryFixture {
    let directory: URL
    let history: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-history-\(UUID())", isDirectory: true)
        history = directory.appendingPathComponent("Text history", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(_ name: String = "Source.md", bytes: Data = Data()) throws -> (URL, DocumentHistoryFileID) {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return (url, try #require(DocumentHistoryFileID(url: url)))
    }

    func revisionFiles() throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(at: history, includingPropertiesForKeys: [.fileSizeKey]))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "revision" }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

struct DocumentHistoryRepositoryTests {
    @Test func recordsExactBytesAndDeduplicatesOnlyAdjacentIdenticalFormat() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let format = MarkdownFileFormat(encoding: .utf16BE, hasBOM: true, lineEnding: .mixed)
        let original = try #require(format.encode("a\r\nb\rc\n"))
        let (url, id) = try fixture.file(bytes: original)
        let repo = DocumentHistoryRepository(directory: fixture.history)
        let secondFormat = MarkdownFileFormat(encoding: .utf16BE, hasBOM: true, lineEnding: .crlf)
        repo.record(original, format: format, reason: .opened, for: id)
        repo.record(original, format: format, reason: .saved, for: id)
        repo.record(original, format: secondFormat, reason: .saved, for: id)
        repo.record(Data(), format: .init(), reason: .externalReload, for: id)
        repo.record(original, format: format, reason: .saved, for: id)
        await repo.flush()

        let reopened = DocumentHistoryRepository(directory: fixture.history)
        let listing = try await reopened.revisions(for: id)
        #expect(listing.unavailableCount == 0)
        #expect(listing.revisions.map(\.reason) == [.saved, .externalReload, .saved, .opened])
        #expect(listing.revisions.map(\.date) == listing.revisions.map(\.date).sorted(by: >))
        #expect(listing.revisions.map(\.byteCount) == [original.count, 0, original.count, original.count])
        let expectedFormats = [format, .init(), secondFormat, format]
        for (index, revision) in listing.revisions.enumerated() {
            let contents = try await reopened.read(revision, for: id)
            #expect(contents.format == expectedFormats[index])
            #expect(contents.data == (index == 1 ? Data() : original))
        }
        #expect(try Data(contentsOf: url) == original)
        let paths = try fixture.revisionFiles()
        #expect(paths.count == 4)
        #expect(paths.allSatisfy { !$0.path.contains(url.lastPathComponent) })
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: fixture.history.path)
        #expect(rootAttributes[.posixPermissions] as? Int == 0o700)
        for path in paths {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test func physicalIdentityFollowsRenameAndNeverUsesTheOldPathOccupant() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let first = Data("first".utf8)
        let (url, id) = try fixture.file(bytes: first)
        let repo = DocumentHistoryRepository(directory: fixture.history)
        repo.record(first, format: .init(), reason: .opened, for: id)

        let renamed = fixture.directory.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: url, to: renamed)
        let movedID = try #require(DocumentHistoryFileID(url: renamed))
        #expect(movedID == id)
        let alias = fixture.directory.appendingPathComponent("Alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: renamed)
        #expect(DocumentHistoryFileID(url: alias) == nil)

        let (_, newOccupant) = try fixture.file(bytes: first)
        #expect(id != newOccupant)
        #expect(try await repo.revisions(for: newOccupant).revisions.isEmpty)

        let external = Data("external".utf8)
        try external.write(to: renamed)
        #expect(DocumentHistoryFileID(url: renamed) == id)
        repo.record(external, format: .init(), reason: .externalReload, for: movedID)
        let history = try await repo.revisions(for: movedID)
        #expect(history.revisions.map(\.reason) == [.externalReload, .opened])

        // An external atomic replacement has its own identity even when its
        // path and contents exactly match the file it replaced.
        try external.write(to: renamed, options: .atomic)
        let externalReplacement = try #require(DocumentHistoryFileID(url: renamed))
        #expect(externalReplacement != id)
        #expect(try await repo.revisions(for: externalReplacement).revisions.isEmpty)
        #expect(try await repo.revisions(for: id).revisions.count == 2)
    }

    @Test func confirmedReplacementCarriesHistoryEvenWithoutRecordingTheSave() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let first = Data([1])
        let (url, firstID) = try fixture.file(bytes: first)
        let repo = DocumentHistoryRepository(directory: fixture.history, limits: .init(maximumRevisionBytes: 8))
        repo.record(first, format: .init(), reason: .opened, for: firstID)

        let saved = Data([2])
        try saved.write(to: url, options: .atomic)
        let savedID = try #require(DocumentHistoryFileID(url: url))
        #expect(savedID != firstID)
        repo.record(saved, format: .init(), reason: .saved, for: savedID, replacing: firstID)

        let oversized = Data(repeating: 3, count: 9)
        try oversized.write(to: url, options: .atomic)
        let oversizedID = try #require(DocumentHistoryFileID(url: url))
        repo.record(oversized, format: .init(), reason: .saved, for: oversizedID, replacing: savedID)

        let optedOut = Data([4])
        try optedOut.write(to: url, options: .atomic)
        let finalID = try #require(DocumentHistoryFileID(url: url))
        repo.reassociate(from: oversizedID, to: finalID)

        let listing = try await repo.revisions(for: finalID)
        #expect(listing.revisions.map(\.reason) == [.saved, .opened])
        let last = try #require(listing.revisions.first)
        #expect(try await repo.read(last, for: finalID).data == saved)
        #expect(try await repo.revisions(for: firstID).revisions.isEmpty)
        #expect(try await repo.revisions(for: oversizedID).revisions.isEmpty)
        #expect(try Data(contentsOf: url) == optedOut)
    }

    @Test func missingHeaderAndPayloadCorruptionAreIsolatedAndInterruptedStagingIsRemoved() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let original = Data("first".utf8)
        let (source, id) = try fixture.file(bytes: original)
        let repo = DocumentHistoryRepository(directory: fixture.history)
        for byte in UInt8(1)...3 { repo.record(Data([byte]), format: .init(), reason: .saved, for: id) }
        let originalList = try await repo.revisions(for: id)
        let orderedFiles = try fixture.revisionFiles().sorted { $0.lastPathComponent > $1.lastPathComponent }
        let invalidPayload = try #require(orderedFiles.first)
        let missing = try #require(orderedFiles.dropFirst().first)
        let invalidHeader = try #require(orderedFiles.last)
        let interrupted = missing.deletingLastPathComponent().appendingPathComponent(".pending")
        try Data("partial".utf8).write(to: interrupted)
        try Data([0]).write(to: invalidHeader)
        var damaged = try Data(contentsOf: invalidPayload)
        damaged[damaged.index(before: damaged.endIndex)] ^= 1
        try damaged.write(to: invalidPayload)
        try FileManager.default.removeItem(at: missing)
        repo.pruneExpired()
        await repo.flush()
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))

        let listing = try await repo.revisions(for: id)
        #expect(listing.unavailableCount == 1)
        let surviving = try #require(listing.revisions.first)
        await #expect(throws: DocumentHistoryError.corruptRevision) { try await repo.read(surviving, for: id) }
        let removed = try #require(originalList.revisions.dropFirst().first)
        await #expect(throws: DocumentHistoryError.missingRevision) { try await repo.read(removed, for: id) }

        // A later capture of the same bytes repairs the usable tip rather than
        // deduplicating against a header for an unreadable payload.
        repo.record(Data([3]), format: .init(), reason: .saved, for: id)
        let healedList = try await repo.revisions(for: id)
        let healed = try #require(healedList.revisions.first)
        #expect(try await repo.read(healed, for: id).data == Data([3]))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func retainsNewestWithinPerDocumentGlobalCountAndAgeLimits() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let (_, firstID) = try fixture.file()
        let (_, secondID) = try fixture.file("Another.md")
        let date = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        let repo = DocumentHistoryRepository(directory: fixture.history,
            limits: .init(maximumAge: 5, revisionsPerDocument: 2, maximumRevisions: 3), now: { date.withLock { $0 } })
        for byte in UInt8(1)...3 { repo.record(Data([byte]), format: .init(), reason: .saved, for: firstID) }
        #expect(try await repo.revisions(for: firstID).revisions.count == 2)
        date.withLock { $0.addTimeInterval(1) }
        for byte in UInt8(4)...5 { repo.record(Data([byte]), format: .init(), reason: .saved, for: secondID) }
        #expect(try await repo.revisions(for: firstID).revisions.count == 1)
        #expect(try await repo.revisions(for: secondID).revisions.count == 2)
        #expect(try fixture.revisionFiles().count == 3)

        date.withLock { $0.addTimeInterval(6) }
        repo.pruneExpired()
        await repo.flush()
        #expect(try fixture.revisionFiles().isEmpty)
        #expect(try await repo.revisions(for: firstID).revisions.isEmpty)
    }

    @Test func globalByteLimitIncludesMetadataAndClearNeverTouchesOriginal() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let original = Data("current".utf8)
        let (source, id) = try fixture.file(bytes: original)
        let repo = DocumentHistoryRepository(directory: fixture.history, limits: .init(maximumStorageBytes: 420))
        repo.record(Data(repeating: 1, count: 120), format: .init(), reason: .opened, for: id)
        repo.record(Data(repeating: 2, count: 120), format: .init(), reason: .saved, for: id)
        let listing = try await repo.revisions(for: id)
        #expect(listing.revisions.map(\.reason) == [.saved])
        let revision = try #require(listing.revisions.first)
        let stored = try #require(fixture.revisionFiles().first)
        let storedSize = try #require(stored.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(storedSize > revision.byteCount)
        #expect(storedSize <= 420)

        try await repo.removeAll()
        #expect(try fixture.revisionFiles().isEmpty)
        #expect(try await repo.revisions(for: id).revisions.isEmpty)
        await #expect(throws: DocumentHistoryError.missingRevision) { try await repo.read(revision, for: id) }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func concurrentRepositoriesPublishAndPruneWholeRevisions() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let (_, id) = try fixture.file()
        let limits = DocumentHistoryRepository.Limits(revisionsPerDocument: 6)
        let first = DocumentHistoryRepository(directory: fixture.history, limits: limits)
        let second = DocumentHistoryRepository(directory: fixture.history, limits: limits)
        for byte in UInt8(0)...4 {
            first.record(Data([byte]), format: .init(), reason: .saved, for: id)
            second.record(Data([byte + 5]), format: .init(), reason: .externalReload, for: id)
        }
        async let firstFlush: Void = first.flush()
        async let secondFlush: Void = second.flush()
        _ = await (firstFlush, secondFlush)

        let listing = try await second.revisions(for: id)
        #expect(listing.unavailableCount == 0)
        #expect(listing.revisions.count == 6)
        var values = Set<Data>()
        for revision in listing.revisions {
            values.insert(try await first.read(revision, for: id).data)
        }
        #expect(values.count == 6)
        #expect(values.contains(Data([4])))
        #expect(values.contains(Data([9])))
        #expect(try fixture.revisionFiles().count == 6)
    }
}
