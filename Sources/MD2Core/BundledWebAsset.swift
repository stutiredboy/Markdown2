import CryptoKit
import Foundation

/// The complete allowlist of application-owned web resources. URLs include a
/// content hash, so caches may reuse an asset across documents but never across
/// a changed bundle. Each resource is read and hashed only on first use.
public enum BundledWebAsset: String, CaseIterable, Sendable {
    case katexCSS = "katex/katex.bundle.css"
    case katex = "katex/katex.min.js"
    case mhchem = "katex/mhchem.min.js"
    case underscore = "diagrams/underscore.min.js"
    case raphael = "diagrams/raphael.min.js"
    case flowchart = "diagrams/flowchart.min.js"
    case sequence = "diagrams/sequence-diagram.min.js"
    case mermaid = "diagrams/mermaid.min.js"

    public static let scheme = "md2-app"

    public var data: Data { resource.data }
    public var url: URL { resource.url }
    public var text: String { String(decoding: data, as: UTF8.self) }
    public var mimeType: String { self == .katexCSS ? "text/css" : "text/javascript" }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "assets",
              let candidate = Self.allCases.first(where: { url.path.hasSuffix("/" + $0.rawValue) }),
              url == candidate.url else { return nil }
        self = candidate
    }

    private struct Resource: Sendable {
        let data: Data
        let url: URL

        init(_ asset: BundledWebAsset) {
            let path = asset.rawValue as NSString
            let file = MD2CoreResources.bundle.url(
                forResource: path.lastPathComponent,
                withExtension: nil,
                subdirectory: path.deletingLastPathComponent
            )
            data = file.flatMap { try? Data(contentsOf: $0) } ?? Data()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            url = URL(string: "\(BundledWebAsset.scheme)://assets/\(digest)/\(asset.rawValue)")!
        }
    }

    private enum Cache {
        static let katexCSS = Resource(.katexCSS)
        static let katex = Resource(.katex)
        static let mhchem = Resource(.mhchem)
        static let underscore = Resource(.underscore)
        static let raphael = Resource(.raphael)
        static let flowchart = Resource(.flowchart)
        static let sequence = Resource(.sequence)
        static let mermaid = Resource(.mermaid)
    }

    private var resource: Resource {
        switch self {
        case .katexCSS: Cache.katexCSS
        case .katex: Cache.katex
        case .mhchem: Cache.mhchem
        case .underscore: Cache.underscore
        case .raphael: Cache.raphael
        case .flowchart: Cache.flowchart
        case .sequence: Cache.sequence
        case .mermaid: Cache.mermaid
        }
    }
}

/// Standalone HTML embeds its dependencies; app pages share bundled resources.
public enum RenderAssetMode: Sendable {
    case inline
    case appScheme

    func script(_ asset: BundledWebAsset) -> String {
        switch self {
        case .inline: "<script>\n\(asset.text)\n</script>"
        case .appScheme: "<script src=\"\(asset.url.absoluteString)\"></script>"
        }
    }

    var mathStylesheet: String {
        switch self {
        case .inline: "<style>\n\(BundledWebAsset.katexCSS.text)\n</style>"
        case .appScheme: "<link rel=\"stylesheet\" href=\"\(BundledWebAsset.katexCSS.url.absoluteString)\">"
        }
    }
}
