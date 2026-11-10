import Foundation

/// Source-preserving subset of the renderer's pipe syntax. Ambiguous syntax is
/// rejected instead of giving editing and rendering different column numbers.
enum MarkdownTableSyntax {
    struct Row {
        let body: String
        let cells: [NSRange]
        let contents: [NSRange]
        let leadingPipe: Bool
        let trailingPipe: Bool
        let indent: String
        var isDelimiter: Bool {
            cells.allSatisfy {
                (body as NSString).substring(with: $0).trimmingCharacters(in: .whitespaces)
                    .range(of: #"^:?-+:?$"#, options: .regularExpression) != nil
            }
        }
    }

    static func row(_ body: String) -> Row? {
        let source = body as NSString
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let bounds = source.range(of: trimmed, options: .literal)
        let indent = source.substring(to: bounds.location)
        guard indent.count <= 3, indent.allSatisfy({ $0 == " " }) else { return nil }
        var separators: [Int] = []
        var escaped = false, code = false
        var position = bounds.location
        let characters = Array(trimmed)
        for (index, character) in characters.enumerated() {
            // The renderer recognizes whole Characters, not ASCII scalars
            // inside a grapheme (for example a pipe followed by U+0301).
            // Ranges still address the original UTF-16 source.
            defer { position += character.utf16.count }
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" {
                // The renderer toggles per character. Multi-backtick runs are
                // intentionally outside the safe editing subset.
                if index + 1 < characters.count, characters[index + 1] == "`" { return nil }
                code.toggle()
            }
            if character == "|", !code { separators.append(position) }
        }
        guard !code, !separators.isEmpty else { return nil }
        let leading = separators.first == bounds.location
        let trailing = separators.last == NSMaxRange(bounds) - 1
        // splitTableLine strips an ending pipe even when escaped/code-owned.
        guard trimmed.last != "|" || trailing else { return nil }
        let start = bounds.location + (leading ? 1 : 0)
        // Without a closing rail, trailing whitespace belongs to the last
        // cell. Keep it in that cell's raw range so column edits cannot move
        // padding into a new cell or leave deleted-cell padding behind.
        let end = trailing ? NSMaxRange(bounds) - 1 : source.length
        guard start <= end else { return nil }
        let internalPipes = separators.filter { $0 >= start && $0 < end }
        var cells: [NSRange] = [], contents: [NSRange] = []
        var cellStart = start
        for edge in internalPipes + [end] {
            let range = NSRange(location: cellStart, length: edge - cellStart)
            cells.append(range)
            let value = source.substring(with: range)
            let content = value.trimmingCharacters(in: .whitespaces)
            if content.isEmpty {
                contents.append(NSRange(location: cellStart + min(1, range.length), length: 0))
            } else {
                let relative = (value as NSString).range(of: content, options: .literal)
                contents.append(NSRange(location: cellStart + relative.location, length: relative.length))
            }
            cellStart = edge + 1
        }
        return Row(body: body, cells: cells, contents: contents,
                   leadingPipe: leading, trailingPipe: trailing, indent: indent)
    }
}
