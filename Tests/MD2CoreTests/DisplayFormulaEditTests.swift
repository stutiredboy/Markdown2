import Foundation
import Testing
@testable import MD2Core

struct DisplayFormulaEditTests {
    @Test func mapsRepeatedFormulasThroughMixedLineEndingsAndUnicode() throws {
        let tex = #"\text{汉字 👩🏽‍💻 é} + x"#
        let first = "  $$ \t\(tex) \t$$ \t"
        let second = "$$\(tex)$$"
        let prefix = "前文 👋\r\n\r\n"
        let between = "\r\r重复文本 \(tex)\n\n"
        let suffix = "\r\n\r\n后文"
        let source = prefix + first + between + second + suffix
        let rendered = MarkdownRenderer().render(source, includeDisplayFormulaEdits: true)
        #expect(Set(rendered.displayFormulaEdits.keys) == [3, 7])
        let firstEdit = try #require(rendered.displayFormulaEdits[3])
        let secondEdit = try #require(rendered.displayFormulaEdits[7])
        #expect(firstEdit.range == NSRange(location: (prefix + "  $$ \t").utf16.count, length: tex.utf16.count))
        #expect(secondEdit.range == NSRange(location: (prefix + first + between + "$$").utf16.count, length: tex.utf16.count))
        #expect(firstEdit.source.utf16.elementsEqual(tex.utf16))
        #expect(secondEdit.source.utf16.elementsEqual(tex.utf16))

        let newTex = #"\text{修改} = 2"#
        let result = (source as NSString).replacingCharacters(in: secondEdit.range, with: newTex)
        let expected = prefix + first + between + "$$\(newTex)$$" + suffix
        #expect(result.utf8.elementsEqual(expected.utf8))
    }

    @Test func sourceMapKeepsLabelsAndTagsAndLeavesRenderingUnchanged() {
        let labeled = #"x+1 \label{eq:first}"#
        let tagged = #"y+2 \tag{A}"#
        let source = "$$\(labeled)$$\n\n$$\(tagged)$$\n"
        let renderer = MarkdownRenderer()
        let normal = renderer.render(source)
        let mapped = renderer.render(source, includeDisplayFormulaEdits: true)
        #expect(normal.displayFormulaEdits.isEmpty)
        #expect(mapped.body == normal.body)
        #expect(mapped.html == normal.html)
        #expect(mapped.stats == normal.stats)
        #expect(mapped.displayFormulaEdits[1]?.source == labeled)
        #expect(mapped.displayFormulaEdits[3]?.source == tagged)
    }

    @Test func preservesDistinctUnicodeRepresentationsOfTheSameVisibleFormula() throws {
        let precomposed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let source = "$$\(precomposed)$$\r\n$$\(decomposed)$$"
        let rendered = MarkdownRenderer().render(source, includeDisplayFormulaEdits: true)
        let first = try #require(rendered.displayFormulaEdits[1])
        let second = try #require(rendered.displayFormulaEdits[2])
        #expect(first.range.length == 4)
        #expect(second.range.length == 5)
        #expect(first.source.utf8.elementsEqual(precomposed.utf8))
        #expect(second.source.utf8.elementsEqual(decomposed.utf8))
    }

    @Test(arguments: [
        "$$\nx+y\n$$", #"\[x+y\]"#, #"\begin{equation}x+y\end{equation}"#,
        "> $$x+y$$", "- item\n\n  $$x+y$$", "```\n$$x+y$$\n```", "    $$x+y$$",
        "inline $x+y$ and `$$x+y$$`", "$$ $$", "$$$x$$", "$$x$$y$$",
        "---\nvalue: x\n$$x+y$$\n---", "$$\u{0301}x$$",
        #"<div class="math math-display" data-md2-source-line="1">x</div>"#
    ]) func skipsUnsupportedSyntax(_ source: String) {
        #expect(MarkdownRenderer().render(source, includeDisplayFormulaEdits: true).displayFormulaEdits.isEmpty)
    }

    @Test func validatesTheReplacementWithoutChangingInteriorBytes() throws {
        let tex = #"\text{ 👩🏽‍💻 é \$ } + x"#
        let result = try #require(DisplayFormulaEdit.validatedReplacement(" \t\(tex)\t "))
        #expect(result.utf8.elementsEqual(tex.utf8))
    }

    @Test(arguments: ["", " \t ", "x\ny", "x\r\ny", "x\u{2028}y", "x\u{0000}y",
                      "$$x$$", "$x", "x$", "a$$b", "\u{0301}x", "x\u{0600}"])
    func rejectsAmbiguousReplacement(_ source: String) {
        #expect(DisplayFormulaEdit.validatedReplacement(source) == nil)
    }
}
