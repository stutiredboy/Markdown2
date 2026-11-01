import Foundation

extension String {
    var normalizedMarkdownLines: [String] {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    var trimmedMarkdownLine: String {
        trimmingCharacters(in: .whitespaces)
    }
}

/// Markdown's block markers and link syntax are ASCII, and CommonMark reads
/// them by code point. A joining scalar right after a marker (a combining mark,
/// ZWJ, a variation selector or a spacing mark) fuses with the marker's last
/// character into one grapheme, which a `Character` comparison does not match,
/// so the block parser compares and drops markers as Unicode scalars.
extension String {
    /// `hasPrefix`, compared as Unicode scalars.
    func hasScalarPrefix(_ prefix: String) -> Bool {
        unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// The text after its first `count` Unicode scalars, so dropping a marker
    /// keeps a joining scalar that follows it. Built from the sliced scalar
    /// view, which copies the bytes rather than re-encoding each scalar.
    func droppingScalars(_ count: Int) -> String {
        String(unicodeScalars.dropFirst(count))
    }
}
