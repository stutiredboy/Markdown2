import Foundation
import ICU

/// Bounded, cancellable ICU search. Call from a worker so compilation, scanning
/// and replacement expansion yield the editor's main actor.
public enum RegexSearch {
    public struct Match: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String?
    }

    public enum Failure: String, Codable, Error, Sendable {
        case invalidPattern
        case invalidReplacement
        case limitExceeded
        case searchFailed
    }

    public static let maximumPatternUTF16 = 4_096
    public static let maximumTemplateUTF16 = 4_096
    public static let maximumTextUTF16 = 2_000_000
    private static let matchLimit = 20_000
    private static let replacementLimit = 2_000_000

    /// UTF-16 ranges in source order. The scope contains the entire match.
    /// Anchors and lookarounds still see the surrounding document. Matches
    /// that split an extended grapheme are skipped, including zero-width ones.
    public static func matches(
        of pattern: String, in text: String, caseSensitive: Bool = false,
        scope: NSRange? = nil, replacementTemplate: String? = nil, replacementTarget: NSRange? = nil
    ) throws -> [Match] {
        try Task.checkCancellation()
        guard !pattern.isEmpty else { return [] }
        let budget = Budget()
        var units = Array(text.utf16.prefix(maximumTextUTF16 + 1))
        guard units.count <= maximumTextUTF16 else { throw Failure.limitExceeded }
        let length = units.count
        let bounds = scope ?? NSRange(location: 0, length: length)
        guard scope == nil || bounds.length > 0,
              bounds.location >= 0, bounds.location <= length,
              bounds.length >= 0, bounds.length <= length - bounds.location,
              isScalarBoundary(bounds.location, in: units),
              isScalarBoundary(NSMaxRange(bounds), in: units) else { return [] }

        // ICU borrows the source buffer. Close the expression before the
        // borrow ends. A sentinel supplies storage even for an empty source.
        units.append(0)
        return try units.withUnsafeBufferPointer { buffer in
            try withExpression(pattern, caseSensitive: caseSensitive, budget: budget) { expression in
                let template = try replacementTemplate.map { try Template($0, expression: expression) }
                let source = buffer.prefix(length)
                var status = U_ZERO_ERROR
                uregex_setText(expression, buffer.baseAddress, Int32(length), &status)
                uregex_setRegion(expression, Int32(bounds.location), Int32(NSMaxRange(bounds)), &status)
                uregex_useTransparentBounds(expression, 1, &status)
                uregex_useAnchoringBounds(expression, 0, &status)
                try check(status)

                var boundaries = GraphemeBoundaries(text)
                var results: [Match] = []
                var remainingOutput = replacementLimit
                while true {
                    try budget.check()
                    let found = uregex_findNext(expression, &status)
                    try budget.check()
                    try check(status)
                    guard found != 0 else { return results }
                    guard let range = try range(of: 0, expression: expression),
                          range.location >= bounds.location, NSMaxRange(range) <= NSMaxRange(bounds)
                    else { throw Failure.searchFailed }
                    guard try boundaries.contains(range.location, budget: budget),
                          try boundaries.contains(NSMaxRange(range), budget: budget) else { continue }
                    guard results.count < matchLimit else { throw Failure.limitExceeded }
                    let replacement = replacementTarget == nil || replacementTarget == range
                        ? try template?.expand(expression: expression, source: source, remaining: &remainingOutput)
                        : nil
                    results.append(Match(range: range, replacement: replacement))
                }
            }
        }
    }

    /// Parse and validate capture references without scanning the document.
    public static func validateReplacement(
        _ template: String, for pattern: String, caseSensitive: Bool = false
    ) throws {
        let budget = Budget()
        try withExpression(pattern, caseSensitive: caseSensitive, budget: budget) { expression in
            _ = try Template(template, expression: expression)
            try budget.check()
        }
    }

    private static func withExpression<T>(
        _ pattern: String, caseSensitive: Bool, budget: Budget, body: (OpaquePointer) throws -> T
    ) throws -> T {
        try budget.check()
        let units = Array(pattern.utf16.prefix(maximumPatternUTF16 + 1))
        guard !units.isEmpty else { throw Failure.invalidPattern }
        guard units.count <= maximumPatternUTF16 else { throw Failure.limitExceeded }
        var status = U_ZERO_ERROR
        let flags = caseSensitive ? 0 : UInt32(UREGEX_CASE_INSENSITIVE.rawValue)
        let expression = units.withUnsafeBufferPointer { buffer in
            uregex_open(buffer.baseAddress, Int32(buffer.count), flags, nil, &status)
        }
        defer { if let expression { uregex_close(expression) } }
        try budget.check()
        if status == U_REGEX_PATTERN_TOO_BIG || status == U_MEMORY_ALLOCATION_ERROR {
            throw Failure.limitExceeded
        }
        guard let expression, status.rawValue <= U_ZERO_ERROR.rawValue else { throw Failure.invalidPattern }

        // ICU ticks count backtracking work, independent of wall time. The
        // callback also sums ticks across successive find operations, which
        // reset ICU's operation counter. The stack limit bounds ICU's heap
        // used for backtracking. Both hooks run synchronously on this worker.
        let context = Unmanaged.passUnretained(budget).toOpaque()
        uregex_setStackLimit(expression, 8 * 1024 * 1024, &status)
        uregex_setTimeLimit(expression, Budget.matchTickLimit, &status)
        uregex_setMatchCallback(expression, { pointer, _ in
            let budget = Unmanaged<Budget>.fromOpaque(pointer!).takeUnretainedValue()
            return budget.consumeMatchTick() ? 1 : 0
        }, context, &status)
        uregex_setFindProgressCallback(expression, { pointer, _ in
            let budget = Unmanaged<Budget>.fromOpaque(pointer!).takeUnretainedValue()
            return budget.consumeFindStep() ? 1 : 0
        }, context, &status)
        try check(status)
        return try withExtendedLifetime(budget) { try body(expression) }
    }

    private static func check(_ status: UErrorCode) throws {
        guard status.rawValue > U_ZERO_ERROR.rawValue else { return }
        switch status {
        case U_REGEX_STACK_OVERFLOW, U_REGEX_TIME_OUT, U_REGEX_STOPPED_BY_CALLER, U_MEMORY_ALLOCATION_ERROR:
            try Task.checkCancellation()
            throw Failure.limitExceeded
        default:
            throw Failure.searchFailed
        }
    }

    private static func range(of group: Int32, expression: OpaquePointer) throws -> NSRange? {
        var status = U_ZERO_ERROR
        let start = Int(uregex_start(expression, group, &status))
        let end = Int(uregex_end(expression, group, &status))
        try check(status)
        if start == -1, end == -1 { return nil }  // Unmatched optional group.
        guard start >= 0, end >= start else { throw Failure.searchFailed }
        return NSRange(location: start, length: end - start)
    }

    private static func isScalarBoundary<C: RandomAccessCollection<UInt16>>(_ index: Int, in units: C) -> Bool
    where C.Index == Int {
        index == units.endIndex || !(0xDC00...0xDFFF).contains(units[index])
    }

    private final class Budget {
        static let matchTickLimit: Int32 = 128

        private let deadline = ContinuousClock.now + .milliseconds(300)
        private var ticksRemaining = matchTickLimit
        private var findSteps = 0

        func check() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.limitExceeded }
        }

        func consumeMatchTick() -> Bool {
            ticksRemaining -= 1
            return ticksRemaining > 0 && !Task.isCancelled && ContinuousClock.now < deadline
        }

        func consumeFindStep() -> Bool {
            findSteps += 1
            // Check the clock and cancellation regularly without paying for
            // either on every character of a large, simple no-match search.
            return !findSteps.isMultiple(of: 64) || (!Task.isCancelled && ContinuousClock.now < deadline)
        }
    }

    /// Match endpoints arrive in ascending order. Compute boundaries only up
    /// to the last endpoint needed, including on sparse searches in large text.
    private struct GraphemeBoundaries {
        private var characters: String.Iterator
        private var offset = 0
        private var checks = 0

        init(_ text: String) { characters = text.makeIterator() }

        mutating func contains(_ index: Int, budget: Budget) throws -> Bool {
            while offset < index, let character = characters.next() {
                offset += character.utf16.count
                checks += 1
                if checks.isMultiple(of: 512) { try budget.check() }
            }
            return offset == index
        }
    }

    private struct Template {
        enum Part {
            case literal([UInt16])
            case capture(Int32)
        }

        let parts: [Part]

        init(_ template: String, expression: OpaquePointer) throws {
            let units = Array(template.utf16.prefix(maximumTemplateUTF16 + 1))
            guard units.count <= maximumTemplateUTF16 else { throw Failure.limitExceeded }
            var status = U_ZERO_ERROR
            let groupCount = uregex_groupCount(expression, &status)
            try check(status)
            var parts: [Part] = []
            var literal: [UInt16] = []
            var index = 0
            while index < units.count {
                let unit = units[index]
                // Only dollar and backslash are escapable. Other characters
                // (including literal newlines) are copied as written.
                if unit == 0x5C, index + 1 < units.count, [0x24, 0x5C].contains(units[index + 1]) {
                    literal.append(units[index + 1])
                    index += 2
                    continue
                }
                if unit == 0x24, index + 1 < units.count,
                   let capture = try Self.capture(in: units, from: &index, expression: expression, count: groupCount) {
                    if !literal.isEmpty {
                        parts.append(.literal(literal))
                        literal = []
                    }
                    parts.append(.capture(capture))
                    continue
                }
                literal.append(unit)
                index += 1
            }
            if !literal.isEmpty { parts.append(.literal(literal)) }
            self.parts = parts
        }

        private static func capture(
            in units: [UInt16], from index: inout Int, expression: OpaquePointer, count: Int32
        ) throws -> Int32? {
            let start = index + 1
            if units[start] == 0x7B {
                let name = start + 1
                guard let end = units[name...].firstIndex(of: 0x7D), end > name else {
                    throw Failure.invalidReplacement
                }
                var status = U_ZERO_ERROR
                let group = units.withUnsafeBufferPointer { buffer in
                    uregex_groupNumberFromName(expression, buffer.baseAddress! + name, Int32(end - name), &status)
                }
                guard status.rawValue <= U_ZERO_ERROR.rawValue, group > 0 else {
                    throw Failure.invalidReplacement
                }
                index = end + 1
                return group
            }
            guard (0x30...0x39).contains(units[start]) else { return nil }
            index = start
            var group: Int32 = 0
            while index < units.count, (0x30...0x39).contains(units[index]) {
                // Check against the small compiled group count before taking
                // more digits, so even a huge reference can't overflow.
                group = group * 10 + Int32(units[index] - 0x30)
                guard group <= count else { throw Failure.invalidReplacement }
                index += 1
            }
            return group
        }

        func expand(
            expression: OpaquePointer, source: Slice<UnsafeBufferPointer<UInt16>>, remaining: inout Int
        ) throws -> String {
            var output: [UInt16] = []
            for part in parts {
                switch part {
                case .literal(let units):
                    guard units.count <= remaining else { throw Failure.limitExceeded }
                    remaining -= units.count
                    output.append(contentsOf: units)
                case .capture(let group):
                    guard let range = try range(of: group, expression: expression) else { continue }
                    let end = NSMaxRange(range)
                    guard end <= source.count, isScalarBoundary(range.location, in: source),
                          isScalarBoundary(end, in: source) else { throw Failure.searchFailed }
                    guard range.length <= remaining else { throw Failure.limitExceeded }
                    remaining -= range.length
                    output.append(contentsOf: source[range.location..<end])
                }
            }
            return String(decoding: output, as: UTF16.self)
        }
    }
}
