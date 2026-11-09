import Foundation

/// Literal, Unicode-aware search. Every returned range uses source UTF-16 units
/// and starts/ends at an extended grapheme boundary, including folded matches.
public enum TextSearch {
    public struct Options: Equatable, Sendable {
        public var caseSensitive: Bool
        public var wholeWord: Bool

        public init(caseSensitive: Bool = false, wholeWord: Bool = false) {
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
        }
    }

    /// Nonoverlapping matches, fully contained by `scope`. Scope edges never
    /// create word boundaries. An invalid/empty scope returns no matches.
    /// Diacritic insensitivity is independent of case sensitivity.
    public static func matches(
        of query: String, in text: String, options: Options = .init(),
        scope: NSRange? = nil, maximumMatches: Int = .max
    ) -> [NSRange] {
        guard !query.isEmpty, maximumMatches > 0 else { return [] }
        let source = text as NSString
        let bounds = scope ?? NSRange(location: 0, length: source.length)
        guard bounds.location != NSNotFound, bounds.location >= 0, bounds.length > 0,
              bounds.location <= source.length, bounds.length <= source.length - bounds.location else { return [] }
        var comparison: NSString.CompareOptions = [.diacriticInsensitive]
        if !options.caseSensitive { comparison.insert(.caseInsensitive) }
        // Grapheme/token boundaries are computed once, not once per match. A
        // token is a continuous run of L/M/N/Pc; Chinese is not segmented.
        var boundaries = [Bool](repeating: false, count: source.length + 1)
        var wordInteriors = options.wholeWord ? [Bool](repeating: false, count: source.length + 1) : []
        var offset = 0
        var previousWasWord = false
        for character in text {
            boundaries[offset] = true
            if options.wholeWord {
                // A mixed grapheme may contain ZWJ without creating a word
                // boundary at either edge (for example the Indic conjunct क्‍ष).
                // Keep graphemes atomic, but classify the adjacent edge scalars.
                let scalars = character.unicodeScalars
                if previousWasWord, let first = scalars.first, isWordScalar(first) {
                    wordInteriors[offset] = true
                }
                previousWasWord = scalars.last.map(isWordScalar) ?? false
            }
            offset += character.utf16.count
        }
        boundaries[offset] = true
        var results: [NSRange] = []
        var cursor = bounds.location
        let limit = bounds.location + bounds.length
        while cursor < limit {
            var range = source.range(of: query, options: comparison,
                                     range: NSRange(location: cursor, length: limit - cursor))
            guard range.location != NSNotFound else { break }
            // Foundation's exact-match fast path may omit trailing combining
            // marks ("cafe" in decomposed "café"). Include only a mark suffix,
            // never an emoji modifier or a ZWJ continuation.
            if range.length > 0, boundaries[range.location], !boundaries[NSMaxRange(range)] {
                let expanded = source.rangeOfComposedCharacterSequences(for: range)
                let suffix = source.substring(with: NSRange(location: NSMaxRange(range), length: NSMaxRange(expanded) - NSMaxRange(range)))
                let onlyMarks = suffix.unicodeScalars.allSatisfy {
                    [.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory)
                }
                if expanded.location == range.location, NSMaxRange(expanded) <= limit, onlyMarks,
                   (source.substring(with: expanded) as NSString).compare(query, options: comparison) == .orderedSame {
                    range = expanded
                }
            }
            let end = range.location + range.length
            if range.length > 0, boundaries[range.location], boundaries[end],
               !options.wholeWord || (!wordInteriors[range.location] && !wordInteriors[end]) {
                results.append(range)
                if results.count == maximumMatches { break }
                cursor = end
            } else {
                cursor = range.location + max(range.length, 1)
            }
        }
        return results
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber, .connectorPunctuation: true
        default: false
        }
    }

}
