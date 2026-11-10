import Foundation
import Testing
@testable import MD2Core

struct MarkdownTableEditingTests {
    struct Sample: Sendable {
        let before: String
        let action: MarkdownTableEditing.Action
        let after: String
        init(_ before: String, _ action: MarkdownTableEditing.Action, _ after: String) {
            self.before = before; self.action = action; self.after = after
        }
    }
    @Test(arguments: [
        Sample("| A¦ | B |\n| :-- | --: |\n| x | y |", .nextCell, "| A | «B» |\n| :-- | --: |\n| x | y |"),
        Sample("| A | «B» |\n| :-- | --: |\n| x | y |", .nextCell, "| A | B |\n| :-- | --: |\n| «x» | y |"),
        Sample("| A | B |\n| --- | --- |\n| x¦ | y |", .previousCell, "| A | «B» |\n| --- | --- |\n| x | y |"),
        Sample("| A¦ | B |\n| --- | --- |", .previousCell, "| A¦ | B |\n| --- | --- |"),
        Sample("| A | B¦ |\n| --- | --- |", .nextCell, "| A | B |\n| --- | --- |\n| ¦ |  |"),
        Sample("| A | B |\n| --- | --- |\n| x | y¦ |", .nextCell, "| A | B |\n| --- | --- |\n| x | y |\n| ¦ |  |"),
        Sample("| A | B |\n| --- | --- |\n| x | y¦ |\n", .nextCell, "| A | B |\n| --- | --- |\n| x | y |\n| ¦ |  |\n"),
        Sample("| A¦ | B |\n| --- | --- |\n| x | y |", .insertRowBelow, "| A | B |\n| --- | --- |\n| ¦ |  |\n| x | y |"),
        Sample("| A | B |\n| --- | --- |\n| x¦ | y |", .insertRowAbove, "| A | B |\n| --- | --- |\n| ¦ |  |\n| x | y |"),
        Sample("| A | B |\n| --- | --- |\n| x | y¦ |", .deleteRow, "| A | «B» |\n| --- | --- |"),
        Sample("| A | B |\n| --- | --- |\n| x¦ | y |\n| z | q |", .deleteRow, "| A | B |\n| --- | --- |\n| «z» | q |"),
        Sample("| A | B |\n| :-- | --: |\n| x¦ | y |", .insertColumnBefore, "|  | A | B |\n| --- | :-- | --: |\n| ¦ | x | y |"),
        Sample("| A | B |\n| :-- | --: |\n| x | y¦ |", .insertColumnAfter, "| A | B |  |\n| :-- | --: | --- |\n| x | y | ¦ |"),
        Sample("| A | B |\n| :-- | --: |\n| x¦ | y |", .deleteColumn, "| B |\n| --: |\n| «y» |"),
        Sample("| A | B |\n| :-- | --: |\n| x | y¦ |", .deleteColumn, "| A |\n| :-- |\n| «x» |"),
        Sample("A | B\n--- | ---\nx | y¦", .nextCell, "A | B\n--- | ---\nx | y\n| ¦ |  |"),
        Sample("A |  B   | C    \n- | :--   | --:    \nx |  y   | z¦    ", .insertColumnAfter,
               "A |  B   | C    |  |\n- | :--   | --:    | --- |\nx |  y   | z    | ¦ |"),
        Sample("A |  B   | C    \n- | :--   | --:    \nx |  y   | z¦    ", .deleteColumn,
               "A |  B   \n- | :--   \nx |  «y»   "),
        Sample("A |  B   | C    \n- | :--   | --:    \nx |  y¦   | z    ", .deleteColumn,
               "A | C    \n- | --:    \nx | «z»    "),
        Sample("A |  B   \n- | :--   \nx |  y¦   ", .insertColumnAfter,
               "A |  B   |  |\n- | :--   | --- |\nx |  y   | ¦ |"),
        Sample("| A | B |\r\n| --- | --- |\r\n| 中🙂é¦ | &vert; |", .nextCell,
               "| A | B |\r\n| --- | --- |\r\n| 中🙂é | «&vert;» |")
    ])
    func transformations(_ sample: Sample) throws {
        let before = fixture(sample.before), after = fixture(sample.after)
        let edit = try MarkdownTableEditing.result(before.text, selection: before.selection, action: sample.action).get()
        let result = (before.text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(result.utf16.elementsEqual(after.text.utf16))
        #expect(edit.selection == after.selection)
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func preservesLineEndingsAndAdjacentContent(_ ending: String) throws {
        let source = "before\(ending)\(ending)| A | B |\(ending)| :- | -: |\(ending)| x | y |\(ending)\(ending): caption\(ending)after"
        let caret = (source as NSString).range(of: "y").location
        let edit = try MarkdownTableEditing.result(source, selection: NSRange(location: caret, length: 0), action: .nextCell).get()
        let updated = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(updated == source.replacingOccurrences(of: "| x | y |\(ending)", with: "| x | y |\(ending)|  |  |\(ending)"))
    }

    @Test(arguments: [
        "```\n| A | B |\n| - | - |\n| x¦ | y |\n```",
        "~~~~\n| A | B |\n| - | - |\n| x¦ | y |\n~~~~",
        "- parent\n\n  | A | B |\n  | - | - |\n  | x¦ | y |",
        "> | A | B |\n> | - | - |\n> | x¦ | y |",
        "    | A | B |\n    | - | - |\n    | x¦ | y |",
        "<div>\n\n| A | B |\n| - | - |\n| x¦ | y |\n</div>",
        "<!--\n| A | B |\n| - | - |\n| x¦ | y |\n-->",
        "<!-- closed --> <!-- open\n| A | B |\n| - | - |\n| x¦ | y |\n-->",
        "<DIV\nclass='block'>\n\n| A | B |\n| - | - |\n| x¦ | y |\n</DIV>",
        "---\ntitle: draft\n| A | B |\n| - | - |\n| x¦ | y |\n---",
        "| A | B |\n| - | - |\n| x¦ |",
        "| A | B |\n| - | - |\n| ``x|y``¦ | z |",
        "| A | B |\n| - | - |\n| `x¦ | y |",
        "| A | B |\n| -¦ | - |\n| x | y |",
        "| A | B |\n| - | - |\n| «x | y» |"
    ])
    func rejectsWithoutRewriting(_ marked: String) {
        let input = fixture(marked)
        #expect(MarkdownTableEditing.edit(input.text, selection: input.selection, action: .deleteColumn) == nil)
    }

    @Test(arguments: ["- parent\n\n", "> quoted\n\n", "<div>closed</div>\n\n", "<!-- closed -->\n\n", "```\n<div>\n```\n\n", "<!--\n$$\n-->\n\n"])
    func trulyTopLevelAfterContainersIsSupported(_ prefix: String) throws {
        let source = prefix + "| A | B |\n| - | - |\n| x | y |"
        let position = (source as NSString).range(of: "x").location
        #expect(MarkdownTableEditing.edit(source, selection: NSRange(location: position, length: 0), action: .nextCell) != nil)
    }

    @Test func deletionGuardsAndBudgets() {
        let single = "| A |\n| - |\n| x |"
        #expect(MarkdownTableEditing.result(single, selection: NSRange(location: 2, length: 0), action: .deleteRow) == .failure(.header))
        #expect(MarkdownTableEditing.result(single, selection: NSRange(location: 2, length: 0), action: .deleteColumn) == .failure(.lastColumn))
        let huge = String(repeating: "a", count: MarkdownTableEditing.maximumSourceUTF16 + 1)
        #expect(MarkdownTableEditing.result(huge, selection: NSRange(location: 0, length: 0), action: .nextCell) == .failure(.budget))
        let tall = "| A |\n| - |\n" + String(repeating: "| x |\n", count: MarkdownTableEditing.maximumRows)
        #expect(MarkdownTableEditing.result(tall, selection: NSRange(location: 2, length: 0), action: .nextCell) == .failure(.budget))
    }

    @Test func rejectsInvalidUTF16AndPreservesNativeTabFallback() {
        let source = "| 🙂 | B |\n| - | - |"
        #expect(MarkdownTableEditing.edit(source, selection: NSRange(location: 3, length: 0), action: .nextCell) == nil)
        #expect(MarkdownTableEditing.edit(source, selection: NSRange(location: NSNotFound, length: 0), action: .nextCell) == nil)
        #expect(MarkdownEditing.edit("ordinary", selection: NSRange(location: 0, length: 0), action: .indent) == nil)
        #expect(MarkdownEditing.edit("- list", selection: NSRange(location: 3, length: 0), action: .indent) != nil)
    }

    private func fixture(_ input: String) -> (text: String, selection: NSRange) {
        let ns = input as NSString
        if input.contains("¦") {
            let location = ns.range(of: "¦").location
            return (input.replacingOccurrences(of: "¦", with: ""), NSRange(location: location, length: 0))
        }
        let start = ns.range(of: "«").location, end = ns.range(of: "»").location
        return (input.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""),
                NSRange(location: start, length: end - start - 1))
    }
}
