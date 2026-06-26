import Foundation

/// Configuration handed to ``MarkdownRenderer/render(_:config:)`` for the
/// technical/academic features that the pure renderer cannot discover on its
/// own. The renderer stays a pure, `Sendable` value: file IO (resolving and
/// loading a `.bib`) and settings access happen in the app layer, which builds
/// this config and passes it in. The default value reproduces the renderer's
/// configuration-free behavior, so the many call sites and tests that need no
/// academic features keep working unchanged.
public struct RenderConfig: Sendable, Equatable {
    /// Parsed bibliography entries keyed by citation key. Loaded by the app layer
    /// from the document's associated `.bib` file.
    public var bibliography: [String: BibEntry]
    /// Whether inline citations render as author-year or numeric.
    public var citationStyle: CitationStyle
    /// When true, every display equation is numbered; otherwise only equations
    /// carrying a `\label{}` are.
    public var numberAllEquations: Bool
    /// KaTeX macros (`\command` → expansion) applied to all math in the document,
    /// read from the optional `math-macros:` front-matter field.
    public var mathMacros: [String: String]

    public init(
        bibliography: [String: BibEntry] = [:],
        citationStyle: CitationStyle = .authorYear,
        numberAllEquations: Bool = false,
        mathMacros: [String: String] = [:]
    ) {
        self.bibliography = bibliography
        self.citationStyle = citationStyle
        self.numberAllEquations = numberAllEquations
        self.mathMacros = mathMacros
    }
}
