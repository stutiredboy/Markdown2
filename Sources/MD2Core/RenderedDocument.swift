import Foundation

public struct RenderedDocument: Equatable, Sendable {
    public let html: String
    /// The rendered content that sits inside the page's `<main>` element,
    /// without the surrounding document shell (head/scripts). Used by the
    /// live-preview path to swap content in place without reloading the page.
    public let body: String
    public let outline: [Heading]
    public let stats: DocumentStats
    /// The `math-macros:` front-matter map the page's shell was built with.
    /// The live preview swaps only the body, so it passes these along for the
    /// formulas to render with.
    public let mathMacros: [String: String]
    /// Exact edits from the original source, keyed by the renderer's 1-based
    /// top-level formula line. Empty when the caller did not request a map.
    public let displayFormulaEdits: [Int: DisplayFormulaEdit]

    public init(
        html: String,
        body: String,
        outline: [Heading],
        stats: DocumentStats,
        mathMacros: [String: String] = [:],
        displayFormulaEdits: [Int: DisplayFormulaEdit] = [:]
    ) {
        self.html = html
        self.body = body
        self.outline = outline
        self.stats = stats
        self.mathMacros = mathMacros
        self.displayFormulaEdits = displayFormulaEdits
    }
}
