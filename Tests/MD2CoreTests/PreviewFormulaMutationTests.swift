import Foundation
import Testing
@testable import MD2App

@MainActor
struct PreviewFormulaMutationTests {
    @Test func rejectsAStaleFormulaAfterSameLengthTaskEdit() async throws {
        let store = DocumentStore()
        let text = "- [ ] A task\r\n\r\n$$ x + 1 $$\n"
        store.text = text
        await store.flushPendingRender()
        let revision = store.renderedTextMutationRevision
        let target = try #require(store.previewFormulaTarget(line: 3, renderedAt: revision))
        #expect(target.edit?.source == "x + 1")

        let lineRevision = store.sourceLineRevision
        #expect(store.toggleTask(atLine: 1, to: true, renderedAt: lineRevision))
        #expect(store.sourceLineRevision == lineRevision)
        #expect(store.previewFormulaTarget(line: 3, renderedAt: revision) == nil)
        #expect(await store.applyPreviewFormula(target, replacement: "y + 2", isReading: { true }) == .stale)
        #expect(store.text == "- [x] A task\r\n\r\n$$ x + 1 $$\n")
    }

    @Test func noOpInvalidAndWrongModeDoNotCreateUndo() async throws {
        let store = DocumentStore()
        store.text = "$$ x $$\r\n"
        await store.flushPendingRender()
        let target = try #require(store.previewFormulaTarget(line: 1, renderedAt: store.renderedTextMutationRevision))

        #expect(await store.applyPreviewFormula(target, replacement: "x", isReading: { true }) == .unchanged)
        #expect(await store.applyPreviewFormula(target, replacement: "x\n+ 1", isReading: { true }) == .requiresSource)
        #expect(await store.applyPreviewFormula(target, replacement: "y", isReading: { false }) == .stale)
        #expect(await store.applyPreviewFormula(target, replacement: "y", beforeMutation: { false },
                                                isReading: { true }) == .stale)
        #expect(store.text == "$$ x $$\r\n")
        #expect(!store.undoManager.canUndo)
    }
}
