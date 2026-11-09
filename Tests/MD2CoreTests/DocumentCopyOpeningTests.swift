import AppKit
import Darwin
import Foundation
import Testing
@testable import MD2App

@MainActor
private final class CopyOpeningWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?
    func watch(url: URL) {}
    func stop() {}
}

@MainActor
private struct CopyOpeningFixture {
    let directory: URL
    let source: URL
    let store: DocumentStore
    let original = Data("Original disk bytes\n".utf8)
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-copy-opening-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("original.md")
        try original.write(to: source)
        store = Self.makeStore()
        store.open(source)
        store.text = "Original disk bytes\n" // Same bytes deliberately defeat hash-only validation.
    }
    static func makeStore() -> DocumentStore {
        DocumentStore(saveLocationPicker: { _ in nil }, fileWatcherFactory: { CopyOpeningWatcher() },
                      autosaveDelay: 3_600, maximumAutosaveDelay: 7_200, recoveryDelay: 3_600)
    }
    func receipt() async throws -> DocumentCopyReceipt {
        try #require(await store.copyFlow.create(from: store, text: Self.text, chooseName: { _ in "copy.md" }))
    }
    func open(_ receipt: DocumentCopyReceipt, reader: DocumentCopyReader = .init(),
              makeStore: @MainActor () -> DocumentStore = Self.makeStore) async -> DocumentStore? {
        await store.copyFlow.openCreatedCopy(receipt, from: store, text: Self.text, makeStore: makeStore, reader: reader)
    }
    static func text(_ key: L10nKey) -> String { L10n.text(key, language: .english) }
    func remove() { store.closeDocument(discardRecovery: false); try? FileManager.default.removeItem(at: directory) }
}

@MainActor
struct DocumentCopyOpeningTests {
    @Test func receiptReplacementAndDeletionRefuseWithoutStarterStoreOrLostSuccess() async throws {
        for replacement in ["missing", "ordinary", "identical-hardlink", "symlink", "dangling", "directory", "fifo"] {
            let fixture = try CopyOpeningFixture()
            defer { fixture.remove() }
            let receipt = try await fixture.receipt()
            let moved = fixture.directory.appendingPathComponent("moved.md")
            try FileManager.default.moveItem(at: receipt.destinationURL, to: moved)
            switch replacement {
            case "ordinary": try Data("Unrelated".utf8).write(to: receipt.destinationURL)
            case "identical-hardlink":
                try FileManager.default.linkItem(at: fixture.source, to: receipt.destinationURL)
                #expect(try Data(contentsOf: receipt.destinationURL) == Data(contentsOf: moved))
            case "symlink": try FileManager.default.createSymbolicLink(at: receipt.destinationURL, withDestinationURL: fixture.source)
            case "dangling": try FileManager.default.createSymbolicLink(atPath: receipt.destinationURL.path, withDestinationPath: "missing.md")
            case "directory": try FileManager.default.createDirectory(at: receipt.destinationURL, withIntermediateDirectories: false)
            case "fifo": #expect(mkfifo(receipt.destinationURL.path, 0o600) == 0)
            default: break
            }
            var storesCreated = 0
            let opened = await fixture.open(receipt, makeStore: { storesCreated += 1; return CopyOpeningFixture.makeStore() })
            #expect(opened == nil && storesCreated == 0)
            #expect(fixture.store.copyFlow.receipt == receipt)
            #expect(fixture.store.copyFlow.message?.contains("Created Markdown copy") == true)
            #expect(fixture.store.copyFlow.detail == CopyOpeningFixture.text(.copyOpenFailed))
            #expect(try Data(contentsOf: fixture.source) == fixture.original)
            #expect(try Data(contentsOf: moved) == fixture.original)
            #expect(fixture.store.fileURL == fixture.source)
        }
    }

    @Test func additionalHardlinkToActualCopyIsConservativelyRefused() async throws {
        let fixture = try CopyOpeningFixture()
        defer { fixture.remove() }
        let receipt = try await fixture.receipt()
        let alias = fixture.directory.appendingPathComponent("alias.md")
        try FileManager.default.linkItem(at: receipt.destinationURL, to: alias)
        #expect(await fixture.open(receipt) == nil)
        #expect(fixture.store.copyFlow.receipt == receipt)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(try Data(contentsOf: alias) == fixture.original)
    }

