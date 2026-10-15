import Foundation
import Synchronization

/// Renderer patterns are fixed by the implementation (not document input).
/// Reuse their immutable compiled form across blocks and background renders.
enum MarkdownRegex {
    private static let cache = Mutex<[String: NSRegularExpression]>([:])

    static func expression(_ pattern: String) -> NSRegularExpression? {
        cache.withLock { expressions in
            if let expression = expressions[pattern] { return expression }
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            expressions[pattern] = expression
            return expression
        }
    }
}
