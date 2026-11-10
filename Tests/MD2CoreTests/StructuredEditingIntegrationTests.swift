import Foundation
import Testing
@testable import MD2Core

/// Integration contracts between the independently implemented paste and table
/// packages. Expected literals originate in TSV, not in either table parser.
struct StructuredEditingIntegrationTests {
    @Test(arguments: ["\n", "\r\n", "\r"])
    func pastedLiteralTableSupportsNavigationAndColumnRoundTrip(_ ending: String) throws {
        let literal = " &amp; | `x` \\ ![i](https://example.com/x) "
        let tsv = "Name\tDetail\tLast\n中文😀\t\"line1\nline2\tinside\"\t\"\(literal)\""
        let output = try MarkdownPaste.convert(.table, payload: .init(plainText: tsv)).get()
        let original = "BEFORE_SENTINEL\(ending)PASTE_HERE\(ending)AFTER_SENTINEL"
        let paste = try #require(MarkdownPaste.edit(original,
            selection: (original as NSString).range(of: "PASTE_HERE"), output: output))
        let pasted = (original as NSString).replacingCharacters(in: paste.range, with: paste.replacement)
        #expect(pasted.hasPrefix("BEFORE_SENTINEL\(ending)\(ending)"))
        #expect(pasted.hasSuffix("\(ending)\(ending)AFTER_SENTINEL"))
        let body = MarkdownRenderer().render(pasted).body
        let visible = RenderedPlainText.extract(from: body)
        #expect(visible.contains(literal))
        #expect(visible.contains("中文😀"))
        #expect(visible.contains("line1\nline2\tinside"))
        #expect(!body.contains("<img"))
        #expect(!body.contains("<a "))
        #expect(count("<th", in: body) - count("<thead", in: body) == 3)
        #expect(count("<td", in: body) == 3)

        let header = (pasted as NSString).range(of: "Name")
        let next = try MarkdownTableEditing.result(pasted, selection: header, action: .nextCell).get()
        #expect(next.range.length == 0 && next.replacement.isEmpty)
        #expect((pasted as NSString).substring(with: next.selection) == "Detail")
        let cell = (pasted as NSString).range(of: "中文😀")
        let insert = try MarkdownTableEditing.result(pasted, selection: cell, action: .insertColumnAfter).get()
        let widened = (pasted as NSString).replacingCharacters(in: insert.range, with: insert.replacement)
        let widenedBody = MarkdownRenderer().render(widened).body
        #expect(count("<th", in: widenedBody) - count("<thead", in: widenedBody) == 4)
        #expect(count("<td", in: widenedBody) == 4)
        #expect(RenderedPlainText.extract(from: widenedBody).contains(literal))
        let remove = try MarkdownTableEditing.result(widened, selection: insert.selection, action: .deleteColumn).get()
        let restored = (widened as NSString).replacingCharacters(in: remove.range, with: remove.replacement)
        #expect(restored.utf16.elementsEqual(pasted.utf16))
    }

    @Test func generatedHeaderOnlyTableAppendsEditableBody() throws {
        let output = try MarkdownPaste.convert(.table, payload: .init(plainText: "单列😀")).get()
        let edit = try #require(MarkdownPaste.edit("", selection: NSRange(location: 0, length: 0), output: output))
        let table = edit.replacement
        let lastHeader = (table as NSString).range(of: "单列😀")
        let append = try MarkdownTableEditing.result(table, selection: lastHeader, action: .nextCell).get()
        let added = (table as NSString).replacingCharacters(in: append.range, with: append.replacement)
        let body = MarkdownRenderer().render(added).body
        #expect(count("<th", in: body) - count("<thead", in: body) == 1)
        #expect(count("<td", in: body) == 1)
        #expect(MarkdownTableEditing.result(added, selection: append.selection, action: .deleteColumn) == .failure(.lastColumn))
        let remove = try MarkdownTableEditing.result(added, selection: append.selection, action: .deleteRow).get()
        let restored = (added as NSString).replacingCharacters(in: remove.range, with: remove.replacement)
        #expect(restored.utf16.elementsEqual(table.utf16))
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
