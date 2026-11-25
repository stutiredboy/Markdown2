import Foundation

/// Captured at the pointer, in the isolated WebKit world. Source-line metadata
/// identifies the block even when its rendered text is repeated or transformed.
struct PreviewParagraphHit {
    let line: Int
    let revision: Int
    private let plainLines: [String]?
    private let row: Int?
    private let column: Int?

    init?(_ value: Any?) {
        guard let data = value as? [String: Any], let line = data["line"] as? Int, line > 0,
              let revision = data["revision"] as? Int else { return nil }
        self.line = line
        self.revision = revision
        plainLines = data["plainLines"] as? [String]
        row = data["row"] as? Int
        column = data["column"] as? Int
    }

    /// Use a UTF-16 column only if the entire plain paragraph corresponds
    /// literally to its source lines. A generated inline, changed spelling or
    /// ambiguous caret still has the renderer's trustworthy block start.
    @MainActor func caret(in source: NSString) -> NSRange? {
        guard var range = MarkdownEditorView.Coordinator.sourceLineRange(forLine: line, in: source) else { return nil }
        let blockStart = NSRange(location: range.location, length: 0)
        guard let plainLines, let row, plainLines.indices.contains(row), let column,
              column >= 0, column <= plainLines[row].utf16.count else { return blockStart }
        var caret = blockStart
        for (index, visible) in plainLines.enumerated() {
            guard range.length <= 32_768 else { return blockStart }
            let raw = source.substring(with: range) as NSString
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !visible.isEmpty, (trimmed as NSString).isEqual(to: visible) else { return blockStart }
            if index == row {
                let prefixLength = raw.range(of: visible, options: .literal).location
                caret = NSRange(location: range.location + prefixLength + column, length: 0)
            }
            if index + 1 < plainLines.count {
                let next = NSMaxRange(range)
                guard next < source.length else { return blockStart }
                range = MarkdownEditorView.Coordinator.sourceLineRange(startingAt: next, in: source)
            }
        }
        return caret
    }
}
