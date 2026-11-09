import Foundation

/// Bounds link-regex attempts to disjoint candidates. In particular an
/// unfinished `[...[` run is visited once, rather than once per opening bracket.
public enum MarkdownLinkSyntax {
    /// Raw source still contains backslash pairs; the renderer replaces escaped
    /// punctuation with opaque tokens before it asks for candidates.
    public enum Input { case rawSource, protectedEscapes }

    public static func candidateRanges(in text: String, includeImageMarker: Bool = false,
                                       input: Input = .rawSource) -> [NSRange] {
        let units = Array(text.utf16)
        var result: [NSRange] = []
        var opening: Int?
        var index = 0
        let lastBrace = lastAttributeClosingBrace(in: units, input: input)
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
                    end = endOfImageAttributes(in: units, after: end, lastClosingBrace: lastBrace, input: input)
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

    /// Find the last syntactic brace once. A raw backslash consumes its next
    /// unit here: paired backslashes leave a following brace structural, while
    /// an odd run protects it. This matches the renderer's punctuation escapes.
    /// Using a known closing bound prevents rescanning an unfinished suffix for
    /// each image (including suffixes containing only escaped closing braces).
    static func lastAttributeClosingBrace(in units: [UInt16], input: Input) -> Int {
        guard input == .rawSource else { return units.lastIndex(of: 125) ?? -1 }
        var last = -1
        var index = 0
        while index < units.count {
            if units[index] == 92 { index += 2; continue }
            if units[index] == 125 { last = index }
            index += 1
        }
        return last
    }

    /// The renderer's optional `{[^}]*}` payload is one syntactic unit, even
    /// when its keys are unknown. Raw source must skip escaped braces; protected
    /// renderer input has already replaced them and uses its first literal `}`.
    static func endOfImageAttributes(in units: [UInt16], after end: Int,
                                     lastClosingBrace: Int, input: Input) -> Int {
        guard end < lastClosingBrace, units[end] == 123 else { return end }
        var cursor = end + 1
        while cursor <= lastClosingBrace {
            if input == .rawSource, units[cursor] == 92 { cursor += 2; continue }
            if units[cursor] == 125 { return cursor + 1 }
            cursor += 1
        }
        return end
    }
}
