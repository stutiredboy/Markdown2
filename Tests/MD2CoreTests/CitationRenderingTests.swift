import Testing
@testable import MD2Core

struct CitationRenderingTests {
    private static let bibSource = """
    @article{smith2023, author = {Jane Smith}, title = {On Things}, journal = {Journal of Things}, year = {2023} }
    @book{jones2024, author = {John Jones}, title = {Big Book}, publisher = {Pub Co}, year = {2024} }
    @article{ab2022, author = {Amy Adams and Bob Brown and Carl Clark}, title = {Three Authors}, year = {2022} }
    """

    private func config(_ style: CitationStyle = .authorYear) -> RenderConfig {
        RenderConfig(bibliography: BibTeXParser.parse(Self.bibSource), citationStyle: style)
    }

    private func render(_ markdown: String, _ style: CitationStyle = .authorYear) -> String {
        MarkdownRenderer().render(markdown, config: config(style)).html.withoutSourceLineMetadata
    }

    // MARK: Syntax variants (3.2–3.6)

    @Test func parentheticalAuthorYear() {
        let html = render("As shown by [@smith2023], the result holds.")
        #expect(html.contains("(Smith, 2023)"))
        #expect(!html.contains("[@smith2023]"))
    }

    @Test func inTextAuthorYear() {
        let html = render("@smith2023 showed that the result holds.")
        #expect(html.contains("Smith (2023)"))
        #expect(!html.contains("@smith2023"))
    }

    @Test func suppressedAuthorRendersYearOnly() {
        let html = render("As shown previously [-@smith2023].")
        // The inline citation shows the year only; the author name still appears
        // in the trailing bibliography section, so assert on the citation span.
        #expect(html.contains(#"<span class="citation">(2023)</span>"#))
    }

    @Test func multipleCitationsSemicolonSeparated() {
        let html = render("Several studies [@smith2023; @jones2024] confirm this.")
        #expect(html.contains("(Smith, 2023; Jones, 2024)"))
    }

    @Test func citationWithLocator() {
        let html = render("See [@smith2023, p. 42] for details.")
        #expect(html.contains("(Smith, 2023, p. 42)"))
    }

    @Test func threeAuthorsUseEtAl() {
        let html = render("Shown in [@ab2022].")
        #expect(html.contains("(Adams et al., 2022)"))
    }

    // MARK: Numeric style (3.x)

    @Test func numericStyleBracketsInFirstCitationOrder() {
        let html = render("First [@smith2023] then [@jones2024].", .numeric)
        #expect(html.contains("[1]"))
        #expect(html.contains("[2]"))
    }

    @Test func numericMultipleCitations() {
        let html = render("Both [@smith2023; @jones2024].", .numeric)
        #expect(html.contains("[1, 2]"))
    }

    // MARK: Bibliography section (4.x)

    @Test func bibliographySectionListsCitedEntries() {
        let html = render("See [@smith2023] and [@jones2024].")
        #expect(html.contains(#"<section class="bibliography">"#))
        #expect(html.contains("On Things"))
        #expect(html.contains("Big Book"))
    }

    @Test func bibliographyAlphabeticalInAuthorYear() {
        // Cite jones (J) before smith (S): author-year orders Jones before Smith.
        let html = render("Text [@jones2024] and [@smith2023].")
        let jones = html.range(of: "Big Book")
        let smith = html.range(of: "On Things")
        #expect(jones != nil && smith != nil)
        if let jones, let smith { #expect(jones.lowerBound < smith.lowerBound) }
    }

    @Test func bibliographyCitationOrderInNumeric() {
        // Cite smith first then jones: numeric keeps citation order.
        let html = render("Text [@smith2023] and [@jones2024].", .numeric)
        let smith = html.range(of: "On Things")
        let jones = html.range(of: "Big Book")
        #expect(smith != nil && jones != nil)
        if let smith, let jones { #expect(smith.lowerBound < jones.lowerBound) }
    }

    @Test func noBibliographySectionWithoutCitations() {
        let html = render("Plain text with no citations.")
        #expect(!html.contains(#"<section class="bibliography">"#))
    }

    @Test func duplicateCitationsShareOneEntry() {
        let html = render("First [@smith2023] and again [@smith2023].")
        let occurrences = html.components(separatedBy: #"<li id="bib-smith2023">"#).count - 1
        #expect(occurrences == 1)
    }

    // MARK: Code precedence (3.8 / requirement)

    @Test func citationInsideInlineCodeStaysLiteral() {
        let html = render("Use `[@smith2023]` to cite.")
        #expect(html.contains("[@smith2023]"))
        #expect(!html.contains("(Smith, 2023)"))
    }

    @Test func citationInsideFencedCodeStaysLiteral() {
        let html = render("""
        ```
        [@smith2023]
        ```
        """)
        #expect(html.contains("[@smith2023]"))
        #expect(!html.contains("(Smith, 2023)"))
    }

    // MARK: Unknown keys and graceful fallback

    @Test func unknownBracketedKeyRendersRawKey() {
        let html = render("Citing [@unknownkey] here.")
        #expect(html.contains("unknownkey"))
        #expect(!html.contains(#"<section class="bibliography">"#))
    }

    @Test func missingBibliographyFallsBackToRawKey() {
        // Empty config: no bibliography loaded.
        let html = MarkdownRenderer().render("Citing [@smith2023] here.").html
        #expect(html.contains("smith2023"))
        #expect(!html.contains(#"<section class="bibliography">"#))
    }

    // MARK: False-positive guards (14.2)

    @Test func emailAddressIsNotACitation() {
        let html = render("Contact john@example.com for details.")
        #expect(html.contains("john@example.com"))
        #expect(!html.contains(#"<span class="citation">"#))
    }

    @Test func atSignFollowedByWhitespaceIsNotACitation() {
        let html = render("Let us meet @ noon.")
        #expect(html.contains("@ noon"))
        #expect(!html.contains(#"<span class="citation">"#))
    }

    @Test func bareUnknownKeyStaysLiteral() {
        let html = render("@todo revisit this")
        #expect(html.contains("@todo"))
        #expect(!html.contains(#"<span class="citation">"#))
    }
}
