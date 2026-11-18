import Foundation

/// The editable TeX of a top-level single-line `$$…$$` display formula.
/// Ranges use UTF-16 offsets in the original, unnormalized source. The Markdown
/// delimiters, adjacent whitespace and line endings lie outside the range.
public struct DisplayFormulaEdit: Equatable, Sendable {
    public let range: NSRange
    public let source: String

    /// Accept a single TeX payload without ambiguous delimiters. Trim edge
    /// whitespace so the original formula's padding still defines the layout.
    public static func validatedReplacement(_ replacement: String) -> String? {
        guard !replacement.unicodeScalars.contains(where: {
            CharacterSet.newlines.contains($0) || ($0.properties.generalCategory == .control && $0 != "\t")
        }) else { return nil }
        let tex = replacement.trimmingCharacters(in: .whitespaces)
        guard !tex.isEmpty,
              tex.unicodeScalars.first != "$", tex.unicodeScalars.last != "$",
              tex.range(of: "$$", options: .literal) == nil else { return nil }

        // An initial combining mark or a similar joining scalar can make the
        // delimiter and payload share a grapheme. Native editing cannot select
        // just the payload in that case.
        let surrounded = "$$\(tex)$$"
        guard surrounded.dropFirst(2).dropLast(2).utf16.elementsEqual(tex.utf16) else { return nil }
        return tex
    }
}

/// Only the top-level render walk records candidates, once it knows which
/// source lines really produced display math. Walk the original line endings
/// lazily up to the last candidate so CRLF offsets stay exact, with no second
/// parsing pass or per-line offset table.
final class DisplayFormulaSourceMap {
    private let source: String.UTF16View
    private var cursor: String.Index
    private var offset = 0
    private var lineNumber = 1
    private(set) var edits: [Int: DisplayFormulaEdit] = [:]

    init(markdown: String) {
        source = markdown.utf16
        cursor = source.startIndex
    }

    func record(line: String, number: Int, tex: String) {
        let whitespace = CharacterSet.whitespaces
        guard let opening = line.unicodeScalars.firstIndex(where: { !whitespace.contains($0) }),
              line.unicodeScalars[opening...].starts(with: "$$".unicodeScalars),
              let start = tex.unicodeScalars.firstIndex(where: { !whitespace.contains($0) }),
              let payload = DisplayFormulaEdit.validatedReplacement(tex) else { return }
        let outerPadding = line.utf16.distance(from: line.startIndex, to: opening)
        let innerPadding = tex.utf16.distance(from: tex.startIndex, to: start)
        let relative = NSRange(location: outerPadding + 2 + innerPadding, length: payload.utf16.count)
        guard let payloadRange = Range(relative, in: line),
              (line as NSString).rangeOfComposedCharacterSequences(for: relative) == relative,
              line[payloadRange].utf16.elementsEqual(payload.utf16),
              let lineOffset = offset(ofLine: number) else { return }
        edits[number] = DisplayFormulaEdit(
            range: NSRange(location: lineOffset + relative.location, length: relative.length),
            source: payload
        )
    }

    private func offset(ofLine number: Int) -> Int? {
        while lineNumber < number, cursor < source.endIndex {
            let unit = source[cursor]
            advance()
            if unit == 0x0D, cursor < source.endIndex, source[cursor] == 0x0A { advance() }
            if unit == 0x0D || unit == 0x0A { lineNumber += 1 }
        }
        return lineNumber == number ? offset : nil
    }

    private func advance() {
        source.formIndex(after: &cursor)
        offset += 1
    }
}
