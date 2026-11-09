import Foundation

/// Shared fence syntax for rendering, outline, styling and editing. Callers
/// retain their existing container/indentation policy and pass the content line.
public struct MarkdownFence: Equatable, Sendable {
    public let marker: String
    public let info: String

    public static func opening(in line: String) -> MarkdownFence? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let scalars = trimmed.unicodeScalars
        guard let character = scalars.first, character == "`" || character == "~" else { return nil }
        let run = scalars.prefix { $0 == character }
        guard run.count >= 3 else { return nil }
        let info = String(scalars.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
        guard character != "`" || !info.unicodeScalars.contains("`") else { return nil }
        return MarkdownFence(marker: String(run), info: info)
    }

    /// Only the same marker, at least as long as the opener, followed by
    /// whitespace may close a fence. A shorter or mixed fence is literal code.
    public func isClosed(by line: String) -> Bool {
        let scalars = line.trimmingCharacters(in: .whitespaces).unicodeScalars
        let run = scalars.prefix { $0 == marker.unicodeScalars.first }
        return run.count >= marker.unicodeScalars.count
            && String(scalars.dropFirst(run.count)).trimmingCharacters(in: .whitespaces).isEmpty
    }
}
