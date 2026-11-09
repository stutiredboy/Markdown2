import Foundation
import XCTest
@testable import MD2Core

final class MarkdownNestingSafetyTests: XCTestCase {
    /// Keep a future stack-overflow regression in a child, on the same detached
    /// task stack used by preview rendering, rather than killing the test runner.
    func testDeepContainersInIsolatedProcess() async throws {
        let variable = "MD2_NESTING_SAFETY_FIXTURE"
        if let fixture = ProcessInfo.processInfo.environment[variable] {
            let parts = fixture.split(separator: ":")
            let depth = try XCTUnwrap(Int(parts[1]))
            let source = Self.source(kind: String(parts[0]), depth: depth)
            let document = await Task.detached {
                MarkdownRenderer().render(source, assetMode: .appScheme)
            }.value
            XCTAssertTrue(document.body.contains("markdown-source-fallback"), fixture)
            XCTAssertTrue(document.body.contains("BODY_AFTER_CONTAINER"), fixture)
            XCTAssertTrue(document.body.contains("&lt;script&gt;"), fixture)
            XCTAssertFalse(document.body.contains("<script>"), fixture)
            XCTAssertEqual(document.stats.lines, source.normalizedMarkdownLines.count)
            XCTAssertTrue(document.outline.isEmpty)
            print("MD2_NESTING_COMPLETED=\(fixture)")
            return
        }

        try Self.runIsolatedFixtures(variable: variable)
    }

    private static func runIsolatedFixtures(variable: String) throws {
        for kind in ["quote", "list", "mixed", "compact-list"] {
            for depth in [128, 512, 1_024] {
                let fixture = "\(kind):\(depth)"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["xctest", "-XCTest",
                    "MD2CoreTests.MarkdownNestingSafetyTests/testDeepContainersInIsolatedProcess",
                    Bundle(for: Self.self).bundlePath]
                var environment = ProcessInfo.processInfo.environment
                environment[variable] = fixture
                process.environment = environment
                let log = FileManager.default.temporaryDirectory.appendingPathComponent("md2-nesting-\(UUID()).log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let output = try FileHandle(forWritingTo: log)
                defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
                process.standardOutput = output
                process.standardError = output
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                try process.run()
                let completed = finished.wait(timeout: .now() + 30) == .success
                if !completed { process.terminate(); process.waitUntilExit() }
                let diagnostics = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                XCTAssertTrue(completed, "\(fixture) exceeded 30s: \(diagnostics)")
                XCTAssertEqual(process.terminationReason, .exit, "\(fixture): \(diagnostics)")
                XCTAssertEqual(process.terminationStatus, 0, "\(fixture): \(diagnostics)")
                XCTAssertTrue(diagnostics.contains("MD2_NESTING_COMPLETED=\(fixture)"), diagnostics)
            }
        }
    }

    func testWorkBudgetPreservesCompleteEscapedSource() {
        // Below the depth limit, but repeated metadata scans would amplify
        // this source beyond the shared traversal-work limit.
        let source = String(repeating: "> ", count: 40)
            + String(repeating: "wide content ", count: 40_000)
            + "<script>literal</script>\n\nBODY_AFTER_CONTAINER"
        let document = MarkdownRenderer().render(source, assetMode: .appScheme)
        XCTAssertTrue(document.body.contains("markdown-source-fallback"))
        XCTAssertTrue(document.body.contains("&lt;script&gt;literal&lt;/script&gt;"))
        XCTAssertTrue(document.body.contains("BODY_AFTER_CONTAINER"))
        XCTAssertEqual(document.stats.lines, 3)
    }

    func testNormalNestingAndNextRenderRemainStructured() {
        let renderer = MarkdownRenderer()
        _ = renderer.render(Self.source(kind: "quote", depth: 1_024), assetMode: .appScheme)
        let source = String(repeating: "> ", count: 12) + "**ordinary**\n\n# After"
        let document = renderer.render(source, assetMode: .appScheme)
        XCTAssertFalse(document.body.contains("markdown-source-fallback"))
        XCTAssertTrue(document.body.contains("<strong>ordinary</strong>"))
        XCTAssertEqual(document.outline.map(\.title), ["After"])
    }

    private static func source(kind: String, depth: Int) -> String {
        let payload = "<script>literal</script> [link][hidden]"
        let nested: String
        switch kind {
        case "compact-list":
            // Metadata treats the remainder as item text; reference collection
            // recursively inspects it. Exercise that pass independently.
            nested = String(repeating: "- ", count: depth) + payload
        case "list":
            nested = (0..<depth).map { String(repeating: "  ", count: $0) + "- item" }
                .joined(separator: "\n") + "\n" + String(repeating: "  ", count: depth) + payload
        case "mixed":
            // List continuations contain quotes, whose body then contains
            // another list. All paths must debit the same active depth.
            nested = (0..<depth).map { String(repeating: "  > ", count: $0) + "- item" }
                .joined(separator: "\n") + "\n" + String(repeating: "  > ", count: depth) + payload
        default:
            nested = String(repeating: "> ", count: depth) + payload
        }
        return nested + "\n\n# BODY_AFTER_CONTAINER\n\n[hidden]: https://example.com"
    }
}
