import Foundation

/// Pure match-set differencing for the editor's find highlights, kept in MD2Core
/// so it is unit-testable independently of the AppKit layout manager. Both
/// inputs are sorted, non-overlapping match ranges, as produced by
/// `TextSearch.matches`.
public enum FindHighlightDiff {
    public struct Result: Equatable {
        /// Ranges in `new` but not `old`: must be painted.
        public var added: [NSRange]
        /// Ranges in `old` but not `new`: must be unpainted.
        public var removed: [NSRange]
        /// Ranges present in both: painted state is unchanged.
        public var unchanged: [NSRange]

        public init(
            added: [NSRange] = [],
            removed: [NSRange] = [],
            unchanged: [NSRange] = []
        ) {
            self.added = added
            self.removed = removed
            self.unchanged = unchanged
        }
    }

    /// The added/removed/unchanged partition between two sorted match lists.
    /// Ranges at identical locations are unchanged; a range that only moved
    /// appears as one remove and one add.
    public static func diff(from old: [NSRange], to new: [NSRange]) -> Result {
        var added: [NSRange] = []
        var removed: [NSRange] = []
        var unchanged: [NSRange] = []
        var i = 0
        var j = 0

        while i < old.count || j < new.count {
            if i >= old.count {
                added.append(new[j])
                j += 1
            } else if j >= new.count {
                removed.append(old[i])
                i += 1
            } else {
                let oldRange = old[i]
                let newRange = new[j]
                if NSEqualRanges(oldRange, newRange) {
                    unchanged.append(oldRange)
                    i += 1
                    j += 1
                } else if oldRange.location < newRange.location {
                    removed.append(oldRange)
                    i += 1
                } else {
                    added.append(newRange)
                    j += 1
                }
            }
        }

        return Result(added: added, removed: removed, unchanged: unchanged)
    }
}
