import AppKit
import Foundation
import Testing
@testable import MD2Core
@testable import MD2App

struct MarkdownFenceConsistencyTests {
    static let samples = [
        "````markdown\n```\n# code, not a heading\n- literal\n```\n````\n# real heading\n- after",
        "```\n~~~\n# code, not a heading\n- literal\n```\n# real heading\n- after",
        "~~~~\n~~~\n```\n# code, not a heading\n- literal\n~~~~~\n# real heading\n- after",
        "```\n``` trailing text\n# code, not a heading\n- literal\n```` \t\n# real heading\n- after"
    ]

    @Test(arguments: samples)
    func fenceBoundariesAgreeAcrossConsumers(_ source: String) throws {
        let plan = MarkdownStylePlan(source)
        let headings = plan.spans.filter { (1...6).contains($0.kind.rawValue) }
            .map { (source as NSString).substring(with: $0.range) }
        #expect(headings == ["# real heading"])
        #expect(OutlineBuilder().build(from: source).map(\.title) == ["real heading"])
        let rendered = MarkdownRenderer().render(source, assetMode: .appScheme)
        #expect(rendered.outline.map(\.title) == ["real heading"])
        #expect(rendered.body.contains("# code, not a heading"))
        #expect(rendered.body.components(separatedBy: "<pre").count == 2)
        #expect(rendered.body.components(separatedBy: "<h1").count == 2)

        let literal = (source as NSString).range(of: "- literal")
        let inside = try #require(MarkdownEditing.edit(source,
            selection: NSRange(location: NSMaxRange(literal), length: 0), action: .newline))
        #expect(inside.replacement == "\n")
        let after = try #require(MarkdownEditing.edit(source,
            selection: NSRange(location: source.utf16.count, length: 0), action: .newline))
        #expect(after.replacement == "\n- ")
    }

    @Test func unterminatedLongFenceKeepsShorterFenceAndHeadingLiteral() {
        let source = "````\n```\n# still code"
        #expect(OutlineBuilder().build(from: source).isEmpty)
        #expect(MarkdownStylePlan(source).spans.allSatisfy { !(1...6).contains($0.kind.rawValue) })
        let body = MarkdownRenderer().render(source, assetMode: .appScheme).body
        #expect(body.contains("```\n# still code"))
        #expect(!body.contains("<h1"))
    }

    @Test func invalidBacktickInfoDoesNotOpenFence() {
        let source = "```invalid`info\n# real heading"
        #expect(MarkdownFence.opening(in: "```invalid`info") == nil)
        #expect(OutlineBuilder().build(from: source).map(\.title) == ["real heading"])
        #expect(MarkdownStylePlan(source).spans.contains { $0.kind == .heading1 })
        #expect(!MarkdownRenderer().render(source, assetMode: .appScheme).body.contains("<pre"))
    }

    @Test func listContinuationUsesTheFullFenceMarker() {
        let source = "- parent\n  ````\n  ```\n  # still code\n  ~~~~\n  `````\n  paragraph\n- sibling"
        let body = MarkdownRenderer().render(source, assetMode: .appScheme).body
        #expect(body.contains("```\n# still code\n~~~~"))
        #expect(body.contains("paragraph"))
        #expect(body.contains("sibling"))
        #expect(body.components(separatedBy: "<pre").count == 2)
        #expect(!body.contains("<h1"))
    }

    @Test @MainActor func changingFenceLengthRefreshesCodeAndHeadingStyles() async {
        let text = "````\n```\n# code, not a heading\n```\n````\n# real heading"
        let view = NSTextView()
        view.string = text
        let controller = MarkdownStylingController()
        controller.schedule(in: view)
        await controller.flush()
        view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        controller.schedule(in: view)
        await controller.flush()
        let reference = NSTextView()
        reference.string = view.string
        MarkdownTextStyler.apply(to: reference)
        #expect(view.textStorage!.isEqual(to: reference.textStorage!))
    }
}
