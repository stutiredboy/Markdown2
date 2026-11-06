import Foundation
import Testing
@testable import MD2Core

struct MarkdownEditingBoundaryTests {
    @Test(arguments: ["\n", "\r\n", "\r"])
    func blockInsertionAtEOFUsesTheDocumentLineEnding(_ newline: String) throws {
        let source = "first\(newline)last"
        let end = NSRange(location: source.utf16.count, length: 0)
        let code = try #require(MarkdownEditing.edit(source, selection: end, action: .codeBlock))
        #expect(code.replacement == "\(newline)```\(newline)\(newline)```")
        #expect(code.selection == NSRange(location: source.utf16.count + newline.utf16.count + 3 + newline.utf16.count, length: 0))
        let table = try #require(MarkdownEditing.edit(source, selection: end, action: .table))
        #expect(table.replacement == "\(newline)| Column 1 | Column 2 |\(newline)| --- | --- |\(newline)|  |  |")

        let terminated = source + newline
        let emptyLastLine = try #require(MarkdownEditing.edit(terminated,
            selection: NSRange(location: terminated.utf16.count, length: 0), action: .codeBlock))
        #expect(emptyLastLine.replacement == "```\(newline)\(newline)```")
    }

    @Test(arguments: [
        "https://example.com/?literal=&copy;",
        "https://example.com/?literal=&#35;target",
        "https://example.com/?literal=&amp;",
        "https://example.com/a\"b",
        "https://example.com/a<b>",
        "https://example.com/路径?q=中文",
        "https://example.com/?literal=%26copy%3B&percent=%2523"
    ])
    func clipboardLinkKeepsItsDestinationAfterRendering(_ clipboard: String) throws {
        let label = "中文🙂e\u{301}"
        let selection = NSRange(location: 0, length: label.utf16.count)
        let edit = try #require(MarkdownEditing.edit(label, selection: selection, action: .link, clipboard: clipboard))
        let markdown = (label as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        let body = MarkdownRenderer().render(markdown, assetMode: .appScheme).body
        let pattern = try NSRegularExpression(pattern: #"<a href="([^"]*)">"#)
        let match = try #require(pattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                                 "inserted Markdown must render a link: \(markdown)")
        let href = (body as NSString).substring(with: match.range(at: 1))
        let actual = try #require(URL(string: HTMLSafety.decodeHTMLAttributeEntities(href)))
        let expected = try #require(URL(string: clipboard))
        #expect(actual == expected, "clipboard \(clipboard) became \(actual.absoluteString)")
        #expect((markdown as NSString).substring(with: edit.selection).utf16.elementsEqual(label.utf16))
    }
}
