import Foundation

/// Document-local CommonMark link definitions. Labels retain escapes/entities:
/// only Unicode case folding and whitespace normalization participate in matching.
struct LinkReference {
    let destination: String
    let title: String?

    static func normalize(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func isReserved(_ label: String) -> Bool {
        let key = normalize(label)
        return key == "toc" || key.hasPrefix("^") || key.hasPrefix("@") || key.hasPrefix("!")
    }

    /// Unescape punctuation and decode entities only in destinations and titles,
    /// never in labels. URL safety is checked again at the HTML emission boundary.
    static func decode(_ text: String) -> String {
        let pattern = ##"\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])"##
        let unescaped = text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        return HTMLSafety.decodeEntities(unescaped)
    }

    static func parse(_ lines: [String], at start: Int) -> (label: String, reference: LinkReference, next: Int)? {
        guard start < lines.count else { return nil }
        var cursor = ReferenceCursor(lines: lines, line: start)
        var indent = 0
        while cursor.peek == " " { cursor.advance(); indent += 1 }
        guard indent <= 3, cursor.take("[") else { return nil }
        var label = ""
        while let char = cursor.peek, char != "]" {
            guard label.unicodeScalars.count < 999, char != "[" else { return nil }
            if char == "\n", cursor.nextLineIsBlank { return nil }
            if char == "\\" {
                label.append(char); cursor.advance()
                if let escaped = cursor.peek { label.append(escaped); cursor.advance() }
            } else {
                label.append(char); cursor.advance()
            }
        }
        guard cursor.take("]"), cursor.take(":"), !normalize(label).isEmpty,
              label.unicodeScalars.count <= 999, !isReserved(label) else { return nil }
        cursor.spaces()
        if cursor.peek == "\n" { cursor.advance(); cursor.spaces() }

        var destination = ""
        if cursor.take("<") {
            while let char = cursor.peek, char != ">" {
                guard char != "\n", char != "<" else { return nil }
                destination.append(char); cursor.advance()
                if char == "\\", let next = cursor.peek, next != "\n" {
                    destination.append(next); cursor.advance()
                }
            }
            guard cursor.take(">") else { return nil }
        } else {
            var depth = 0
            while let char = cursor.peek, !char.isWhitespace {
                guard char != "<", !char.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
                if char == "(" { depth += 1 }
                if char == ")" { depth -= 1; if depth < 0 { return nil } }
                destination.append(char); cursor.advance()
                if char == "\\", let next = cursor.peek, next != "\n" {
                    destination.append(next); cursor.advance()
                }
            }
            guard !destination.isEmpty, depth == 0 else { return nil }
        }
        let destinationEndLine = cursor.line
        let separated = cursor.peek?.isWhitespace == true
        cursor.spaces()
        let titleOnNextLine = cursor.peek == "\n"
        if titleOnNextLine { cursor.advance(); cursor.spaces() }
        let withoutTitle = (label, LinkReference(destination: decode(destination), title: nil), destinationEndLine + 1)
        guard let opener = cursor.peek, ["\"", "'", "("].contains(opener), separated else {
            return titleOnNextLine || cursor.peek == nil ? withoutTitle : nil
        }
        cursor.advance()
        let closer: Character = opener == "(" ? ")" : opener
        var title = ""
        while let char = cursor.peek, char != closer {
            if char == "\n", cursor.nextLineIsBlank { return titleOnNextLine ? withoutTitle : nil }
            if opener == "(", char == "(" { return titleOnNextLine ? withoutTitle : nil }
            title.append(char); cursor.advance()
            if char == "\\", let next = cursor.peek {
                title.append(next); cursor.advance()
            }
        }
        guard cursor.take(closer) else { return titleOnNextLine ? withoutTitle : nil }
        cursor.spaces()
        guard cursor.peek == nil || cursor.peek == "\n" else { return titleOnNextLine ? withoutTitle : nil }
        return (label, LinkReference(destination: decode(destination), title: decode(title)), cursor.line + 1)
    }
}

/// Advances through source lines without joining the entire remaining document
/// for each definition (which would make a long definition list quadratic).
private struct ReferenceCursor {
    let lines: [String]
    var line: Int
    private var column: String.Index

    init(lines: [String], line: Int) {
        self.lines = lines
        self.line = line
        column = lines[line].startIndex
    }

    var peek: Character? {
        guard line < lines.count else { return nil }
        if column < lines[line].endIndex { return lines[line][column] }
        return line + 1 < lines.count ? "\n" : nil
    }

    var nextLineIsBlank: Bool {
        line + 1 < lines.count && lines[line + 1].trimmingCharacters(in: .whitespaces).isEmpty
    }

    mutating func advance() {
        guard line < lines.count else { return }
        if column < lines[line].endIndex { column = lines[line].index(after: column) }
        else { line += 1; if line < lines.count { column = lines[line].startIndex } }
    }

    mutating func take(_ char: Character) -> Bool {
        guard peek == char else { return false }
        advance()
        return true
    }

    mutating func spaces() {
        while peek == " " || peek == "\t" { advance() }
    }
}
