import Foundation

/// Bounded, source-preserving table editing. No renderer or AppKit dependency.
public enum MarkdownTableEditing {
    public enum Action: Equatable, Sendable {
        case nextCell, previousCell
        case insertRowAbove, insertRowBelow, deleteRow
        case insertColumnBefore, insertColumnAfter, deleteColumn
    }
    public enum Rejection: Error, Equatable, Sendable {
        case unsupported, selection, header, lastColumn, budget
    }
    // A key press never scans an unbounded source or rewrites an unbounded table.
    public static let maximumSourceUTF16 = 500_000
    public static let maximumTableUTF16 = 100_000
    public static let maximumRows = 1_000
    public static let maximumColumns = 128
    public static let maximumCells = 20_000
    public static let maximumSourceLines = 20_000

    struct Line {
        let start: Int
        let body: String
        let ending: String
        var end: Int { start + body.utf16.count + ending.utf16.count }
    }
    struct Table {
        let lines: [Line]
        let rows: [MarkdownTableSyntax.Row]
        let row: Int
        let column: Int
        let sourceUnits: Int
        let sourceLines: Int
    }

    public static func edit(_ text: String, selection: NSRange, action: Action) -> MarkdownEditing.Edit? {
        try? result(text, selection: selection, action: action).get()
    }

    public static func result(_ text: String, selection: NSRange, action: Action) -> Result<MarkdownEditing.Edit, Rejection> {
        do { return .success(try transform(text, selection: selection, action: action)) }
        catch let reason as Rejection { return .failure(reason) }
        catch { return .failure(.unsupported) }
    }

    private static func table(_ text: String, selection: NSRange) throws -> Table {
        let source = text as NSString
        guard source.length <= maximumSourceUTF16 else { throw Rejection.budget }
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= source.length, selection.length <= source.length - selection.location else { throw Rejection.selection }
        for boundary in [selection.location, NSMaxRange(selection)] where boundary > 0 && boundary < source.length {
            if UTF16.isLeadSurrogate(source.character(at: boundary - 1)), UTF16.isTrailSurrogate(source.character(at: boundary)) {
                throw Rejection.selection
            }
        }
        guard text.contains("|") else { throw Rejection.unsupported }
        var lines: [Line] = []
        var position = 0, start = 0
        while position < source.length {
            let unit = source.character(at: position)
            guard unit == 10 || unit == 13 else { position += 1; continue }
            let contentEnd = position
            position += 1
            if unit == 13, position < source.length, source.character(at: position) == 10 { position += 1 }
            lines.append(Line(start: start, body: source.substring(with: NSRange(location: start, length: contentEnd - start)),
                              ending: source.substring(with: NSRange(location: contentEnd, length: position - contentEnd))))
            guard lines.count <= maximumSourceLines else { throw Rejection.budget }
            start = position
        }
        if start < source.length {
            lines.append(Line(start: start, body: source.substring(from: start), ending: ""))
            guard lines.count <= maximumSourceLines else { throw Rejection.budget }
        }
        guard let current = lines.firstIndex(where: {
            selection.location >= $0.start && selection.location <= $0.start + $0.body.utf16.count
        }), NSMaxRange(selection) <= lines[current].start + lines[current].body.utf16.count else { throw Rejection.selection }
        guard lines[current].body.contains("|") else { throw Rejection.unsupported }
        var first = current, last = current
        while first > 0, lines[first - 1].body.contains("|") {
            first -= 1
            guard current - first < maximumRows else { throw Rejection.budget }
        }
        while last + 1 < lines.count, lines[last + 1].body.contains("|") {
            last += 1
            guard last - first + 1 <= maximumRows else { throw Rejection.budget }
        }
        let selected = Array(lines[first...last])
        guard selected.last!.end - selected[0].start <= maximumTableUTF16 else { throw Rejection.budget }
        guard selected.count >= 2,
              MarkdownEditing.supportsTopLevelTable(source, at: selected[0].start),
              safeBlockContext(Array(lines[..<first])) else { throw Rejection.unsupported }
        let rows = try selected.map { line -> MarkdownTableSyntax.Row in
            guard let row = MarkdownTableSyntax.row(line.body) else { throw Rejection.unsupported }
            return row
        }
        guard rows[1].isDelimiter, !rows[0].isDelimiter else { throw Rejection.unsupported }
        let count = rows[0].cells.count
        guard count <= maximumColumns else { throw Rejection.budget }
        guard rows.count <= maximumCells / count else { throw Rejection.budget }
        guard rows.allSatisfy({ $0.cells.count == count && $0.indent == rows[0].indent }) else { throw Rejection.unsupported }
        let rowIndex = current - first
        guard rowIndex != 1 else { throw Rejection.selection }
        let local = NSRange(location: selection.location - selected[rowIndex].start, length: selection.length)
        guard let column = rows[rowIndex].cells.firstIndex(where: {
            local.location >= $0.location && NSMaxRange(local) <= NSMaxRange($0)
        }) else { throw Rejection.selection }
        return Table(lines: selected, rows: rows, row: rowIndex, column: column,
                     sourceUnits: source.length, sourceLines: lines.count)
    }

