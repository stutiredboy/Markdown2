import Foundation

/// The inline scaling workloads: one-line documents of N fragments, each a
/// shape that an inline pass which rescans the line per fragment renders in
/// quadratic time. `InlineRenderingPerformanceTests` asserts
/// that doubling N stays under 3x, and `Scripts/benchmark_inline.swift`
/// renders the same documents in a release build, so a benchmark number and a
/// test always measure the same input. Foundation only: the probe compiles
/// this file without the test target.
enum InlineScalingWorkload: String, CaseIterable, Sendable {
    case urlAutolinks
    case markdownLinks
    case mailtoAutolinks
    case entities
    case bareURLs
    case bareURLsWithEntities
    case referenceLinks
    case referenceLinksWithProtectedKeys
    /// Code spans and both inline math forms claimed by the one scan.
    case verbatimSpans
    /// Currency `$` signs: every `$` attempt fails at the next one.
    case unpairedDollars
    /// `\(` openers with no closer: quadratic before the scan's failure frontier.
    case unterminatedParenMath

    func document(count: Int) -> String {
        switch self {
        case .urlAutolinks:
            return (0..<count).map { "<https://example.com/path/\($0)>" }.joined(separator: " ")
        case .markdownLinks:
            return (0..<count).map { "[link \($0)](https://example.com/path/\($0))" }.joined(separator: " ")
        case .mailtoAutolinks:
            return (0..<count).map { "<mailto:user\($0)@example.com>" }.joined(separator: " ")
        case .entities:
            return (0..<count).map { _ in "&nbsp;" }.joined(separator: " ")
        case .bareURLs:
            return (0..<count).map { "https://example.com/path/\($0)" }.joined(separator: " ")
        case .bareURLsWithEntities:
            return (0..<count).map { "https://example.com/?a=\($0)&amp;b=2" }.joined(separator: " ")
        case .referenceLinks, .referenceLinksWithProtectedKeys:
            let protected = self == .referenceLinksWithProtectedKeys
            let body = (0..<count).map { index -> String in
                let key = protected ? "ref&amp;\(index)" : "ref\(index)"
                return "[label \(index)][\(key)]"
            }.joined(separator: " ")
            let definitions = (0..<count).map { index -> String in
                let key = protected ? "ref&amp;\(index)" : "ref\(index)"
                return "[\(key)]: https://example.com/path/\(index)"
            }.joined(separator: "\n")
            return body + "\n\n" + definitions
        case .verbatimSpans:
            return (0..<count).map { "`c\($0)` $x_\($0)$ \\(y_\($0)\\)" }.joined(separator: " ")
        case .unpairedDollars:
            return (0..<count).map { "costs $\($0) today" }.joined(separator: " ")
        case .unterminatedParenMath:
            return (0..<count).map { "\\(x\($0)" }.joined(separator: " ")
        }
    }

    /// The workloads that also have a one-fragment-per-line shape.
    static let onePerLineCases: [Self] = [.urlAutolinks, .bareURLs]

    func onePerLine(count: Int) -> String {
        switch self {
        case .urlAutolinks:
            return (0..<count).map { "<https://example.com/path/\($0)>" }.joined(separator: "\n")
        case .bareURLs:
            return (0..<count).map { "https://example.com/path/\($0)" }.joined(separator: "\n")
        default:
            return document(count: count)
        }
    }

    func matches(_ body: String, count: Int) -> Bool {
        switch self {
        case .urlAutolinks, .markdownLinks, .bareURLs, .referenceLinks, .referenceLinksWithProtectedKeys:
            return body.components(separatedBy: #"href="https://example.com/path/"#).count - 1 == count
        case .mailtoAutolinks:
            return body.components(separatedBy: #"href="mailto:user"#).count - 1 == count
        case .entities:
            return body.components(separatedBy: "&nbsp;").count - 1 == count
                && !body.contains("&amp;nbsp;")
        case .bareURLsWithEntities:
            return body.components(separatedBy: #"href="https://example.com/?a="#).count - 1 == count
                && body.contains(#"href="https://example.com/?a=\#(count - 1)&amp;b=2""#)
                && !body.contains("&amp;amp;")
        case .verbatimSpans:
            return body.components(separatedBy: "<code>c").count - 1 == count
                && body.components(separatedBy: "math-inline").count - 1 == 2 * count
        case .unpairedDollars:
            return body.components(separatedBy: "$").count - 1 == count && !body.contains("math-inline")
        case .unterminatedParenMath:
            return body.components(separatedBy: "(x").count - 1 == count && !body.contains("math-inline")
        }
    }
}
