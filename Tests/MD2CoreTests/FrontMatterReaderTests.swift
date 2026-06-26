import Testing
@testable import MD2Core

struct FrontMatterReaderTests {
    @Test func readsSingleLineScalarFields() {
        let fields = FrontMatterReader.fields(in: """
        ---
        title: My Document
        bibliography: refs.bib
        ---

        Body text.
        """)

        #expect(fields["title"] == "My Document")
        #expect(fields["bibliography"] == "refs.bib")
    }

    @Test func stripsSurroundingQuotes() {
        let fields = FrontMatterReader.fields(in: """
        ---
        bibliography: "my refs.bib"
        ---
        """)

        #expect(fields["bibliography"] == "my refs.bib")
    }

    @Test func noFrontMatterYieldsEmpty() {
        #expect(FrontMatterReader.fields(in: "# Just a heading\n\nBody.").isEmpty)
    }

    @Test func ignoresIndentedAndValuelessKeys() {
        let fields = FrontMatterReader.fields(in: """
        ---
        authors:
          - Jane
        bibliography: refs.bib
        ---
        """)

        // The nested `authors:` mapping is out of scope; the scalar is still read.
        #expect(fields["authors"] == nil)
        #expect(fields["bibliography"] == "refs.bib")
    }

    @Test func parsesMathMacrosFlowMapping() {
        let macros = FrontMatterReader.parseMathMacros(#"{ "\\vec": "\\mathbf" }"#)

        // JSON `\\`-escaping yields the single backslashes KaTeX expects.
        #expect(macros["\\vec"] == "\\mathbf")
    }

    @Test func malformedMathMacrosYieldEmpty() {
        #expect(FrontMatterReader.parseMathMacros("not json").isEmpty)
        #expect(FrontMatterReader.parseMathMacros(nil).isEmpty)
    }
}