    @Test func replacementDuringReadAndAfterReadIsRefused() async throws {
        for afterRead in [false, true] {
            let fixture = try CopyOpeningFixture()
            defer { fixture.remove() }
            let receipt = try await fixture.receipt()
            let original = fixture.source
            let moved = fixture.directory.appendingPathComponent("moved.md")
            let substitute: @Sendable () throws -> Void = {
                try FileManager.default.moveItem(at: receipt.destinationURL, to: moved)
                try FileManager.default.linkItem(at: original, to: receipt.destinationURL)
            }
            var reader = DocumentCopyReader()
            if afterRead { reader.afterRead = substitute }
            else { reader.afterInitialValidation = substitute }
            #expect(await fixture.open(receipt, reader: reader) == nil)
            #expect(try Data(contentsOf: original) == fixture.original)
            #expect(try Data(contentsOf: moved) == fixture.original)
            #expect(fixture.store.copyFlow.receipt == receipt)
        }
    }

    @Test func replacementBetweenBackgroundReadAndStoreAdoptionIsRefused() async throws {
        let fixture = try CopyOpeningFixture()
        defer { fixture.remove() }
        let receipt = try await fixture.receipt()
        let moved = fixture.directory.appendingPathComponent("moved.md")
        var candidate: DocumentStore?
        let result = await fixture.open(receipt, makeStore: {
            // This is later than the reader's final check and just before the
            // actual Store entry point; no ordinary path read may slip in here.
            do {
                try FileManager.default.moveItem(at: receipt.destinationURL, to: moved)
                try FileManager.default.linkItem(at: fixture.source, to: receipt.destinationURL)
            } catch { Issue.record(error) }
            let store = CopyOpeningFixture.makeStore()
            candidate = store
            return store
        })
        defer { candidate?.closeDocument(discardRecovery: false) }
        #expect(result == nil)
        #expect(candidate?.fileURL == nil && candidate?.isDirty == false)
        #expect(fixture.store.copyFlow.receipt == receipt)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
    }

