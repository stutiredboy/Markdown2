import Foundation

/// One example from a vendored CommonMark / GFM reference corpus, in the
/// upstream `spec.json` shape. See `Corpus/README.md` for provenance.
struct ConformanceExample: Codable, Sendable, Hashable {
    let markdown: String
    let html: String
    let example: Int
    let section: String
}

/// Which reference corpus an example came from.
enum CorpusOrigin: String, Sendable, CaseIterable {
    case commonMark = "CommonMark"
    case gfm = "GFM"
}

/// A corpus example tagged with its origin and a stable identifier.
struct CorpusEntry: Sendable, Hashable {
    let origin: CorpusOrigin
    let example: ConformanceExample

    /// Stable identifier across runs, e.g. `CommonMark#42` or `GFM#207`.
    var id: String { "\(origin.rawValue)#\(example.example)" }
    var section: String { example.section }
}

enum CorpusError: Error, CustomStringConvertible {
    case resourceMissing(String)

    var description: String {
        switch self {
        case .resourceMissing(let name):
            return "Conformance corpus resource not found in test bundle: \(name).json (subdirectory Corpus)"
        }
    }
}

/// Loads the vendored, offline CommonMark + GFM conformance corpus from the
/// test bundle. No network access; the corpus is bundled via the `MD2CoreTests`
/// `resources:` entry in `Package.swift`.
enum ConformanceCorpus {
    static let commonMarkResource = "commonmark-0.31.2.spec"
    static let gfmResource = "gfm-0.29.extensions.spec"

    static func load() throws -> [CorpusEntry] {
        try load(resource: commonMarkResource, origin: .commonMark)
            + load(resource: gfmResource, origin: .gfm)
    }

    static func load(resource: String, origin: CorpusOrigin) throws -> [CorpusEntry] {
        guard let url = Bundle.module.url(
            forResource: resource,
            withExtension: "json",
            subdirectory: "Corpus"
        ) else {
            throw CorpusError.resourceMissing(resource)
        }
        let data = try Data(contentsOf: url)
        let examples = try JSONDecoder().decode([ConformanceExample].self, from: data)
        return examples.map { CorpusEntry(origin: origin, example: $0) }
    }

    /// All examples grouped by upstream `section`, preserving first-seen order.
    static func groupedBySection() throws -> [(section: String, entries: [CorpusEntry])] {
        let all = try load()
        var order: [String] = []
        var groups: [String: [CorpusEntry]] = [:]
        for entry in all {
            if groups[entry.section] == nil { order.append(entry.section) }
            groups[entry.section, default: []].append(entry)
        }
        return order.map { ($0, groups[$0]!) }
    }

    /// The distinct section names present in the corpus, in first-seen order.
    static func sections() throws -> [String] {
        try groupedBySection().map(\.section)
    }
}
