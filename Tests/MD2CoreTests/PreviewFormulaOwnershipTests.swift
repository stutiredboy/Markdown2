import Foundation
import Testing
@testable import MD2App

@MainActor
struct PreviewFormulaOwnershipTests {
    @Test(arguments: [
        ("| Header |\r\n| ------ |\r\n$$x+y$$\r\n", 3, "x|y"),
        ("[ref]:\r\n$$x + y$$\r\n", 2, "x+y")
    ])
    func replacingTexMustKeepTheSelectedDisplayBlock(source: String, line: Int, replacement: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-formula-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Formula.md")
        let before = Data(source.utf8)
        try before.write(to: file)
        let store = DocumentStore()
        defer { _ = store.closeDocument(discardRecovery: true) }
        store.open(file)
        await store.flushPendingRender()

        let revision = store.renderedTextMutationRevision
        let target = try #require(store.previewFormulaTarget(line: line, renderedAt: revision))
        try #require(target.edit != nil, "the original line renders as an editable formula")

        // A pipe can extend the preceding table. Compact TeX can become a
        // destination for the preceding link definition. Both payloads are
        // individually valid for direct editing but remove the formula here.
        let result = await store.applyPreviewFormula(target, replacement: replacement, isReading: { true })
        #expect(result == .requiresSource)
        #expect(Data(store.text.utf8) == before)
        #expect(try Data(contentsOf: file) == before)
        #expect(!store.isDirty)
        #expect(!store.undoManager.canUndo)
        #expect(store.isCurrent(target))
    }
}
