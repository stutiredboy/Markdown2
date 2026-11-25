import Testing
@testable import MD2App

struct ConflictPassageComparisonTests {
    @Test func separatedParagraphChangesAreLabeledAtTheirSourceLines() throws {
        let comparison = try ConflictPassageComparison.compare(
            editor: "# Draft\r\n\r\n编辑段落。\r\n\r\nMiddle\r\n\r\nOriginal ending.\r\n",
            disk: "# Draft\n\nOriginal opening.\n\nMiddle\n\n磁盘结尾。\n"
        )
        #expect(!comparison.isCoarse)
        #expect(comparison.passages.map(\.editorLines) == [3..<4, 7..<8])
        #expect(comparison.passages.map(\.diskLines) == [3..<4, 7..<8])
        #expect(comparison.passages.map(\.editorText) == ["编辑段落。", "Original ending."])
        #expect(comparison.passages.map(\.diskText) == ["Original opening.", "磁盘结尾。"])
    }

    @Test func insertionAndDeletionAmongRepeatedLinesUseTheCorrectOccurrence() throws {
        let result = try ConflictPassageComparison.compare(
            editor: "Title\nsame\nkept\nsame\nremoved\nend",
            disk: "Title\nnew\nsame\nkept\nsame\nend"
        )
        #expect(result.passages.map(\.editorLines) == [2..<2, 5..<6])
        #expect(result.passages.map(\.diskLines) == [2..<3, 6..<6])
        #expect(result.passages.map(\.editorText) == ["", "removed"])
        #expect(result.passages.map(\.diskText) == ["new", ""])
    }

    @Test func lineSeparatorsEmptyFilesAndFinalNewlines() throws {
        #expect(try ConflictPassageComparison.compare(editor: "猫\r\r犬\r\n", disk: "猫\n\n犬\n").passages.isEmpty)
        #expect(try ConflictPassageComparison.compare(editor: "", disk: "").passages.isEmpty)
        let fromEmpty = try #require(ConflictPassageComparison.compare(editor: "", disk: "hello").passages.first)
        #expect(fromEmpty.editorLines == 1..<1)
        #expect(fromEmpty.diskLines == 1..<2)
        let finalNewline = try #require(ConflictPassageComparison.compare(editor: "one\n", disk: "one").passages.first)
        #expect(finalNewline.editorLines == 2..<3)
        #expect(finalNewline.diskLines == 2..<2)
    }

    @Test func normalizationOnlyEditPreservesExactText() throws {
        let result = try ConflictPassageComparison.compare(editor: "prefix\nCafé\n", disk: "prefix\nCafe\u{301}\n")
        let passage = try #require(result.passages.first)
        #expect(passage.editorLines == 2..<3)
        #expect(!passage.editorText.utf8.elementsEqual(passage.diskText.utf8))
        #expect(Array(passage.diskText.utf8) == Array("Cafe\u{301}".utf8))
    }

    @Test func distantEditsInLongDocumentLeaveCommonParagraphsOut() throws {
        let shared = String(repeating: "unchanged\n", count: 10_000)
        let result = try ConflictPassageComparison.compare(editor: "mine\n" + shared + "end",
                                                       disk: "before\n" + shared + "disk end")
        #expect(!result.isCoarse)
        #expect(result.passages.map(\.editorLines) == [1..<2, 10_002..<10_003])
        #expect(result.passages.map(\.diskText) == ["before", "disk end"])
    }

    @Test func entirelyRewrittenMiddleRemainsCompleteWhenEditBudgetIsExceeded() throws {
        let editor = (0..<500).map { "Old \($0)" }.joined(separator: "\n")
        let disk = (0..<500).map { "New \($0)" }.joined(separator: "\n")
        let result = try ConflictPassageComparison.compare(editor: "shared\n" + editor + "\nend",
                                                      disk: "shared\n" + disk + "\nend")
        let passage = try #require(result.passages.first)
        #expect(result.isCoarse)
        #expect(passage.editorLines == 2..<502)
        #expect(passage.editorText == editor)
        #expect(passage.diskText == disk)
    }

    @Test func supersededComparisonCanBeCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ConflictPassageComparison.compare(editor: "mine", disk: "on disk")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func newlineHeavyFallbackRetainsBothSidesIncludingTheShorterSide() throws {
        let many = String(repeating: "d\n", count: 70_000)
        let result = try ConflictPassageComparison.compare(editor: "title\nsmall", disk: "title\n" + many)
        let passage = try #require(result.passages.first)
        #expect(result.isCoarse)
        #expect(passage.editorLines == 2..<3)
        #expect(passage.diskLines == 2..<70_003)
        #expect(passage.editorText == "small")
        #expect(passage.diskText == many)
    }
}
