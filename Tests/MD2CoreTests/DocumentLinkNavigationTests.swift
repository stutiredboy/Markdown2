import Foundation
import Testing
@testable import MD2App

@MainActor
struct DocumentLinkNavigationTests {
    @Test func openingFileWithEncodedFragmentRevealsItsHeading() async throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore()
        store.open(link(file, fragment: "目标章节"))
        await store.flushPendingRender()
        await settle { store.jumpLine != nil }
        #expect(store.fileURL == file)
        #expect(store.jumpLine == 5)
        #expect(store.jumpHeadingID == "目标章节")
        #expect(!store.isDirty)
        #expect(store.alert == nil)
        store.stopWatchingFile()
    }

    @Test func explicitEmptyFragmentRevealsTop() async throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore()
        store.open(link(file, fragment: ""))
        await store.flushPendingRender()
        await settle { store.jumpLine != nil }
        #expect(store.jumpLine == 1)
        #expect(store.jumpFraction == 0)
        store.stopWatchingFile()
    }

    @Test func unknownFragmentReportsTheMissingHeadingWithoutEditing() async throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore()
        store.open(link(file, fragment: "unknown-heading"))
        await store.flushPendingRender()
        await settle { store.alert != nil }
        #expect(store.alert?.detail.contains("unknown-heading") == true)
        #expect(store.jumpLine == nil)
        #expect(!store.isDirty)
        store.stopWatchingFile()
    }

    @Test func existingDirtyDocumentNavigatesUsingLatestUnsavedHeadings() async throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore()
        store.open(file)
        await store.flushPendingRender()
        store.text = "Prefix\n\n" + store.text
        store.requestHeadingNavigation("目标章节")
        await settle { store.jumpLine != nil }
        #expect(store.jumpLine == 7)
        #expect(store.isDirty)
        #expect(store.fileURL == file)
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("# First"))
        store.stopWatchingFile()
    }

    @Test func latestLinkWinsAndClosingCancelsPendingNavigation() async throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore()
        store.open(file)
        store.requestHeadingNavigation("first")
        store.requestHeadingNavigation("目标章节")
        await settle { store.jumpLine != nil }
        #expect(store.jumpLine == 5)
        store.jumpLine = nil
        store.jumpHeadingID = nil
        store.requestHeadingNavigation("first")
        #expect(store.closeDocument(discardRecovery: false))
        await store.flushPendingRender()
        await Task.yield()
        #expect(store.jumpLine == nil)
    }

    @Test func openingAnotherDocumentCancelsTheOldPendingLink() async throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("second.md")
        try "# Other\n".write(to: second, atomically: true, encoding: .utf8)
        let store = DocumentStore()
        store.open(link(file, fragment: "目标章节"))
        store.open(second)
        await store.flushPendingRender()
        await Task.yield()
        #expect(store.fileURL == second)
        #expect(store.jumpLine == nil)
        #expect(store.alert == nil)
        store.stopWatchingFile()
    }

    @Test func linkTargetDecodesFragmentExactlyOnceAndPreservesFilenameCharacters() {
        let target = DocumentLinkTarget(URL(string: "file:///tmp/a%23b%3Fc.md?ignored=1#heading%2520literal")!)
        #expect(target.fileURL.path == "/tmp/a#b?c.md")
        #expect(target.fileURL.query == nil)
        #expect(target.fileURL.fragment == nil)
        #expect(target.fragment == "heading%20literal")
    }

    @Test func missingLinkAlertDoesNotAlterDocument() {
        let store = DocumentStore(alertTextProvider: { L10n.text($0, language: .zhHans) })
        let text = store.text
        store.reportMissingLocalLink(URL(fileURLWithPath: "/tmp/missing.md"))
        #expect(store.alert?.message == "无法打开 missing.md。")
        #expect(store.text == text)
        #expect(!store.isDirty)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-link-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("document with spaces.md")
        try "# First\n\nIntroduction.\n\n# 目标章节\n\nBody.\n".write(to: file, atomically: true, encoding: .utf8)
        return (directory, file)
    }

    private func link(_ file: URL, fragment: String) -> URL {
        var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
        components.fragment = fragment
        return components.url!
    }
}
