import Foundation
import Darwin
import Testing
@testable import MD2App

@MainActor
struct DocumentLifecycleTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("md2-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func saveImmediatelyAfterRenameFollowsIdentity() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("report.md")
        let renamed = dir.appendingPathComponent("renamed.md")
        try Data("Original".utf8).write(to: old)
        let store = DocumentStore()
        store.open(old)
        try FileManager.default.moveItem(at: old, to: renamed)
        store.text = "Edited"
        #expect(store.save())
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "Edited")
        #expect(store.fileURL?.lastPathComponent == "renamed.md")
    }

    @Test func savePreservesGBKBytesAndCRLF() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.md")
        let bytes = Data([0xd6, 0xdc, 0xb1, 0xa8, 0x0d, 0x0a])
        try bytes.write(to: url)
        let store = DocumentStore()
        store.open(url)
        store.text += "new\n"
        #expect(store.save())
        #expect(try Data(contentsOf: url) == bytes + Data("new\r\n".utf8))
    }

    @Test func savePreservesUnicodeBOMAndEndian() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("unicode.md")
        let bytes = Data([0xfe, 0xff]) + ("周报\r\n".data(using: .utf16BigEndian)!)
        try bytes.write(to: url)
        let store = DocumentStore()
        store.open(url)
        #expect(store.save())
        #expect(try Data(contentsOf: url) == bytes)
    }
}

@MainActor
struct DocumentRecoveryTests {
    private func fixture() throws -> (URL, DocumentRecoveryRepository) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("md2-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, DocumentRecoveryRepository(directory: dir.appendingPathComponent("recovery")))
    }

    private func eventually(_ condition: () throws -> Bool) async throws -> Bool {
        for _ in 0..<150 {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try condition()
    }

    @Test func continuousTypingSavesBeforeIdleTimeout() async throws {
        let (dir, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try Data("initial".utf8).write(to: url)
        let store = DocumentStore(autosaveDelay: 5, maximumAutosaveDelay: 0.15)
        store.open(url)
        for _ in 0..<15 {
            store.text += "x"
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) != "initial")
        store.closeDocument(discardRecovery: true)
    }

    @Test func untitledTypingIsThrottledAndRestoresWithFormat() async throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(recoveryRepository: repository, recoveryDelay: 0.05)
        store.text = "未命名草稿"
        store.windowFrame = "100 100 980 680 0 0 1920 1080 "
        for _ in 0..<10 {
            store.text += "!"
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!(try repository.load()).isEmpty)
        #expect(store.persistRecoveryNow())
        store.closeDocument(discardRecovery: false)
        let snapshot = try #require(repository.load().first)
        let restored = DocumentStore(recoveryRepository: repository)
        restored.restore(snapshot)
        #expect(restored.text == store.text)
        #expect(restored.fileURL == nil)
        #expect(restored.isDirty)
        #expect(restored.windowFrame == store.windowFrame)
        #expect(restored.undoManager.canUndo == false)
        restored.closeDocument(discardRecovery: true)
        #expect(try repository.load().isEmpty)
    }

