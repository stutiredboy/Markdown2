import Foundation
import Testing
@testable import MD2App

@MainActor
struct PreviewTableResizeTests {
    private let key = "2|0|Name\u{1f}Value"

    @Test func parsesIntegerWidthsAtBothLimits() {
        #expect(PreviewTableResize.parse(["key": key, "widths": [40, 2000]]) ==
                PreviewTableResize.Update(key: key, widths: [40, 2000]))
        let longestKey = String(repeating: "🐱", count: 1024)
        let widestTable = Array(repeating: 50, count: 64)
        #expect(PreviewTableResize.parse(["key": longestKey, "widths": widestTable]) ==
                PreviewTableResize.Update(key: longestKey, widths: widestTable))
    }

    @Test func parsesMissingOrNullWidthsAsReset() {
        let reset = PreviewTableResize.Update(key: key, widths: nil)
        #expect(PreviewTableResize.parse(["key": key]) == reset)
        #expect(PreviewTableResize.parse(["key": key, "widths": NSNull()]) == reset)
    }

    @Test func rejectsMalformedKeysAndBodies() {
        #expect(PreviewTableResize.parse(["key": "", "widths": [80]]) == nil)
        #expect(PreviewTableResize.parse(["key": String(repeating: "🐱", count: 1024) + "x"]) == nil)
        #expect(PreviewTableResize.parse(["widths": [80]]) == nil)
        #expect(PreviewTableResize.parse(["key": 42, "widths": [80]]) == nil)
        #expect(PreviewTableResize.parse(["key": key, "widths": ["80"]]) == nil)
        #expect(PreviewTableResize.parse(["key": key, "widths": 80]) == nil)
        #expect(PreviewTableResize.parse("2|0|Name") == nil)
    }

    @Test func rejectsInvalidColumnCountsAndWidths() {
        #expect(PreviewTableResize.parse(["key": key, "widths": [Int]()]) == nil)
        #expect(PreviewTableResize.parse(["key": key, "widths": Array(repeating: 80, count: 65)]) == nil)
        for value in [39.0, 2001.0, 40.5, Double.nan, Double.infinity, -Double.infinity] {
            #expect(PreviewTableResize.parse(["key": key, "widths": [80.0, value]]) == nil)
        }
        #expect(PreviewTableResize.parse(["key": key, "widths": [true]]) == nil)
    }

    @Test func storesOverwritesAndResetsWidths() throws {
        let store = PreviewTableColumnWidths()
        store.apply(.init(key: key, widths: [60, 80]))
        #expect(store.entries == [key: [60, 80]])
        store.apply(.init(key: key, widths: [120, 80]))
        let literal = store.javaScriptLiteral()
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: [Int]]
        #expect(decoded == [key: [120, 80]])
        store.apply(.init(key: key, widths: nil))
        #expect(store.entries.isEmpty)
        #expect(store.javaScriptLiteral() == "{}")
    }

    @Test func capsNewEntriesButAllowsUpdatingOrRemovingExistingEntries() {
        let store = PreviewTableColumnWidths()
        for index in 0..<256 {
            store.apply(.init(key: "1|\(index)|Name", widths: [60]))
        }
        store.apply(.init(key: "1|256|Name", widths: [60]))
        #expect(store.entries.count == 256)
        #expect(store.entries["1|256|Name"] == nil)
        store.apply(.init(key: "1|0|Name", widths: [80]))
        #expect(store.entries.count == 256)
        #expect(store.entries["1|0|Name"] == [80])
        store.apply(.init(key: "1|0|Name", widths: nil))
        store.apply(.init(key: "1|256|Name", widths: [60]))
        #expect(store.entries["1|256|Name"] == [60])
        store.removeAll()
        #expect(store.entries.isEmpty)
    }

    @Test func openingAnotherFileAndClosingClearWidths() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "first.md")
        let second = directory.appending(path: "second.md")
        try Data("# First".utf8).write(to: first)
        try Data("# Second".utf8).write(to: second)
        let store = DocumentStore(fileWatcherFactory: { Watcher() })
        defer { store.closeDocument(discardRecovery: false) }
        store.open(first)
        try #require(store.text == "# First")
        let identity = store.documentIdentity
        store.previewTableColumnWidths.apply(.init(key: key, widths: [60, 80]))

        store.open(second)
        #expect(store.text == "# Second")
        #expect(store.documentIdentity != identity)
        #expect(store.previewTableColumnWidths.entries.isEmpty)

        store.previewTableColumnWidths.apply(.init(key: key, widths: [60, 80]))
        #expect(store.closeDocument(discardRecovery: false))
        #expect(store.previewTableColumnWidths.entries.isEmpty)
    }

    @Test func replacingTheReusableFolderPreviewClearsWidths() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# First".utf8).write(to: directory.appending(path: "first.md"))
        try Data("# Second".utf8).write(to: directory.appending(path: "second.md"))
        let root = try FolderIndex.authorize(directory)
        let files = try FolderIndex.scan(root).files
        let firstRow = try #require(files.first { $0.name == "first.md" })
        let secondRow = try #require(files.first { $0.name == "second.md" })
        let first = try FolderIndex.open(firstRow, in: root)
        let second = try FolderIndex.open(secondRow, in: root)
        let store = DocumentStore(fileWatcherFactory: { Watcher() })
        defer { store.closeDocument(discardRecovery: false) }
        let firstDocument = try #require(MarkdownFileDecoder.decode(first.data))
        let secondDocument = try #require(MarkdownFileDecoder.decode(second.data))
        try store.openVerifiedFolderFile(first, decoded: firstDocument)
        try #require(store.text == "# First")
        let identity = store.documentIdentity
        store.previewTableColumnWidths.apply(.init(key: key, widths: [60, 80]))

        try store.openVerifiedFolderFile(second, decoded: secondDocument, replacingCleanPreview: true)
        #expect(store.text == "# Second")
        #expect(store.documentIdentity != identity)
        #expect(store.previewTableColumnWidths.entries.isEmpty)
    }

    @Test func externalReloadOfTheSameFileKeepsWidths() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "original.md")
        try Data("# Original".utf8).write(to: file)
        let watcher = Watcher()
        let store = DocumentStore(fileWatcherFactory: { watcher })
        defer { store.closeDocument(discardRecovery: false) }
        store.open(file)
        try #require(store.text == "# Original")
        let identity = store.documentIdentity
        store.previewTableColumnWidths.apply(.init(key: key, widths: [60, 80]))

        try Data("# External revision".utf8).write(to: file)
        watcher.onEvent?()
        for _ in 0..<100 where store.pendingExternalReload == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(store.pendingExternalReload != nil)
        store.completeExternalReload(anchor: nil)
        #expect(store.text == "# External revision")
        #expect(store.documentIdentity == identity)
        #expect(store.previewTableColumnWidths.entries == [key: [60, 80]])
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "md2-table-widths-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private final class Watcher: DocumentFileWatching {
        var onEvent: (() -> Void)?
        func watch(url: URL) {}
        func stop() {}
    }
}
