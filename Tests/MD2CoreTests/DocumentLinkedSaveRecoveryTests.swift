import Darwin
import Foundation
import Testing
@testable import MD2App

@MainActor
struct DocumentLinkedSaveRecoveryTests {
    private enum SimulatedInterruption: Error { case write }

    @MainActor
    private struct Fixture {
        let directory: URL
        let source: URL
        let alias: URL
        let repository: DocumentRecoveryRepository
        let original = Data([0xfe, 0xff]) + "原文\r\n".data(using: .utf16BigEndian)!
        let draft = "修订🧪\n正文\n"
        let target = Data([0xfe, 0xff]) + "修订🧪\r\n正文\r\n".data(using: .utf16BigEndian)!

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-linked-save-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            source = directory.appendingPathComponent("source.md")
            alias = directory.appendingPathComponent("alias.md")
            repository = DocumentRecoveryRepository(directory: directory.appendingPathComponent("recovery"))
            try original.write(to: source)
            try FileManager.default.linkItem(at: source, to: alias)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func snapshot() throws -> DocumentRecoverySnapshot {
            try #require(repository.load().first)
        }

        func interruptSave(after count: Int) throws {
            let store = DocumentStore(recoveryRepository: repository)
            defer { store.closeDocument(discardRecovery: false) }
            store.open(source)
            store.text = draft
            store.linkedSaveWrite = { [self] data, handle, offset in
                if data == target {
                    #expect(offset == nil)
                    // Read the actual on-disk record before the first truncation.
                    let checkpoint = try snapshot()
                    #expect(checkpoint.isDirty)
                    #expect(checkpoint.text == draft)
                    #expect(checkpoint.fingerprint?.contentHash == DocumentFileFingerprint.hash(of: original))
                    #expect(checkpoint.linkedSave?.fileKey != nil)
                    #expect(checkpoint.linkedSave?.targetHash == DocumentFileFingerprint.hash(of: target))
                    try DocumentLinkedSaveFile.write(Data(data.prefix(count)), to: handle, resumingAt: nil)
                }
                // Suppress in-process rollback to simulate termination.
                throw SimulatedInterruption.write
            }
            #expect(!store.save())
            #expect(try Data(contentsOf: source) == target.prefix(count))
            #expect(try Data(contentsOf: alias) == target.prefix(count))
        }

        func restore() throws -> DocumentStore {
            let store = DocumentStore(recoveryRepository: repository)
            store.restore(try snapshot())
            return store
        }

