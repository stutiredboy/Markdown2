import Foundation
import Testing
@testable import MD2Core

struct MarkdownEditingTests {
    struct Example: Sendable {
        let before: String
        let action: MarkdownEditing.Action
        let after: String
        var clipboard: String? = nil
        var trackedCloser = false
        init(_ before: String, _ action: MarkdownEditing.Action, _ after: String,
             clipboard: String? = nil, trackedCloser: Bool = false) {
            self.before = before; self.action = action; self.after = after
            self.clipboard = clipboard; self.trackedCloser = trackedCloser
        }
    }

    @Test(arguments: [
        Example("- 中文🙂¦", .newline, "- 中文🙂\n- ¦"),
        Example("* a¦", .newline, "* a\n* ¦"),
        Example("+ a¦", .newline, "+ a\n+ ¦"),
        Example("9. a¦", .newline, "9. a\n10. ¦"),
        Example("99) a¦", .newline, "99) a\n100) ¦"),
        Example("1. one¦\n2. two\n3. three", .newline, "1. one\n2. ¦\n3. two\n4. three"),
        Example("1. one¦\n  - nested\n2. two", .newline, "1. one\n2. ¦\n  - nested\n3. two"),
        Example("- [x] done¦", .newline, "- [x] done\n- [ ] ¦"),
        Example("+ [X] done¦", .newline, "+ [X] done\n+ [ ] ¦"),
        Example("1. [ ] task¦", .newline, "1. [ ] task\n2. [ ] ¦"),
        Example("> a¦", .newline, "> a\n> ¦"),
        Example(">> a¦", .newline, ">> a\n> > ¦"),
        Example("> - [ ] a¦", .newline, "> - [ ] a\n> - [ ] ¦"),
        Example("- > a¦", .newline, "- > a\n  > ¦"),
        Example("- parent\n  2) child¦", .newline, "- parent\n  2) child\n  3) ¦"),
        Example("- ¦", .newline, "¦"),
        Example("1. ¦", .newline, "¦"),
        Example("- [ ] ¦", .newline, "¦"),
        Example("> - [x] ¦", .newline, "> ¦"),
        Example("> ¦", .newline, "¦"),
        Example("> > ¦", .newline, "> ¦"),
        Example("- parent\n  - ¦", .newline, "- parent\n  ¦"),
        Example("- ab¦cd", .newline, "- ab\n- ¦cd"),
        Example("- ab«cd»ef", .newline, "- ab\n- ¦ef"),
        Example("¦- a", .newline, "\n¦- a"),
        Example("abc¦", .newline, "abc\n¦"),
        Example("---¦", .newline, "---\n¦"),
        Example("- - -¦", .newline, "- - -\n¦"),
        Example("- a\r\n- b¦", .newline, "- a\r\n- b\r\n- ¦"),
        Example("- a\r- b¦", .newline, "- a\r- b\r- ¦"),
        Example("```swift\n  - literal¦", .newline, "```swift\n  - literal\n  ¦"),
        Example("~~~\n1. literal¦", .newline, "~~~\n1. literal\n¦"),
        Example("````\n```\n- literal¦", .newline, "````\n```\n- literal\n¦"),
        Example("```\n``` trailing\n- literal¦", .newline, "```\n``` trailing\n- literal\n¦"),
        Example("```\nx\n```\n- a¦", .newline, "```\nx\n```\n- a\n- ¦"),
        Example("> ```\n> - literal¦", .newline, "> ```\n> - literal\n> ¦"),
        Example("> ```\n> > literal¦", .newline, "> ```\n> > literal\n> ¦"),
        Example("- > ```\n  > - literal¦", .newline, "- > ```\n  > - literal\n  > ¦"),
        Example("```\n- ```¦", .newline, "```\n- ```\n¦"),
        Example("> ```\n- a¦", .newline, "> ```\n- a\n- ¦"),
        Example("- ```¦", .newline, "- ```\n  ¦"),
        Example("- ```\n  1. literal¦", .newline, "- ```\n  1. literal\n  ¦"),
        Example("    - literal¦", .newline, "    - literal\n    ¦"),
        Example("- a¦", .softNewline, "- a\n  ¦"),
        Example("100. a¦", .softNewline, "100. a\n     ¦"),
        Example("1)   a¦", .softNewline, "1)   a\n     ¦"),
        Example("-     a¦", .softNewline, "-     a\n  ¦"),
        Example("-\ta¦", .softNewline, "-\ta\n     ¦"),
        Example("- [ ] a¦", .softNewline, "- [ ] a\n  ¦"),
        Example("> 10. a¦", .softNewline, "> 10. a\n>     ¦"),
        Example("- ¦", .softNewline, "- \n  ¦"),
        Example("- a\n  continuation¦", .softNewline, "- a\n  continuation\n  ¦"),
        Example("- a\n  continuation¦", .newline, "- a\n  continuation\n- ¦"),
        Example("100. a\n     continuation\n     more¦", .newline, "100. a\n     continuation\n     more\n101. ¦"),
        Example("> - a\n>   continuation¦", .newline, "> - a\n>   continuation\n> - ¦"),
        Example("- a\n      - literal¦", .newline, "- a\n      - literal\n      ¦"),
        Example("- a\n- b¦", .indent, "- a\n  - b¦"),
        Example("100. a\n101. b¦", .indent, "100. a\n     101. b¦"),
        Example("- a\n  - b¦", .outdent, "- a\n- b¦"),
        Example("- a¦", .outdent, "- a¦"),
        Example("> - a\n> - b¦", .indent, "> - a\n>   - b¦"),
        Example("- a\n- > b¦", .indent, "- a\n  - > b¦"),
        Example("- a\n  - > b¦", .outdent, "- a\n- > b¦"),
        Example("- a\n«- b\n- c\n»- d", .indent, "- a\n  «- b\n  - c\n»- d"),
        Example("- a\n- b¦\n  - child\n  continuation\n- c", .indent, "- a\n  - b¦\n    - child\n    continuation\n- c"),
        Example("- a\n\t- b¦", .outdent, "- a\n- b¦"),
        Example("«中文🙂»", .bold, "**«中文🙂»**"),
        Example("**«中文🙂»**", .bold, "«中文🙂»"),
        Example("«**中文🙂**»", .bold, "«中文🙂»"),
        Example("¦", .bold, "**¦**"),
        Example("**¦**", .bold, "¦"),
        Example("«word»", .italic, "*«word»*"),
        Example("*«word»*", .italic, "«word»"),
        Example("**«word»**", .italic, "***«word»***"),
        Example("***«word»***", .italic, "**«word»**"),
        Example("«**word**»", .italic, "*«**word**»*"),
        Example("«label»", .link, "[label](¦)"),
        Example("«label»", .link, "[«label»](https://example.com)", clipboard: "https://example.com"),
        Example("«label»", .link, "[«label»](https://example.com/a%28b%29)", clipboard: "https://example.com/a(b)"),
        Example("¦", .link, "[¦](https://example.com)", clipboard: "https://example.com"),
        Example("«label»", .link, "[label](¦)", clipboard: "some text"),
        Example("«label»", .link, "[label](¦)", clipboard: "javascript:alert(1)"),
        Example("[«label»](url)", .link, "«label»"),
        Example("«[label](url(a))»", .link, "«label»"),
        Example("«正文»", .heading(2), "## «正文»"),
        Example("## 正文¦", .heading(0), "正文¦"),
        Example("## 正文¦", .heading(4), "#### 正文¦"),
        Example("> - 标题¦", .heading(2), "> - ## 标题¦"),
        Example("«one\ntwo\n»three", .heading(1), "# «one\n# two\n»three"),
        Example("¦", .codeBlock, "```\n¦\n```"),
        Example("«let x = 1»", .codeBlock, "```\n«let x = 1»\n```"),
        Example("«```»", .codeBlock, "````\n«```»\n````"),
        Example("before¦after", .codeBlock, "before\n```\n¦\n```\nafter"),
        Example("¦", .table, "| «Column 1» | Column 2 |\n| --- | --- |\n|  |  |"),
        Example("¦", .type("("), "(¦)"),
        Example("¦", .type("{"), "{¦}"),
        Example("¦", .type("'"), "'¦'"),
        Example("\"¦\"", .type("\""), "\"\"¦", trackedCloser: true),
        Example("`¦`", .deleteBackward, "¦", trackedCloser: true),
        Example("«中🙂»", .type("["), "[«中🙂»]"),
        Example("(¦)", .type(")"), "()¦", trackedCloser: true),
        Example("(¦)", .deleteBackward, "¦", trackedCloser: true),
        Example("¦", .type("\""), "\"¦\""),
        Example("¦", .type("`"), "`¦`"),
        Example("`¦`", .type("`"), "``¦", trackedCloser: true),
        Example("¦", .type("（"), "（¦）"),
        Example("「¦」", .deleteBackward, "¦", trackedCloser: true),
        Example("《¦》", .type("》"), "《》¦", trackedCloser: true)
    ])
    func editing(_ example: Example) throws {
        let before = fixture(example.before), after = fixture(example.after)
        let tracked = example.trackedCloser ? Set([before.selection.location]) : []
        let edit = try #require(MarkdownEditing.edit(before.text, selection: before.selection,
            action: example.action, clipboard: example.clipboard, autoClosingPositions: tracked))
        let result = (before.text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(result == after.text)
        #expect(edit.selection == after.selection)
        #expect(Range(edit.selection, in: result) != nil)
    }

    @Test(arguments: [
        ("word¦", MarkdownEditing.Action.type("'")),
        ("¦word", .type("(")),
        ("\\¦", .type("[")),
        ("``¦", .type("`")),
        ("a¦", .deleteBackward),
        ("foo(¦)", .deleteBackward),
        ("foo(¦)", .type(")")),
        ("word¦", .indent),
        ("```\n- code¦", .indent),
        ("¦", .type("pasted text"))
    ])
    func nativeFallback(_ example: (String, MarkdownEditing.Action)) {
        let input = fixture(example.0)
        #expect(MarkdownEditing.edit(input.text, selection: input.selection, action: example.1) == nil)
    }

    @Test func malformedAndSurrogateSplittingRangesAreRejected() {
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: 1, length: 0),
                      NSRange(location: 0, length: Int.max), NSRange(location: 5, length: 0)] {
            #expect(MarkdownEditing.edit("🙂", selection: range, action: .bold) == nil)
        }
    }

    @Test(arguments: ["- item", "100. item", "1)   item", "- [ ] task"])
    func softNewlineRendersInsideTheSameListItem(_ text: String) throws {
        let edit = try #require(MarkdownEditing.edit(text, selection: NSRange(location: text.utf16.count, length: 0), action: .softNewline))
        let continued = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) + "continued"
        let html = MarkdownRenderer().render(continued).body
        #expect(html.components(separatedBy: "</li>").count == 2)
        let content = try #require(html.range(of: "continued"))
        let closing = try #require(html.range(of: "</li>"))
        #expect(content.lowerBound < closing.lowerBound)
    }

    @Test func returnOnALargeDocumentHasBoundedCost() throws {
        let text = String(repeating: "A paragraph with 中文 and **emphasis**.\n", count: 28_000) + "- item"
        let start = ContinuousClock.now
        let edit = try #require(MarkdownEditing.edit(text, selection: NSRange(location: text.utf16.count, length: 0), action: .newline))
        #expect(edit.replacement == "\n- ")
        let elapsed = start.duration(to: .now)
        print("Return at EOF, \(text.utf8.count) bytes: \(elapsed)")
        #expect(elapsed < .milliseconds(100))

        let tabStart = ContinuousClock.now
        let tab = try #require(MarkdownEditing.edit(text,
            selection: NSRange(location: text.utf16.count, length: 0), action: .indent))
        let tabElapsed = tabStart.duration(to: .now)
        #expect(!tab.replacement.isEmpty)
        print("Tab at EOF, \(text.utf8.count) bytes: \(tabElapsed)")
        #expect(tabElapsed < .milliseconds(100))
    }

    @Test func anEarlierFenceDoesNotSlowReturnAtDocumentEnd() throws {
        let text = "```swift\nlet x = 1\n```\n" +
            String(repeating: "An ordinary paragraph.\n", count: 40_000) + "- item"
        let start = ContinuousClock.now
        let edit = try #require(MarkdownEditing.edit(text,
            selection: NSRange(location: text.utf16.count, length: 0), action: .newline))
        let elapsed = start.duration(to: .now)
        print("Return after earlier fence, \(text.utf8.count) bytes: \(elapsed)")
        #expect(edit.replacement == "\n- ")
        #expect(elapsed < .milliseconds(100))
    }

    private func fixture(_ marked: String) -> (text: String, selection: NSRange) {
        if let caret = marked.range(of: "¦") {
            let location = NSRange(caret, in: marked).location
            return (marked.replacingOccurrences(of: "¦", with: ""), NSRange(location: location, length: 0))
        }
        let start = marked.range(of: "«")!, end = marked.range(of: "»")!
        let location = NSRange(start, in: marked).location
        let length = NSRange(end, in: marked).location - location - 1
        return (marked.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""),
                NSRange(location: location, length: length))
    }
}
