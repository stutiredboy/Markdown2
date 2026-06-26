import Foundation

/// A single parsed BibTeX entry. Field names are lower-cased; values are the
/// brace/quote-stripped raw strings. The convenience accessors expose the few
/// fields the preview's lightweight citation rendering needs; everything else
/// stays available through `fields` for the bibliography section.
public struct BibEntry: Sendable, Equatable {
    public let key: String
    /// Lower-cased entry type, e.g. `article`, `book`, `inproceedings`.
    public let type: String
    /// Lower-cased field name → value.
    public let fields: [String: String]

    public init(key: String, type: String, fields: [String: String]) {
        self.key = key
        self.type = type
        self.fields = fields
    }

    public var title: String? { fields["title"] }
    public var year: String? { fields["year"] }
    public var journal: String? { fields["journal"] }
    public var booktitle: String? { fields["booktitle"] }
    public var publisher: String? { fields["publisher"] }

    /// The parsed author list, or an empty array when there is no `author` field.
    public var authors: [PersonName] {
        PersonName.parseList(fields["author"] ?? "")
    }
}

/// A person name split into family (surname) and given parts. Citation rendering
/// keys off the family name; the bibliography section can show the full name.
public struct PersonName: Sendable, Equatable {
    public let family: String
    public let given: String

    public init(family: String, given: String) {
        self.family = family
        self.given = given
    }

    /// The surname used in author-year citations. Falls back to the given part
    /// when a name has no comma and only one token (a mononym/organization).
    public var surname: String {
        family.isEmpty ? given : family
    }

    /// "Given Family" for bibliography display, collapsing empty parts.
    public var fullName: String {
        switch (given.isEmpty, family.isEmpty) {
        case (true, _): return family
        case (_, true): return given
        default: return "\(given) \(family)"
        }
    }

    /// Parses a BibTeX `author` field. Authors are separated by ` and `; each
    /// author is either `Last, First` (comma form) or `First Last` (space form,
    /// where the final whitespace-delimited token is the surname).
    public static func parseList(_ field: String) -> [PersonName] {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return splitOnAnd(trimmed)
            .map { parseOne($0) }
            .filter { !($0.family.isEmpty && $0.given.isEmpty) }
    }

    /// Splits an author field on the ` and ` separator (case-insensitive), while
    /// keeping a literal `and` that sits inside braces (e.g. an organization name
    /// `{Smith and Sons}`) intact.
    private static func splitOnAnd(_ field: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        let scalars = Array(field)
        var index = 0
        while index < scalars.count {
            let character = scalars[index]
            if character == "{" { depth += 1 }
            else if character == "}" { depth = max(0, depth - 1) }

            if depth == 0,
               character == " ",
               index + 4 < scalars.count,
               scalars[index + 1] == "a" || scalars[index + 1] == "A",
               scalars[index + 2] == "n" || scalars[index + 2] == "N",
               scalars[index + 3] == "d" || scalars[index + 3] == "D",
               scalars[index + 4] == " " {
                parts.append(current)
                current = ""
                index += 5
                continue
            }

            current.append(character)
            index += 1
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func parseOne(_ author: String) -> PersonName {
        let stripped = author.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespaces)

        if let comma = stripped.firstIndex(of: ",") {
            let family = stripped[..<comma].trimmingCharacters(in: .whitespaces)
            let given = stripped[stripped.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return PersonName(family: family, given: given)
        }

        let tokens = stripped.split(separator: " ").map(String.init)
        guard let last = tokens.last else {
            return PersonName(family: stripped, given: "")
        }
        if tokens.count == 1 {
            return PersonName(family: last, given: "")
        }
        return PersonName(family: last, given: tokens.dropLast().joined(separator: " "))
    }
}
