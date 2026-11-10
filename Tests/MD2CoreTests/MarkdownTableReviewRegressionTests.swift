import Foundation
import Testing
@testable import MD2Core

/// Permanent regressions adapted from the fixed independent review probes: expectations below are handwritten source or
/// input cell arrays, never obtained from MarkdownTableSyntax.
struct MarkdownTableReviewRegressionTests {
    private func apply(_ source: String, at marker: String,
                       _ action: MarkdownTableEditing.Action) throws -> (String, NSRange) {
        let selection = (source as NSString).range(of: marker)
        #expect(selection.location != NSNotFound)
        let edit = try MarkdownTableEditing.result(source, selection: selection, action: action).get()
        return ((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    private func cells(_ source: String, tag: String) throws -> [String] {
        let html = MarkdownRenderer().render(source).body
        let ns = html as NSString
        let regex = try NSRegularExpression(pattern: "<\(tag)(?:\\s[^>]*)?>([\\s\\S]*?)</\(tag)>")
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    @Test func noOuterThreeColumnPaddingSurvivesEveryNonTargetCell() throws {
        let source = "BEFORE\r\n\r\nA  | B   | C    \r\n:---  | :---:   | ---:    \r\nx  | y   | z    \r\n\r\n: caption\nAFTER"
        let (added, _) = try apply(source, at: "z", .insertColumnAfter)
        let expected = "BEFORE\r\n\r\nA  | B   | C    |  |\r\n:---  | :---:   | ---:    | --- |\r\nx  | y   | z    |  |\r\n\r\n: caption\nAFTER"
        #expect(added.utf16.elementsEqual(expected.utf16))
        #expect(try cells(added, tag: "th") == ["A", "B", "C", ""])
        #expect(try cells(added, tag: "td") == ["x", "y", "z", ""])
        let (deleted, selection) = try apply(source, at: "z", .deleteColumn)
        let removed = "BEFORE\r\n\r\nA  | B   \r\n:---  | :---:   \r\nx  | y   \r\n\r\n: caption\nAFTER"
        #expect(deleted.utf16.elementsEqual(removed.utf16))
        #expect((deleted as NSString).substring(with: selection) == "y")
    }

    @Test(arguments: [false, true])
    func deleteLeadingColumnKeepsPreviouslyInteriorEmptyCell(_ trailingRail: Bool) throws {
        let rail = trailingRail ? "|" : ""
        let source = "A |  | C\(rail)\n- | - | -\(rail)\nx |  | z\(rail)"
        #expect(try cells(source, tag: "th") == ["A", "", "C"])
        let (edited, _) = try apply(source, at: "x", .deleteColumn)
        #expect(try cells(edited, tag: "th") == ["", "C"], "Unselected blank header cell must remain: \(edited.debugDescription)")
        #expect(try cells(edited, tag: "td") == ["", "z"], "Unselected blank body cell must remain: \(edited.debugDescription)")
    }

    @Test(arguments: [false, true])
    func deleteTrailingColumnKeepsPreviouslyInteriorEmptyCell(_ leadingRail: Bool) throws {
        let rail = leadingRail ? "|" : ""
        let source = "\(rail)A |  | C\n\(rail)- | - | -\n\(rail)x |  | z"
        #expect(try cells(source, tag: "th") == ["A", "", "C"])
        let (edited, _) = try apply(source, at: "z", .deleteColumn)
        #expect(try cells(edited, tag: "th") == ["A", ""], "Unselected blank header cell must remain: \(edited.debugDescription)")
        #expect(try cells(edited, tag: "td") == ["x", ""], "Unselected blank body cell must remain: \(edited.debugDescription)")
    }

    @Test func deletingEitherEdgePreservesHeaderOnlyBlankCell() throws {
        let source = "A |  | C\n- | - | -\nx | y | z"
        let (left, _) = try apply(source, at: "x", .deleteColumn)
        #expect(try cells(left, tag: "th") == ["", "C"])
        #expect(try cells(left, tag: "td") == ["y", "z"])
        let (right, _) = try apply(source, at: "z", .deleteColumn)
        #expect(try cells(right, tag: "th") == ["A", ""])
        #expect(try cells(right, tag: "td") == ["x", "y"])
    }

    @Test(arguments: ["\u{0085}", "\u{2028}", "\u{2029}"])
    func nonMarkdownLineSeparatorsCannotInventATable(_ separator: String) throws {
        let source = "A | B\(separator)- | -\(separator)x | y"
        #expect(try cells(source, tag: "th").isEmpty)
        #expect(MarkdownTableEditing.edit(source, selection: (source as NSString).range(of: "x"), action: .deleteColumn) == nil)
        // In real LF-delimited tables those same units remain ordinary cell
        // content. UTF-16 source/range accounting must retain them exactly.
        let table = "| A | B |\n| - | - |\n| x\(separator)q | y |"
        let (edited, _) = try apply(table, at: "y", .deleteColumn)
        #expect(edited.utf16.elementsEqual("| A |\n| - |\n| x\(separator)q |".utf16))
    }

    @Test(arguments: ["|", "\\", "`"], ["\u{301}", "\u{FE0F}", "\u{200D}", "\u{200D}🙂"])
    func grammarGraphemesAgreeWithActualRenderer(_ syntax: String, _ suffix: String) throws {
        let row = "| x \(syntax)\(suffix)| y ` | z |"
        let source = row + "\n| - | - | - |\n" + row
        if let parsed = MarkdownTableSyntax.row(row) {
            #expect(parsed.cells.count == (try cells(source, tag: "th")).count)
            #expect(parsed.cells.count == (try cells(source, tag: "td")).count)
        }
    }

    @Test func actualRendererMustAgreeBeforeEditingCombiningPipe() throws {
        let source = "| A |\u{301} B |\n| - | - |\n| x |\u{301} y |"
        let selection = (source as NSString).range(of: "x")
        let rendered = try cells(source, tag: "th")
        #expect(rendered.count == 1)
        #expect(MarkdownTableEditing.edit(source, selection: selection, action: .deleteColumn) == nil,
                "UTF-16 syntax scanner must refuse a separator that actual Character-based renderer does not split")
    }

    @Test func growthMayNotExceedSourceUnitLimit() throws {
        let table = "| A | B |\n| - | - |\n| x | y |"
        let source = String(repeating: "p", count: 500_000 - table.utf16.count - 2) + "\n\n" + table
        #expect(source.utf16.count == 500_000)
        let selection = (source as NSString).range(of: "y")
        #expect(MarkdownTableEditing.result(source, selection: selection, action: .nextCell) == .failure(.budget))
    }

    @Test func growthMayNotExceedSourceLineLimit() throws {
        let source = String(repeating: "\n", count: 19_997) + "| A | B |\n| - | - |\n| x | y |"
        let selection = (source as NSString).range(of: "y")
        #expect(MarkdownTableEditing.result(source, selection: selection, action: .nextCell) == .failure(.budget))
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func eofAndHeaderOnlyAppendUseLocalEnding(_ ending: String) throws {
        let source = "前文🙂\(ending)\(ending)A | B\(ending):-- | --:"
        let (edited, selection) = try apply(source, at: "B", .nextCell)
        let expected = source + ending + "|  |  |"
        #expect(edited.utf16.elementsEqual(expected.utf16))
        #expect(selection == NSRange(location: source.utf16.count + ending.utf16.count + 2, length: 0))
        #expect(try cells(edited, tag: "td") == ["", ""])
    }

    @Test(arguments: [
        "- list\n\n", "> quote\n\n", "~~~~\n<div>\n~~~~\n\n",
        "<!--\n$$\n-->\n\n", "Use `<div>` as literal code.\n\n",
        "    <div>\n\n", "> <div>\n\n", "Use ``<div>`` as literal code.\n\n",
        "- list\n\n  <div>\n\n", "1. list <div>\n\n",
        "Use `a literal\n<div>` in code.\n\n"
    ])
    func unrelatedPriorContainersDoNotPoisonTopLevelTable(_ prefix: String) throws {
        let source = prefix + "| A | B |\n| - | - |\n| x | y |"
        #expect(try cells(source, tag: "th") == ["A", "B"])
        let result = MarkdownTableEditing.result(source, selection: (source as NSString).range(of: "x"), action: .nextCell)
        #expect(result.isSuccess, "Top-level table after literal previous block: \(prefix.debugDescription), got \(result)")
    }

    @Test(arguments: [
        "- list\n\n  | A | B |\n  | - | - |\n  | x | y |",
        "> | A | B |\n> | - | - |\n> | x | y |",
        "````\n```\n| A | B |\n| - | - |\n| x | y |\n````",
        "<div>\n\n| A | B |\n| - | - |\n| x | y |\n</div>",
        "<!--\n| A | B |\n| - | - |\n| x | y |\n-->",
        "> unmatched ` code\n<div>\nclosing tick `\n\n| A | B |\n| - | - |\n| x | y |",
        "- unmatched ` code\n<div>\nclosing tick `\n\n| A | B |\n| - | - |\n| x | y |",
        "| A | B |\n| - | - |\n| x | y |\n| ragged |"
    ])
    func unsafeContainerAndRaggedBoundariesRefuse(_ source: String) {
        #expect(MarkdownTableEditing.edit(source, selection: (source as NSString).range(of: "x"), action: .deleteColumn) == nil)
    }

    @Test func selectedCellDeletionPreservesAdjacentEscapesAndUnicode() throws {
        let source = "| A | B | C |\n| :- | :-: | -: |\n| 中👩‍💻é | `a|b` \\| c | \\\\ |"
        let (edited, _) = try apply(source, at: "中👩‍💻é", .deleteColumn)
        let expected = "| B | C |\n| :-: | -: |\n| `a|b` \\| c | \\\\ |"
        #expect(edited.utf16.elementsEqual(expected.utf16))
        #expect(try cells(edited, tag: "th") == ["B", "C"])
        #expect(try cells(edited, tag: "td").count == 2)
    }

    @Test func invalidRangesCrossCellsAndSurrogatesReject() {
        let source = "| 🙂 | B |\r\n| - | - |\r\n| x | y |"
        for range in [NSRange(location: 3, length: 0), NSRange(location: 2, length: 1),
                      NSRange(location: 2, length: 6), NSRange(location: NSNotFound, length: 0),
                      NSRange(location: source.utf16.count + 1, length: 0)] {
            #expect(MarkdownTableEditing.edit(source, selection: range, action: .deleteColumn) == nil)
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
