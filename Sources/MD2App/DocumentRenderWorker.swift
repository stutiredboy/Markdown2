import Foundation
import MD2Core

struct DocumentRenderSnapshot: Sendable {
    let text: String
    let baseURL: URL?
    let citationStyle: CitationStyle
    let numberAllEquations: Bool
    var inlineFeatures: InlineFeatures = .init()
    var alertLanguage: AlertLanguage = .english
    var remoteResourcePolicy: RemoteResourcePolicy = .blocked
    var offlineHTMLLabels = OfflineHTMLLabels()
}

/// Serial, non-main-actor rendering keeps CPU work and bibliography IO away
/// from input handling. DocumentStore coalesces pending preview revisions.
actor DocumentRenderWorker {
    private let beforeRendering: (@Sendable () async -> Void)?

    init(beforeRendering: (@Sendable () async -> Void)? = nil) {
        self.beforeRendering = beforeRendering
    }

    /// Rendering, local file reads, image decoding and base64 encoding all stay
    /// on this worker; bounded image validation must not block editor input.
    func renderSelfContainedHTML(
        _ snapshot: DocumentRenderSnapshot,
        builder: (@Sendable (String, URL?) -> SelfContainedHTMLBuilder.Output)? = nil
    ) async -> SelfContainedHTMLBuilder.Output {
        var offlineSnapshot = snapshot
        offlineSnapshot.remoteResourcePolicy = .blocked
        let rendered = await render(offlineSnapshot, assetMode: .inline)
        if let builder { return builder(rendered.html, snapshot.baseURL) }
        return SelfContainedHTMLBuilder.build(html: rendered.html, baseURL: snapshot.baseURL,
                                             labels: snapshot.offlineHTMLLabels)
    }

    func render(_ snapshot: DocumentRenderSnapshot, assetMode: RenderAssetMode = .appScheme) async -> RenderedDocument {
        await beforeRendering?()
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
            mathMacros: FrontMatterReader.parseMathMacros(fields["math-macros"]),
            inlineFeatures: snapshot.inlineFeatures, alertLanguage: snapshot.alertLanguage),
            assetMode: assetMode, remoteResourcePolicy: snapshot.remoteResourcePolicy)
    }
}
