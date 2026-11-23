import AppKit
import Foundation
import XCTest
import MD2Core
@testable import MD2App

/// Run small workloads in the normal test suite. The standalone script runs
/// the original sizes against the same app and renderer targets in release mode.
final class P1BenchmarkTests: XCTestCase {
    private static let mixedParagraph = "## 标题 Example\n\n这是客户端性能审查的测试段落。English words **bold** and `code`.\n\n- item one\n- item two\n\n"

    @MainActor
    func testWorkloads() async throws {
        let output = ProcessInfo.processInfo.environment["MD2_P1_BENCHMARK_OUTPUT"]
        let samples = output == nil ? 1 : 3
        let normalSizes = output == nil ? [1_000] : [10_000, 100_000, 500_000, 1_000_000]
        let bracketSizes = output == nil ? [1_000] : [1_000, 5_000, 10_000, 20_000]
        let renderer = MarkdownRenderer()
        _ = renderer.render("warm up")
        let warmup = NSTextView()
        warmup.string = Self.mixedParagraph
        MarkdownTextStyler.apply(to: warmup)

        let normalInputs = normalSizes.map { size in
            String(repeating: Self.mixedParagraph, count: size / Self.mixedParagraph.utf8.count)
        }
        let normal = normalInputs.map { content in
            renderAndStyle(content, renderer: renderer, samples: samples)
        }
        let adversarial = bracketSizes.map { size in
            renderAndStyle(String(repeating: "[", count: size), renderer: renderer, samples: samples)
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let real = try ["README.zh-CN.md", "Examples/Sample.md"].map { path in
            let content = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
            return renderAndStyle(content, renderer: renderer, samples: samples, file: path)
        }
        let edit = try normalInputs.map { try styleAfterEditing($0, samples: samples) }

        if let output {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            for (name, rows) in [("normal", normal), ("adversarial", adversarial), ("real", real), ("edit", edit)] {
                try (rows.joined(separator: "\n") + "\n").write(
                    to: directory.appendingPathComponent("\(name).log"), atomically: true, encoding: .utf8
                )
            }
        }
    }

    @MainActor
    private func renderAndStyle(
        _ content: String, renderer: MarkdownRenderer, samples: Int, file: String? = nil
    ) -> String {
        let view = NSTextView()
        view.string = content
        var renderTimes: [Double] = []
        var styleTimes: [Double] = []
        var htmlBytes = 0
        for _ in 0..<samples {
            let (result, renderMS) = timed { renderer.render(content) }
            let (_, styleMS) = timed { MarkdownTextStyler.apply(to: view) }
            XCTAssertFalse(result.body.isEmpty)
            XCTAssertNotNil(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil))
            renderTimes.append(renderMS)
            styleTimes.append(styleMS)
            htmlBytes = result.html.utf8.count
        }
        if let file {
            let times = zip(renderTimes, styleTimes).map { [$0, $1] }
            return "file=\(file) bytes=\(content.utf8.count) render_style_ms=\(times)"
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        return "bytes=\(content.utf8.count) lines=\(lines) render_ms=\(renderTimes) style_ms=\(styleTimes) html_bytes=\(htmlBytes)"
    }

    @MainActor
    private func styleAfterEditing(_ content: String, samples: Int) throws -> String {
        let view = NSTextView()
        view.string = content
        let storage = try XCTUnwrap(view.textStorage)
        MarkdownTextStyler.apply(to: view)
        var previous = MarkdownStylePlan(content)
        var planTimes: [Double] = []
        var applyTimes: [Double] = []
        var changedLengths: [Int] = []

        for _ in 0..<samples {
            let position = storage.length / 2
            storage.replaceCharacters(in: NSRange(location: position, length: 0), with: "x")
            let ((plan, range), planMS) = timed {
                let plan = MarkdownStylePlan(view.string)
                return (plan, plan.changedRange(from: previous))
            }
            XCTAssertTrue(NSLocationInRange(position, range))
            XCTAssertLessThanOrEqual(NSMaxRange(range), storage.length)
            let (_, applyMS) = timed { MarkdownTextStyler.apply(plan, range: range, to: view) }
            planTimes.append(planMS)
            applyTimes.append(applyMS)
            changedLengths.append(range.length)
            previous = plan
        }
        // Isolate the work normally performed by the background styling worker.
        return "bytes=\(content.utf8.count) background_plan_ms=\(planTimes) main_style_ms=\(applyTimes) changed_utf16=\(changedLengths)"
    }

    private func timed<Result>(_ operation: () -> Result) -> (Result, Double) {
        let start = ContinuousClock.now
        let result = operation()
        let duration = start.duration(to: .now).components
        return (result, Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
    }
}