    @Test func recoveryRetainsUnrepresentableEditsAndCancellationDoesNotTranscode() async throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gbk.md")
        let original = Data([0xd6, 0xdc, 0xb1, 0xa8])
        try original.write(to: url)
        let store = DocumentStore(recoveryRepository: repository, autosaveDelay: 0.05, recoveryDelay: 0.02)
        store.open(url)
        #expect(store.fileFormat.encoding == .gbk)
        store.text += "🚀"
        #expect(try await eventually { store.encodingConversionRequest != nil })
        #expect(try Data(contentsOf: url) == original)
        store.resolveEncodingConversion(convertToUTF8: false)
        #expect(store.isDirty)
        #expect(store.fileFormat.encoding == .gbk)
        #expect(store.persistRecoveryNow())
        let snapshot = try #require(repository.load().first)
        #expect(snapshot.text == "周报🚀")
        #expect(snapshot.format.encoding == .gbk)
        store.closeDocument(discardRecovery: false)
        let restored = DocumentStore(recoveryRepository: repository)
        restored.restore(snapshot)
        #expect(restored.text == "周报🚀")
        restored.resolveEncodingConversion(convertToUTF8: true)
        #expect(try String(contentsOf: url, encoding: .utf8) == "周报🚀")
        #expect(restored.fileFormat.encoding == .utf8)
        restored.closeDocument(discardRecovery: true)
    }

    @Test func restorationDetectsEditsMadeWhileAppWasClosed() throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try Data("original".utf8).write(to: url)
        let store = DocumentStore(recoveryRepository: repository)
        store.open(url)
        store.text = "unsaved draft"
        #expect(store.persistRecoveryNow())
        store.closeDocument(discardRecovery: false)
        try Data("external".utf8).write(to: url, options: .atomic)
        let restored = DocumentStore(recoveryRepository: repository)
        restored.restore(try #require(repository.load().first))
        #expect(restored.hasExternalConflict)
        #expect(restored.text == "unsaved draft")
        #expect(!restored.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == "external")
        restored.closeDocument(discardRecovery: true)
    }

    @Test func cleanWindowRestoresLatestDiskContentAfterRename() throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.md"), new = dir.appendingPathComponent("new.md")
        try Data("old content".utf8).write(to: old)
        let store = DocumentStore(recoveryRepository: repository)
        store.open(old)
        store.closeDocument(discardRecovery: false)
        try FileManager.default.moveItem(at: old, to: new)
        // In-place external write preserves the identity being tested.
        try Data("latest".utf8).write(to: new)
        let restored = DocumentStore(recoveryRepository: repository)
        restored.restore(try #require(repository.load().first))
        #expect(restored.fileURL?.lastPathComponent == "new.md")
        #expect(restored.text == "latest")
        #expect(!restored.isDirty)
        restored.closeDocument(discardRecovery: true)
    }

    @Test func cleanRecoveryRecordOmitsDocumentText() throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clean.md")
        try String(repeating: "confidential notes\n", count: 100).write(to: url, atomically: true, encoding: .utf8)
        let store = DocumentStore(recoveryRepository: repository)
        store.open(url)
        #expect(store.persistRecoveryNow())
        let record = try #require(try FileManager.default.contentsOfDirectory(at: repository.directory,
                                                                               includingPropertiesForKeys: nil).first)
        let json = try String(contentsOf: record, encoding: .utf8)
        #expect(!json.contains("confidential notes"))
        #expect(!json.contains("\"text\""))
        store.closeDocument(discardRecovery: true)
    }

    @Test func interruptedRestorationMarkerSurvivesUntilFinished() throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!repository.restorationWasInterrupted)
        try repository.beginRestoration()
        #expect(repository.restorationWasInterrupted)
        #expect(try repository.load().isEmpty)
        try repository.finishRestoration()
        #expect(!repository.restorationWasInterrupted)
    }

    @Test func saveKeepsCreationDateAndExtendedAttributes() throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tagged.md")
        try "before".write(to: url, atomically: true, encoding: .utf8)
        let creation = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: creation], ofItemAtPath: url.path)
        let name = "com.example.markdown2.test-tag"
        let value = Array("blue".utf8)
        let didSet = value.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, value.count, 0, 0)
        }
        #expect(didSet == 0)
        let store = DocumentStore(recoveryRepository: repository)
        store.open(url)
        store.text = "after"
        #expect(store.save())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let savedCreation = try #require(attributes[.creationDate] as? Date)
        #expect(abs(savedCreation.timeIntervalSince(creation)) < 1)
        var buffer = [UInt8](repeating: 0, count: 16)
        let capacity = buffer.count
        let length = buffer.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, capacity, 0, 0)
        }
        #expect(length == value.count)
        #expect(Array(buffer.prefix(value.count)) == value)
        store.closeDocument(discardRecovery: true)
    }

    @Test func saveKeepsHardLinkedNamesTogether() throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("original.md")
        let alias = dir.appendingPathComponent("alias.md")
        try "before".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: url, to: alias)
        let store = DocumentStore(recoveryRepository: repository)
        store.open(url)
        store.text = "after"
        #expect(store.save())
        #expect(try String(contentsOf: alias, encoding: .utf8) == "after")
        var originalInfo = stat(), aliasInfo = stat()
        #expect(stat(url.path, &originalInfo) == 0)
        #expect(stat(alias.path, &aliasInfo) == 0)
        #expect(originalInfo.st_ino == aliasInfo.st_ino)
        store.closeDocument(discardRecovery: true)
    }

    @Test func deletionNeverAutosavesBackToOldPath() async throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gone.md")
        try Data("initial".utf8).write(to: url)
        let store = DocumentStore(saveLocationPicker: { _ in nil }, recoveryRepository: repository,
                                  autosaveDelay: 0.05, recoveryDelay: 0.02)
        store.open(url)
        try FileManager.default.removeItem(at: url)
        store.text = "keep me"
        #expect(try await eventually { store.backingFileMissing })
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!store.save()) // Cancelling the explicit destination panel is safe.
        #expect(store.isDirty)
        #expect(try repository.load().first?.text == "keep me")
        store.closeDocument(discardRecovery: true)
    }

    @Test func closeCancelsAlreadyScheduledWrites() async throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try Data("initial".utf8).write(to: url)
        let store = DocumentStore(recoveryRepository: repository, autosaveDelay: 0.05, recoveryDelay: 0.05)
        store.open(url)
        store.text = "discard me"
        #expect(store.closeDocument(discardRecovery: true))
        try await Task.sleep(for: .milliseconds(150))
        #expect(try String(contentsOf: url, encoding: .utf8) == "initial")
        #expect(try repository.load().isEmpty)
    }

    @Test func badRecordDoesNotHideValidDraft() throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(recoveryRepository: repository)
        store.text = "valid draft"
        #expect(store.persistRecoveryNow())
        let invalid = repository.directory.appendingPathComponent("invalid.json")
        try Data("broken".utf8).write(to: invalid)
        #expect(try repository.load().count == 1)
        #expect(repository.unreadableRecords.map { $0.resolvingSymlinksInPath() } == [invalid.resolvingSymlinksInPath()])
        #expect(FileManager.default.fileExists(atPath: invalid.path))
        store.closeDocument(discardRecovery: true)
    }

    @Test func recoveryFailureIsVisibleAndReportedToQuit() throws {
        let (dir, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let obstruction = dir.appendingPathComponent("file-not-directory")
        try Data().write(to: obstruction)
        let repository = DocumentRecoveryRepository(directory: obstruction)
        let store = DocumentStore(recoveryRepository: repository)
        store.text = "do not lose"
        #expect(!store.persistRecoveryNow())
        #expect(store.alert != nil)
        #expect(store.isDirty)
        store.closeDocument(discardRecovery: false)
    }
}