    @Test func copyMovedAfterOpeningSavesActualCopyAndNeverOriginalAlias() async throws {
        let fixture = try CopyOpeningFixture()
        defer { fixture.remove() }
        let receipt = try await fixture.receipt()
        let copy = try #require(await fixture.open(receipt))
        defer { copy.closeDocument(discardRecovery: false) }
        let moved = fixture.directory.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: receipt.destinationURL, to: moved)
        try FileManager.default.linkItem(at: fixture.source, to: receipt.destinationURL)
        copy.text = "Only the real copy changes"
        #expect(copy.save())
        // F_GETPATH returns /private/var for a fixture created through /var.
        #expect(copy.fileURL?.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        #expect(try String(contentsOf: moved, encoding: .utf8) == copy.text)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(try Data(contentsOf: receipt.destinationURL) == fixture.original)
    }

    @Test func changedContentsOnTheSameInodeDoNotSatisfyOldReceipt() async throws {
        let fixture = try CopyOpeningFixture()
        defer { fixture.remove() }
        let receipt = try await fixture.receipt()
        let handle = try FileHandle(forWritingTo: receipt.destinationURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("Modified copy bytes".utf8))
        try handle.close()
        #expect(await fixture.open(receipt) == nil)
        #expect(fixture.store.copyFlow.receipt == receipt)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
    }

    @Test func concurrentReceiptReadsHaveIndependentOffsets() async throws {
        let fixture = try CopyOpeningFixture()
        defer { fixture.remove() }
        fixture.store.text = String(repeating: "中文 😀\r\n", count: 30_000)
        let receipt = try await fixture.receipt()
        let expected = try Data(contentsOf: receipt.destinationURL)
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<4 {
                group.addTask { try DocumentCopyReader().read(receipt).data }
            }
            var values: [Data] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(results.count == 4 && results.allSatisfy { $0 == expected })
    }

    @Test func deletedCopyCannotSaveThroughIdenticalOriginalHardlinkEvenAfterPriorSaves() async throws {
        for priorSaves in [0, 2] {
            let fixture = try CopyOpeningFixture()
            defer { fixture.remove() }
            let receipt = try await fixture.receipt()
            let copy = try #require(await fixture.open(receipt))
            defer { copy.closeDocument(discardRecovery: false) }
            for _ in 0..<priorSaves {
                copy.text = "Temporary change"
                #expect(copy.save())
                copy.text = String(decoding: fixture.original, as: UTF8.self)
                #expect(copy.save())
            }
            try FileManager.default.removeItem(at: receipt.destinationURL)
            try FileManager.default.linkItem(at: fixture.source, to: receipt.destinationURL)
            copy.text = "Must never reach original"
            #expect(!copy.save())
            #expect(copy.backingFileMissing && copy.isDirty)
            #expect(try Data(contentsOf: fixture.source) == fixture.original)
            #expect(try Data(contentsOf: receipt.destinationURL) == fixture.original)
        }
    }

    @Test func atomicReplacementRaceNeverUsesHardlinkInPlaceWriter() async throws {
        let fixture = try CopyOpeningFixture()
        defer { fixture.remove() }
        let receipt = try await fixture.receipt()
        let copy = try #require(await fixture.open(receipt))
        defer { copy.closeDocument(discardRecovery: false) }
        let moved = fixture.directory.appendingPathComponent("moved-at-commit.md")
        var called = false
        copy.copySaveIO.replace = { target, temporary in
            called = true
            try FileManager.default.moveItem(at: target, to: moved)
            try FileManager.default.linkItem(at: fixture.source, to: target)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary, backupItemName: nil, options: [])
        }
        copy.text = "Saved only in copy"
        #expect(copy.save() && called)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(try Data(contentsOf: moved) == fixture.original)
        #expect(try String(contentsOf: receipt.destinationURL, encoding: .utf8) == copy.text)
        copy.copySaveIO = .init()
        copy.text += " again"
        #expect(copy.save())
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
    }

    @Test func failedTemporaryWriteAndCanceledReplacementPreserveSavedCopy() async throws {
        for partialWrite in [false, true] {
            let fixture = try CopyOpeningFixture()
            defer { fixture.remove() }
            let receipt = try await fixture.receipt()
            let copy = try #require(await fixture.open(receipt))
            defer { copy.closeDocument(discardRecovery: false) }
            var temporary: URL?
            if partialWrite {
                copy.copySaveIO.writeTemporary = { data, url in
                    temporary = url
                    try Data(data.prefix(2)).write(to: url)
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            } else {
                copy.copySaveIO.replace = { _, url in temporary = url; throw CancellationError() }
            }
            copy.text = "Keep this in memory after failure"
            #expect(!copy.save())
            #expect(copy.isDirty && copy.text == "Keep this in memory after failure")
            #expect(try Data(contentsOf: receipt.destinationURL) == fixture.original)
            #expect(try Data(contentsOf: fixture.source) == fixture.original)
            #expect(!FileManager.default.fileExists(atPath: try #require(temporary).path))
            copy.copySaveIO = .init()
            #expect(copy.save())
            #expect(try String(contentsOf: receipt.destinationURL, encoding: .utf8) == copy.text)
        }
    }

    @Test func normalRepeatedAtomicSaveUndoRedoAndReopenRemainIndependent() async throws {
        let fixture = try CopyOpeningFixture()
        defer { fixture.remove() }
        let receipt = try await fixture.receipt()
        let copy = try #require(await fixture.open(receipt))
        defer { copy.closeDocument(discardRecovery: false) }
        var previous = stat()
        #expect(lstat(receipt.destinationURL.path, &previous) == 0)
        copy.undoManager.beginUndoGrouping()
        #expect(copy.editorSession.applyUndoableEdit(changing: copy.text, to: "Copy edit with 中文 😀\n"))
        copy.undoManager.endUndoGrouping()
        #expect(copy.save())
        var after = stat()
        #expect(lstat(receipt.destinationURL.path, &after) == 0 && previous.st_ino != after.st_ino)
        copy.undoManager.undo()
        #expect(copy.save())
        #expect(try Data(contentsOf: receipt.destinationURL) == fixture.original)
        copy.undoManager.redo()
        #expect(copy.save())
        let expected = copy.text
        #expect(copy.closeDocument(discardRecovery: false))
        let reopened = CopyOpeningFixture.makeStore()
        defer { reopened.closeDocument(discardRecovery: false) }
        reopened.open(receipt.destinationURL)
        #expect(reopened.text == expected && !reopened.isDirty)
        #expect(reopened.save())
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
    }
}
