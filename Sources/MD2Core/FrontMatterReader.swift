import Foundation

/// A deliberately minimal reader for the leading YAML front-matter block. The
/// renderer only *displays* front matter (see `MarkdownRenderer.frontMatterBlock`);
/// the academic features need to *read* a couple of scalar keys (`bibliography:`,
/// `math-macros:`) from it. This reader maps the block to `[key: value]` for
/// single-line scalar values only. Full YAML (nested maps, sequences, multi-line
/// block scalars, anchors) is a Non-Goal; such keys are simply not surfaced, and
/// the block still renders verbatim as before.
public enum FrontMatterReader {
    /// Parses single-line `key: value` scalars from a document's leading
    /// front-matter block (delimited by `---` fences on their own lines at the
    /// very top of the document). Returns an empty dictionary when there is no
    /// front-matter block. Surrounding quotes on a value are stripped.
    public static func fields(in markdown: String) -> [String: String] {
        let lines = markdown.normalizedMarkdownLines
        guard let first = lines.first, first.trimmedMarkdownLine == "---" else {
            return [:]
        }

        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.trimmedMarkdownLine == "---" {
                break
            }
            if let (key, value) = parseScalarLine(line) {
                fields[key] = value
            }
            index += 1
        }
        return fields
    }

    /// Splits a `key: value` line. Indented (nested) lines and lines without a
    /// colon are ignored. A value that is empty (a `key:` opening a nested block)
    /// is also ignored, since only scalars are supported.
    private static func parseScalarLine(_ line: String) -> (key: String, value: String)? {
        // Reject indented lines: a leading space means the key is nested under a
        // parent mapping, which is outside the single-line-scalar scope.
        guard line.first != " ", line.first != "\t" else { return nil }

        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }

        let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !rawValue.isEmpty else { return nil }

        return (key, unquote(rawValue))
    }

    /// Strips a single pair of matching surrounding quotes from a scalar value.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first!
        let last = value.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Interprets a `math-macros:` field value as a `\command` → expansion map.
    /// The value is a YAML/JSON flow mapping such as `{ "\\vec": "\\mathbf" }`;
    /// JSON's `\\`-escaping yields the single backslashes KaTeX expects. Returns
    /// an empty map when the value is absent or cannot be parsed (graceful: bad
    /// macro syntax never breaks rendering).
    public static func parseMathMacros(_ value: String?) -> [String: String] {
        guard let value, !value.isEmpty,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var macros: [String: String] = [:]
        for (key, raw) in object {
            if let string = raw as? String {
                macros[key] = string
            }
        }
        return macros
    }
}
