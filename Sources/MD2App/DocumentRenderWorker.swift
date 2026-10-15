import Foundation
import MD2Core

struct DocumentRenderSnapshot: Sendable {
    let text: String
    let baseURL: URL?
    let citationStyle: CitationStyle
    let numberAllEquations: Bool
}

/// Serial, non-main-actor rendering keeps CPU work and bibliography IO away
/// from input handling. DocumentStore coalesces pending preview revisions.
actor DocumentRenderWorker {
    func render(_ snapshot: DocumentRenderSnapshot) -> RenderedDocument {
        let fields = FrontMatterReader.fields(in: snapshot.text)
        var bibliography: [String: BibEntry] = [:]
        if let baseURL = snapshot.baseURL {
            let url = baseURL.appendingPathComponent(fields["bibliography"] ?? "references.bib")
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                bibliography = BibTeXParser.parse(contents)
            }
        }
        return MarkdownRenderer().render(snapshot.text, config: RenderConfig(
            bibliography: bibliography, citationStyle: snapshot.citationStyle,
            numberAllEquations: snapshot.numberAllEquations,
            mathMacros: FrontMatterReader.parseMathMacros(fields["math-macros"])))
    }
}
