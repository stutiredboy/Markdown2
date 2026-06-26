import Foundation

/// One parsed citation reference: a key plus the Pandoc modifiers that affect
/// how it renders (author suppression and an optional locator such as `p. 42`).
struct CitationItem {
    let key: String
    let suppressAuthor: Bool
    let locator: String?
}

/// Document-wide citation state, mirroring `FootnoteContext`: parsed bibliography
/// entries seeded from `RenderConfig`, the set of keys actually cited in
/// first-citation order (for numeric numbering and bibliography ordering), and
/// the active style. The inline citation pass registers keys here as it renders
/// them; the trailing bibliography section reads the cited set back out.
final class CitationContext {
    /// Citation key → parsed BibTeX entry, seeded from the loaded `.bib`.
    let entries: [String: BibEntry]
    /// Cited keys in first-citation order; the index + 1 is the numeric label.
    private(set) var citedKeys: [String] = []
    let style: CitationStyle

    init(entries: [String: BibEntry] = [:], style: CitationStyle = .authorYear) {
        self.entries = entries
        self.style = style
    }

    /// Whether any bibliography entries were loaded; gates citation rendering and
    /// the bibliography section.
    var hasBibliography: Bool { !entries.isEmpty }
    var hasCitations: Bool { !citedKeys.isEmpty }

    /// Registers a cited key in first-citation order if it has a bibliography
    /// entry. Returns true when the key is known (so the caller renders a
    /// citation) and false when it is not (so the caller leaves the text literal
    /// or shows the raw key).
    @discardableResult
    func register(_ key: String) -> Bool {
        guard entries[key] != nil else { return false }
        if !citedKeys.contains(key) {
            citedKeys.append(key)
        }
        return true
    }

    /// The 1-based numeric label of an already-registered key.
    func number(for key: String) -> Int? {
        guard let index = citedKeys.firstIndex(of: key) else { return nil }
        return index + 1
    }

    // MARK: - Inline rendering (plain display text; the caller escapes + wraps)

    /// Renders a parenthetical citation group `[@a; @b]`. Author-year wraps the
    /// items in parentheses; numeric wraps numbers in brackets.
    func renderParenthetical(_ items: [CitationItem]) -> String {
        switch style {
        case .authorYear:
            let parts = items.map { authorYearItem($0) }
            return "(" + parts.joined(separator: "; ") + ")"
        case .numeric:
            let parts = items.map { numericItem($0) }
            return "[" + parts.joined(separator: ", ") + "]"
        }
    }

    /// Renders an in-text citation `@key` where the author sits outside the
    /// parentheses (author-year) or as a bare number (numeric).
    func renderInText(_ item: CitationItem) -> String {
        switch style {
        case .authorYear:
            guard let entry = entries[item.key] else { return item.key }
            let year = displayYear(entry)
            if item.suppressAuthor {
                return "(" + appendLocator(year, item.locator) + ")"
            }
            let authors = authorList(entry)
            return "\(authors) (" + appendLocator(year, item.locator) + ")"
        case .numeric:
            return numericItem(item)
        }
    }

    // MARK: - Item formatting

    /// One author-year item without the surrounding parentheses: `Smith, 2023`,
    /// or just `2023` when the author is suppressed.
    private func authorYearItem(_ item: CitationItem) -> String {
        guard let entry = entries[item.key] else { return item.key }
        let year = displayYear(entry)
        if item.suppressAuthor {
            return appendLocator(year, item.locator)
        }
        let authors = authorList(entry)
        let base = authors.isEmpty ? year : "\(authors), \(year)"
        return appendLocator(base, item.locator)
    }

    /// One numeric item: the bracket-less number, with an optional locator.
    private func numericItem(_ item: CitationItem) -> String {
        guard let number = number(for: item.key) else { return item.key }
        return appendLocator(String(number), item.locator)
    }

    private func appendLocator(_ base: String, _ locator: String?) -> String {
        guard let locator, !locator.isEmpty else { return base }
        return "\(base), \(locator)"
    }

    /// Short author form: "Smith" (one), "Smith & Jones" (two), "Smith et al."
    /// (three or more). Falls back to the title or key when there is no author.
    private func authorList(_ entry: BibEntry) -> String {
        let authors = entry.authors
        switch authors.count {
        case 0:
            return entry.title ?? entry.key
        case 1:
            return authors[0].surname
        case 2:
            return "\(authors[0].surname) & \(authors[1].surname)"
        default:
            return "\(authors[0].surname) et al."
        }
    }

    private func displayYear(_ entry: BibEntry) -> String {
        entry.year ?? "n.d."
    }

    // MARK: - Bibliography section

    /// Cited entries in the order they should appear in the bibliography:
    /// alphabetical by first author surname (author-year) or first-citation order
    /// (numeric).
    func bibliographyEntries() -> [BibEntry] {
        let cited = citedKeys.compactMap { entries[$0] }
        switch style {
        case .numeric:
            return cited
        case .authorYear:
            return cited.sorted { lhs, rhs in
                sortKey(lhs).localizedCaseInsensitiveCompare(sortKey(rhs)) == .orderedAscending
            }
        }
    }

    /// Sort key for author-year ordering: first author surname, then year.
    private func sortKey(_ entry: BibEntry) -> String {
        let surname = entry.authors.first?.surname ?? entry.title ?? entry.key
        return "\(surname) \(entry.year ?? "")"
    }

    /// A full author list for the bibliography line (not shortened), e.g.
    /// "Jane Smith, John Jones".
    func fullAuthorList(_ entry: BibEntry) -> String {
        let names = entry.authors.map { $0.fullName }.filter { !$0.isEmpty }
        return names.joined(separator: ", ")
    }
}
