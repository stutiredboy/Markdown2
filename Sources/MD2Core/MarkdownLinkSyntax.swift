import Foundation

/// Bounds link-regex attempts to disjoint candidates. In particular an
/// unfinished `[...[` run is visited once, rather than once per opening bracket.
public enum MarkdownLinkSyntax {
    /// Raw source still contains backslash pairs; the renderer replaces escaped
    /// punctuation with opaque tokens before it asks for candidates.
    public enum Input { case rawSource, protectedEscapes }

    /// Label, angle destination, bare destination, and optional title. Allow
    /// pairs in the bare path without an unbounded regex nesting/backtrack.
    public static func inlineLinkPattern(input: Input) -> String {
        input == .rawSource ? rawLinkPattern : protectedLinkPattern
    }

    private static let rawLinkPattern = linkPattern(.rawSource)
    private static let protectedLinkPattern = linkPattern(.protectedEscapes)
    private static func linkPattern(_ input: Input) -> String {
        let bare = input == .rawSource ? #"(?:\\[^\r\n]|[^\\()\s])"# : #"[^()\s]"#
        let destination = "(?:\(bare)++|\\(\(bare)*+\\))++"
        let angle = input == .rawSource ? #"<(.+?)>"# : #"&lt;(.+?)&gt;"#
        let quote = input == .rawSource ? "\"" : "&quot;"
        let title = input == .rawSource ? #"(?:\\[^\r\n]|[^"\\\r\n])++"# : ".+?"
        return #"\[([^\]]+)\]\("# + "(?:\(angle)|(\(destination)))(?:\\s+\(quote)(\(title))\(quote))?\\)"
    }

    public static func candidateRanges(in text: String, includeImageMarker: Bool = false,
                                       input: Input = .rawSource) -> [NSRange] {
        candidateRanges(in: text, includeImageMarker: includeImageMarker, input: input, useLegacyLinkEnvelope: false)
    }

    /// The portable-attachment scanner uses an intentionally broader legacy
    /// envelope as well as recognized links to refuse ambiguous source edits.
    static func legacyLinkEnvelopes(in text: String) -> [NSRange] {
        candidateRanges(in: text, includeImageMarker: false, input: .rawSource, useLegacyLinkEnvelope: true)
    }

    private static func candidateRanges(in text: String, includeImageMarker: Bool, input: Input,
                                        useLegacyLinkEnvelope: Bool) -> [NSRange] {
        let units = Array(text.utf16)
        var result: [NSRange] = []
        var opening: Int?
        var index = 0
        let lastBrace = (includeImageMarker || useLegacyLinkEnvelope)
            ? lastAttributeClosingBrace(in: units, input: input) : -1
        while index < units.count {
            if units[index] == 91, opening == nil,
               !includeImageMarker || (index > 0 && units[index - 1] == 33) { opening = index }
            if units[index] == 93 {
                if let start = opening, index + 1 < units.count, units[index + 1] == 40 {
                    if !includeImageMarker, !useLegacyLinkEnvelope {
                        opening = nil
                        let tail = linkEnd(in: units, after: index + 2, input: input)
                        if let end = tail.end {
                            result.append(NSRange(location: start, length: end - start))
                            index = end
                        } else {
                            index = tail.resume
                        }
                        continue
                    }
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

    private static let rawAngle: [UInt16] = [60]
    private static let rawAngleEnd: [UInt16] = [62]
    private static let rawQuote: [UInt16] = [34]
    private static let escapedAngle = Array("&lt;".utf16)
    private static let escapedAngleEnd = Array("&gt;".utf16)
    private static let escapedQuote = Array("&quot;".utf16)

    /// Walk just the destination and possible title, resuming at the first
    /// unclaimed unit on failure. In particular an unfinished destination
    /// cannot steal the closing ')' from a later link separated by prose.
    private static func linkEnd(in units: [UInt16], after start: Int, input: Input)
        -> (end: Int?, resume: Int) {
        var cursor = start
        let angle = input == .rawSource ? rawAngle : escapedAngle
        let angleEnd = input == .rawSource ? rawAngleEnd : escapedAngleEnd
        let quote = input == .rawSource ? rawQuote : escapedQuote
        func advanceEscape() -> Bool {
            guard input == .rawSource, units[cursor] == 92, cursor + 1 < units.count,
                  units[cursor + 1] != 10, units[cursor + 1] != 13 else { return false }
            cursor += 2
            return true
        }
        func isSpace(_ unit: UInt16) -> Bool {
            if unit < 128 { return unit == 32 || (9...13).contains(unit) }
            return Unicode.Scalar(unit).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
        }
        if units[cursor...].starts(with: angle) {
            cursor += angle.count
            while cursor < units.count, !units[cursor...].starts(with: angleEnd) {
                if units[cursor] == 10 || units[cursor] == 13 { return (nil, cursor) }
                if !advanceEscape() { cursor += 1 }
            }
            guard cursor < units.count else { return (nil, cursor) }
            cursor += angleEnd.count
        } else {
            var depth = 0
            while cursor < units.count {
                let unit = units[cursor]
                if unit == 41, depth == 0 { break }
                if isSpace(unit) { break }
                if advanceEscape() { continue }
                if unit == 40 { depth += 1 }
                if unit == 41 { depth -= 1 }
                cursor += 1
            }
            guard depth == 0 else { return (nil, cursor) }
        }
        if cursor < units.count, isSpace(units[cursor]) {
            repeat { cursor += 1 } while cursor < units.count && isSpace(units[cursor])
            guard units[cursor...].starts(with: quote) else { return (nil, cursor) }
            cursor += quote.count
            // Once in a quoted title, ')' is text. Stop at the first unescaped
            // quote; the regex will still validate the title and label.
            while cursor < units.count, !units[cursor...].starts(with: quote) {
                if units[cursor] == 10 || units[cursor] == 13 { return (nil, cursor) }
                if !advanceEscape() { cursor += 1 }
            }
            guard cursor < units.count else { return (nil, cursor) }
            cursor += quote.count
        }
        guard cursor < units.count, units[cursor] == 41 else { return (nil, cursor) }
        return (cursor + 1, cursor + 1)
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