        func expectSharedContents(_ bytes: Data) throws {
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try Data(contentsOf: alias) == bytes)
            var info = stat()
            var linkedInfo = stat()
            try #require(stat(source.path, &info) == 0)
            try #require(stat(alias.path, &linkedInfo) == 0)
            #expect(info.st_dev == linkedInfo.st_dev)
            #expect(info.st_ino == linkedInfo.st_ino)
        }
    }

    @Test(arguments: [0, 3])
    func deferringAndFinishingPreservesExactBytesAndHardLinks(partialCount: Int) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.interruptSave(after: partialCount)
        let deferred = try fixture.restore()
        #expect(deferred.hasExternalConflict)
        #expect(deferred.offersLinkedSaveRepair)
        deferred.resolveLinkedSaveRepair(finish: false)
        #expect(deferred.hasExternalConflict)
        #expect(deferred.externalConflictRequest == nil)
        #expect(deferred.prepareForTermination(), "quit must preserve the journal and leave both aliases untouched")
        #expect(deferred.closeDocument(discardRecovery: false))
        try fixture.expectSharedContents(Data(fixture.target.prefix(partialCount)))
        #expect(try fixture.snapshot().text == fixture.draft)
        #expect(try fixture.snapshot().linkedSave != nil)

        let resumed = try fixture.restore()
        defer { resumed.closeDocument(discardRecovery: true) }
        #expect(resumed.offersLinkedSaveRepair)
        resumed.resolveLinkedSaveRepair(finish: true)
        #expect(!resumed.hasExternalConflict)
        #expect(!resumed.isDirty)
        #expect(resumed.text == fixture.draft)
        try fixture.expectSharedContents(fixture.target)
        #expect(try fixture.snapshot().linkedSave == nil)
        #expect(try fixture.snapshot().text.isEmpty, "clean backed-file records omit content")
    }

    @Test func completedInterruptedSaveIsRecognizedWithoutAnAdditionalWrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.interruptSave(after: fixture.target.count)
        let restored = DocumentStore(recoveryRepository: fixture.repository)
        defer { restored.closeDocument(discardRecovery: true) }
        restored.linkedSaveWrite = { _, _, _ in Issue.record("Recognizing complete bytes must not write to disk") }
        restored.restore(try fixture.snapshot())
        #expect(!restored.hasExternalConflict)
        #expect(!restored.isDirty)
        #expect(restored.text == fixture.draft)
        try fixture.expectSharedContents(fixture.target)
        #expect(try fixture.snapshot().linkedSave == nil)
    }

    @Test func aSecondInterruptionKeepsTheSameJournalAndCanResume() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.interruptSave(after: 3)
        let interruptedAgain = try fixture.restore()
        interruptedAgain.linkedSaveWrite = { data, handle, offset in
            #expect(offset == 3, "retry must append without truncating the prefix")
            try DocumentLinkedSaveFile.write(Data(data.prefix(2)), to: handle, resumingAt: offset)
            throw SimulatedInterruption.write
        }
        interruptedAgain.resolveLinkedSaveRepair(finish: true)
        #expect(interruptedAgain.isDirty)
        #expect(interruptedAgain.alert != nil)
        #expect(interruptedAgain.prepareForTermination())
        #expect(interruptedAgain.closeDocument(discardRecovery: false))
        try fixture.expectSharedContents(Data(fixture.target.prefix(5)))
        #expect(try fixture.snapshot().linkedSave != nil)

        let restored = try fixture.restore()
        defer { restored.closeDocument(discardRecovery: true) }
        #expect(restored.offersLinkedSaveRepair)
        restored.resolveLinkedSaveRepair(finish: true)
        #expect(!restored.isDirty)
        try fixture.expectSharedContents(fixture.target)
    }

    @Test func changedPrefixRequiresFreshConsent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.interruptSave(after: 3)
        let store = try fixture.restore()
        defer { store.closeDocument(discardRecovery: true) }
        try Data(fixture.target.prefix(5)).write(to: fixture.alias)
        store.resolveLinkedSaveRepair(finish: true)
        try fixture.expectSharedContents(Data(fixture.target.prefix(5)))
        #expect(store.isDirty)
        #expect(store.externalConflictRequest != nil, "the previous approval covered only the old prefix")
        #expect(store.offersLinkedSaveRepair)
        store.resolveLinkedSaveRepair(finish: true)
        try fixture.expectSharedContents(fixture.target)
    }

    @Test func unrelatedInPlaceChangeIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.interruptSave(after: 3)
        let store = try fixture.restore()
        defer { store.closeDocument(discardRecovery: true) }
        let external = Data("External editor".utf8)
        try external.write(to: fixture.alias)
        store.resolveLinkedSaveRepair(finish: true)
        #expect(store.hasExternalConflict)
        #expect(!store.offersLinkedSaveRepair)
        #expect(store.text == fixture.draft)
        try fixture.expectSharedContents(external)
    }

    @Test func replacingTheNamedEntryCannotAuthorizeRepairOnEitherInode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.interruptSave(after: 3)
        let store = try fixture.restore()
        defer { store.closeDocument(discardRecovery: true) }
        try fixture.original.write(to: fixture.source, options: .atomic)
        store.resolveLinkedSaveRepair(finish: true)
        #expect(store.hasExternalConflict)
        #expect(!store.offersLinkedSaveRepair)
        #expect(store.text == fixture.draft)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(try Data(contentsOf: fixture.alias) == fixture.target.prefix(3))

        let relaunched = try fixture.restore()
        defer { relaunched.closeDocument(discardRecovery: true) }
        #expect(relaunched.hasExternalConflict || relaunched.offersLinkedSaveRepair)
        // A bookmark may follow the original inode to its other name. Neither
        // this nor following the reused path can silently overwrite a file.
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(try Data(contentsOf: fixture.alias) == fixture.target.prefix(3))
    }

    @Test func laterDraftEditsRemainAvailableAfterRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.interruptSave(after: 3)
        let store = try fixture.restore()
        store.resolveLinkedSaveRepair(finish: false)
        store.text += "New edits"
        #expect(store.prepareForTermination())
        #expect(store.closeDocument(discardRecovery: false))
        let restored = try fixture.restore()
        defer { restored.closeDocument(discardRecovery: true) }
        #expect(restored.hasExternalConflict)
        #expect(!restored.offersLinkedSaveRepair, "the draft differs from the interrupted save's byte sequence")
        #expect(restored.text == fixture.draft + "New edits")
        try fixture.expectSharedContents(Data(fixture.target.prefix(3)))
    }

    @Test func legacyDraftDoesNotInferAnInterruptedSaveFromPrefixAlone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let baseline = try #require(DocumentFileFingerprint.current(at: fixture.source))
        let snapshot = DocumentRecoverySnapshot(id: UUID(), text: fixture.draft, fileURL: fixture.source,
            identity: DocumentFileIdentity(url: fixture.source),
            format: MarkdownFileFormat(encoding: .utf16BE, hasBOM: true, lineEnding: .crlf),
            fingerprint: baseline, isDirty: true, windowFrame: nil)
        try fixture.repository.write(snapshot)
        try Data(fixture.target.prefix(3)).write(to: fixture.source)
        let restored = try fixture.restore()
        defer { restored.closeDocument(discardRecovery: true) }
        #expect(restored.hasExternalConflict)
        #expect(!restored.offersLinkedSaveRepair)
        #expect(restored.text == fixture.draft)
        try fixture.expectSharedContents(Data(fixture.target.prefix(3)))
    }
}
