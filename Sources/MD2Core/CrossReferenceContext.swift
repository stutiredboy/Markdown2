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

/// Document-wide cross-reference state, populated by a label pre-scan (so a
/// `\ref{}` that appears before its target still resolves, mirroring how the
/// footnote pre-scan enables forward references) and then re-driven during the
/// render walk to emit each element's number.
///
/// The pre-scan assigns numbers via `assignFigure`/`assignTable`/`assignEquation`
/// in document order. `resetCounters()` then rewinds the counters so the render
/// walk re-assigns the *same* numbers as it emits each element, while `number(for:)`
/// resolves `\ref{}` against the fully-populated label map.
final class CrossReferenceContext {
    private(set) var labels: [String: CrossRefTarget] = [:]
    private var figureCounter = 0
    private var tableCounter = 0
    private var equationCounter = 0
    let numberAllEquations: Bool

    init(numberAllEquations: Bool = false) {
        self.numberAllEquations = numberAllEquations
    }

    var hasLabels: Bool { !labels.isEmpty }

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

    /// Rewinds the sequential counters after the pre-scan so the render walk
    /// re-assigns identical numbers. The label map is left intact for `\ref{}`.
    func resetCounters() {
        figureCounter = 0
        tableCounter = 0
        equationCounter = 0
    }

    /// Resolves a `\ref{}` label to its target's number, or nil when the label is
    /// undefined (the caller then leaves `\ref{label}` literal).
    func number(for label: String) -> String? {
        labels[label]?.number
    }
}
