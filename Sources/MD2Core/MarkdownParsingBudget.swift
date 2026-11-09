import Foundation

/// One render owns one budget, shared by every recursive container traversal.
/// Count scanned UTF-8 bytes as well as active traversal frames: a shallow but
/// very wide container can otherwise repeatedly rescan arbitrarily much text.
/// This is deliberately local state, never retained on the Sendable renderer.
final class MarkdownParsingBudget {
    private static let maximumDepth = 64
    private var remainingWork = 16 * 1_024 * 1_024
    private var depth = 0
    private(set) var exhausted = false

    func enter(lines: [String]) -> Bool {
        // Stop counting as soon as the limit is exceeded, without overflowing
        // an accumulator or doing another complete scan after exhaustion.
        guard !exhausted, !Task.isCancelled else { return false }
        for line in lines {
            guard spend(line.utf8.count + 1) else { return false }
        }
        return enter(work: 0)
    }

    func enter(work: Int) -> Bool {
        guard !exhausted, !Task.isCancelled else { return false }
        guard depth < Self.maximumDepth, spend(work) else {
            exhausted = true
            return false
        }
        depth += 1
        return true
    }

    func leave() { depth -= 1 }

    private func spend(_ work: Int) -> Bool {
        guard work <= remainingWork else {
            exhausted = true
            return false
        }
        remainingWork -= work
        return true
    }
}