struct MarkdownFileFormatTests {
    @Test func supportedFormatsRoundTripWithoutByteChanges() throws {
        for encoding in MarkdownFileFormat.Encoding.allCases {
            for bom in [false, true] where bom || [.utf8, .gbk, .gb18030].contains(encoding) {
                for ending in [MarkdownFileFormat.LineEnding.lf, .crlf, .cr, .mixed] {
                    let format = MarkdownFileFormat(encoding: encoding, hasBOM: bom, lineEnding: ending)
                    let text = ending == .mixed ? "周报\r\n第一行\n第二行\r" : "周报\n第一行\n"
                    let bytes = try #require(format.encode(text))
                    let decoded = try #require(MarkdownFileDecoder.decode(bytes))
                    #expect(decoded.format.encode(decoded.text) == bytes)
                    #expect(decoded.format.lineEnding == ending)
                }
            }
        }
    }

    @Test func gb18030FourByteCharactersKeepTheirEncoding() throws {
        let format = MarkdownFileFormat(encoding: .gb18030)
        let bytes = try #require(format.encode("周报🚀"))
        let decoded = try #require(MarkdownFileDecoder.decode(bytes))
        #expect(decoded.format.encoding == .gb18030)
        #expect(decoded.format.encode(decoded.text) == bytes)
    }

