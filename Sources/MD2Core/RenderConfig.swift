import Foundation

/// Configuration handed to ``MarkdownRenderer/render(_:config:)`` for the
/// syntax preferences, language, and academic features the renderer cannot discover on its
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
    public var inlineFeatures: InlineFeatures
    public var alertLanguage: AlertLanguage

    public init(
        bibliography: [String: BibEntry] = [:],
        citationStyle: CitationStyle = .authorYear,
        numberAllEquations: Bool = false,
        mathMacros: [String: String] = [:],
        inlineFeatures: InlineFeatures = .init(),
        alertLanguage: AlertLanguage = .english
    ) {
        self.bibliography = bibliography
        self.citationStyle = citationStyle
        self.numberAllEquations = numberAllEquations
        self.mathMacros = mathMacros
        self.inlineFeatures = inlineFeatures
        self.alertLanguage = alertLanguage
    }
}

public struct InlineFeatures: Sendable, Equatable {
    public var highlight: Bool
    public var superscript: Bool
    public var subscriptEnabled: Bool

    public init(highlight: Bool = false, superscript: Bool = false, subscriptEnabled: Bool = false) {
        self.highlight = highlight
        self.superscript = superscript
        self.subscriptEnabled = subscriptEnabled
    }
}

public enum AlertLanguage: Sendable {
    case english, simplifiedChinese

    func title(for kind: String) -> String {
        switch (self, kind) {
        case (.simplifiedChinese, "NOTE"): "注意"
        case (.simplifiedChinese, "TIP"): "提示"
        case (.simplifiedChinese, "IMPORTANT"): "重要"
        case (.simplifiedChinese, "WARNING"): "警告"
        case (.simplifiedChinese, "CAUTION"): "当心"
        default: kind.capitalized
        }
    }
}
