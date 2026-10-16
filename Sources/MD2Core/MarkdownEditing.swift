import Foundation

/// Pure source edits. All ranges use UTF-16, just like NSTextView; nil means
/// the caller should use the native text-editing behavior.
public enum MarkdownEditing {
    public enum Action: Equatable, Sendable {
        case newline, softNewline, indent, outdent, deleteBackward
        case type(String)
        case bold, italic, link, heading(Int), codeBlock, table
    }

    public struct Edit: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String
        public let selection: NSRange
    }

    public static func edit(
        _ text: String, selection: NSRange, action: Action, clipboard: String? = nil
    ) -> Edit? {
        // Ordinary letters take the native path without walking a large source
        // string to translate its selection into Swift indices.
        if case .type(let input) = action,
           input.utf16.count != 1 || (pairs[input] == nil && !pairs.values.contains(input)) { return nil }
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= source.length, selection.length <= source.length - selection.location,
              Range(selection, in: text) != nil else { return nil }
        for boundary in [selection.location, NSMaxRange(selection)] where boundary > 0 && boundary < source.length {
            guard !UTF16.isLeadSurrogate(source.character(at: boundary - 1)) ||
                    !UTF16.isTrailSurrogate(source.character(at: boundary)) else { return nil }
        }
        switch action {
        case .newline, .softNewline:
            return newline(source, selection, soft: action == .softNewline)
        case .indent, .outdent:
            return indent(source, selection, outdent: action == .outdent)
        case .bold: return wrap(source, selection, marker: "**")
        case .italic: return wrap(source, selection, marker: "*")
        case .link: return link(source, selection, clipboard: clipboard)
        case .heading(let level): return heading(source, selection, level: level)
        case .codeBlock: return block(source, selection, table: false)
        case .table: return block(source, selection, table: true)
        case .type(let input): return pair(source, selection, input: input)
        case .deleteBackward:
            guard selection.length == 0, selection.location > 0, selection.location < source.length else { return nil }
            let left = source.substring(with: NSRange(location: selection.location - 1, length: 1))
            let right = source.substring(with: NSRange(location: selection.location, length: 1))
            guard pairs[left] == right, !isEscaped(source, at: selection.location - 1) else { return nil }
            return replacing(NSRange(location: selection.location - 1, length: 2), with: "")
        }
    }

    private static func replacing(_ range: NSRange, with replacement: String, selection: NSRange? = nil) -> Edit {
        Edit(range: range, replacement: replacement,
             selection: selection ?? NSRange(location: range.location + replacement.utf16.count, length: 0))
    }

    private struct Line {
        let range: NSRange
        let body: String
        let ending: String
        var prefix: Prefix { Prefix(body) }
    }

    private static func line(_ source: NSString, at location: Int) -> Line {
        var start = 0, end = 0, contentsEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
        return Line(range: NSRange(location: start, length: end - start),
                    body: source.substring(with: NSRange(location: start, length: contentsEnd - start)),
                    ending: source.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
    }

    private static func lines(_ source: NSString, through location: Int) -> [Line] {
        var result: [Line] = [], start = 0
        while start <= location {
            let current = line(source, at: start)
            // NSString reports the preceding line at EOF without a final
            // newline. Do not count that line twice as its own list parent.
            guard current.range.location == start else { break }
            result.append(current)
            guard NSMaxRange(current.range) > start else { break }
            start = NSMaxRange(current.range)
        }
        return result
    }

    private struct Marker {
        let range: NSRange
        let quote: Bool
        let next: String
        let continuation: String
    }

    private struct Prefix {
        let source: NSString
        var markers: [Marker] = []
        var end = 0
        var quoteCount: Int { markers.filter(\.quote).count }
        var list: Marker? { markers.last(where: { !$0.quote }) }
        var containerQuotes: [Marker] {
            markers.filter { $0.quote && $0.range.location < (list?.range.location ?? source.length) }
        }
        var indentStart: Int { containerQuotes.last.map { NSMaxRange($0.range) } ?? 0 }
        var indent: Int {
            MarkdownIndentation.width(String(source.substring(from: indentStart).prefix { $0 == " " || $0 == "\t" }))
        }

        init(_ text: String) {
            source = text as NSString
            var offset = 0
            while offset < source.length {
                while offset < source.length, [32, 9].contains(source.character(at: offset)) { offset += 1 }
                guard offset < source.length else { break }
                let tail = source.substring(from: offset)
                if tail.hasPrefix(">") {
                    let count = tail.hasPrefix("> ") || tail.hasPrefix(">\t") ? 2 : 1
                    let raw = source.substring(with: NSRange(location: offset, length: count))
                    markers.append(Marker(range: NSRange(location: offset, length: count), quote: true,
                                          next: raw == ">" ? "> " : raw, continuation: raw))
                    offset += count
                } else if let match = tail.range(of: #"^(?:[-*+]|[0-9]{1,9}[.)])[ \t]+"#, options: .regularExpression) {
                    let raw = String(tail[match])
                    let delimiter = String(raw.prefix { $0 != " " && $0 != "\t" })
                    let gap = String(raw.dropFirst(delimiter.count))
                    var next = raw
                    if let number = Int(delimiter.dropLast()), let punctuation = delimiter.last {
                        next = "\(number + 1)\(punctuation)\(gap)"
                    }
                    var count = raw.utf16.count
                    let rest = source.substring(from: offset + count)
                    if let task = rest.range(of: #"^\[[ xX]\](?:[ \t]+|$)"#, options: .regularExpression) {
                        count += rest[task].utf16.count
                        next += "[ ] "
                    }
                    let width = MarkdownIndentation.contentColumn(markerIndent: 0, delimiterWidth: delimiter.count, gap: gap)
                    markers.append(Marker(range: NSRange(location: offset, length: count), quote: false,
                                          next: next, continuation: String(repeating: " ", count: width)))
                    offset += count
                } else { break }
            }
            end = offset
            // A thematic break is not an empty nested list.
            if MarkdownLine.isHorizontalRule(text) { markers = []; end = 0 }
        }

        func continued(soft: Bool) -> String {
            var result = "", previous = 0
            for (index, marker) in markers.enumerated() {
                result += source.substring(with: NSRange(location: previous, length: marker.range.location - previous))
                result += marker.quote || (!soft && index == markers.count - 1) ? marker.next : marker.continuation
                previous = NSMaxRange(marker.range)
            }
            result += source.substring(with: NSRange(location: previous, length: end - previous))
            return result
        }
    }

    private static func newline(_ source: NSString, _ selection: NSRange, soft: Bool) -> Edit {
        let current = line(source, at: selection.location)
        let prefix = current.prefix
        let beforeCaret = (current.body as NSString).substring(to: min(selection.location - current.range.location, current.body.utf16.count))
        let history = lines(source, through: selection.location)
        let ending = current.ending.isEmpty ? (history.last(where: { !$0.ending.isEmpty })?.ending ?? "\n") : current.ending
        if let code = codeContext(history) {
            if code.isOpeningFence {
                return replacing(selection, with: ending + prefix.continued(soft: true))
            }
            // Quotes are containers, not code indentation. Retain them, but
            // never interpret a literal '- ' or '1. ' inside a fence as a list.
            let quoteEnd = prefix.markers.filter(\.quote).prefix(code.quotes).last.map { NSMaxRange($0.range) } ?? 0
            let head = (beforeCaret as NSString).substring(to: min(quoteEnd, beforeCaret.utf16.count))
            let rest = String(beforeCaret.dropFirst(head.count))
            return replacing(selection, with: ending + head + rest.prefix { $0 == " " || $0 == "\t" })
        }
        guard selection.location - current.range.location >= prefix.end else {
            return replacing(selection, with: ending)
        }
        if !soft, selection.length == 0, let last = prefix.markers.last,
           (current.body as NSString).substring(from: prefix.end).trimmingCharacters(in: .whitespaces).isEmpty {
            // Exit one container at a time: '> - ' becomes '> ', then ''.
            return replacing(NSRange(location: current.range.location + last.range.location,
                                     length: current.body.utf16.count - last.range.location), with: "")
        }
        if !soft, prefix.list == nil, let parent = enclosingList(history) {
            return replacing(selection, with: ending + parent.prefix.continued(soft: false))
        }
        return replacing(selection, with: ending + prefix.continued(soft: soft))
    }

    /// A content-column continuation belongs to the nearest enclosing item.
    /// This also keeps Return after a Shift-Return in that item's list.
    private static func enclosingList(_ history: [Line]) -> Line? {
        guard let current = history.last else { return nil }
        let prefix = current.prefix
        for candidate in history.dropLast().reversed() {
            if candidate.body.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let other = candidate.prefix
            guard other.containerQuotes.count == prefix.containerQuotes.count else { break }
            if let marker = other.list, other.indent < prefix.indent,
               other.indent + marker.continuation.count <= prefix.indent { return candidate }
            if other.indent < prefix.indent { break }
        }
        return nil
    }

    /// Tracks fences with their quote/list container. A list-looking line in a
    /// fence is literal text, and leaving the container ends an unclosed fence.
    private struct CodeContext {
        let quotes: Int
        var isOpeningFence = false
    }

    private static func codeContext(_ history: [Line]) -> CodeContext? {
        var fence: (character: Character, count: Int, quotes: Int, indent: Int, line: Int)?
        for current in history {
            let prefix = current.prefix
            let quoteEnd = prefix.markers.filter(\.quote).prefix(fence?.quotes ?? prefix.quoteCount).last.map { NSMaxRange($0.range) } ?? 0
            let unquoted = (current.body as NSString).substring(from: quoteEnd)
            if let active = fence {
                if prefix.quoteCount < active.quotes || (!unquoted.trimmingCharacters(in: .whitespaces).isEmpty &&
                    MarkdownIndentation.width(unquoted) < active.indent) {
                    fence = nil
                } else {
                    let trimmed = unquoted.trimmingCharacters(in: .whitespaces)
                    let run = trimmed.prefix { $0 == active.character }
                    if run.count >= active.count, trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                        fence = nil
                    }
                    continue
                }
            }
            let content = (current.body as NSString).substring(from: prefix.end)
            if let first = content.first, first == "`" || first == "~" {
                let count = content.prefix { $0 == first }.count
                if count >= 3, first != "`" || !content.dropFirst(count).contains("`") {
                    let required = prefix.list.flatMap { marker -> Int? in
                        guard marker.range.location >= quoteEnd else { return nil }
                        return MarkdownIndentation.width((current.body as NSString).substring(with:
                            NSRange(location: quoteEnd, length: max(0, marker.range.location - quoteEnd))))
                            + marker.continuation.count
                    } ?? 0
                    fence = (first, count, prefix.quoteCount, required, current.range.location)
                }
            }
        }
        if let fence {
            return CodeContext(quotes: fence.quotes, isOpeningFence: fence.line == history.last?.range.location)
        }
        guard let current = history.last, current.prefix.indent >= 4 else { return nil }
        // Four-space code outside a list; within a list, use its content column.
        if let parent = enclosingList(history), let marker = parent.prefix.list {
            let column = parent.prefix.indent + marker.continuation.count
            return current.prefix.indent >= column + 4 ? CodeContext(quotes: current.prefix.quoteCount) : nil
        }
        return CodeContext(quotes: current.prefix.containerQuotes.count)
    }

    private struct Change {
        let range: NSRange
        let text: String
    }

    private static func changedLines(_ source: NSString, _ selection: NSRange, changes: [Change]) -> Edit? {
        guard let first = changes.first, let last = changes.last else { return nil }
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let replacement = NSMutableString(string: source.substring(with: range))
        for change in changes.reversed() {
            replacement.replaceCharacters(in: NSRange(location: change.range.location - range.location, length: change.range.length), with: change.text)
        }
        func mapped(_ position: Int) -> Int {
            var delta = 0
            for change in changes {
                if position < change.range.location { break }
                if position < NSMaxRange(change.range) { return change.range.location + delta + change.text.utf16.count }
                delta += change.text.utf16.count - change.range.length
            }
            return position + delta
        }
        let start = mapped(selection.location), end = mapped(NSMaxRange(selection))
        return replacing(range, with: replacement as String, selection: NSRange(location: start, length: end - start))
    }

    private static func selectedLines(_ source: NSString, _ selection: NSRange) -> [Line] {
        if selection.length == 0 { return [line(source, at: selection.location)] }
        let last = NSMaxRange(selection) - 1
        return lines(source, through: last).filter { NSMaxRange($0.range) > selection.location || $0.range.location == selection.location }
    }

    private static func indent(_ source: NSString, _ selection: NSRange, outdent: Bool) -> Edit? {
        var selected = selectedLines(source, selection)
        guard let first = selected.first, let marker = first.prefix.list,
              codeContext(lines(source, through: first.range.location)) == nil else { return nil }
        let prefix = first.prefix
        let previous = lines(source, through: first.range.location).dropLast().reversed().first {
            !$0.body.trimmingCharacters(in: .whitespaces).isEmpty && $0.prefix.containerQuotes.count == prefix.containerQuotes.count &&
                $0.prefix.indent <= prefix.indent && (!outdent || $0.prefix.indent < prefix.indent)
        }
        let target: Int
        if outdent {
            guard prefix.indent > 0 else {
                return replacing(NSRange(location: selection.location, length: 0), with: "", selection: selection)
            }
            if let previous, previous.prefix.list != nil {
                target = previous.prefix.indent
            } else {
                target = max(0, prefix.indent - 4)
            }
        } else if let previous, let parentMarker = previous.prefix.list, previous.prefix.indent == prefix.indent {
            target = prefix.indent + parentMarker.continuation.count
        } else {
            target = prefix.indent + max(2, marker.continuation.count)
        }
        let delta = target - prefix.indent
        // Move the selected item's descendants and continuation lines with it.
        if let last = selected.last {
            var next = NSMaxRange(last.range)
            while next < source.length {
                let candidate = line(source, at: next)
                guard candidate.prefix.containerQuotes.count == prefix.containerQuotes.count, candidate.prefix.indent > prefix.indent else { break }
                selected.append(candidate)
                next = NSMaxRange(candidate.range)
            }
        }
        let changes = selected.compactMap { current -> Change? in
            let p = current.prefix
            guard p.containerQuotes.count == prefix.containerQuotes.count else { return nil }
            let whitespace = (current.body as NSString).substring(from: p.indentStart).prefix { $0 == " " || $0 == "\t" }
            return Change(range: NSRange(location: current.range.location + p.indentStart, length: whitespace.utf16.count),
                          text: String(repeating: " ", count: max(0, p.indent + delta)))
        }
        return changedLines(source, selection, changes: changes)
    }

    private static func wrap(_ source: NSString, _ selection: NSRange, marker: String) -> Edit {
        let selected = source.substring(with: selection), width = marker.utf16.count
        let selectedLeftRun = selected.prefix { $0 == "*" }.count
        let selectedRightRun = selected.reversed().prefix { $0 == "*" }.count
        if selected.hasPrefix(marker), selected.hasSuffix(marker), selection.length >= width * 2,
           width == 2 || (selectedLeftRun % 2 == 1 && selectedRightRun % 2 == 1) {
            let content = (selected as NSString).substring(with: NSRange(location: width, length: selection.length - width * 2))
            return replacing(selection, with: content, selection: NSRange(location: selection.location, length: content.utf16.count))
        }
        if selection.location >= width, NSMaxRange(selection) + width <= source.length,
           source.substring(with: NSRange(location: selection.location - width, length: width)) == marker,
           source.substring(with: NSRange(location: NSMaxRange(selection), length: width)) == marker {
            let leftRun = source.substring(to: selection.location).reversed().prefix { $0 == "*" }.count
            let rightRun = source.substring(from: NSMaxRange(selection)).prefix { $0 == "*" }.count
            if width == 2 || (leftRun % 2 == 1 && rightRun % 2 == 1) {
                return replacing(NSRange(location: selection.location - width, length: selection.length + 2 * width),
                                 with: selected, selection: NSRange(location: selection.location - width, length: selection.length))
            }
        }
        return replacing(selection, with: marker + selected + marker,
                         selection: NSRange(location: selection.location + width, length: selection.length))
    }

    private static func link(_ source: NSString, _ selection: NSRange, clipboard: String?) -> Edit {
        let selected = source.substring(with: selection)
        // Toggle either a whole selected link or just its selected label.
        let whole = selected as NSString
        if selected.hasPrefix("["), let split = selected.range(of: "]("), selected.hasSuffix(")") {
            let label = String(selected[selected.index(after: selected.startIndex)..<split.lowerBound])
            let suffix = whole.substring(from: NSRange(split, in: selected).location + 1)
            if destinationLength(suffix) == suffix.utf16.count {
                return replacing(selection, with: label, selection: NSRange(location: selection.location, length: label.utf16.count))
            }
        }
        if selection.location > 0, source.character(at: selection.location - 1) == 91,
           NSMaxRange(selection) < source.length, source.character(at: NSMaxRange(selection)) == 93,
           let count = destinationLength(source.substring(from: NSMaxRange(selection) + 1)) {
            return replacing(NSRange(location: selection.location - 1, length: selection.length + count + 2), with: selected,
                             selection: NSRange(location: selection.location - 1, length: selection.length))
        }
        let url = clipboardURL(clipboard)
        let replacement = "[\(selected)](\(url ?? ""))"
        let caret = selection.length == 0 ? selection.location + 1 : selection.location + selection.length + 3
        return replacing(selection, with: replacement,
                         selection: url != nil && selection.length > 0
                            ? NSRange(location: selection.location + 1, length: selection.length)
                            : NSRange(location: caret, length: 0))
    }

    private static func destinationLength(_ string: String) -> Int? {
        guard string.first == "(" else { return nil }
        var depth = 0, escaped = false, length = 0
        for char in string {
            length += char.utf16.count
            if escaped { escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "(" { depth += 1 }
            if char == ")" { depth -= 1; if depth == 0 { return length } }
            if char.isNewline { return nil }
        }
        return nil
    }

    private static func clipboardURL(_ string: String?) -> String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains(where: \.isWhitespace),
              let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
              (["http", "https"].contains(scheme) && !(url.host ?? "").isEmpty) ||
                (scheme == "mailto" && url.path.contains("@")) else { return nil }
        return value.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    private static func heading(_ source: NSString, _ selection: NSRange, level: Int) -> Edit? {
        guard (0...6).contains(level) else { return nil }
        let changes = selectedLines(source, selection).map { current -> Change in
            let offset = current.prefix.end
            let tail = (current.body as NSString).substring(from: offset)
            let old = tail.range(of: #"^#{1,6}(?:[ \t]+|$)"#, options: .regularExpression).map { NSRange($0, in: tail).length } ?? 0
            return Change(range: NSRange(location: current.range.location + offset, length: old),
                          text: level == 0 ? "" : String(repeating: "#", count: level) + " ")
        }
        return changedLines(source, selection, changes: changes)
    }

    private static func block(_ source: NSString, _ selection: NSRange, table: Bool) -> Edit {
        let selected = source.substring(with: selection)
        let ending = line(source, at: selection.location).ending
        let newline = ending.isEmpty ? "\n" : ending
        let leading = selection.location > 0 && ![10, 13].contains(source.character(at: selection.location - 1)) ? newline : ""
        let trailing = NSMaxRange(selection) < source.length && ![10, 13].contains(source.character(at: NSMaxRange(selection))) ? newline : ""
        if table {
            let header = selected.isEmpty ? "Column 1" : selected.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "|", with: "\\|")
            let body = "| \(header) | Column 2 |\(newline)| --- | --- |\(newline)|  |  |"
            return replacing(selection, with: leading + body + trailing,
                             selection: NSRange(location: selection.location + leading.utf16.count + 2, length: header.utf16.count))
        }
        let longestRun = selected.components(separatedBy: CharacterSet(charactersIn: "`").inverted).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        let body = fence + newline + selected + (selected.hasSuffix(newline) ? "" : newline) + fence
        return replacing(selection, with: leading + body + trailing,
                         selection: NSRange(location: selection.location + leading.utf16.count + fence.count + newline.utf16.count, length: selection.length))
    }

    private static let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`", "（": "）", "「": "」", "《": "》"]

    private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
        var index = location, count = 0
        while index > 0, source.character(at: index - 1) == 92 { count += 1; index -= 1 }
        return count % 2 == 1
    }

    private static func pair(_ source: NSString, _ selection: NSRange, input: String) -> Edit? {
        guard input.utf16.count == 1, pairs[input] != nil || pairs.values.contains(input),
              !isEscaped(source, at: selection.location) else { return nil }
        if selection.length == 0, selection.location < source.length, pairs.values.contains(input),
           source.substring(with: NSRange(location: selection.location, length: 1)) == input {
            return replacing(selection, with: "", selection: NSRange(location: selection.location + 1, length: 0))
        }
        guard let closing = pairs[input] else { return nil }
        if selection.length == 0 {
            let before = source.substring(to: selection.location).last
            let after = source.substring(from: selection.location).first
            if after?.isLetter == true || after?.isNumber == true { return nil }
            if input == closing, before?.isLetter == true || before?.isNumber == true || before == "`" { return nil }
        }
        return replacing(selection, with: input + source.substring(with: selection) + closing,
                         selection: NSRange(location: selection.location + input.utf16.count, length: selection.length))
    }
}

/// Shared with the renderer: tabs occupy four columns; marker gaps of five or
/// more spaces start code rather than pushing the list content column out.
enum MarkdownIndentation {
    static func width(_ string: String) -> Int {
        string.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    static func contentColumn(markerIndent: Int, delimiterWidth: Int, gap: String) -> Int {
        let width = width(gap)
        return markerIndent + delimiterWidth + (width >= 5 ? 1 : max(width, 1))
    }
}
