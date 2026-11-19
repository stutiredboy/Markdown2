import Foundation
import Testing
@testable import MD2Core

struct RegexSearchTests {
    @Test func caseOptionsUseICUSemantics() throws {
        let text = "café CAFE cafe Cafe"
        let matches = try RegexSearch.matches(of: "cafe", in: text)
        #expect(matches.map(\.range.location) == [5, 10, 15])
        let exact = try RegexSearch.matches(of: "cafe", in: text, caseSensitive: true)
        #expect(exact.map(\.range.location) == [10])
        #expect(try RegexSearch.matches(of: "", in: text).isEmpty)
    }

    @Test func extendedGraphemesAndUTF16Offsets() throws {
        let text = "😀👩‍💻e\u{301}\r\n猫"
        let ranges = try RegexSearch.matches(of: #"\X"#, in: text).map(\.range)
        #expect(ranges == [
            NSRange(location: 0, length: 2), NSRange(location: 2, length: 5),
            NSRange(location: 7, length: 2), NSRange(location: 9, length: 2),
            NSRange(location: 11, length: 1)
        ])
        #expect(try RegexSearch.matches(of: "👩|💻|e|\r|\n", in: text).isEmpty)
        #expect(try RegexSearch.matches(of: ".", in: text, scope: NSRange(location: 1, length: 1)).isEmpty)
        #expect(try RegexSearch.matches(of: ".", in: text, scope: NSRange(location: 1, length: .max)).isEmpty)
    }

    @Test func scopeKeepsDocumentAnchorAndLookAroundContext() throws {
        let text = "😀xcat!\ncat"
        let scope = NSRange(location: 3, length: 3)
        let captures = try RegexSearch.matches(
            of: #"(?<=(x))cat(?=!)"#, in: text, scope: scope, replacementTemplate: "$1-$0"
        )
        #expect(captures.map(\.range) == [scope])
        #expect(captures.map(\.replacement) == ["x-cat"])
        for pattern in ["^cat", "cat$", #"\bcat"#, "cat!"] {
            #expect(try RegexSearch.matches(of: pattern, in: text, scope: scope).isEmpty)
        }
        let lastLine = NSRange(location: 8, length: 3)
        #expect(try RegexSearch.matches(of: "(?m)^cat$", in: text, scope: lastLine).map(\.range) == [lastLine])
    }

    @Test func zeroLengthMatchesAdvanceAndRespectGraphemeBoundaries() throws {
        let text = "😀e\u{301}猫"
        let matches = try RegexSearch.matches(of: "(?:)", in: text, replacementTemplate: "x$0")
        #expect(matches.map(\.range) == [0, 2, 4, 5].map { NSRange(location: $0, length: 0) })
        #expect(matches.map(\.replacement) == ["x", "x", "x", "x"])
        let end = try RegexSearch.matches(of: "$", in: "")
        #expect(end.map(\.range) == [NSRange(location: 0, length: 0)])
        #expect(try RegexSearch.matches(of: "(?:)", in: text, scope: NSRange(location: 2, length: 0)).isEmpty)
    }

    @Test func matchesAdjacentToAnEmptyEndMatchStayOrdered() throws {
        let matches = try RegexSearch.matches(of: "a*", in: "aa", replacementTemplate: "[$0]")
        #expect(matches.map(\.range) == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 0)])
        #expect(matches.map(\.replacement) == ["[aa]", "[]"])
    }

    @Test func expandsNumberedNamedAndOptionalCapturesWithLiteralEscapes() throws {
        let pattern = #"(?<name>\p{L}+)(\d+)?"#
        let template = #"${name}|$2|$0|\$1|\\|$"#
        try RegexSearch.validateReplacement(template, for: pattern)
        let matches = try RegexSearch.matches(of: pattern, in: "猫7 魚", replacementTemplate: template)
        #expect(matches.map(\.replacement) == ["猫|7|猫7|$1|\\|$", "魚||魚|$1|\\|$"])
        let clusters = try RegexSearch.matches(of: #"(e)(\p{M})"#, in: "e\u{301}", replacementTemplate: "$2")
        #expect(clusters.map(\.replacement) == ["\u{301}"])
    }

    @Test func replacementCanExpandOnlyTheSelectedMatch() throws {
        let matches = try RegexSearch.matches(
            of: #"(\w+)"#, in: "one two", replacementTemplate: "<$1>",
            replacementTarget: NSRange(location: 4, length: 3)
        )
        #expect(matches.map(\.replacement) == [nil, "<two>"])
    }

    @Test func malformedPatternAndTemplateFailWithoutPartialResults() {
        #expect(throws: RegexSearch.Failure.invalidPattern) {
            try RegexSearch.matches(of: "(", in: "test")
        }
        for template in ["$2", "$99999999999999999999999", "${unknown}", "${", "${}"] {
            #expect(throws: RegexSearch.Failure.invalidReplacement) {
                try RegexSearch.validateReplacement(template, for: "(a)")
            }
            #expect(throws: RegexSearch.Failure.invalidReplacement) {
                try RegexSearch.matches(of: "(a)", in: "", replacementTemplate: template)
            }
        }
    }

    @Test func pathologicalBacktrackingStopsAndNextQueryWorks() throws {
        let text = "ok " + String(repeating: "a", count: 8_000) + "!"
        #expect(throws: RegexSearch.Failure.limitExceeded) {
            try RegexSearch.matches(of: "ok|(a+)+$", in: text)
        }
        #expect(try RegexSearch.matches(of: "ok", in: text).map(\.range) == [NSRange(location: 0, length: 2)])
    }

    @Test func inputAndOutputLimitsFailWithoutTruncation() {
        #expect(throws: RegexSearch.Failure.limitExceeded) {
            try RegexSearch.matches(of: String(repeating: "a", count: 4_097), in: "a")
        }
        #expect(throws: RegexSearch.Failure.limitExceeded) {
            try RegexSearch.matches(of: "missing", in: String(repeating: "a", count: 2_000_001))
        }
        #expect(throws: RegexSearch.Failure.limitExceeded) {
            try RegexSearch.matches(of: "a", in: String(repeating: "a", count: 20_001))
        }
        #expect(throws: RegexSearch.Failure.limitExceeded) {
            try RegexSearch.matches(
                of: "a+", in: String(repeating: "a", count: 2_000),
                replacementTemplate: String(repeating: "$0", count: 2_000)
            )
        }
    }

    @Test func cancelledWorkerReturnsCancellationInsteadOfMatches() async {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try RegexSearch.matches(of: "a", in: "abc")
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
    }
}
