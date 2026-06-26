import Foundation

/// A small, dependency-free BibTeX parser covering the common subset needed for
/// in-preview citation rendering: `@type{key, field = value, …}` entries with
/// brace-, quote-, or bare-delimited values and `#` concatenation. Full BibTeX
/// (`@string` macros, cross-references, preamble) is out of scope — Pandoc
/// handles those on export. Malformed entries are skipped, never fatal.
public enum BibTeXParser {
    /// Parses BibTeX source into entries keyed by citation key. The first
    /// definition of a key wins; later duplicates are ignored. `@string`,
    /// `@preamble`, and `@comment` blocks are skipped.
    public static func parse(_ source: String) -> [String: BibEntry] {
        var scanner = Scanner(source)
        var entries: [String: BibEntry] = [:]

        while let entry = scanner.nextEntry() {
            switch entry {
            case let .entry(bib):
                if entries[bib.key] == nil {
                    entries[bib.key] = bib
                }
            case .ignored:
                continue
            }
        }

        return entries
    }

    private enum ParseResult {
        case entry(BibEntry)
        case ignored
    }

    /// A forward-only character scanner over the BibTeX source.
    private struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ source: String) {
            characters = Array(source)
        }

        private var isAtEnd: Bool { index >= characters.count }

        private func peek() -> Character? {
            isAtEnd ? nil : characters[index]
        }

        private mutating func advance() -> Character? {
            guard !isAtEnd else { return nil }
            defer { index += 1 }
            return characters[index]
        }

        private mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace { index += 1 }
        }

        /// Advances to and consumes the next `@`, returning the lower-cased entry
        /// type that follows it, or nil at end of input.
        private mutating func nextType() -> String? {
            while let c = advance() {
                if c == "@" {
                    var type = ""
                    while let next = peek(), next.isLetter {
                        type.append(next)
                        index += 1
                    }
                    return type.lowercased()
                }
            }
            return nil
        }

        /// Skips a brace- or paren-delimited block (used to discard `@string`,
        /// `@preamble`, `@comment`). Assumes the opening delimiter has not yet
        /// been consumed; tolerates leading whitespace.
        private mutating func skipBalancedBlock() {
            skipWhitespace()
            guard let open = peek(), open == "{" || open == "(" else { return }
            let close: Character = open == "{" ? "}" : ")"
            index += 1
            var depth = 1
            while let c = advance() {
                if c == open { depth += 1 }
                else if c == close {
                    depth -= 1
                    if depth == 0 { return }
                }
            }
        }

        /// Parses the next entry, or nil at end of input. Non-entry blocks
        /// (`@string`/`@preamble`/`@comment`) return `.ignored`.
        mutating func nextEntry() -> ParseResult? {
            guard let type = nextType() else { return nil }

            if type == "string" || type == "preamble" || type == "comment" {
                skipBalancedBlock()
                return .ignored
            }

            skipWhitespace()
            guard peek() == "{" else {
                // Malformed: no opening brace. Skip whatever block follows so the
                // scan can recover at the next `@`.
                skipBalancedBlock()
                return .ignored
            }
            index += 1 // consume "{"

            let key = readKey()
            guard !key.isEmpty else {
                skipToEntryEnd()
                return .ignored
            }

            var fields: [String: String] = [:]
            while true {
                skipWhitespace()
                guard let c = peek() else { break }
                if c == "}" { index += 1; break }
                if c == "," { index += 1; continue }

                guard let (name, value) = readField() else { break }
                if !name.isEmpty {
                    fields[name.lowercased()] = value
                }
            }

            return .entry(BibEntry(key: key, type: type, fields: fields))
        }

        /// Reads the citation key up to the first comma or closing brace.
        private mutating func readKey() -> String {
            skipWhitespace()
            var key = ""
            while let c = peek(), c != ",", c != "}", !c.isWhitespace {
                key.append(c)
                index += 1
            }
            // Consume up to and including the comma if present.
            while let c = peek(), c != ",", c != "}" { index += 1 }
            if peek() == "," { index += 1 }
            return key
        }

        /// Reads one `name = value` field. Returns nil when no field name is
        /// found (end of entry or malformed).
        private mutating func readField() -> (name: String, value: String)? {
            skipWhitespace()
            var name = ""
            while let c = peek(), c.isLetter || c.isNumber || c == "_" || c == "-" || c == "+" || c == ":" {
                name.append(c)
                index += 1
            }
            guard !name.isEmpty else { return nil }

            skipWhitespace()
            guard peek() == "=" else {
                // A name with no value: tolerate by returning an empty value.
                return (name, "")
            }
            index += 1 // consume "="

            let value = readValue()
            return (name, value)
        }

        /// Reads a (possibly `#`-concatenated) field value: `{…}`, `"…"`, or a
        /// bare token. Concatenated parts are joined with no separator.
        private mutating func readValue() -> String {
            var result = ""
            while true {
                skipWhitespace()
                guard let c = peek() else { break }

                if c == "{" {
                    result += readBraced()
                } else if c == "\"" {
                    result += readQuoted()
                } else {
                    result += readBare()
                }

                skipWhitespace()
                if peek() == "#" {
                    index += 1 // consume "#" and continue concatenation
                    continue
                }
                break
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Reads a brace-delimited value, preserving balanced inner braces'
        /// content but dropping the outermost braces. Whitespace runs collapse to
        /// single spaces so multi-line values read cleanly.
        private mutating func readBraced() -> String {
            guard peek() == "{" else { return "" }
            index += 1
            var depth = 1
            var value = ""
            while let c = advance() {
                if c == "{" { depth += 1; value.append(c) }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { break }
                    value.append(c)
                } else {
                    value.append(c)
                }
            }
            return collapseWhitespace(value)
        }

        private mutating func readQuoted() -> String {
            guard peek() == "\"" else { return "" }
            index += 1
            var value = ""
            var depth = 0
            while let c = advance() {
                if c == "{" { depth += 1; value.append(c) }
                else if c == "}" { depth = max(0, depth - 1); value.append(c) }
                else if c == "\"" && depth == 0 { break }
                else { value.append(c) }
            }
            return collapseWhitespace(value)
        }

        private mutating func readBare() -> String {
            var value = ""
            while let c = peek(), c != ",", c != "}", c != "#", !c.isWhitespace {
                value.append(c)
                index += 1
            }
            return value
        }

        /// Collapses internal whitespace/newline runs to a single space while
        /// preserving a single leading/trailing space, so a trailing space before a
        /// `#` concatenation (`"a " # "b"` → `a b`) is not lost. The full value is
        /// trimmed once at the end of `readValue`.
        private func collapseWhitespace(_ value: String) -> String {
            value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }

        /// Recovers from a malformed entry by skipping to its closing brace.
        private mutating func skipToEntryEnd() {
            var depth = 1
            while let c = advance() {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return }
                }
            }
        }
    }
}
