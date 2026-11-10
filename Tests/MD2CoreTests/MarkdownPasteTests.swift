import Foundation
import Testing
@testable import MD2Core

struct MarkdownPasteTests {
    private func html(_ value: String, plain: String? = nil, limits: MarkdownPaste.Limits = .init()) throws -> MarkdownPaste.Output {
        try MarkdownPaste.convert(.markdown, payload: .init(plainText: plain, html: Data(value.utf8)), limits: limits).get()
    }
    private func table(_ value: String, limits: MarkdownPaste.Limits = .init()) throws -> MarkdownPaste.Output {
        try MarkdownPaste.convert(.table, payload: .init(plainText: value), limits: limits).get()
    }
    @Test func plainTextAndPlainOnlyMarkdownAreExactSource() throws {
        let text = " [title](https://example.com)\r\n🙂e\u{301}  \r![](/tmp/file)"
        for kind in [MarkdownPaste.Kind.plainText, .markdown] {
            let output = try MarkdownPaste.convert(kind, payload: .init(plainText: text)).get()
            #expect(Array(output.text.utf16) == Array(text.utf16))
            #expect(!output.isBlock)
            let edit = try #require(MarkdownPaste.edit("xyz", selection: NSRange(location: 1, length: 1), output: output))
            #expect(Array(edit.replacement.utf16) == Array(text.utf16))
        }
    }
    @Test func richPriorityAndClipboardLimitsAreExplicit() throws {
        let payload = MarkdownPaste.Payload(plainText: "plain", html: Data("<b>html</b>".utf8), rtf: Data("bad rtf".utf8))
        #expect(try MarkdownPaste.convert(.markdown, payload: payload).get().text == "**html**")
        #expect(try MarkdownPaste.convert(.plainText, payload: payload).get().text == "plain")
        var limits = MarkdownPaste.Limits(); limits.plainBytes = 4
        #expect(MarkdownPaste.convert(.markdown, payload: payload, limits: limits) == .failure(.limit))
    }
    @Test func defaultTSVCellAndOutputEdgesAreInclusive() throws {
        let row = Array(repeating: "x", count: 20).joined(separator: "\t")
        let source = Array(repeating: row, count: 999).joined(separator: "\n")
        #expect(try table(source).text.components(separatedBy: "\n").count == 1000)
        let wider = source + "\tlast"
        #expect(MarkdownPaste.convert(.table, payload: .init(plainText: wider)) == .failure(.limit))
        for length in [99_987, 99_988, 99_989] {
            let value = String(repeating: "x", count: length)
            let result = MarkdownPaste.convert(.table, payload: .init(plainText: value))
            if length <= 99_988 { #expect(try result.get().text.utf16.count == length + 12) }
            else { #expect(result == .failure(.limit)) }
        }
    }
    @Test func semanticHTMLRendersHeadingsListsQuoteCodeAndSafeLinks() throws {
        let output = try html("<div class='copy' style='font-size:14px'><h2>Title</h2><p><strong>bold</strong> and <em>italic</em> <a href='https://example.com/?a=1&amp;b=2'>link</a></p><ol start='3'><li>one<ul><li>nested</li></ul></li><li>two</li></ol><blockquote><p>quote</p></blockquote><pre><code>let x = `tick`\n</code></pre></div>")
        #expect(output.fallbackReason == nil)
        #expect(output.text.contains("3. one"))
        let body = MarkdownRenderer().render(output.text).body
        for tag in ["<h2", "<strong>bold</strong>", "<em>italic</em>", "<ol ", "<ul>", "<blockquote ", "<pre ", "href=\"https://example.com/?a=1&amp;b=2\""] { #expect(body.contains(tag), "missing \(tag) in \(body)") }
    }
    @Test(arguments: ["<img src='https://example.com/a'>", "<script>alert(1)</script>", "<p onclick='bad()'>x</p>", "<table><tr><td>x</td></tr></table>", "<a href='javascript&#58;alert(1)'>x</a>", "<a href='file:///tmp/x'>x</a>", "<b>unclosed"])
    func rejectedRichUsesCompleteLiteralRepresentation(_ rich: String) throws {
        let plain = "![image](https://example.com/a) <img src='file:///tmp/x'>\nhttps://example.com www.example.com test@example.com\n&#33;&#91;x&#93; &amp;lt; `unclosed 中文🙂e\u{301}"
        let output = try html(rich, plain: plain)
        #expect(output.fallbackReason != nil)
        let body = MarkdownRenderer().render(output.text).body
        #expect(!body.contains("<img"))
        #expect(!body.contains("<a "))
        #expect(!body.contains("<script"))
        #expect(!body.contains("<code>"))
        #expect(body.contains("&amp;#33;"))
        #expect(body.contains("&amp;amp;lt;"))
        #expect(body.contains("中文🙂e\u{301}"))
        #expect(RenderedPlainText.extract(from: body) == plain)
    }
    @Test func malformedMetadataPlacementCannotSilentlyDropText() throws {
        let captured = "visible hidden"
        for markup in ["<head>visible</head><p>hidden</p>", "<b><p>visible</p></b>", "<a href='https://a'><a href='https://b'>visible</a>hidden</a>"] {
            let output = try html(markup, plain: captured)
            #expect(output.fallbackReason != nil)
            #expect(RenderedPlainText.extract(from: MarkdownRenderer().render(output.text).body) == captured)
        }
        for rtf in [#"{\rtf1 visible \fonttbl hidden}"#, #"{\rtf1 {visible \colortbl hidden}}"#, #"{\rtf1\b999999999999999999999 visible}"#] {
            let output = try MarkdownPaste.convert(.markdown, payload: .init(plainText: captured, rtf: Data(rtf.utf8))).get()
            #expect(output.fallbackReason != nil)
            #expect(RenderedPlainText.extract(from: MarkdownRenderer().render(output.text).body) == captured)
        }
    }
    @Test func unsupportedWithoutPlainRejects() {
        #expect(MarkdownPaste.convert(.markdown, payload: .init(html: Data("<img src='x'>".utf8))) == .failure(.unavailable))
    }
    @Test func htmlEntitiesAndCodeDelimiterAreLiteral() throws {
        let output = try html("<p>&amp;lt; &lt;img&gt; ![x](https://a) <code>` &lt;tag&gt; `</code></p><pre>```\ntext</pre>")
        let body = MarkdownRenderer().render(output.text).body
        #expect(!body.contains("<img")); #expect(!body.contains("<a "))
        #expect(body.contains("&amp;lt;")); #expect(body.contains("<code>` &lt;tag&gt; `</code>"))
        #expect(body.contains("```\ntext"))
    }
    @Test func tsvQuotedCellsAndLiteralRendererAgreement() throws {
        let tsv = " left \tpipe|tick`\\\\|\t<html> &copy; **x**\r\n\"tab\tline\r\nnext\"\t\"a\"\"b\"\t"
        let output = try table(tsv)
        let body = MarkdownRenderer().render(output.text).body
        #expect(body.components(separatedBy: "</th>").count - 1 == 3)
        #expect(body.components(separatedBy: "</td>").count - 1 == 3)
        #expect(body.contains("&#32;left&#32;</th>"))
        #expect(body.contains("pipe&#124;tick&#96;&#92;&#92;&#124;"))
        #expect(body.contains("&lt;html&gt; &amp;copy; **x**"))
        #expect(body.contains("tab&#9;line<br>next"))
        #expect(body.contains("a&quot;b") || body.contains("a\"b"))
        #expect(!body.contains("<strong>"))
    }
    @Test func tsvRaggedEmptyAndTerminalRecords() throws {
        let output = try table("A\tB\t\n1\n\n")
        let body = MarkdownRenderer().render(output.text).body
        #expect(body.components(separatedBy: "</th>").count - 1 == 3)
        #expect(body.components(separatedBy: "</td>").count - 1 == 6)
        #expect(output.text.components(separatedBy: "\n").count == 4)
        #expect(try table("single").text == "| single |\n| --- |")
    }
    @Test(arguments: ["\"unclosed", "a\"b\tc", "\"a\"junk\tb"])
    func malformedTSVRejectsWholeInput(_ value: String) {
        #expect(MarkdownPaste.convert(.table, payload: .init(plainText: value)) == .failure(.malformed))
    }
    @Test func budgetsNeverFallbackAndUseBytesAndPaddedCells() {
        var limits = MarkdownPaste.Limits()
        limits.richBytes = 3
        #expect(MarkdownPaste.convert(.markdown, payload: .init(plainText: "fallback", html: Data("<p>你好</p>".utf8)), limits: limits) == .failure(.limit))
        limits = .init(); limits.plainBytes = 5
        #expect(MarkdownPaste.convert(.plainText, payload: .init(plainText: "你好"), limits: limits) == .failure(.limit))
        limits = .init(); limits.cells = 5
        #expect(MarkdownPaste.convert(.table, payload: .init(plainText: "A\tB\tC\nx"), limits: limits) == .failure(.limit))
        for dimension in ["tokens", "depth", "output", "deadline"] {
            limits = .init()
            switch dimension { case "tokens": limits.tokens = 1; case "depth": limits.depth = 1; case "output": limits.outputBytes = 2; default: limits.seconds = 0 }
            #expect(MarkdownPaste.convert(.markdown, payload: .init(plainText: "ok", html: Data("<p><b>hello</b></p>".utf8)), limits: limits) == .failure(.limit))
        }
    }
    @Test func rtfStrictSubsetAndUnicode() throws {
        let rtf = #"{\rtf1\ansi\ansicpg1252\uc1 Plain {\b bold} {\i italic}\par \u20013?\u25991?\u-10179?\u-8638?}"#
        let output = try MarkdownPaste.convert(.markdown, payload: .init(rtf: Data(rtf.utf8))).get()
        let body = MarkdownRenderer().render(output.text).body
        #expect(body.contains("<strong>bold</strong>")); #expect(body.contains("<em>italic</em>"))
        #expect(body.contains("中文🙂"))
    }
    @Test(arguments: [#"{\rtf1 {\field{\*\fldinst HYPERLINK \"https://example.com\"}{\fldrslt x}}}"#, #"{\rtf1 {\pict 1234}}"#, #"{\rtf1\ansicpg936 abc}"#, #"{\rtf1\ul text}"#, #"{\rtf1\u-10179?}"#])
    func unsupportedRTFFallsBackLiterally(_ rtf: String) throws {
        let output = try MarkdownPaste.convert(.markdown, payload: .init(plainText: "![x](https://example.com)", rtf: Data(rtf.utf8))).get()
        #expect(output.fallbackReason != nil)
        #expect(!MarkdownRenderer().render(output.text).body.contains("<img"))
    }
    @Test func literalFallbackOnlyAdoptsAtWholeContentSelection() throws {
        let output = try html("<img>", plain: "https://example.com/a?x=1&y=2\n    ![x](remote)")
        #expect(output.isBlock)
        for source in ["![x](https://example.com/PLACE)", "<img src=\"PLACE\">", "before **PLACE** after"] {
            let selection = (source as NSString).range(of: "PLACE")
            #expect(MarkdownPaste.edit(source, selection: selection, output: output) == nil)
        }
        #expect(MarkdownPaste.edit("", selection: NSRange(location: 0, length: 0), output: output) != nil)
        #expect(MarkdownPaste.edit("whole document", selection: NSRange(location: 0, length: 14), output: output) != nil)
        #expect(MarkdownPaste.edit(" \nselected\n ", selection: NSRange(location: 2, length: 8), output: output) != nil)
        let body = MarkdownRenderer().render(output.text).body
        #expect(!body.contains("<pre")); #expect(!body.contains("<a ")); #expect(!body.contains("<img"))
        #expect(RenderedPlainText.extract(from: body).contains("    ![x](remote)"))
    }
    @Test func tableLimitsHaveInclusiveBoundaries() throws {
        for rows in [998, 999, 1000] {
            let source = Array(repeating: "x", count: rows).joined(separator: "\n")
            let result = MarkdownPaste.convert(.table, payload: .init(plainText: source))
            if rows <= 999 { #expect(try result.get().text.contains("| x |")) }
            else { #expect(result == .failure(.limit)) }
        }
        for columns in [127, 128, 129] {
            let source = Array(repeating: "x", count: columns).joined(separator: "\t")
            let result = MarkdownPaste.convert(.table, payload: .init(plainText: source))
            if columns <= 128 { #expect(try result.get().text.contains("| x |")) }
            else { #expect(result == .failure(.limit)) }
        }
        var limits = MarkdownPaste.Limits()
        limits.cells = 6
        #expect(try table("A\tB\nx\ty", limits: limits).text.contains("| x |")) // 3 physical rows * 2 columns
        limits.cells = 5
        #expect(MarkdownPaste.convert(.table, payload: .init(plainText: "A\tB\nx\ty"), limits: limits) == .failure(.limit))
        let sample = try table("你好🙂").text
        for cap in [sample.utf16.count - 1, sample.utf16.count, sample.utf16.count + 1] {
            limits = .init(); limits.tableOutputUTF16 = cap
            let result = MarkdownPaste.convert(.table, payload: .init(plainText: "你好🙂"), limits: limits)
            if cap < sample.utf16.count { #expect(result == .failure(.limit)) } else { #expect(try result.get().text == sample) }
        }
        for cap in [sample.utf8.count - 1, sample.utf8.count, sample.utf8.count + 1] {
            limits = .init(); limits.outputBytes = cap
            let result = MarkdownPaste.convert(.table, payload: .init(plainText: "你好🙂"), limits: limits)
            if cap < sample.utf8.count { #expect(result == .failure(.limit)) } else { #expect(try result.get().text == sample) }
        }
    }
    @Test func finalTableReplacementBudgetIncludesCRLFAndBlockSeparators() throws {
        let raw = "H\tB\n1\t2"
        for source in ["", "before\nafter", "before\r\nafter"] {
            let at = source.isEmpty ? 0 : (source as NSString).range(of: "after").location
            let selection = NSRange(location: at, length: 0)
            let unconstrained = try table(raw)
            let planned = try #require(MarkdownPaste.edit(source, selection: selection, output: unconstrained))
            let n = planned.replacement.utf16.count
            for cap in [n - 1, n, n + 1] {
                var limits = MarkdownPaste.Limits(); limits.tableOutputUTF16 = cap
                let converted = MarkdownPaste.convert(.table, payload: .init(plainText: raw), limits: limits)
                if cap < unconstrained.text.utf16.count { #expect(converted == .failure(.limit)); continue }
                let output = try converted.get()
                #expect((MarkdownPaste.edit(source, selection: selection, output: output) != nil) == (cap >= n))
            }
            var limits = MarkdownPaste.Limits(); limits.outputBytes = planned.replacement.utf8.count - 1
            if limits.outputBytes >= unconstrained.text.utf8.count {
                let output = try table(raw, limits: limits)
                #expect(MarkdownPaste.edit(source, selection: selection, output: output) == nil)
            }
        }
    }
    @Test func strictRichAndPlainByteBoundaries() throws {
        let rich = "<p>中文</p>", plain = "中文🙂"
        for offset in [-1, 0, 1] {
            var limits = MarkdownPaste.Limits(); limits.richBytes = rich.utf8.count + offset
            let result = MarkdownPaste.convert(.markdown, payload: .init(plainText: "fallback", html: Data(rich.utf8)), limits: limits)
            if offset < 0 { #expect(result == .failure(.limit)) } else { #expect(try result.get().fallbackReason == nil) }
            limits = .init(); limits.plainBytes = plain.utf8.count + offset
            let plainResult = MarkdownPaste.convert(.plainText, payload: .init(plainText: plain), limits: limits)
            if offset < 0 { #expect(plainResult == .failure(.limit)) } else { #expect(try plainResult.get().text == plain) }
        }
    }
    @Test func structuredEditUsesCRLFAndRejectsSurrogateSplit() throws {
        let output = try table("H\tB\n1\t2")
        let edit = try #require(MarkdownPaste.edit("before\r\nafter", selection: NSRange(location: 8, length: 0), output: output))
        #expect(edit.replacement.hasPrefix("\r\n| H")); #expect(edit.replacement.hasSuffix("\r\n\r\n"))
        #expect(MarkdownPaste.edit("🙂", selection: NSRange(location: 1, length: 0), output: output) == nil)
    }
}
