import Foundation
import Testing
@testable import MD2Core

struct MarkdownTableHTMLContextTests {
    private let table = "| A | B |\n| - | - |\n| x | y |"

    @Test(arguments: 0...5)
    func openingTagEscapesFollowRendererParity(_ slashes: Int) throws {
        let prefix = "Use " + String(repeating: "\\", count: slashes) + "<div> as text.\n\n"
        let rendered = MarkdownRenderer().render(prefix + table).body
        #expect(rendered.contains("<div>") == slashes.isMultiple(of: 2))
        #expect(rendered.contains("&lt;div&gt;") == !slashes.isMultiple(of: 2))
        try expectNavigation(prefix, allowed: !slashes.isMultiple(of: 2))
    }

    @Test(arguments: 0...5)
    func closingTagEscapesCannotCloseARealContainer(_ slashes: Int) throws {
        let prefix = "<div>\n" + String(repeating: "\\", count: slashes) + "</div>\n\n"
        let rendered = MarkdownRenderer().render(prefix + table).body
        #expect(rendered.contains("</div>") == slashes.isMultiple(of: 2))
        #expect(rendered.contains("&lt;/div&gt;") == !slashes.isMultiple(of: 2))
        try expectNavigation(prefix, allowed: slashes.isMultiple(of: 2))
    }

    @Test(arguments: 0...5)
    func openingAndClosingCommentsUseTheSameEscapeParity(_ slashes: Int) throws {
        let escapes = String(repeating: "\\", count: slashes)
        try expectNavigation(escapes + "<!-- unfinished\n\n", allowed: !slashes.isMultiple(of: 2))
        try expectNavigation("<!-- open\n" + escapes + "-->\n\n", allowed: slashes.isMultiple(of: 2))
    }

    private static let punctuationFixtures: [(String, Bool)] = [
        (#"<\!-- literal"# + "\n\n", true),
        (#"<!\-- literal"# + "\n\n", true),
        ("<!-- open\n" + #"--\>"# + "\n\n", false),
        ("<!-- open\n" + #"--\>"# + "\n-->\n\n", true),
        ("<div>\n" + #"</div\>"# + "\n\n", false),
        ("<div>\n" + #"</div \>"# + "\n\n", false),
        ("<div>\n" + #"</div \>"# + "\n</div>\n\n", true)
    ]
    @Test(arguments: punctuationFixtures)
    func escapedPunctuationDoesNotFormABoundary(_ fixture: (String, Bool)) throws {
        try expectNavigation(fixture.0, allowed: fixture.1)
    }

    @Test(arguments: [
        "Use \\<!-- `<div>` as literal text.\n\n",
        "Use \\`literal\n<div>` here\n\n",
        "# Heading \\`<div>`\n\n",
        "Use ``literal\n<div>`` here\n\n"
    ])
    func codeOwnershipStillPrecedesPunctuationEscapes(_ prefix: String) throws {
        let rendered = MarkdownRenderer().render(prefix + table).body
        #expect(rendered.contains("<code>"))
        #expect(rendered.contains("&lt;div&gt;"))
        #expect(!rendered.contains("<div>"))
        try expectNavigation(prefix, allowed: true)
    }

    private func expectNavigation(_ prefix: String, allowed: Bool) throws {
        let source = prefix + table
        let position = prefix.utf16.count + (table as NSString).range(of: "x").location
        let result = MarkdownTableEditing.result(source, selection: NSRange(location: position, length: 1), action: .nextCell)
        if allowed {
            let edit = try result.get()
            #expect(edit.range.length == 0 && edit.replacement.isEmpty)
            #expect((source as NSString).substring(with: edit.selection) == "y")
        } else { #expect(result == .failure(.unsupported)) }
    }
}
