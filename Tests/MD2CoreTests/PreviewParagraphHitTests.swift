import AppKit
import Testing
@testable import MD2App

@MainActor
struct PreviewParagraphHitTests {
    @Test func repeatedPlainLinesResolveToTheClickedUTF16Column() throws {
        let lines = ["重复 🐱 text", "重复 🐱 text"]
        let paragraph = lines.joined(separator: "\r\n")
        let source = paragraph + "\r\n\r\n  " + lines[0] + "\r" + lines[1] + "  "
        let hit = try #require(PreviewParagraphHit(["line": 4, "revision": 2, "plainLines": lines,
                                                   "row": 1, "column": "重复 🐱 ".utf16.count]))
        let lastOccurrence = (source as NSString).range(of: "text", options: .backwards)
        #expect(hit.caret(in: source as NSString) == NSRange(location: lastOccurrence.location, length: 0))
    }

    @Test func transformedAmbiguousAndMissingColumnsUseTheSourceBlockStart() throws {
        let text = "same\n\n**same**\nsame"
        let start = NSRange(location: 6, length: 0)
        let data: [String: Any] = ["line": 3, "revision": 2]
        let blockOnly = try #require(PreviewParagraphHit(data))
        #expect(blockOnly.caret(in: text as NSString) == start)
        let mismatch = try #require(PreviewParagraphHit(
            data.merging(["plainLines": ["same", "same"], "row": 1, "column": 2]) { $1 }))
        #expect(mismatch.caret(in: text as NSString) == start)
        let invalid = try #require(PreviewParagraphHit(
            data.merging(["plainLines": ["**same**"], "row": 0, "column": -1]) { $1 }))
        #expect(invalid.caret(in: text as NSString) == start)
        #expect(PreviewParagraphHit(["line": 3]) == nil)
    }

    @Test func sourceSelectionRequiresCurrentPageAndExactTextMutationRevision() async throws {
        let store = DocumentStore()
        let original = "- [ ] task\n\n同一句话\n\n同一句话"
        store.text = original
        await store.flushPendingRender()
        let token = store.remoteResourceContextToken
        let hit = try #require(PreviewParagraphHit(["revision": store.renderedTextMutationRevision,
                                                   "line": 5, "plainLines": ["同一句话"], "row": 0, "column": 2]))
        let editor = try #require(store.placePreviewCaret(hit, for: token))
        let second = (original as NSString).range(of: "同一句话", options: .backwards)
        #expect(editor.selectedRange() == NSRange(location: second.location + 2, length: 0))
        #expect(!store.undoManager.canUndo)
        #expect(store.text == original)

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(store.placePreviewCaret(hit, for: UUID()) == nil)
        #expect(editor.selectedRange().location == 0)
        let lineRevision = store.sourceLineRevision
        #expect(store.toggleTask(atLine: 1, to: true, renderedAt: lineRevision))
        #expect(store.sourceLineRevision == lineRevision)
        #expect(store.placePreviewCaret(hit, for: token) == nil)
        await store.flushPendingRender()
        #expect(store.placePreviewCaret(hit, for: token) == nil)
    }
}
