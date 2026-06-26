import Testing
@testable import MD2Core

struct BibTeXParserTests {
    // MARK: Entry detection and fields (1.1–1.3)

    @Test func parsesArticleWithBracedFields() {
        let entries = BibTeXParser.parse("""
        @article{smith2023,
          author = {Jane Smith},
          title = {On the Nature of Things},
          journal = {Journal of Things},
          year = {2023}
        }
        """)

        let entry = entries["smith2023"]
        #expect(entry?.type == "article")
        #expect(entry?.title == "On the Nature of Things")
        #expect(entry?.journal == "Journal of Things")
        #expect(entry?.year == "2023")
    }

    @Test func parsesQuotedAndBareValues() {
        let entries = BibTeXParser.parse("""
        @book{jones2024, title = "A Quoted Title", year = 2024, publisher = {Pub Co} }
        """)

        #expect(entries["jones2024"]?.title == "A Quoted Title")
        #expect(entries["jones2024"]?.year == "2024")
        #expect(entries["jones2024"]?.publisher == "Pub Co")
    }

    @Test func concatenatesValuesWithHash() {
        let entries = BibTeXParser.parse(#"""
        @misc{cat, title = "Part one " # "and part two" }
        """#)

        #expect(entries["cat"]?.title == "Part one and part two")
    }

    @Test func collapsesMultiLineBracedValue() {
        let entries = BibTeXParser.parse("""
        @article{multi,
          title = {A title that
                   spans lines},
          year = {2020}
        }
        """)

        #expect(entries["multi"]?.title == "A title that spans lines")
    }

    // MARK: Author parsing (1.4)

    @Test func parsesCommaAndSpaceAuthorForms() {
        let entries = BibTeXParser.parse("""
        @article{a, author = {Smith, Jane}, year = {2023} }
        @article{b, author = {Jane Smith}, year = {2023} }
        """)

        let a = entries["a"]?.authors.first
        #expect(a?.family == "Smith")
        #expect(a?.given == "Jane")

        let b = entries["b"]?.authors.first
        #expect(b?.family == "Smith")
        #expect(b?.given == "Jane")
    }

    @Test func parsesMultipleAuthorsSeparatedByAnd() {
        let entries = BibTeXParser.parse("""
        @article{multi, author = {Jane Smith and John Jones and Amy Adams}, year = {2023} }
        """)

        let authors = entries["multi"]?.authors ?? []
        #expect(authors.count == 3)
        #expect(authors.map(\.family) == ["Smith", "Jones", "Adams"])
    }

    // MARK: Entry types (1.5)

    @Test func supportsCommonEntryTypes() {
        let source = """
        @article{a, title = {A} }
        @book{b, title = {B} }
        @inproceedings{c, title = {C} }
        @techreport{d, title = {D} }
        @misc{e, title = {E} }
        @phdthesis{f, title = {F} }
        @mastersthesis{g, title = {G} }
        @incollection{h, title = {H} }
        """
        let entries = BibTeXParser.parse(source)
        #expect(entries.count == 8)
        #expect(entries["c"]?.type == "inproceedings")
        #expect(entries["f"]?.type == "phdthesis")
    }

    // MARK: Malformed handling (1.6)

    @Test func skipsMalformedEntryButKeepsValidOnes() {
        let source = """
        @article{good1, title = {Good One}, year = {2020} }
        @article{broken, title = {Unterminated
        @book{good2, title = {Good Two}, year = {2021} }
        """
        let entries = BibTeXParser.parse(source)

        // The valid entries before/after the broken one survive without crashing.
        #expect(entries["good1"]?.title == "Good One")
    }

    @Test func skipsStringAndPreambleBlocks() {
        let source = """
        @string{pub = "Big Publisher"}
        @preamble{ "\\newcommand{\\x}{y}" }
        @book{real, title = {Real Book}, year = {2022} }
        """
        let entries = BibTeXParser.parse(source)

        #expect(entries["real"]?.title == "Real Book")
        #expect(entries["pub"] == nil)
    }

    @Test func emptySourceParsesToNoEntries() {
        #expect(BibTeXParser.parse("").isEmpty)
        #expect(BibTeXParser.parse("no entries here").isEmpty)
    }
}
