import Foundation
import Testing
@testable import MD2Core

@Suite(.serialized)
struct MarkdownPasteResidualRegressionTests {
    @Test(arguments: [
        (#"{\rtf1 A\u13?B}"#, "A\nB"),
        (#"{\rtf1\uc0 A\u13 B}"#, "A\nB"),
        (#"{\rtf1 A\u13?\u10?B}"#, "A\nB"),
        (#"{\rtf1 A\'0dB}"#, "A\nB"),
        (#"{\rtf1 A\u13?\b \u10?B\b0}"#, "A\n**B**"),
        (#"{\rtf1\b A\u13?\b0 \u10?B}"#, "**A**\nB"),
        (#"{\rtf1{\b A\u13?}\u10?B}"#, "**A**\nB"),
        (#"{\rtf1 A\line B}"#, "A\nB"),
        (#"{\rtf1 A\par B}"#, "A\n\nB")
    ])
    func pC4RTFLineBoundariesSurviveLiteralEscaping(_ input: String, _ expected: String) throws {
        let output = try MarkdownPaste.convert(.markdown, payload: .init(plainText: "fallback sentinel", rtf: Data(input.utf8))).get()
        #expect(output.fallbackReason == nil)
        #expect(output.text == expected)
        let body = MarkdownRenderer().render(output.text).body
        #expect(RenderedPlainText.extract(from: body) == (input.contains("\\par") ? "A\n\nB" : "A\nB"))
        if expected.contains("**") { #expect(body.contains("<strong>")) }
    }

    @Test func richLiteralCallersKeepCRBoundariesWithoutChangingPlainSource() throws {
        #expect(PasteLiteral.escape("A\rB\r\nC") == "A\nB\nC")
        #expect(PasteLiteral.escape("A\rB\r\nC", table: true) == "A<br>B<br>C")
        for (html, expected) in [("<p>A\rB</p>", "A B"), ("<p>A&#13;B</p>", "A B"), ("<code>A\r\nB</code>", "`A B`"), ("<pre>A\rB\r\nC</pre>", "```\nA\nB\nC\n```")] {
            let output = try MarkdownPaste.convert(.markdown, payload: .init(html: Data(html.utf8))).get()
            #expect(output.fallbackReason == nil)
            #expect(output.text == expected)
        }
        let source = "A\rB\r\nC"
        for kind in [MarkdownPaste.Kind.plainText, .markdown] {
            let output = try MarkdownPaste.convert(kind, payload: .init(plainText: source)).get()
            #expect(Array(output.text.utf16) == Array(source.utf16))
        }
    }

    @Test func finalHTMLBytesAreInclusiveAfterOuterWhitespaceRemoval() throws {
        for bytes in [2_097_151, 2_097_152, 2_097_153] {
            // '[' expands to the five ASCII bytes of &#91;, below raw-rich cap.
            let literal = String(repeating: "[", count: 419_430) + String(repeating: "x", count: bytes - 2_097_150)
            let result = MarkdownPaste.convert(.markdown, payload: .init(plainText: "fallback sentinel", html: Data(("<p>" + literal + "</p>").utf8)))
            if bytes <= 2_097_152 {
                let output = try result.get()
                #expect(output.fallbackReason == nil)
                #expect(output.text.utf8.count == bytes)
            } else {
                #expect(result == .failure(.limit))
            }
        }
    }

    @Test func nestedHTMLScratchWhitespaceDoesNotChangeTheFinalCap() throws {
        for html in ["<p>A<br>B</p>", "<div><p>A<br>B</p></div>", " \n<!--one--> <span><p>A<br>B</p></span> <!--two--> "] {
            for byteLimit in [5, 6, 7] {
                var limits = MarkdownPaste.Limits(); limits.outputBytes = byteLimit
                let result = MarkdownPaste.convert(.markdown, payload: .init(html: Data(html.utf8)), limits: limits)
                if byteLimit < 6 { #expect(result == .failure(.limit)) }
                else {
                    let output = try result.get()
                    #expect(output.text == "A<br>B")
                    #expect(output.fallbackReason == nil)
                }
            }
        }
        // Trimmable edges must never excuse excessive interior whitespace.
        var limits = MarkdownPaste.Limits(); limits.outputBytes = 5
        #expect(MarkdownPaste.convert(.markdown, payload: .init(html: Data("<p>A</p><p>B</p>".utf8)), limits: limits) == .failure(.limit))
    }

    @Test func largePrefixWithManyNodesUsesIncrementalOutputAccounting() throws {
        let prefix = String(repeating: "a", count: 400_000)
        let html = "<p>" + prefix + "</p>" + String(repeating: "<span>x</span>", count: 6_000)
        var limits = MarkdownPaste.Limits(); limits.outputBytes = 406_002
        // Default one-second deadline and 20,000-token cap remain unchanged.
        let output = try MarkdownPaste.convert(.markdown, payload: .init(html: Data(html.utf8)), limits: limits).get()
        #expect(output.fallbackReason == nil)
        #expect(output.text == prefix + "\n\n" + String(repeating: "x", count: 6_000))
        #expect(output.text.utf8.count == limits.outputBytes)
    }

    @Test func supportedDepthFitsTheBackgroundThreadStack() throws {
        for (open, close, levels) in [("<span>", "</span>", 64), ("<div>", "</div>", 64), ("<blockquote>", "</blockquote>", 64), ("<b>", "</b>", 64), ("<ul><li>", "</li></ul>", 32)] {
            let html = String(repeating: open, count: levels) + "x" + String(repeating: close, count: levels)
            let output = try MarkdownPaste.convert(.markdown, payload: .init(html: Data(html.utf8))).get()
            #expect(output.fallbackReason == nil)
            #expect(output.text.contains("x"))
        }
    }
}
