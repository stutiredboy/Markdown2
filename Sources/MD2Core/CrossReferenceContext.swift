import Foundation

/// A numbered, labeled element that a `\ref{}` can resolve to. `number` is a
/// string (not an Int) so manual `\tag{3.1}` equation numbers are representable
/// alongside the auto-assigned sequential figure/table/equation counts.
struct CrossRefTarget: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case figure
        case table
        case equation
    }

    let kind: Kind
    let number: String
    let label: String
}

/// Document-wide cross-reference state, driven by the render walk alone.
///
/// The walk numbers each figure/table/equation via `assignFigure`/`assignTable`/
/// `assignEquation` as it emits it, wherever it sits — top level, blockquote,
/// list item, table caption, or footnote (rendered after the body). A `\ref{}`
/// cannot resolve in place, because its target may be emitted later, so it
/// renders as a provisional anchor from `provisionalAnchor(for:literal:)`, and
/// `resolveReferences(in:)` fills in each number once the whole document has
/// rendered. Numbering and resolution therefore share one traversal, and every
/// `\ref{}` shows the number its target displays.
final class CrossReferenceContext {
    private(set) var labels: [String: CrossRefTarget] = [:]
    private var figureCounter = 0
    private var tableCounter = 0
    private var equationCounter = 0
    let numberAllEquations: Bool

    /// A `\ref{}` site awaiting resolution, indexed by its placeholder number.
    private struct Site {
        let label: String
        let opening: String
        let literal: String
    }

    private var sites: [Site] = []

    private static let placeholderSentinel: Unicode.Scalar = "\u{E001}"
    private static let anchorClosing = "</a>"

    /// A fresh random nonce per render, so authored text can never spell a
    /// placeholder and turn into a cross-reference.
    private lazy var placeholderNonce = Array(UUID().uuidString.unicodeScalars)

    init(numberAllEquations: Bool = false) {
        self.numberAllEquations = numberAllEquations
    }

    /// Assigns the next sequential figure number to `label` and registers it.
    @discardableResult
    func assignFigure(label: String) -> String {
        figureCounter += 1
        let number = String(figureCounter)
        labels[label] = CrossRefTarget(kind: .figure, number: number, label: label)
        return number
    }

    /// Assigns the next sequential table number to `label` and registers it.
    @discardableResult
    func assignTable(label: String) -> String {
        tableCounter += 1
        let number = String(tableCounter)
        labels[label] = CrossRefTarget(kind: .table, number: number, label: label)
        return number
    }

    /// Determines a display equation's number from its `\label`/`\tag` and the
    /// "number all equations" setting, registering a labeled equation for
    /// `\ref{}`. Returns the number to display, or nil when the equation is
    /// unnumbered. A manual `\tag{n}` wins and does not consume an auto-number;
    /// otherwise a label (or the number-all setting) draws the next sequential
    /// number.
    @discardableResult
    func assignEquation(label: String?, tag: String?) -> String? {
        if let tag, !tag.isEmpty {
            if let label { labels[label] = CrossRefTarget(kind: .equation, number: tag, label: label) }
            return tag
        }
        if label != nil || numberAllEquations {
            equationCounter += 1
            let number = String(equationCounter)
            if let label { labels[label] = CrossRefTarget(kind: .equation, number: number, label: label) }
            return number
        }
        return nil
    }

    /// Records a `\ref{label}` site and returns its provisional HTML: the
    /// cross-reference anchor with a placeholder where the number goes. Inline
    /// passes that inspect a fragment's HTML (URL safety, the no-nested-links
    /// rule, the bare-URL continuation guard) therefore see the anchor it
    /// becomes. `literal` is what the site renders as when no element ends up
    /// carrying `label`; it must hold no inline protector tokens, since it is
    /// emitted after inline restoration.
    func provisionalAnchor(for label: String, literal: String) -> String {
        let opening = "<a class=\"cross-ref\" href=\"#\(HTMLEscaping.escapeAttribute(label))\">"
        var placeholder = String.UnicodeScalarView()
        placeholder.append(Self.placeholderSentinel)
        placeholder.append(contentsOf: placeholderNonce)
        placeholder.append(contentsOf: String(sites.count).unicodeScalars)
        placeholder.append(Self.placeholderSentinel)
        sites.append(Site(label: label, opening: opening, literal: literal))
        return opening + String(placeholder) + Self.anchorClosing
    }

    /// Whether `html` holds a provisional anchor, whose visible number is not
    /// known until the whole document has rendered.
    static func containsProvisionalAnchor(_ html: String) -> Bool {
        html.unicodeScalars.contains(placeholderSentinel)
    }

    /// Fills every provisional anchor in `html` with its target's number, or
    /// replaces the whole anchor with the site's literal when the label names
    /// no element. Duplicate labels resolve to the last definition, as in
    /// LaTeX. One forward scan over Unicode scalars, so a combining mark after
    /// a placeholder cannot hide its closing sentinel inside a grapheme.
    func resolveReferences(in html: String) -> String {
        guard !sites.isEmpty else { return html }

        let scalars = html.unicodeScalars
        let closing = Self.anchorClosing.unicodeScalars
        var result = String.UnicodeScalarView()
        var cursor = scalars.startIndex

        while let start = scalars[cursor...].firstIndex(of: Self.placeholderSentinel) {
            result.append(contentsOf: scalars[cursor..<start])
            guard let placeholder = placeholderIndex(in: scalars, at: start) else {
                result.append(Self.placeholderSentinel)
                cursor = scalars.index(after: start)
                continue
            }
            let site = sites[placeholder.index]
            cursor = placeholder.end
            if let target = labels[site.label] {
                result.append(contentsOf: HTMLEscaping.escape(target.number).unicodeScalars)
                continue
            }
            // Unwrap the anchor. A fragment is restored whole, so its opening
            // tag was just copied and its closing tag comes next.
            let opening = site.opening.unicodeScalars
            if result.reversed().starts(with: opening.reversed()),
               scalars[cursor...].starts(with: closing) {
                result.removeLast(opening.count)
                cursor = scalars.index(cursor, offsetBy: closing.count)
            }
            result.append(contentsOf: site.literal.unicodeScalars)
        }
        result.append(contentsOf: scalars[cursor...])
        return String(result)
    }

    /// Parses `<sentinel><nonce><decimal><sentinel>` at `start`. Anything else —
    /// including authored private-use text — is not a placeholder and stays put.
    private func placeholderIndex(
        in scalars: String.UnicodeScalarView,
        at start: String.UnicodeScalarView.Index
    ) -> (index: Int, end: String.UnicodeScalarView.Index)? {
        var cursor = scalars.index(after: start)
        for expected in placeholderNonce {
            guard cursor < scalars.endIndex, scalars[cursor] == expected else { return nil }
            cursor = scalars.index(after: cursor)
        }

        var index = 0
        var digits = 0
        while cursor < scalars.endIndex, (0x30...0x39).contains(scalars[cursor].value) {
            index = index * 10 + Int(scalars[cursor].value - 0x30)
            guard index < sites.count else { return nil }
            digits += 1
            cursor = scalars.index(after: cursor)
        }

        guard digits > 0, cursor < scalars.endIndex, scalars[cursor] == Self.placeholderSentinel else { return nil }
        return (index, scalars.index(after: cursor))
    }
}
