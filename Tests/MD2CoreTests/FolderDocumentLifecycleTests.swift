import Foundation
import Testing
@testable import MD2App

@MainActor
struct FolderDocumentLifecycleTests {
    @Test func savedFolderDocumentRecoversWithVerifiedIdentityAndRefusesNewHardLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        try fixture.open(in: store)
        store.text = "# Saved from folder\n"
        #expect(store.save())
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == store.text)
        store.text = "# Recovered draft\n"
        #expect(store.persistRecoveryNow())
        #expect(store.closeDocument(discardRecovery: false))

        let restored = fixture.makeStore(saveLocation: fixture.file.standardizedFileURL)
        defer { restored.closeDocument(discardRecovery: false) }
        restored.restore(try fixture.snapshot())
        #expect(!restored.backingFileMissing && !restored.hasExternalConflict)
        #expect(restored.isDirty && restored.text == "# Recovered draft\n")
        #expect(restored.save())

        let alias = fixture.directory.appending(path: "other-name.md")
        try FileManager.default.linkItem(at: fixture.file, to: alias)
        restored.text = "# Keep me in the editor\n"
        #expect(!restored.save())
        #expect(restored.isDirty && restored.text == "# Keep me in the editor\n")
        #expect(try String(contentsOf: alias, encoding: .utf8) == "# Recovered draft\n")
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "# Recovered draft\n")
    }

    @Test func reopeningARecoveryRecordDoesNotAcceptAnIdenticalReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        try fixture.open(in: store)
        store.text = "# Unsaved edits\n"
        #expect(store.persistRecoveryNow())
        #expect(store.closeDocument(discardRecovery: false))
        let moved = fixture.directory.appending(path: "old.md")
        try FileManager.default.moveItem(at: fixture.file, to: moved)
        try fixture.original.write(to: fixture.file)

        let restored = fixture.makeStore()
        defer { restored.closeDocument(discardRecovery: false) }
        let snapshot = try fixture.snapshot()
        restored.restore(snapshot)
        #expect(restored.backingFileMissing && restored.isDirty)
        #expect(restored.text == "# Unsaved edits\n")
        #expect(!restored.save())

        let selectedReplacement = try fixture.selection()
        let explicitlySelected = fixture.makeStore()
        defer { explicitlySelected.closeDocument(discardRecovery: false) }
        explicitlySelected.restore(snapshot, openingFolderFile: selectedReplacement)
        #expect(explicitlySelected.backingFileMissing && explicitlySelected.isDirty)
        #expect(!explicitlySelected.save())
        restored.detachUnavailableFolderDraft(replacedBy: selectedReplacement.url)
        #expect(restored.fileURL == nil && restored.text == "# Unsaved edits\n" && restored.isDirty)
        #expect(try Data(contentsOf: fixture.file) == fixture.original)
        #expect(try Data(contentsOf: moved) == fixture.original)
    }

    @Test func openFolderDocumentUsesTheRealPathAfterItsParentMoves() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let parent = fixture.directory.appending(path: "original", directoryHint: .isDirectory)
        let movedParent = fixture.directory.appending(path: "moved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let note = parent.appending(path: "nested.md")
        try fixture.original.write(to: note)
        let root = try FolderIndex.authorize(parent)
        let row = try #require(FolderIndex.scan(root).files.first)
        let opened = try FolderIndex.open(row, in: root)
        let store = fixture.makeStore()
        defer { store.closeDocument(discardRecovery: false) }
        try store.openVerifiedFolderFile(opened, decoded: MarkdownFileDecoder.decode(opened.data))

        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: movedParent)
        let movedNote = movedParent.appending(path: note.lastPathComponent)
        #expect(throws: FolderIndex.Failure.rootUnavailable) { try opened.validate() }
        store.refreshFileLocation()
        #expect(store.fileURL == movedNote)
        store.text = "# Moved safely\n"
        #expect(store.save())
        #expect(try String(contentsOf: movedNote, encoding: .utf8) == store.text)
        #expect(try fixture.snapshot().fileURL == movedNote)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let file: URL
        let recovery: DocumentRecoveryRepository
        let original = Data("# Original\n".utf8)

        init() throws {
            let candidate = FileManager.default.temporaryDirectory
                .appending(path: "md2-folder-lifecycle-\(UUID())", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            directory = try FolderIndex.authorize(candidate).url
            file = directory.appending(path: "note.md")
            try original.write(to: file)
            recovery = DocumentRecoveryRepository(directory: directory.appending(path: "recovery"))
        }

        func makeStore(saveLocation: URL? = nil) -> DocumentStore {
            DocumentStore(saveLocationPicker: { _ in saveLocation ?? file },
                          fileWatcherFactory: { FolderLifecycleWatcher() },
                          recoveryRepository: recovery, autosaveDelay: 3_600, maximumAutosaveDelay: 3_600)
        }

        func open(in store: DocumentStore) throws {
            let opened = try selection()
            try store.openVerifiedFolderFile(opened, decoded: MarkdownFileDecoder.decode(opened.data))
            #expect(store.fileURL == self.file)
        }

        func selection() throws -> FolderIndex.OpenedFile {
            let root = try FolderIndex.authorize(directory)
            let file = try #require(FolderIndex.scan(root).files.first { $0.url == self.file })
            return try FolderIndex.open(file, in: root)
        }

        func snapshot() throws -> DocumentRecoverySnapshot {
            try #require(recovery.load().first)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
private final class FolderLifecycleWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?
    func watch(url: URL) {}
    func stop() {}
}
