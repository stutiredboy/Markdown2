import Foundation
import MD2Core

/// Capture expansion and assembly of an atomic edit in the regex worker process.
enum RegexFindWorker {
    static func result<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async -> Result<Value, any Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    struct Edit: Codable, Sendable {
        let range: NSRange
        let replacement: String
        let count: Int
    }

    static func makeEdit(
        pattern: String, template: String, source: String, caseSensitive: Bool, scope: NSRange?,
        target: NSRange?
    ) throws -> Edit? {
        let matches = try RegexSearch.matches(
            of: pattern, in: source, caseSensitive: caseSensitive, scope: scope,
            replacementTemplate: template, replacementTarget: target
        )
        if let target {
            guard let match = matches.first(where: { $0.range == target }), let value = match.replacement else { return nil }
            let original = (source as NSString).substring(with: target)
            guard !original.utf16.elementsEqual(value.utf16) else { return nil }
            return Edit(range: target, replacement: value, count: 1)
        }
        guard let first = matches.first, let last = matches.last else { return nil }
        let original = source as NSString
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var cursor = range.location
        var replacement = ""
        for match in matches {
            try Task.checkCancellation()
            replacement += original.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            guard let value = match.replacement else { throw RegexSearch.Failure.searchFailed }
            replacement += value
            cursor = NSMaxRange(match.range)
        }
        guard !original.substring(with: range).utf16.elementsEqual(replacement.utf16) else { return nil }
        return Edit(range: range, replacement: replacement, count: matches.count)
    }
}
