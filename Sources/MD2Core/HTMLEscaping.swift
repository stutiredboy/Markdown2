import Foundation

/// Centralized HTML escaping shared by the renderer and the syntax highlighter
/// so the escaping rules live in exactly one place and cannot drift apart.
///
/// Escaping works on UTF-8 bytes, not on `Character`s. A combining mark joins
/// the character before it into one grapheme, so a `Character`-level search
/// (which `String.replacingOccurrences` performs) does not find a `"` or `<`
/// followed by U+0301, and author text could close a double-quoted attribute
/// and add an event handler. The escaped characters are ASCII, and an ASCII
/// byte never occurs inside a multi-byte UTF-8 sequence, so every occurrence is
/// replaced however the text clusters.
enum HTMLEscaping {
    /// Escapes the five characters that are unsafe in element text / double-quoted
    /// attribute context.
    static func escape(_ source: String) -> String {
        escaped(source, apostrophe: false)
    }

    /// Attribute-context escaping additionally encodes the single quote, for use
    /// in single-quoted attribute values.
    static func escapeAttribute(_ source: String) -> String {
        escaped(source, apostrophe: true)
    }

    private static func escaped(_ source: String, apostrophe: Bool) -> String {
        let needsEscape: (UInt8) -> Bool = { byte in
            byte == UInt8(ascii: "&") || byte == UInt8(ascii: "<") || byte == UInt8(ascii: ">")
                || byte == UInt8(ascii: "\"") || (apostrophe && byte == UInt8(ascii: "'"))
        }
        guard source.utf8.contains(where: needsEscape) else { return source }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.utf8.count + 16)
        for byte in source.utf8 {
            switch byte {
            case UInt8(ascii: "&"): bytes.append(contentsOf: "&amp;".utf8)
            case UInt8(ascii: "<"): bytes.append(contentsOf: "&lt;".utf8)
            case UInt8(ascii: ">"): bytes.append(contentsOf: "&gt;".utf8)
            case UInt8(ascii: "\""): bytes.append(contentsOf: "&quot;".utf8)
            case UInt8(ascii: "'") where apostrophe: bytes.append(contentsOf: "&#39;".utf8)
            default: bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
