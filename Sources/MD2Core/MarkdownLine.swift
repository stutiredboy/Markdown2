import Foundation

enum MarkdownLine {
    static func heading(in line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = trimmed.unicodeScalars.prefix { $0 == "#" }.count

        guard (1...6).contains(level) else { return nil }
        let afterHashes = trimmed.droppingScalars(level)
        guard afterHashes.hasScalarPrefix(" ") else { return nil }

        let rawTitle = afterHashes
            .droppingScalars(1)
            .trimmingCharacters(in: .whitespaces)

        guard !rawTitle.isEmpty else { return nil }

        let cleanedTitle = rawTitle.replacingOccurrences(
            of: #"\s+#+\s*$"#,
            with: "",
            options: .regularExpression
        )

        return (level, cleanedTitle)
    }

    static func fenceMarker(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasScalarPrefix("```") {
            return "```"
        }

        if trimmed.hasScalarPrefix("~~~") {
            return "~~~"
        }

        return nil
    }

    static func setextHeadingLevel(in line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard trimmed.count >= 1 else { return nil }

        if Set(trimmed) == Set<Character>(["="]) {
            return 1
        }

        if trimmed.count >= 3, Set(trimmed) == Set<Character>(["-"]) {
            return 2
        }

        return nil
    }

    static func isIndentedCode(_ line: String) -> Bool {
        line.hasScalarPrefix("    ") || line.hasScalarPrefix("\t")
    }

    static func stripCodeIndent(_ line: String) -> String {
        if line.hasScalarPrefix("\t") {
            return line.droppingScalars(1)
        }

        if line.hasScalarPrefix("    ") {
            return line.droppingScalars(4)
        }

        return line
    }

    /// Whether a trimmed line opens or continues a blockquote.
    static func isBlockquote(_ trimmed: String) -> Bool {
        trimmed.hasScalarPrefix(">")
    }

    /// A trimmed blockquote line's content: the text after `>` and one optional
    /// space or tab.
    static func blockquoteContent(_ trimmed: String) -> String {
        var content = trimmed.unicodeScalars.dropFirst()
        if content.first == " " || content.first == "\t" { content = content.dropFirst() }
        return String(content)
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3 else { return false }

        let characters = Set(compact)
        return characters == Set<Character>(["-"]) ||
            characters == Set<Character>(["*"]) ||
            characters == Set<Character>(["_"])
    }
}
