import Foundation
import Testing
@testable import MD2Core

struct MarkdownTableBlockBoundaryTests {
    private let table = "| A | B |\n| - | - |\n| x | y |"

    @Test(arguments: [false, true])
    func deletingLastColumnProtectsExposedEscapedPipe(_ leadingRail: Bool) throws {
        let left = leadingRail ? "|" : ""
        let source = "\(left)A | B\\| | C\n\(left)- | - | -\n\(left)x | y\\| | z"
        let edit = try MarkdownTableEditing.result(source,
            selection: (source as NSString).range(of: "z"), action: .deleteColumn).get()
        let edited = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(edited.utf16.elementsEqual("\(left)A | B\\| |\n\(left)- | - \n\(left)x | y\\| |".utf16))
        #expect(try cells(edited, tag: "th") == ["A", "B|"])
        #expect(try cells(edited, tag: "td") == ["x", "y|"])
    }

    @Test(arguments: [
        "# Heading `\n<div>\n`\n\n",
        "Heading `\n===\n<div>\n`\n\n",
        "Heading `\n---\n<div>\n`\n\n",
        "paragraph `\n***\n<div>\n`\n\n",
        "paragraph `\n___\n<div>\n`\n\n",
        "paragraph `\n[TOC]\n<div>\n`\n\n",
        "[^note]: unmatched `\n<div>\n`\n\n",
        "> unmatched `\n<div>\n`\n\n",
        "- unmatched `\n<div>\n`\n\n",
        "    unmatched `\n<div>\n`\n\n",
        "paragraph\n    <div>\n\n",
        "<div>\n===\n\n", "<!--\n---\n\n", "# <div>\n\n",
        "# Heading `\n<!--\n`\n\n",
        "paragraph `\n~~~\nliteral\n~~~\n<div>\n`\n\n",
        "| Old | Table |\n| - | - |\n: Caption ` {#tbl:old}\n<div>\n`\n\n"
    ])
    func ticksCannotMaskHTMLAcrossCompletedBlocks(_ prefix: String) {
        let source = prefix + table
        #expect(MarkdownTableEditing.edit(source, selection: (source as NSString).range(of: "x"), action: .deleteColumn) == nil)
    }

    @Test(arguments: [
        "# Use `<div>` as code\n\n",
        "Use `<div>` as code\n===\n\n",
        "Use `literal\n<div>` within one paragraph\n\n",
        "    <div>\n\n", "> <div>\n\n", "- <div>\n\n",
        "| <div> | x |\n| - | - |\n\n",
        "[^note]: <div>\n\n",
        "paragraph\n***\n<div>\n</div>\n\n",
        "# Heading `\n<div>\n`\n</div>\n\n"
    ])
    func completedScopesDoNotPoisonLaterTable(_ prefix: String) throws {
        let source = prefix + table
        // Search within the final table because the preceding block may use x.
        let location = source.utf16.count - table.utf16.count + (table as NSString).range(of: "x").location
        let result = MarkdownTableEditing.result(source, selection: NSRange(location: location, length: 1), action: .nextCell)
        _ = try result.get()
    }

    private func cells(_ source: String, tag: String) throws -> [String] {
        let body = MarkdownRenderer().render(source).body as NSString
        let expression = try NSRegularExpression(pattern: "<\(tag)(?:\\s[^>]*)?>([\\s\\S]*?)</\(tag)>")
        return expression.matches(in: body as String, range: NSRange(location: 0, length: body.length))
            .map { body.substring(with: $0.range(at: 1)) }
    }
}