    @Test func malformedBOMDoesNotFallThroughToLegacyDecoding() {
        #expect(MarkdownFileDecoder.decode(Data([0xff, 0xfe, 0x41])) == nil)
    }
}

extension DocumentLifecycleTests {
    @Test func watcherFollowsMoveAndKeepsWindowIdentity() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = dir.appendingPathComponent("report.md")
        let moved = folder.appendingPathComponent("renamed.md")
        try Data("original".utf8).write(to: original)
        let store = DocumentStore(autosaveDelay: 0.05)
        store.open(original)
        let identity = store.documentIdentity
        try FileManager.default.moveItem(at: original, to: moved)
        for _ in 0..<200 where store.fileURL?.lastPathComponent != "renamed.md" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.fileURL?.lastPathComponent == "renamed.md")
        #expect(store.documentIdentity == identity)
        #expect(!store.isDirty)
        #expect(store.baseURL?.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        store.text = "new content"
        for _ in 0..<100 where store.isDirty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try String(contentsOf: moved, encoding: .utf8) == "new content")
        #expect(!FileManager.default.fileExists(atPath: original.path))
        store.closeDocument(discardRecovery: true)
    }

    @Test func oldPathReusedAfterRenameDoesNotStealTheDocument() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("report.md"), renamed = dir.appendingPathComponent("renamed.md")
        try Data("original".utf8).write(to: old)
        let store = DocumentStore()
        store.open(old)
        try FileManager.default.moveItem(at: old, to: renamed)
        try Data("unrelated file".utf8).write(to: old)
        store.text = "edited original"
        #expect(store.save())
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "edited original")
        #expect(try String(contentsOf: old, encoding: .utf8) == "unrelated file")
        store.closeDocument(discardRecovery: true)
    }

    @Test func cancellingEncodingConversionOnManualSaveLeavesOriginalBytes() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gbk.md")
        let bytes = Data([0xd6, 0xdc, 0xb1, 0xa8])
        try bytes.write(to: url)
        var prompts = 0
        let store = DocumentStore(confirmEncodingConversion: { encoding in
            #expect(encoding == "GBK")
            prompts += 1
            return false
        })
        store.open(url)
        store.text += "🚀"
        #expect(!store.save())
        #expect(prompts == 1)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(store.isDirty)
        #expect(store.fileFormat.encoding == .gbk)
        store.closeDocument(discardRecovery: true)
    }
}

extension DocumentRecoveryTests {
    @Test func quitFlushesSafeNamedEditsButRetainsUnencodableDraft() throws {
        let (dir, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gbk.md")
        try Data([0xd6, 0xdc, 0xb1, 0xa8]).write(to: url)
        let store = DocumentStore(recoveryRepository: repository)
        store.open(url)
        store.text += " first"
        #expect(store.prepareForTermination())
        let saved = try Data(contentsOf: url)
        #expect(saved == Data([0xd6, 0xdc, 0xb1, 0xa8]) + Data(" first".utf8))
        store.text += "🚀"
        #expect(store.prepareForTermination())
        #expect(try Data(contentsOf: url) == saved)
        #expect(try repository.load().first?.text == "周报 first🚀")
        #expect(store.encodingConversionRequest == nil)
        store.closeDocument(discardRecovery: true)
    }
}
