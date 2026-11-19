import Foundation
import Testing
@testable import MD2App
import MD2Core

@Suite(.serialized)
struct RegexFindProcessTests {
    @Test func workerRoundTripsUTF16AndSurfacesValidationErrors() async throws {
        let source = "😀e\u{301}\0猫 X"
        let pattern = #"(?<item>e\p{M})\u0000(猫)"#
        let ranges = try await RegexFindProcess.matches(of: pattern, in: source, caseSensitive: false, scope: nil)
        let expectedRange = NSRange(location: 2, length: 4)
        #expect(ranges == [expectedRange])
        let template = "$2\0${item}"
        try await RegexFindProcess.validateReplacement(template, for: pattern, caseSensitive: false)
        let edit = try #require(await RegexFindProcess.makeEdit(
            pattern: pattern, template: template, source: source, caseSensitive: false, scope: nil, target: expectedRange
        ))
        #expect(edit.range == expectedRange)
        #expect(Array(edit.replacement.utf16) == Array("猫\0e\u{301}".utf16))
        await #expect(throws: RegexSearch.Failure.invalidReplacement) {
            try await RegexFindProcess.validateReplacement("$3", for: pattern, caseSensitive: false)
        }
    }

    @Test func deadlineTerminatesWorkerAndNextRequestCanRun() async throws {
        let pattern = String(repeating: "(?=[a-z]*)", count: 400)
        let text = String(repeating: "a", count: 2_000_000)
        await #expect(throws: RegexSearch.Failure.limitExceeded) {
            try await RegexFindProcess.matches(
                of: pattern, in: text, caseSensitive: false, scope: nil, timeout: .milliseconds(30)
            )
        }
        try await assertNextRequestRuns()
    }

    @Test func cancellingRequestTerminatesWorkerAndNextRequestCanRun() async throws {
        let worker = Task {
            try await RegexFindProcess.matches(
                of: String(repeating: "(?=[a-z]*)", count: 400),
                in: String(repeating: "a", count: 2_000_000), caseSensitive: false, scope: nil
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
        try await assertNextRequestRuns()
    }

    private func assertNextRequestRuns() async throws {
        let matches = try await RegexFindProcess.matches(of: "b", in: "abc", caseSensitive: false, scope: nil)
        #expect(matches == [NSRange(location: 1, length: 1)])
    }
}