    /// Conservatively excludes raw block containers. Fence/list semantics are
    /// delegated to MarkdownEditing's existing shared context checks.
    private static func safeBlockContext(_ lines: [Line]) -> Bool {
        let context = paragraphContext(lines)
        var comment = false
        var tags: [String] = []
        var math: String?
        var frontMatter = lines.first?.body == "---"
        let expression = try! NSRegularExpression(pattern: #"</?(?:address|article|aside|blockquote|body|details|dialog|div|dl|fieldset|figure|footer|form|h[1-6]|header|html|iframe|main|nav|ol|p|pre|script|section|style|summary|table|ul)(?=[\s/>]|$)[^>]*(?:>|$)"#, options: [.caseInsensitive])
        for (index, line) in lines.enumerated() {
            let body = line.body
            if frontMatter {
                if index > 0, ["---", "..."].contains(body.trimmingCharacters(in: .whitespaces)) { frontMatter = false }
                continue
            }
            // Tags inside completed blocks do not open a later top-level HTML
            // block. An already-open raw HTML/comment scope still owns its
            // contents, including any Markdown-looking closing-tag line.
            if !comment, tags.isEmpty, math == nil, !context.inspectHTML[index] { continue }
            var visible = ""
            let prose = !comment && tags.isEmpty ? context.masked[index] : body
            var remainder = prose[...]
            while !remainder.isEmpty {
                if comment {
                    guard let end = remainder.range(of: "-->") else { break }
                    remainder = remainder[end.upperBound...]; comment = false
                } else if let opening = remainder.range(of: "<!--") {
                    visible += remainder[..<opening.lowerBound]
                    remainder = remainder[opening.upperBound...]; comment = true
                } else { visible += remainder; break }
            }
            let trimmed = visible.trimmingCharacters(in: .whitespaces)
            if let closer = math {
                if trimmed.contains(closer) { math = nil }
                continue
            }
            if trimmed == "$$" { math = "$$"; continue }
            if trimmed == #"\["# { math = #"\]"#; continue }
            let ns = visible as NSString
            for match in expression.matches(in: visible, range: NSRange(location: 0, length: ns.length)) {
                let token = ns.substring(with: match.range).lowercased()
                let closing = token.hasPrefix("</")
                let name = String(token.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber })
                if closing {
                    if let position = tags.lastIndex(of: name) { tags.removeSubrange(position...) }
                } else if !token.hasSuffix("/>") { tags.append(name) }
            }
        }
        return !comment && tags.isEmpty && math == nil && !frontMatter
    }

