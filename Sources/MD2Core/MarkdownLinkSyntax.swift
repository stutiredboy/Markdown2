import Foundation

/// Bounds link-regex attempts to disjoint candidates. In particular an
/// unfinished `[...[` run is visited once, rather than once per opening bracket.
public enum MarkdownLinkSyntax {
    public static func candidateRanges(in text: String, includeImageMarker: Bool = false) -> [NSRange] {
        let units = Array(text.utf16)
        var result: [NSRange] = []
        var opening: Int?
        var index = 0
        let lastBrace = units.lastIndex(of: 125) ?? -1
        while index < units.count {
            if units[index] == 91, opening == nil,
               !includeImageMarker || (index > 0 && units[index - 1] == 33) { opening = index }
            if units[index] == 93 {
                if let start = opening, index + 1 < units.count, units[index + 1] == 40 {
                    var end = index + 2
                    // Angle destinations may contain literal closing parens.
                    let encodedAngle = Array("&lt;".utf16)
                    if units[end...].starts(with: encodedAngle) {
                        end += encodedAngle.count
                        let close = Array("&gt;".utf16)
                        while end < units.count, !units[end...].starts(with: close) { end += 1 }
                        if end < units.count { end += close.count }
                    } else if end < units.count, units[end] == 60 {
                        while end < units.count, units[end] != 62 { end += 1 }
                        if end < units.count { end += 1 }
                    }
                    while end < units.count, units[end] != 41 { end += 1 }
                    guard end < units.count else { break }
                    end += 1
                    // Image size / figure attributes belong to the same candidate.
                    end = endOfImageAttributes(in: units, after: end, lastClosingBrace: lastBrace)
                    let lower = includeImageMarker && start > 0 && units[start - 1] == 33 ? start - 1 : start
                    result.append(NSRange(location: lower, length: end - lower))
                    index = end - 1
                }
                opening = nil
            }
            index += 1
        }
        return result
    }

    /// The renderer's optional `{[^}]*}` payload is one syntactic unit, even
    /// when its keys are unknown and it is later emitted as literal text. Both
    /// render candidates and source edits must skip through the same first `}`.
    /// A precomputed last brace avoids rescanning an unclosed suffix per image.
    static func endOfImageAttributes(in units: [UInt16], after end: Int, lastClosingBrace: Int) -> Int {
        guard end < lastClosingBrace, units[end] == 123 else { return end }
        var cursor = end + 1
        while cursor < units.count, units[cursor] != 125 { cursor += 1 }
        return cursor < units.count ? cursor + 1 : end
    }
}
