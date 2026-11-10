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
        while position < NSMaxRange(bounds) {
            let character = source.character(at: position)
            if escaped { escaped = false; position += 1; continue }
            if character == 92 { escaped = true; position += 1; continue }
            if character == 96 {
                // The renderer toggles per character. Multi-backtick runs are
                // intentionally outside the safe editing subset.
                if position + 1 < NSMaxRange(bounds), source.character(at: position + 1) == 96 { return nil }
                code.toggle()
            }
            if character == 124, !code { separators.append(position) }
            position += 1
        }
        guard !code, !separators.isEmpty else { return nil }
        let leading = separators.first == bounds.location
        let trailing = separators.last == NSMaxRange(bounds) - 1
        // splitTableLine strips an ending pipe even when escaped/code-owned.
        guard source.character(at: NSMaxRange(bounds) - 1) != 124 || trailing else { return nil }
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
