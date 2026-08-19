import Foundation

/// Pure helpers for the editor's find-match reveal, kept in MD2Core so the
/// behavior is unit-testable without an AppKit window.
public enum FindReveal {
    /// The collapsed selection to set when revealing a match: a caret at the end
    /// of the match. Selecting the whole match would make Backspace delete the
    /// entire matched word as one unit; a collapsed caret keeps normal delete
    /// semantics (one character at a time) while the match stays visible through
    /// its highlight.
    public static func caretRange(for match: NSRange) -> NSRange {
        NSRange(location: match.location + match.length, length: 0)
    }
}