    /// Locate inline ownership using the renderer's block ordering and shared
    /// line grammar. Only an ordinary paragraph can own a code span across
    /// lines; headings, tables, rules and containers are completed scopes.
    /// Indented lines do not interrupt an already-started paragraph, matching
    /// MarkdownRenderer.paragraphBlock rather than treating every indent as code.
    private static func paragraphContext(_ lines: [Line]) -> (masked: [String], inspectHTML: [Bool]) {
        let bodies = lines.map(\.body)
        let trimmed = bodies.map { $0.trimmingCharacters(in: .whitespaces) }
        var result = bodies, inspectHTML = Array(repeating: false, count: lines.count)
        let headings = bodies.map { MarkdownLine.heading(in: $0) != nil }
        let rules = bodies.map(MarkdownLine.isHorizontalRule)
        let quotes = trimmed.map(MarkdownLine.isBlockquote)
        let indented = bodies.map(MarkdownLine.isIndentedCode)
        let fences = bodies.map(MarkdownFence.opening)
        let listColumns = bodies.map(MarkdownEditing.tableListContentColumn)
        let footnotes = bodies.map { $0.range(of: #"^ {0,3}\[\^([^\]\s]+)\]:"#, options: .regularExpression) != nil }
        var tableStarts = Array(repeating: false, count: lines.count)
        var setextStarts = tableStarts
        for index in lines.indices where index + 1 < lines.count {
            tableStarts[index] = bodies[index].contains("|") && MarkdownTableSyntax.row(bodies[index + 1])?.isDelimiter == true
            setextStarts[index] = !trimmed[index].isEmpty && !headings[index] && fences[index] == nil
                && !rules[index] && listColumns[index] == nil && !quotes[index]
                && MarkdownLine.setextHeadingLevel(in: bodies[index + 1]) != nil
        }
        // Precompute closers so many unmatched math openers cannot cause
        // quadratic lookahead. These are the same fixed block delimiters.
        var mathEnds: [Int: Int] = [:]
        for (opening, closing) in [("$$", "$$"), (#"\["#, #"\]"#)] {
            var nextClose: Int?
            for index in lines.indices.reversed() {
                if trimmed[index].hasPrefix(opening) {
                    let rest = trimmed[index].dropFirst(opening.count)
                    if rest.hasSuffix(closing) { mathEnds[index] = index + 1 }
                    else if let nextClose { mathEnds[index] = nextClose + 1 }
                }
                if trimmed[index].hasSuffix(closing) { nextClose = index }
            }
        }
        func paragraphBreak(_ index: Int) -> Bool {
            trimmed[index].isEmpty || headings[index] || fences[index] != nil || rules[index]
                || setextStarts[index] || trimmed[index] == "[TOC]" || quotes[index]
                || footnotes[index] || listColumns[index] != nil || mathEnds[index] != nil || tableStarts[index]
        }
        func mask(_ range: Range<Int>) {
            let text = range.map { bodies[$0] }.joined(separator: "\n")
            let masked = maskingInlineCode(text) as NSString
            var offset = 0
            for index in range {
                let length = bodies[index].utf16.count
                result[index] = masked.substring(with: NSRange(location: offset, length: length))
                inspectHTML[index] = true
                offset += length + 1
            }
        }
        var index = 0
        while index < lines.count {
            if trimmed[index].isEmpty { index += 1; continue }
            if let fence = fences[index] {
                index += 1
                while index < lines.count {
                    let closed = fence.isClosed(by: bodies[index]); index += 1
                    if closed { break }
                }
                continue
            }
            if quotes[index] {
                repeat { index += 1 } while index < lines.count && quotes[index]
                continue
            }
            if indented[index] {
                repeat { index += 1 } while index < lines.count && (indented[index] || trimmed[index].isEmpty)
                continue
            }
            if let end = mathEnds[index] { index = end; continue }
            if trimmed[index].hasPrefix("["), let definition = LinkReference.parse(bodies, at: index) {
                index = definition.next; continue
            }
            if trimmed[index] == "[TOC]" { index += 1; continue }
            if tableStarts[index] {
                index += 2
                while index < lines.count, bodies[index].contains("|") { index += 1 }
                // A labeled caption is rendered inside the preceding table,
                // so its inline span cannot extend into the next paragraph.
                if index < lines.count,
                   bodies[index].range(of: #"^\s*:\s+(.+?)\s*\{#(tbl:[A-Za-z0-9_.\-]+)\}\s*$"#, options: .regularExpression) != nil {
                    mask(index..<(index + 1)); index += 1
                }
                continue
            }
            // Headings own inline spans only within their title. Retain the
            // conservative raw-HTML refusal even for a raw tag in that title;
            // an unmatched title tick may never claim the next block.
            if setextStarts[index] { mask(index..<(index + 1)); index += 2; continue }
            if headings[index] { mask(index..<(index + 1)); index += 1; continue }
            if rules[index] { index += 1; continue }
            if footnotes[index] {
                index += 1
                while index < lines.count {
                    var next = index
                    while next < lines.count, trimmed[next].isEmpty { next += 1 }
                    guard next < lines.count, MarkdownIndentation.width(bodies[next]) >= 2 else { break }
                    index = next + 1
                }
                continue
            }
            if let column = listColumns[index] {
                var fence = MarkdownEditing.tableListOpeningFence(bodies[index])
                index += 1
                while index < lines.count {
                    if let active = fence {
                        if active.isClosed(by: bodies[index]) { fence = nil }
                        index += 1; continue
                    }
                    var next = index
                    while next < lines.count, trimmed[next].isEmpty { next += 1 }
                    guard next < lines.count, MarkdownIndentation.width(bodies[next]) >= column else { break }
                    fence = fences[next]
                    index = next + 1
                }
                continue
            }
            if trimmed[index].hasPrefix("!["), trimmed[index].contains("#fig:"),
               trimmed[index].range(of: #"^!\[[^\]]*\]\([^)]*\)\{[^}]*#fig:[^}]*\}$"#, options: .regularExpression) != nil {
                index += 1; continue
            }
            let start = index
            index += 1
            while index < lines.count, !paragraphBreak(index) { index += 1 }
            mask(start..<index)
        }
        return (result, inspectHTML)
    }

    /// Ignore closed code spans when looking for raw block HTML. Pair maximal
    /// backtick runs once, including multiple-backtick spans in preceding prose;
    /// unmatched runs stay literal and comments retain their own delimiters.
    private static func maskingInlineCode(_ text: String) -> String {
        let source = text as NSString
        var runs: [(start: Int, end: Int)] = []
        var cursor = 0
        while cursor < source.length {
            guard source.character(at: cursor) == 96 else { cursor += 1; continue }
            let start = cursor
            while cursor < source.length, source.character(at: cursor) == 96 { cursor += 1 }
            runs.append((start, cursor))
        }
        guard runs.count > 1 else { return text }
        var latest: [Int: Int] = [:], closers: [Int: Int] = [:]
        for index in runs.indices.reversed() {
            let length = runs[index].end - runs[index].start
            if let next = latest[length] { closers[runs[index].start] = runs[next].end }
            latest[length] = index
        }
        let masked = NSMutableString(string: text)
        cursor = 0
        while cursor < source.length {
            if cursor + 4 <= source.length,
               source.character(at: cursor) == 60, source.character(at: cursor + 1) == 33,
               source.character(at: cursor + 2) == 45, source.character(at: cursor + 3) == 45 {
                let closing = source.range(of: "-->", range: NSRange(location: cursor + 4, length: source.length - cursor - 4))
                guard closing.location != NSNotFound else { break }
                cursor = NSMaxRange(closing)
            } else if let end = closers[cursor] {
                masked.replaceCharacters(in: NSRange(location: cursor, length: end - cursor),
                                         with: String(repeating: " ", count: end - cursor))
                cursor = end
            } else { cursor += 1 }
        }
        return masked as String
    }

    private static func transform(_ text: String, selection: NSRange, action: Action) throws -> MarkdownEditing.Edit {
        let table = try table(text, selection: selection)
        let rows = table.rows, lines = table.lines
        let row = table.row, column = table.column, columns = rows[0].cells.count
        var bodies = lines.map(\.body), endings = lines.map(\.ending)
        var targetRow = row, targetColumn = column
        func navigation(_ r: Int, _ c: Int) -> MarkdownEditing.Edit {
            let range = rows[r].contents[c]
            return MarkdownEditing.Edit(range: NSRange(location: selection.location, length: 0), replacement: "",
                selection: NSRange(location: lines[r].start + range.location, length: range.length), autoClosingPosition: nil)
        }
        func blankRow(like model: MarkdownTableSyntax.Row) -> String {
            // Empty edge cells require explicit rails; otherwise the renderer
            // consumes their separators as optional rails and loses a column.
            model.indent + "|" + Array(repeating: "  ", count: columns).joined(separator: "|") + "|"
        }
        func insertRow(at index: Int) {
            let model = rows[row]
            let newline = lines[row].ending.isEmpty ? (lines.reversed().first { !$0.ending.isEmpty }?.ending ?? "\n") : lines[row].ending
            let terminal = endings.last!
            if index == bodies.count {
                endings[endings.count - 1] = newline
                bodies.append(blankRow(like: model)); endings.append(terminal)
            } else {
                bodies.insert(blankRow(like: model), at: index); endings.insert(newline, at: index)
            }
            targetRow = index; targetColumn = 0
        }
        switch action {
        case .nextCell:
            if column + 1 < columns { return navigation(row, column + 1) }
            let next = row == 0 ? 2 : row + 1
            if next < rows.count { return navigation(next, 0) }
            insertRow(at: bodies.count)
        case .previousCell:
            if column > 0 { return navigation(row, column - 1) }
            if row > 0 { return navigation(row == 2 ? 0 : row - 1, columns - 1) }
            return MarkdownEditing.Edit(range: NSRange(location: selection.location, length: 0), replacement: "",
                                        selection: selection, autoClosingPosition: nil)
        case .insertRowAbove:
            guard row >= 2 else { throw Rejection.header }
            insertRow(at: row)
        case .insertRowBelow:
            insertRow(at: row == 0 ? 2 : row + 1)
        case .deleteRow:
            guard row >= 2 else { throw Rejection.header }
            if row == bodies.count - 1 { endings[row - 1] = endings[row] }
            bodies.remove(at: row); endings.remove(at: row)
            targetRow = bodies.count == 2 ? 0 : min(row, bodies.count - 1)
        case .insertColumnBefore, .insertColumnAfter, .deleteColumn:
            if action == .deleteColumn, columns == 1 { throw Rejection.lastColumn }
            if action != .deleteColumn, columns == maximumColumns { throw Rejection.budget }
            let insertion = column + (action == .insertColumnAfter ? 1 : 0)
            for index in rows.indices {
                let parsed = rows[index]
                let mutable = NSMutableString(string: bodies[index])
                if action == .deleteColumn {
                    let cell = parsed.cells[column]
                    let range = column + 1 < columns
                        ? NSRange(location: cell.location, length: cell.length + 1)
                        : NSRange(location: cell.location - 1, length: cell.length + 1)
                    mutable.deleteCharacters(in: range)
                    let original = parsed.body as NSString
                    let nextFirst = original.substring(with: parsed.cells[column == 0 ? 1 : 0])
                    let nextLast = original.substring(with: parsed.cells[column == columns - 1 ? columns - 2 : columns - 1])
                    // A removed edge may expose an empty cell at any width.
                    // Preserve its separator as structure, and retain leading
                    // cell padding as padding rather than block indentation.
                    // A literal ending pipe also needs a rail: the renderer
                    // otherwise strips that content pipe as its optional rail.
                    let lastContent = nextLast.trimmingCharacters(in: .whitespaces)
                    if !parsed.trailingPipe,
                       columns == 2 || (column == columns - 1 && (lastContent.isEmpty || lastContent.last == "|")) {
                        mutable.append("|")
                    }
                    if !parsed.leadingPipe,
                       columns == 2 || (column == 0 && (nextFirst.isEmpty || nextFirst.first?.isWhitespace == true)) {
                        mutable.insert("|", at: parsed.indent.utf16.count)
                    }
                } else {
                    let value = index == 1 ? " --- " : "  "
                    if insertion < columns { mutable.insert(value + "|", at: parsed.cells[insertion].location) }
                    else { mutable.insert("|" + value, at: NSMaxRange(parsed.cells.last!)) }
                    if insertion == columns, !parsed.trailingPipe { mutable.append("|") }
                    if insertion == 0, !parsed.leadingPipe { mutable.insert("|", at: parsed.indent.utf16.count) }
                }
                bodies[index] = mutable as String
            }
            targetColumn = action == .deleteColumn ? min(column, columns - 2) : insertion
        }
        let outputColumns = columns + (action == .insertColumnBefore || action == .insertColumnAfter ? 1 : action == .deleteColumn ? -1 : 0)
        guard bodies.count <= maximumRows,
              bodies.count <= maximumCells / outputColumns,
              table.sourceLines - lines.count + bodies.count <= maximumSourceLines else {
            throw Rejection.budget
        }
        let outputRows = try bodies.map { body -> MarkdownTableSyntax.Row in
            guard let parsed = MarkdownTableSyntax.row(body), parsed.cells.count == outputColumns,
                  parsed.indent == rows[0].indent else { throw Rejection.unsupported }
            return parsed
        }
        let target = outputRows[targetRow]
        guard targetColumn < target.contents.count else { throw Rejection.unsupported }
        let replacement = zip(bodies, endings).map(+).joined()
        let replacedUnits = lines.last!.end - lines[0].start
        guard replacement.utf16.count <= maximumTableUTF16,
              table.sourceUnits - replacedUnits + replacement.utf16.count <= maximumSourceUTF16 else { throw Rejection.budget }
        let targetOffset = zip(bodies.prefix(targetRow), endings.prefix(targetRow)).reduce(lines[0].start) { $0 + $1.0.utf16.count + $1.1.utf16.count }
        let content = target.contents[targetColumn]
        return MarkdownEditing.Edit(range: NSRange(location: lines[0].start, length: replacedUnits),
            replacement: replacement, selection: NSRange(location: targetOffset + content.location, length: content.length), autoClosingPosition: nil)
    }
}
